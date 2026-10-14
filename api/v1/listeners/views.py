"""Listeners: the app registers the id it made up and gets the token its
requests carry from then on."""

from django.db import IntegrityError, transaction
from rest_framework import serializers, status
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from apps.listeners.models import Listener


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
