from django.contrib import admin
from django.urls import path
from django.shortcuts import render, get_object_or_404
from django.contrib import messages
from django.http import HttpResponseRedirect
from django.utils.html import format_html
from apps.system.services import Logger
from apps.lecture.models import (
    Lecturer,
    Topic,
    Lecture,
    LectureProgress,
    CurrentLecture,
    FavoriteLecture,
    LectureHistory,
)

from .services import LectureImportService

logger = Logger(app_name="lecture_admin")


@admin.register(Lecturer)
class LecturerAdmin(admin.ModelAdmin):
    list_display = ["photo_thumbnail", "name", "order", "created_at"]
    search_fields = ["name"]
    ordering = ["order", "name"]
    list_editable = ["order"]
    list_display_links = ["name"]

    def photo_thumbnail(self, obj):
        if obj.photo:
            return format_html(
                '<img src="{}" width="40" height="40" style="border-radius: 4px; object-fit: cover;" />',
                obj.photo.url,
            )
        return "-"

    photo_thumbnail.short_description = "Photo"

    def get_queryset(self, request):
        return super().get_queryset(request).order_by("order", "name")


class LectureInline(admin.TabularInline):
    model = Lecture
    extra = 0
    fields = [
        "title",
        "order",
        "audio_file",
        "duration",
        "file_size_mb",
        "file_hash_short",
    ]
    readonly_fields = ["file_size_mb", "file_hash_short"]

    def file_hash_short(self, obj):
        if obj.file_hash:
            return f"{obj.file_hash[:8]}..."
        return "-"

    file_hash_short.short_description = "Hash"


@admin.register(Topic)
class TopicAdmin(admin.ModelAdmin):
    list_display = [
        "cover_thumbnail",
        "title",
        "lecturer",
        "order",
        "lecture_count_with_import",
        "created_at",
    ]
    list_filter = ["lecturer", "created_at"]
    search_fields = ["title", "lecturer__name"]
    ordering = ["lecturer__order", "lecturer__name", "order"]
    list_editable = ["order"]
    inlines = [LectureInline]

    def cover_thumbnail(self, obj):
        if obj.cover:
            return format_html(
                '<img src="{}" width="40" height="40" style="border-radius: 4px; object-fit: cover;" />',
                obj.cover.url,
            )
        return "-"

    cover_thumbnail.short_description = "Cover"

    def lecture_count_with_import(self, obj):
        count = obj.lectures.count()
        return format_html(
            '{} lectures <a href="{}/import-lectures/" style="margin-left:10px;">Import</a>',
            count,
            obj.id,
        )

    lecture_count_with_import.short_description = "Lectures"

    def get_urls(self):
        urls = super().get_urls()
        custom_urls = [
            path(
                "<int:object_id>/import-lectures/",
                self.admin_site.admin_view(self.import_lectures_view),
                name="lecture_topic_import_lectures",
            ),
        ]
        return custom_urls + urls

    def import_lectures_view(self, request, object_id):
        topic = get_object_or_404(Topic, id=object_id)

        if request.method == "POST":
            uploaded_files = request.FILES.getlist("lecture_files")

            if not uploaded_files:
                messages.error(request, "Please select files to import")
                return render(request, "admin/import_lectures.html", {"topic": topic})

            logger.info(
                f"Files received for import: {len(uploaded_files)}",
                [f.name for f in uploaded_files],
            )

            try:
                service = LectureImportService(topic)
                imported_count = service.import_files(uploaded_files)

                messages.success(
                    request, f"Successfully imported {imported_count} lectures"
                )
                return HttpResponseRedirect("../")

            except Exception as e:
                messages.error(request, f"Import failed: {str(e)}")

        return render(request, "admin/import_lectures.html", {"topic": topic})


@admin.register(Lecture)
class LectureAdmin(admin.ModelAdmin):
    list_display = [
        "title",
        "topic",
        "order",
        "file_size_mb",
        "duration",
        "file_hash_short",
        "created_at",
    ]
    list_filter = ["topic__lecturer", "topic", "created_at"]
    search_fields = ["title", "topic__title", "topic__lecturer__name", "file_hash"]
    ordering = ["topic__lecturer__order", "topic", "order"]
    list_editable = ["order"]
    readonly_fields = ["file_hash"]

    def file_size_mb(self, obj):
        return f"{obj.file_size_mb} MB"

    file_size_mb.short_description = "Size"

    def file_hash_short(self, obj):
        if obj.file_hash:
            return f"{obj.file_hash[:8]}..."
        return "-"

    file_hash_short.short_description = "Hash"


@admin.register(LectureProgress)
class LectureProgressAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title",
        "progress_percentage_display",
        "completed",
        "listen_count",
        "current_time_display",
        "last_listened",
    ]
    list_filter = ["completed", "last_listened", "lecture__topic__lecturer"]
    search_fields = [
        "user__email",
        "lecture__title",
        "lecture__topic__title",
        "lecture__topic__lecturer__name",
    ]
    readonly_fields = ["created_at", "last_listened"]
    ordering = ["-last_listened"]

    def user_email(self, obj):
        return obj.user.email

    user_email.short_description = "User"

    def lecture_title(self, obj):
        return f"{obj.lecture.topic.lecturer.name} - {obj.lecture.topic.title} - {obj.lecture.title}"

    lecture_title.short_description = "Lecture"

    def current_time_display(self, obj):
        minutes = int(obj.current_time // 60)
        seconds = int(obj.current_time % 60)
        return f"{minutes}:{seconds:02d}"

    current_time_display.short_description = "Position"

    def progress_percentage_display(self, obj):
        return f"{obj.progress_percentage:.1f}%"

    progress_percentage_display.short_description = "Progress"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "lecture__topic__lecturer")
        )


@admin.register(CurrentLecture)
class CurrentLectureAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "topic_title",
        "lecture_title",
        "updated_at",
    ]
    list_filter = ["topic__lecturer", "topic", "updated_at"]
    search_fields = [
        "user__email",
        "topic__title",
        "lecture__title",
        "topic__lecturer__name",
    ]
    readonly_fields = ["created_at", "updated_at"]
    ordering = ["-updated_at"]

    def user_email(self, obj):
        return obj.user.email

    user_email.short_description = "User"

    def topic_title(self, obj):
        return f"{obj.topic.lecturer.name} - {obj.topic.title}"

    topic_title.short_description = "Topic"

    def lecture_title(self, obj):
        return obj.lecture.title

    lecture_title.short_description = "Current Lecture"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "topic__lecturer", "lecture")
        )


@admin.register(FavoriteLecture)
class FavoriteLectureAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title",
        "lecturer_name",
        "topic_title",
        "created_at",
    ]
    list_filter = ["lecture__topic__lecturer", "lecture__topic", "created_at"]
    search_fields = [
        "user__email",
        "lecture__title",
        "lecture__topic__title",
        "lecture__topic__lecturer__name",
    ]
    readonly_fields = ["created_at"]
    ordering = ["-created_at"]

    def user_email(self, obj):
        return obj.user.email

    user_email.short_description = "User"

    def lecture_title(self, obj):
        return obj.lecture.title

    lecture_title.short_description = "Lecture"

    def lecturer_name(self, obj):
        return obj.lecture.topic.lecturer.name

    lecturer_name.short_description = "Lecturer"

    def topic_title(self, obj):
        return obj.lecture.topic.title

    topic_title.short_description = "Topic"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "lecture__topic__lecturer")
        )


@admin.register(LectureHistory)
class LectureHistoryAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title",
        "duration_listened_display",
        "completion_percentage_display",
        "listened_at",
    ]
    list_filter = [
        "listened_at",
        "lecture__topic__lecturer",
        "lecture__topic",
    ]
    search_fields = [
        "user__email",
        "lecture__title",
        "lecture__topic__title",
        "lecture__topic__lecturer__name",
    ]
    readonly_fields = ["listened_at"]
    ordering = ["-listened_at"]

    def user_email(self, obj):
        return obj.user.email

    user_email.short_description = "User"

    def lecture_title(self, obj):
        return f"{obj.lecture.topic.lecturer.name} - {obj.lecture.topic.title} - {obj.lecture.title}"

    lecture_title.short_description = "Lecture"

    def duration_listened_display(self, obj):
        minutes = int(obj.duration_listened // 60)
        seconds = int(obj.duration_listened % 60)
        return f"{minutes}:{seconds:02d}"

    duration_listened_display.short_description = "Duration"

    def completion_percentage_display(self, obj):
        return f"{obj.completion_percentage:.1f}%"

    completion_percentage_display.short_description = "Completed"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "lecture__topic__lecturer")
        )
