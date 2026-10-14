"""Listeners: the app registers the id it made up and gets the token its
requests carry from then on, then syncs what it keeps on the phone."""

from django.db import IntegrityError, transaction
from rest_framework import serializers, status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from apps.listeners.authentication import ListenerTokenAuthentication
from apps.listeners.models import Listener
from apps.listeners.sync import (
    KINDS,
    MAX_RECORDS,
    apply_changes,
    apply_listening,
    changes_since,
    listening_since,
)
from apps.listeners.throttling import ListenerRateThrottle


class RegistrationThrottle(AnonRateThrottle):
    scope = "listeners"


class RegistrationSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    platform = serializers.CharField(max_length=32, required=False, default="")
    app_version = serializers.CharField(max_length=32, required=False, default="")


class ListenerListView(APIView):
    """`POST {"id": uuid, "platform", "app_version"}` → 201 `{"token"}`. An id
    that's taken is a 409, never a new token: the id isn't a secret, and
    whoever knows it would otherwise take over the listener. The app then
    makes up another one."""

    throttle_classes = [RegistrationThrottle]

    def post(self, request):
        data = RegistrationSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        details = data.validated_data
        pk = details.pop("id")
        try:
            with transaction.atomic():
                _, token = Listener.register(pk, **details)
        except IntegrityError:
            return Response(
                {"detail": "This id is taken."}, status=status.HTTP_409_CONFLICT
            )
        return Response({"token": token}, status=status.HTTP_201_CREATED)


class SyncThrottle(ListenerRateThrottle):
    scope = "sync"


class SyncRequestSerializer(serializers.Serializer):
    since = serializers.IntegerField(min_value=0, default=0)
    changes = serializers.DictField(
        child=serializers.ListField(
            child=serializers.DictField(), max_length=MAX_RECORDS
        ),
        default=dict,
    )


class SyncView(APIView):
    """`POST {"since": cursor, "changes": {kind: [record, …]}}` →
    `{"cursor", "changes": {kind: [record, …]}}`, kinds as in `KINDS` plus
    "listening". Keeps the records sent that are newer than the server's, and
    answers with every record written since `since` by other devices (all of
    them for 0); the calendar adds up the time sent and answers with the
    totals. The app sends the cursor it gets back next time."""

    authentication_classes = [ListenerTokenAuthentication]
    permission_classes = [IsAuthenticated]
    throttle_classes = [SyncThrottle]

    def post(self, request):
        data = SyncRequestSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        since, changes = data.validated_data["since"], data.validated_data["changes"]
        with transaction.atomic():
            listener = Listener.objects.select_for_update().get(pk=request.user.pk)
            # Ahead of the server (restored from a backup): start over.
            if since > listener.revision:
                since = 0
            written = {
                kind: apply_changes(listener, kind, changes.get(kind, []))
                for kind in KINDS
            }
            apply_listening(listener, changes.get("listening", []))
            listener.save(update_fields=["revision"])
            answer = {
                kind: changes_since(listener, kind, since, exclude=written[kind])
                for kind in KINDS
            }
            answer["listening"] = listening_since(listener, since)
        return Response({"cursor": listener.revision, "changes": answer})
