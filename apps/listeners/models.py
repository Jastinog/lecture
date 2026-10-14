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
    # Counts the listener's synced writes; each record keeps the count it was
    # written at, so a device asks for what changed after the last one it saw.
    revision = models.BigIntegerField(default=0)

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


class Synced(models.Model):
    """A record the app keeps on the phone and syncs, under a key of its own
    kind (`sync.KINDS`): a topic (a selection's negative id included, so no
    foreign key), a lecturer, a bookmark. The newest `updated_at` wins; a
    removal stays as a tombstone (`deleted`), so it reaches the listener's
    other devices."""

    listener = models.ForeignKey(Listener, on_delete=models.CASCADE, related_name="+")
    # The phone's clock, epoch seconds.
    updated_at = models.FloatField()
    deleted = models.BooleanField(default=False)
    revision = models.BigIntegerField()

    class Meta:
        abstract = True


class TopicSynced(Synced):
    topic_id = models.IntegerField()

    class Meta:
        abstract = True


class Progress(TopicSynced):
    """Where the listener is in a topic."""

    lecture_id = models.IntegerField(null=True, blank=True)
    index = models.PositiveIntegerField(default=0)
    time = models.FloatField(default=0)
    fraction = models.FloatField(default=0)

    class Meta:
        verbose_name_plural = "progress"
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "topic_id"], name="progress_per_topic"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class HistoryEntry(TopicSynced):
    """A topic in the listener's history, with its list card as the app last
    showed it, so the history draws without asking for each topic."""

    topic = models.JSONField(null=True, blank=True)

    class Meta:
        verbose_name_plural = "history"
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "topic_id"], name="history_per_topic"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class Bookmark(Synced):
    """A saved moment in a topic, with its note. Keyed by the id the app gave
    it, unique per listener only: another listener's id is no way in."""

    bookmark_id = models.UUIDField()
    topic_id = models.IntegerField(default=0)
    lecture_id = models.IntegerField(null=True, blank=True)
    index = models.PositiveIntegerField(default=0)
    time = models.FloatField(default=0)
    chapter_title = models.CharField(max_length=500, blank=True)
    note = models.TextField(blank=True)
    created_at = models.FloatField(default=0)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "bookmark_id"], name="bookmark_per_id"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class ShelfItem(TopicSynced):
    """A topic on the listener's shelf, with its status and card."""

    STATUSES = ["want", "listening", "finished", "onHold"]

    status = models.CharField(max_length=16, blank=True)
    topic = models.JSONField(null=True, blank=True)
    added_at = models.FloatField(default=0)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "topic_id"], name="shelf_per_topic"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class TopicRate(TopicSynced):
    """A topic's own playback speed; a tombstone goes back to the default."""

    rate = models.FloatField(default=1)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "topic_id"], name="rate_per_topic"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class Pin(Synced):
    """A lecturer the listener pinned, with what the pin shows."""

    lecturer_id = models.IntegerField()
    name = models.CharField(max_length=200, blank=True)
    photo_url = models.URLField(max_length=500, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "lecturer_id"], name="pin_per_lecturer"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class LanguageChoice(Synced):
    """The language a lecturer's lectures are narrowed to; a tombstone is
    every language."""

    lecturer_id = models.IntegerField()
    language = models.CharField(max_length=16, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "lecturer_id"], name="language_per_lecturer"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class Setting(Synced):
    """One of the listener's settings (`sync.SETTINGS`), by name."""

    name = models.CharField(max_length=32)
    value = models.JSONField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "name"], name="setting_per_name"
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]


class ListeningDay(models.Model):
    """Time spent on a lecture on a day, for the calendar. Devices send what
    they heard since they last synced, which adds up; a reset (the history
    cleared) starts the day over from what comes with it."""

    listener = models.ForeignKey(Listener, on_delete=models.CASCADE, related_name="+")
    # The phone's calendar day.
    day = models.DateField()
    topic_id = models.IntegerField()
    lecture_id = models.IntegerField()
    seconds = models.FloatField(default=0)
    # Epoch seconds.
    last_heard = models.FloatField(default=0)
    topic = models.JSONField(null=True, blank=True)
    lecture_title = models.CharField(max_length=500, blank=True)
    # Cleared and nothing heard since.
    deleted = models.BooleanField(default=False)
    revision = models.BigIntegerField()

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["listener", "day", "topic_id", "lecture_id"],
                name="listening_per_lecture_and_day",
            )
        ]
        indexes = [models.Index(fields=["listener", "revision"])]
