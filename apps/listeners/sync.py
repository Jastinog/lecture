"""Syncing what the app keeps on the phone. Each kind (`KINDS`) is a table of
records under a key of its own; the newest `updated_at` wins, whichever device
wrote it. The calendar (`ListeningDay`) adds up instead: devices send the time
heard since their last sync.

Each listener holds a bounded number of records of a kind, so a client can't
fill the database: past the limit the oldest tombstones make room, and with
none left new keys are dropped."""

import json
import logging
from dataclasses import dataclass

from rest_framework import serializers

from .models import (
    Bookmark,
    HistoryEntry,
    LanguageChoice,
    ListeningDay,
    Pin,
    Progress,
    Setting,
    ShelfItem,
    TopicRate,
)

logger = logging.getLogger(__name__)

# Records of one kind a request may send.
MAX_RECORDS = 1000
# A topic card is a title, a lecturer and a description; anything near this
# isn't one.
MAX_CARD_BYTES = 16 * 1024
INT32 = {"min_value": -(2**31), "max_value": 2**31 - 1}
# The longest a lecture is heard in one sync's increment: a day.
MAX_SECONDS = 24 * 60 * 60
# Stretches of listening a lecture keeps a day, the latest.
MAX_SESSIONS = 100
# Stretches closer than this, in seconds, are one.
SESSION_GAP = 120


class CardField(serializers.JSONField):
    """A topic card as the app encodes it, kept as is."""

    def to_internal_value(self, data):
        card = super().to_internal_value(data)
        if card is not None and (
            not isinstance(card, dict) or len(json.dumps(card)) > MAX_CARD_BYTES
        ):
            raise serializers.ValidationError("Not a topic card.")
        return card


class SyncedSerializer(serializers.Serializer):
    updated_at = serializers.FloatField(min_value=0)
    deleted = serializers.BooleanField(default=False)


class ProgressSerializer(SyncedSerializer):
    topic_id = serializers.IntegerField(**INT32)
    lecture_id = serializers.IntegerField(allow_null=True, required=False, default=None)
    index = serializers.IntegerField(min_value=0, max_value=2**31 - 1, default=0)
    time = serializers.FloatField(min_value=0, default=0)
    fraction = serializers.FloatField(min_value=0, max_value=1, default=0)


class HistorySerializer(SyncedSerializer):
    topic_id = serializers.IntegerField(**INT32)
    topic = CardField(allow_null=True, required=False, default=None)


class BookmarkSerializer(SyncedSerializer):
    id = serializers.UUIDField(source="bookmark_id")
    topic_id = serializers.IntegerField(**INT32, default=0)
    lecture_id = serializers.IntegerField(allow_null=True, required=False, default=None)
    index = serializers.IntegerField(min_value=0, max_value=2**31 - 1, default=0)
    time = serializers.FloatField(min_value=0, default=0)
    chapter_title = serializers.CharField(max_length=500, allow_blank=True, default="")
    note = serializers.CharField(
        max_length=10_000, allow_blank=True, default="", trim_whitespace=False
    )
    created_at = serializers.FloatField(min_value=0, default=0)


class ShelfSerializer(SyncedSerializer):
    topic_id = serializers.IntegerField(**INT32)
    status = serializers.ChoiceField(ShelfItem.STATUSES, allow_blank=True, default="")
    topic = CardField(allow_null=True, required=False, default=None)
    added_at = serializers.FloatField(min_value=0, default=0)


class RateSerializer(SyncedSerializer):
    topic_id = serializers.IntegerField(**INT32)
    rate = serializers.FloatField(min_value=0.5, max_value=3, default=1)


class PinSerializer(SyncedSerializer):
    lecturer_id = serializers.IntegerField(**INT32)
    name = serializers.CharField(max_length=200, allow_blank=True, default="")
    photo_url = serializers.URLField(max_length=500, allow_blank=True, default="")


class LanguageSerializer(SyncedSerializer):
    lecturer_id = serializers.IntegerField(**INT32)
    language = serializers.CharField(max_length=16, allow_blank=True, default="")


# Setting name → the field checking its value.
SETTINGS = {
    "default_rate": serializers.FloatField(min_value=0.5, max_value=3),
}


class SettingSerializer(SyncedSerializer):
    name = serializers.ChoiceField(list(SETTINGS))
    value = serializers.JSONField(allow_null=True, required=False, default=None)

    def validate(self, data):
        if not data["deleted"]:
            try:
                data["value"] = SETTINGS[data["name"]].run_validation(data["value"])
            except serializers.ValidationError as error:
                raise serializers.ValidationError({"value": error.detail})
        return data


@dataclass(frozen=True)
class Kind:
    model: type
    serializer: type
    # The model field records are keyed by.
    key: str
    # Records a listener may hold, tombstones included.
    limit: int


# Kind (as the app names it) → its table.
KINDS = {
    "progress": Kind(Progress, ProgressSerializer, "topic_id", 2000),
    "history": Kind(HistoryEntry, HistorySerializer, "topic_id", 500),
    "bookmarks": Kind(Bookmark, BookmarkSerializer, "bookmark_id", 5000),
    "shelf": Kind(ShelfItem, ShelfSerializer, "topic_id", 2000),
    "rates": Kind(TopicRate, RateSerializer, "topic_id", 2000),
    "pins": Kind(Pin, PinSerializer, "lecturer_id", 500),
    "languages": Kind(LanguageChoice, LanguageSerializer, "lecturer_id", 500),
    "settings": Kind(Setting, SettingSerializer, "name", len(SETTINGS)),
}


def valid(serializer, records, kind):
    """The records that pass `serializer`: one bad record mustn't keep the
    rest from syncing."""
    for record in records:
        data = serializer(data=record)
        if data.is_valid():
            yield data.validated_data
        else:
            logger.warning("Skipped a %s record: %s", kind, data.errors)


def make_room(queryset, held, wanted, limit):
    """How many of `wanted` new records fit next to the `held` ones, after
    dropping the oldest tombstones in `queryset` to make room."""
    over = held + wanted - limit
    if over > 0:
        oldest = queryset.filter(deleted=True).order_by("updated_at")
        dropped, _ = queryset.filter(
            pk__in=list(oldest.values_list("pk", flat=True)[:over])
        ).delete()
        held -= dropped
    return max(0, min(wanted, limit - held))


def apply_changes(listener, kind, records):
    """Writes the `records` of `kind` newer than what's kept, each under a new
    revision of `listener` (locked by the caller). The keys written."""
    spec = KINDS[kind]
    incoming = {}
    for new in valid(spec.serializer, records, kind):
        held = incoming.get(new[spec.key])
        if held is None or new["updated_at"] > held["updated_at"]:
            incoming[new[spec.key]] = new
    if not incoming:
        return set()
    mine = spec.model.objects.filter(listener=listener)
    kept = dict(
        mine.filter(**{f"{spec.key}__in": incoming}).values_list(spec.key, "updated_at")
    )
    fresh = [key for key in incoming if key not in kept]
    room = make_room(mine, mine.count(), len(fresh), spec.limit)
    if room < len(fresh):
        logger.warning(
            "Dropped %d new %s records: over the limit", len(fresh) - room, kind
        )
        # The newest ones get the room.
        fresh.sort(key=lambda key: incoming[key]["updated_at"], reverse=True)
        for key in fresh[room:]:
            del incoming[key]
    winners = []
    for key, new in incoming.items():
        if key in kept and kept[key] >= new["updated_at"]:
            continue
        listener.revision += 1
        winners.append(spec.model(listener=listener, revision=listener.revision, **new))
    fields = [
        f.source for f in spec.serializer().fields.values() if f.source != spec.key
    ]
    spec.model.objects.bulk_create(
        winners,
        update_conflicts=True,
        unique_fields=["listener", spec.key],
        update_fields=fields + ["revision"],
    )
    return {getattr(w, spec.key) for w in winners}


def changes_since(listener, kind, revision, exclude=()):
    """The records of `kind` written after `revision`, but those in `exclude`."""
    spec = KINDS[kind]
    records = (
        spec.model.objects.filter(listener=listener, revision__gt=revision)
        .exclude(**{f"{spec.key}__in": exclude})
        .order_by("revision")
    )
    return spec.serializer(records, many=True).data


# The calendar: time heard adds up.

LISTENING_LIMIT = 20_000


class ListeningSerializer(serializers.Serializer):
    """In a request, `seconds` is the time heard since the last sync, and
    `reset` starts the day over from it; in an answer, the day's total."""

    day = serializers.DateField()
    topic_id = serializers.IntegerField(**INT32)
    lecture_id = serializers.IntegerField(**INT32)
    seconds = serializers.FloatField(min_value=0, max_value=MAX_SECONDS, default=0)
    last_heard = serializers.FloatField(min_value=0, default=0)
    # [start, end] pairs: in a request, those heard since the last sync.
    sessions = serializers.ListField(
        child=serializers.ListField(
            child=serializers.FloatField(min_value=0), min_length=2, max_length=2
        ),
        max_length=MAX_SESSIONS,
        default=list,
    )
    topic = CardField(allow_null=True, required=False, default=None)
    lecture_title = serializers.CharField(max_length=500, allow_blank=True, default="")
    reset = serializers.BooleanField(default=False, write_only=True)
    deleted = serializers.BooleanField(read_only=True)


def merge_sessions(*lists):
    """The [start, end] stretches of `lists` as one, sorted, those that meet
    or nearly do joined, the latest `MAX_SESSIONS` kept."""
    merged = []
    for start, end in sorted((min(s), max(s)) for spans in lists for s in spans):
        if merged and start - merged[-1][1] <= SESSION_GAP:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged[-MAX_SESSIONS:]


def listening_key(record):
    return record["day"], record["topic_id"], record["lecture_id"]


def apply_listening(listener, records):
    """Adds the time in `records` to the days kept (or starts them over, for a
    reset), each under a new revision of `listener` (locked by the caller)."""
    incoming = {}
    for new in valid(ListeningSerializer, records, "listening"):
        key = listening_key(new)
        held = incoming.get(key)
        # A reset drops what came before it in the request.
        if held is None or new["reset"]:
            incoming[key] = dict(new)
        else:
            held["seconds"] += new["seconds"]
            held["sessions"] = merge_sessions(held["sessions"], new["sessions"])
            if new["last_heard"] >= held["last_heard"]:
                held.update(
                    last_heard=new["last_heard"],
                    topic=new["topic"],
                    lecture_title=new["lecture_title"],
                )
    if not incoming:
        return
    mine = ListeningDay.objects.filter(listener=listener)
    kept = {
        listening_key(row.__dict__): row
        for row in mine.filter(day__in={key[0] for key in incoming})
    }
    fresh = [key for key in incoming if key not in kept]
    room = make_room(mine, mine.count(), len(fresh), LISTENING_LIMIT)
    for key in sorted(fresh, key=lambda key: key[0], reverse=True)[room:]:
        del incoming[key]
    rows = []
    for key, new in incoming.items():
        row = kept.get(key) or ListeningDay(
            listener=listener, day=key[0], topic_id=key[1], lecture_id=key[2]
        )
        start_over = new["reset"] or row.deleted
        row.seconds = new["seconds"] if start_over else row.seconds + new["seconds"]
        row.sessions = merge_sessions(
            [] if start_over else row.sessions, new["sessions"]
        )
        if new["last_heard"] >= row.last_heard or new["reset"]:
            row.last_heard = new["last_heard"]
            row.topic = new["topic"] if new["topic"] is not None else row.topic
            row.lecture_title = new["lecture_title"] or row.lecture_title
        row.deleted = row.seconds == 0
        listener.revision += 1
        row.revision = listener.revision
        rows.append(row)
    ListeningDay.objects.bulk_create(
        rows,
        update_conflicts=True,
        unique_fields=["listener", "day", "topic_id", "lecture_id"],
        update_fields=[
            "seconds",
            "last_heard",
            "sessions",
            "topic",
            "lecture_title",
            "deleted",
            "revision",
        ],
    )


def listening_since(listener, revision):
    """The days changed after `revision`, with their totals: the device that
    sent the time gets them too, as other devices may have added to it."""
    rows = ListeningDay.objects.filter(
        listener=listener, revision__gt=revision
    ).order_by("revision")
    return ListeningSerializer(rows, many=True).data
