"""Syncing what the app keeps on the phone. Each kind is a table of records
keyed by topic; the newest `updated_at` wins, whichever device wrote it."""

import json
import logging

from rest_framework import serializers

from .models import HistoryEntry, Progress

logger = logging.getLogger(__name__)

# Records of one kind a request may send: the phone keeps 500 positions.
MAX_RECORDS = 1000
# A topic card is a title, a lecturer and a description; anything near this
# isn't one.
MAX_CARD_BYTES = 32 * 1024


class SyncedSerializer(serializers.Serializer):
    topic_id = serializers.IntegerField(min_value=-(2**31), max_value=2**31 - 1)
    updated_at = serializers.FloatField(min_value=0)
    deleted = serializers.BooleanField(default=False)


class ProgressSerializer(SyncedSerializer):
    lecture_id = serializers.IntegerField(allow_null=True, required=False, default=None)
    index = serializers.IntegerField(min_value=0, max_value=2**31 - 1, default=0)
    time = serializers.FloatField(min_value=0, default=0)
    fraction = serializers.FloatField(min_value=0, max_value=1, default=0)


class HistorySerializer(SyncedSerializer):
    topic = serializers.JSONField(allow_null=True, required=False, default=None)

    def validate_topic(self, card):
        if card is not None and (
            not isinstance(card, dict) or len(json.dumps(card)) > MAX_CARD_BYTES
        ):
            raise serializers.ValidationError("Not a topic card.")
        return card


# Kind (as the app names it) → its table and the fields of a record.
KINDS = {
    "progress": (Progress, ProgressSerializer),
    "history": (HistoryEntry, HistorySerializer),
}


def apply_changes(listener, kind, records):
    """Writes the `records` of `kind` newer than what's kept, each under a new
    revision of `listener` (locked by the caller). The topic ids written."""
    model, serializer = KINDS[kind]
    incoming = {}
    for record in records:
        data = serializer(data=record)
        if not data.is_valid():
            # One bad record mustn't keep the rest from syncing.
            logger.warning("Skipped a %s record: %s", kind, data.errors)
            continue
        new = data.validated_data
        held = incoming.get(new["topic_id"])
        if held is None or new["updated_at"] > held["updated_at"]:
            incoming[new["topic_id"]] = new
    kept = dict(
        model.objects.filter(listener=listener, topic_id__in=incoming).values_list(
            "topic_id", "updated_at"
        )
    )
    winners = []
    for topic_id, new in incoming.items():
        if topic_id in kept and kept[topic_id] >= new["updated_at"]:
            continue
        listener.revision += 1
        winners.append(model(listener=listener, revision=listener.revision, **new))
    fields = [f for f in serializer().fields if f != "topic_id"] + ["revision"]
    model.objects.bulk_create(
        winners,
        update_conflicts=True,
        unique_fields=["listener", "topic_id"],
        update_fields=fields,
    )
    return {w.topic_id for w in winners}


def changes_since(listener, kind, revision, exclude=()):
    """The records of `kind` written after `revision`, but those in `exclude`."""
    model, serializer = KINDS[kind]
    records = (
        model.objects.filter(listener=listener, revision__gt=revision)
        .exclude(topic_id__in=exclude)
        .order_by("revision")
    )
    return serializer(records, many=True).data
