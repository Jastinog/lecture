import uuid
import os
from django.db import models


def lecture_upload_path(instance, filename):
    """Generate nested upload path for lecture files"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lectures/{instance.course.lecturer.code}/{instance.course.code}/{short_name}"


def lecturer_photo_path(instance, filename):
    """Upload path for lecturer photos"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"lecturers/{instance.code}/{short_name}"


def course_cover_path(instance, filename):
    """Upload path for course covers"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    return f"courses/{instance.lecturer.code}/{instance.code}/{short_name}"


class Lecturer(models.Model):
    code = models.CharField(max_length=50, unique=True, null=True)
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


class Course(models.Model):
    lecturer = models.ForeignKey(
        Lecturer, on_delete=models.CASCADE, related_name="courses"
    )
    code = models.CharField(max_length=50, null=True)
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=course_cover_path, blank=True, null=True)
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

    class Meta:
        ordering = ["lecturer", "order"]
        unique_together = ["lecturer", "order", "code"]


class Lecture(models.Model):
    course = models.ForeignKey(
        Course, on_delete=models.CASCADE, related_name="lectures"
    )
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    audio_file = models.FileField(upload_to=lecture_upload_path)
    file_size = models.BigIntegerField(null=True, blank=True)
    duration = models.CharField(max_length=20, blank=True)
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.course.title} - {self.title}"

    class Meta:
        ordering = ["course", "order"]
        unique_together = ["course", "order"]

    @property
    def file_size_mb(self):
        if self.file_size:
            return round(self.file_size / (1024 * 1024), 1)
        return 0.0
