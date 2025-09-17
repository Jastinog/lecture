import uuid
import os
import hashlib
from django.db import models
from django.core.exceptions import ValidationError

from apps.users.models import User


def lecture_upload_path(instance, filename):
    """Generate nested upload path for lecture files"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lecturers/{instance.topic.lecturer.code}/topics/{instance.topic.code}/lectures/{short_name}"


def lecturer_photo_path(instance, filename):
    """Upload path for lecturer photos"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lecturers/{instance.code}/photo/{short_name}"


def topic_cover_path(instance, filename):
    """Upload path for topic covers"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lecturers/{instance.lecturer.code}/topics/{instance.code}/cover/{short_name}"


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
        help_text="Spiritual hierarchy level: 1=Founder-Acharya, 2=Direct Disciple, 3=Grand Disciple"
    )
    guru = models.ForeignKey(
        'self',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='disciples',
        help_text="Spiritual teacher (guru) of this lecturer"
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

    def get_disciples(self):
        """Get all direct disciples"""
        return self.disciples.all()

    def get_guru_chain(self):
        """Get the guru chain up to the founder"""
        chain = []
        current = self.guru
        while current:
            chain.append(current)
            current = current.guru
        return chain

    def clean(self):
        """Validate guru-disciple relationship"""
        if self.guru:
            # Prevent circular references
            if self.guru == self:
                raise ValidationError("Lecturer cannot be guru to themselves")
            
            # Check for circular chain
            current = self.guru
            visited = {self.pk}
            while current:
                if current.pk in visited:
                    raise ValidationError("Circular guru-disciple relationship detected")
                visited.add(current.pk)
                current = current.guru
            
            # Auto-set level based on guru's level
            if self.guru.level == 1:  # Guru is founder
                self.level = 2
            elif self.guru.level == 2:  # Guru is direct disciple
                self.level = 3
            # If guru is level 3, disciple remains level 3
        
        # Founder-Acharya validation
        if self.level == 1:
            if self.guru:
                raise ValidationError("Founder-Acharya cannot have a guru")
            # Check if another founder exists
            if Lecturer.objects.filter(level=1).exclude(pk=self.pk).exists():
                raise ValidationError("Only one Founder-Acharya is allowed")

    class Meta:
        ordering = ["level", "order", "name"]
        unique_together = ["order"]
        indexes = [
            models.Index(fields=["level", "order"]),
            models.Index(fields=["guru"]),
        ]


class Topic(models.Model):
    lecturer = models.ForeignKey(
        Lecturer, on_delete=models.CASCADE, related_name="topics"
    )
    code = models.CharField(max_length=255)
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=topic_cover_path, blank=True, null=True)
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

    class Meta:
        ordering = ["lecturer", "order"]
        unique_together = ["lecturer", "order", "code"]


class Lecture(models.Model):
    topic = models.ForeignKey(Topic, on_delete=models.CASCADE, related_name="lectures")
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    audio_file = models.FileField(upload_to=lecture_upload_path)
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
        return f"{self.topic.title} - {self.title}"

    class Meta:
        ordering = ["topic", "order"]
        unique_together = ["topic", "order"]
        indexes = [
            models.Index(fields=["topic", "file_hash"]),
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
