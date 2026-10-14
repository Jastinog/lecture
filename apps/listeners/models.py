"""The people listening in the app. No sign-up: the app makes up an id, keeps
it in the phone's iCloud Keychain, and registers it once for a token. Not
`users.User`, which are the admins."""

import hashlib
import secrets
from datetime import timedelta

from django.db import models
from django.utils import timezone

# How stale `last_seen` may get before a request writes it again.
LAST_SEEN_PRECISION = timedelta(hours=1)


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Listener(models.Model):
    """The app's user. Its id is a name, not a secret: requests prove who they
    are with the token issued at registration, of which only the hash is kept."""

    id = models.UUIDField(primary_key=True)
    token_hash = models.CharField(max_length=64, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen = models.DateTimeField(default=timezone.now)
    platform = models.CharField(max_length=32, blank=True)
    app_version = models.CharField(max_length=32, blank=True)

    # DRF's `request.user`: permissions and throttles ask this of it.
    is_authenticated = True

    def __str__(self):
        return str(self.id)

    @classmethod
    def register(cls, pk, **details):
        """A new listener and its token, the one time the token is seen."""
        token = secrets.token_urlsafe(32)
        return cls.objects.create(pk=pk, token_hash=hash_token(token), **details), token

    def touch(self):
        """Marks the listener seen now, at most once per `LAST_SEEN_PRECISION`."""
        now = timezone.now()
        if now - self.last_seen >= LAST_SEEN_PRECISION:
            self.last_seen = now
            Listener.objects.filter(pk=self.pk).update(last_seen=now)


class ListenerPlay(models.Model):
    """A lecture a listener started on a day: a topic's plays count each
    listener once per lecture and day, however often they come back to it."""

    listener = models.ForeignKey(
        Listener, on_delete=models.CASCADE, related_name="plays"
    )
    lecture = models.ForeignKey(
        "lecture.Lecture", on_delete=models.CASCADE, related_name="+"
    )
    day = models.DateField()

    def __str__(self):
        return f"{self.listener} - {self.lecture_id} - {self.day}"

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "lecture", "day"], name="listener_play_per_day"
            )
        ]
