import uuid
import os
import hashlib
from django.db import models

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
    return f"lecturers/{instance.code}/{short_name}"


def topic_cover_path(instance, filename):
    """Upload path for topic covers"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lecturers/{instance.lecturer.code}/topics/{instance.code}/{short_name}"


class Lecturer(models.Model):
    code = models.CharField(max_length=255, unique=True)
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    photo = models.ImageField(upload_to=lecturer_photo_path, blank=True, null=True)
    order = models.PositiveIntegerField(
        default=0, help_text="Order for displaying lecturers"
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    class Meta:
        ordering = ["order", "name"]
        unique_together = ["order"]


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
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ["user", "lecture"]
        indexes = [
            models.Index(fields=["user", "lecture"]),
            models.Index(fields=["user", "completed"]),
        ]

    def __str__(self):
        return f"{self.user.email} - {self.lecture.title} ({self.current_time}s)"

    @property
    def progress_percentage(self):
        """Calculate progress percentage if lecture has duration"""

        print(self.current_time, self.lecture.duration)
        if hasattr(self.lecture, "duration") and self.lecture.duration > 0:
            return min(100, (self.current_time / self.lecture.duration) * 100)

        return 60
