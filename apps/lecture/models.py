import uuid
import os
import hashlib
from django.db import models
from django.db.models.signals import post_delete
from django.dispatch import receiver
from django.conf import settings



def get_lecturers_folder():
    """Get lecturers folder name based on environment"""
    env = getattr(settings, "ENVIRONMENT", "dev")
    return "lecturers_dev" if env != "prod" else "lecturers"


def lecture_upload_path(instance, filename):
    """Generate nested upload path for lecture files using IDs"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.topic.lecturer.id}/topics/{instance.topic.id}/lectures/{short_name}"


def lecturer_photo_path(instance, filename):
    """Upload path for lecturer photos using ID"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.id}/photo/{short_name}"


def topic_cover_path(instance, filename):
    """Upload path for topic covers using IDs"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.lecturer.id}/topics/{instance.id}/cover/{short_name}"


class Language(models.Model):
    code = models.CharField(
        max_length=10, unique=True, help_text="Language code (e.g., 'en', 'ru')"
    )
    name = models.CharField(
        max_length=100, help_text="Language name (e.g., 'English', 'Russian')"
    )
    native_name = models.CharField(
        max_length=100, help_text="Native language name (e.g., 'English', 'Русский')"
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.native_name} ({self.code})"

    class Meta:
        ordering = ["name"]


class TopicGroup(models.Model):
    name = models.CharField(
        max_length=100,
        unique=True,
        help_text="Group name (e.g., 'Lectures', 'Kirtans', 'Conversations')",
    )
    code = models.CharField(
        max_length=50,
        unique=True,
        help_text="Group code (e.g., 'lectures', 'kirtans', 'conversations')",
    )
    description = models.TextField(
        blank=True, help_text="Description of the topic group"
    )
    order = models.PositiveIntegerField(
        default=0, help_text="Order for displaying groups"
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    class Meta:
        ordering = ["order", "name"]


class Lecturer(models.Model):
    LEVEL_CHOICES = [
        (1, "Founder-Acharya"),
        (2, "Direct Disciple"),
        (3, "Grand Disciple"),
    ]

    code = models.CharField(max_length=255, unique=True)
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    photo = models.ImageField(upload_to=lecturer_photo_path, blank=True, null=True)
    order = models.PositiveIntegerField(
        default=0, help_text="Order for displaying lecturers"
    )
    level = models.PositiveSmallIntegerField(
        choices=LEVEL_CHOICES,
        default=2,
        help_text="Spiritual hierarchy level: 1=Founder-Acharya, 2=Direct Disciple, 3=Grand Disciple",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    def get_level_display_with_icon(self):
        """Return level display with appropriate icon"""
        level_icons = {
            1: "👑",  # Founder
            2: "🙏",  # Direct disciple
            3: "📿",  # Grand disciple
        }
        return f"{level_icons.get(self.level, '')} {self.get_level_display()}"

    class Meta:
        ordering = ["level", "order", "name"]
        unique_together = ["order"]
        indexes = [
            models.Index(fields=["level", "order"]),
        ]


class Topic(models.Model):
    lecturer = models.ForeignKey(
        Lecturer, on_delete=models.CASCADE, related_name="topics"
    )
    code = models.CharField(max_length=255)
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=topic_cover_path, blank=True, null=True)
    group = models.ForeignKey(
        TopicGroup,
        on_delete=models.PROTECT,
        related_name="topics",
        help_text="Group this topic belongs to",
    )
    languages = models.ManyToManyField(
        Language,
        related_name="topics",
        blank=True,
        help_text="Languages of this topic's lectures, kept in sync from them",
    )
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

    def sync_languages(self):
        """Set the topic's languages to those its lectures are in."""
        self.languages.set(Language.objects.filter(lectures__topic=self).distinct())

    def get_languages_display(self):
        """Return comma-separated list of language names"""
        return ", ".join(self.languages.values_list("native_name", flat=True))

    class Meta:
        ordering = ["lecturer", "group", "order"]
        unique_together = ["lecturer", "order", "code"]
        indexes = [
            models.Index(fields=["lecturer", "group"]),
            models.Index(fields=["group"]),
        ]


class Lecture(models.Model):
    topic = models.ForeignKey(Topic, on_delete=models.CASCADE, related_name="lectures")
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    audio_file = models.FileField(upload_to=lecture_upload_path)
    language = models.ForeignKey(
        Language,
        on_delete=models.PROTECT,
        related_name="lectures",
        help_text="Language of this lecture",
    )
    file_size = models.BigIntegerField(null=True, blank=True)
    duration = models.IntegerField(null=True, blank=True)
    order = models.PositiveIntegerField()
    year = models.PositiveIntegerField(
        null=True, blank=True, help_text="Year of the lecture"
    )
    event = models.CharField(
        max_length=255, blank=True, help_text="Event or occasion of the lecture"
    )
    file_hash = models.CharField(
        max_length=64,
        blank=True,
        help_text="SHA256 hash of original filename for duplicate detection",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.topic.title} - {self.title} ({self.language.code})"

    class Meta:
        # One order across the topic, whatever each lecture's language, so a
        # mixed topic plays in its own sequence.
        ordering = ["topic", "order"]
        unique_together = ["topic", "order"]
        indexes = [
            models.Index(fields=["topic", "language", "file_hash"]),
            models.Index(fields=["language"]),
        ]

    def save(self, *args, **kwargs):
        # Re-sync the topics' languages: this one, and the one it left if moved.
        previous = (
            Lecture.objects.filter(pk=self.pk).values_list("topic_id", flat=True).first()
            if self.pk
            else None
        )
        super().save(*args, **kwargs)
        sync_topics_languages({self.topic_id, previous})

    @property
    def file_size_mb(self):
        if self.file_size:
            return round(self.file_size / (1024 * 1024), 1)
        return 0.0

    @staticmethod
    def generate_file_hash(filename):
        """Generate SHA256 hash from filename"""
        return hashlib.sha256(filename.encode("utf-8")).hexdigest()


def set_lectures_language(lectures, language):
    """Puts every lecture in the queryset in `language` with one update, then
    re-syncs the languages of the topics they're in. Returns how many changed."""
    topic_ids = set(lectures.values_list("topic_id", flat=True))
    changed = lectures.exclude(language=language).update(language=language)
    sync_topics_languages(topic_ids)
    return changed


# A topic's languages follow its lectures: saving (Lecture.save) or deleting a
# lecture re-syncs the topics it touched. Bulk queryset writes skip both, so
# code using them calls sync_topics_languages itself (or goes through
# set_lectures_language).


def sync_topics_languages(topic_ids):
    """Re-syncs the languages of the topics with these ids that still exist."""
    for topic in Topic.objects.filter(pk__in=set(topic_ids) - {None}):
        topic.sync_languages()


@receiver(post_delete, sender=Lecture)
def sync_topic_languages_on_delete(sender, instance, **kwargs):
    # Sent for queryset and cascade deletes too, which skip Lecture.delete();
    # when the topic itself is going, it's gone already and nothing syncs.
    sync_topics_languages({instance.topic_id})
