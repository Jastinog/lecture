from django.db import models


class Lecturer(models.Model):
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    photo = models.ImageField(upload_to="lecturers/", blank=True, null=True)
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
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to="courses/", blank=True, null=True)
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

    class Meta:
        ordering = ["lecturer", "order"]
        unique_together = ["lecturer", "order"]


class Lecture(models.Model):
    course = models.ForeignKey(
        Course, on_delete=models.CASCADE, related_name="lectures"
    )
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    audio_file = models.FileField(upload_to="lectures/")
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
