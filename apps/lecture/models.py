import uuid
import os
import hashlib
from django.db import models
from django.core.exceptions import ValidationError
from django.conf import settings

from apps.users.models import User


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
        Language, related_name="topics", help_text="Languages available in this topic"
    )
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

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

    def clean(self):
        """Validate that lecture language is available in topic"""
        if self.language and self.topic:
            if not self.topic.languages.filter(pk=self.language.pk).exists():
                raise ValidationError(
                    f"Language '{self.language}' is not available in topic '{self.topic.title}'"
                )

    class Meta:
        ordering = ["topic", "language", "order"]
        unique_together = ["topic", "order", "language"]
        indexes = [
            models.Index(fields=["topic", "language", "file_hash"]),
            models.Index(fields=["language"]),
        ]

    @property
    def file_size_mb(self):
        if self.file_size:
            return round(self.file_size / (1024 * 1024), 1)
        return 0.0

    @staticmethod
    def generate_file_hash(filename):
        """Generate SHA256 hash from filename"""
        return hashlib.sha256(filename.encode("utf-8")).hexdigest()


class LectureProgress(models.Model):
    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="lecture_progress"
    )
    lecture = models.ForeignKey(
        Lecture, on_delete=models.CASCADE, related_name="progress_records"
    )
    current_time = models.FloatField(
        default=0.0, help_text="Current playback position in seconds"
    )
    completed = models.BooleanField(
        default=False, help_text="Whether lecture was fully listened to"
    )
    listen_count = models.PositiveIntegerField(
        default=0, help_text="Number of times this lecture was played"
    )
    last_listened = models.DateTimeField(auto_now=True)
    updated_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ["user", "lecture"]
        indexes = [
            models.Index(fields=["user", "lecture"]),
            models.Index(fields=["user", "completed"]),
            models.Index(fields=["updated_at"]),
        ]

    def __str__(self):
        return f"{self.user.email} - {self.lecture.title} ({self.current_time}s)"

    @property
    def progress_percentage(self):
        """Calculate progress percentage if lecture has duration"""
        if hasattr(self.lecture, "duration") and self.lecture.duration > 0:
            return min(100, (self.current_time / self.lecture.duration) * 100)
        return 60


class CurrentLecture(models.Model):
    """Track the current playing lecture for each user per topic"""

    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="current_lectures"
    )
    topic = models.ForeignKey(
        Topic, on_delete=models.CASCADE, related_name="current_listeners"
    )
    lecture = models.ForeignKey(
        Lecture, on_delete=models.CASCADE, related_name="current_players"
    )
    updated_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ["user", "topic"]
        indexes = [
            models.Index(fields=["user", "topic"]),
        ]

    def __str__(self):
        return f"{self.user.email} - {self.topic.title} - {self.lecture.title}"

    def clean(self):
        """Ensure lecture belongs to the topic"""
        if self.lecture and self.topic and self.lecture.topic != self.topic:
            raise ValidationError("Lecture must belong to the specified topic")


class FavoriteLecture(models.Model):
    """User's favorite lectures"""

    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="favorite_lectures"
    )
    lecture = models.ForeignKey(
        Lecture, on_delete=models.CASCADE, related_name="favorited_by"
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ["user", "lecture"]
        indexes = [
            models.Index(fields=["user", "created_at"]),
        ]

    def __str__(self):
        return f"{self.user.email} - {self.lecture.title}"


class LectureHistory(models.Model):
    """History of listened lectures"""

    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="lecture_history"
    )
    lecture = models.ForeignKey(
        Lecture, on_delete=models.CASCADE, related_name="history_records"
    )
    listened_at = models.DateTimeField(auto_now_add=True)
    duration_listened = models.IntegerField(
        default=0, help_text="Duration listened in seconds"
    )
    completion_percentage = models.FloatField(
        default=0.0, help_text="Percentage of lecture completed"
    )

    class Meta:
        indexes = [
            models.Index(fields=["user", "listened_at"]),
            models.Index(fields=["user", "lecture"]),
        ]

    def __str__(self):
        return f"{self.user.email} - {self.lecture.title} ({self.listened_at})"


class LectureMarker(models.Model):
    """User markers/notes for specific timestamps in lectures"""
    
    user = models.ForeignKey(
        User, 
        on_delete=models.CASCADE, 
        related_name="lecture_markers"
    )
    lecture = models.ForeignKey(
        Lecture, 
        on_delete=models.CASCADE, 
        related_name="markers"
    )
    timestamp = models.FloatField(
        help_text="Marker timestamp in seconds"
    )
    text = models.TextField(
        help_text="Marker note text"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["lecture", "timestamp"]
        indexes = [
            models.Index(fields=["user", "lecture"]),
            models.Index(fields=["lecture", "timestamp"]),
            models.Index(fields=["user", "created_at"]),
        ]

    def __str__(self):
        text_preview = self.text[:50] + "..." if len(self.text) > 50 else self.text
        return f"{self.user.email} - {self.lecture.title} ({self.formatted_timestamp}) - {text_preview}"

    @property
    def formatted_timestamp(self):
        """Format timestamp as MM:SS or HH:MM:SS"""
        if self.timestamp is None:
            return "0:00"
        
        total_seconds = int(self.timestamp)
        hours = total_seconds // 3600
        minutes = (total_seconds % 3600) // 60
        seconds = total_seconds % 60
        
        if hours > 0:
            return f"{hours}:{minutes:02d}:{seconds:02d}"
        return f"{minutes}:{seconds:02d}"

    def clean(self):
        """Validate timestamp and text"""
        if self.timestamp is None or self.timestamp < 0:
            raise ValidationError("Timestamp cannot be negative or empty")
        
        if not self.text or not self.text.strip():
            raise ValidationError("Marker text cannot be empty")
        
        if self.lecture and self.lecture.duration:
            if self.timestamp > self.lecture.duration:
                raise ValidationError(
                    f"Timestamp {self.formatted_timestamp} exceeds lecture duration"
                )
