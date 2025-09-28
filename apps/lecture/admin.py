from django.contrib import admin
from django.urls import path
from django.shortcuts import render, get_object_or_404
from django.contrib import messages
from django.http import HttpResponseRedirect
from django.utils.html import format_html
from apps.system.services import Logger
from apps.lecture.models import (
    Language,
    TopicGroup,
    Lecturer,
    Topic,
    Lecture,
    LectureProgress,
    CurrentLecture,
    FavoriteLecture,
    LectureHistory,
    LectureMarker,
)

from .services import LectureImport

logger = Logger(app_name="lecture_admin")


@admin.register(Language)
class LanguageAdmin(admin.ModelAdmin):
    list_display = ["code", "name", "native_name", "is_active", "created_at"]
    list_filter = ["is_active"]
    search_fields = ["code", "name", "native_name"]
    ordering = ["name"]
    list_editable = ["is_active"]


@admin.register(TopicGroup)
class TopicGroupAdmin(admin.ModelAdmin):
    list_display = ["name", "code", "order", "is_active", "topics_count", "created_at"]
    list_filter = ["is_active"]
    search_fields = ["name", "code", "description"]
    ordering = ["order", "name"]
    list_editable = ["order", "is_active"]

    def topics_count(self, obj):
        return obj.topics.count()

    topics_count.short_description = "Topics"

    def get_queryset(self, request):
        return super().get_queryset(request).prefetch_related("topics")


@admin.register(Lecturer)
class LecturerAdmin(admin.ModelAdmin):
    list_display = [
        "photo_thumbnail",
        "name",
        "level_display",
        "order",
        "topics_count",
        "created_at",
    ]
    list_filter = ["level"]
    search_fields = ["name"]
    ordering = ["level", "order", "name"]
    list_editable = ["order"]
    list_display_links = ["name"]

    fieldsets = (
        ("Basic Information", {"fields": ("name", "code", "description", "photo")}),
        (
            "Hierarchy",
            {
                "fields": ("level",),
                "description": "Spiritual hierarchy: Level 1=Founder, Level 2=Direct Disciple, Level 3=Grand Disciple",
            },
        ),
        ("Display", {"fields": ("order",)}),
    )

    def photo_thumbnail(self, obj):
        if obj.photo:
            return format_html(
                '<img src="{}" width="40" height="40" style="border-radius: 4px; object-fit: cover;" />',
                obj.photo.url,
            )
        return "-"

    photo_thumbnail.short_description = "Photo"

    def level_display(self, obj):
        return format_html(
            '<span title="{}">{}</span>',
            obj.get_level_display(),
            obj.get_level_display_with_icon(),
        )

    level_display.short_description = "Level"

    def topics_count(self, obj):
        return obj.topics.count()

    topics_count.short_description = "Topics"

    def get_queryset(self, request):
        return super().get_queryset(request).prefetch_related("topics")


class LectureInline(admin.TabularInline):
    model = Lecture
    extra = 0
    fields = [
        "title",
        "language",
        "order",
        "year",
        "event",
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
        "lecturer_with_level",
        "group",
        "languages_display",
        "order",
        "lecture_count_with_import",
        "created_at",
    ]
    list_filter = ["lecturer__level", "lecturer", "group", "languages", "created_at"]
    search_fields = ["title", "lecturer__name"]
    ordering = [
        "lecturer__level",
        "lecturer__order",
        "lecturer__name",
        "group__order",
        "order",
    ]
    list_editable = ["order"]
    inlines = [LectureInline]
    filter_horizontal = ["languages"]

    def cover_thumbnail(self, obj):
        if obj.cover:
            return format_html(
                '<img src="{}" width="40" height="40" style="border-radius: 4px; object-fit: cover;" />',
                obj.cover.url,
            )
        return "-"

    cover_thumbnail.short_description = "Cover"

    def lecturer_with_level(self, obj):
        return format_html(
            '{} <small style="color: #666;">({})</small>',
            obj.lecturer.name,
            obj.lecturer.get_level_display_with_icon(),
        )

    lecturer_with_level.short_description = "Lecturer"

    def languages_display(self, obj):
        languages = obj.languages.all()
        if languages:
            return ", ".join([lang.code for lang in languages])
        return "-"

    languages_display.short_description = "Languages"

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
                service = LectureImport(topic)
                imported_count = service.import_files(uploaded_files)

                messages.success(
                    request, f"Successfully imported {imported_count} lectures"
                )
                return HttpResponseRedirect("../")

            except Exception as e:
                messages.error(request, f"Import failed: {str(e)}")

        return render(request, "admin/import_lectures.html", {"topic": topic})

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("lecturer", "group")
            .prefetch_related("languages")
        )


@admin.register(Lecture)
class LectureAdmin(admin.ModelAdmin):
    list_display = [
        "title",
        "topic_with_lecturer",
        "language",
        "order",
        "year",
        "event",
        "file_size_mb",
        "duration",
        "file_hash_short",
        "created_at",
    ]
    list_filter = [
        "topic__lecturer__level",
        "topic__lecturer",
        "topic",
        "language",
        "year",
        "created_at",
    ]
    search_fields = [
        "title",
        "topic__title",
        "topic__lecturer__name",
        "event",
        "file_hash",
    ]
    ordering = [
        "topic__lecturer__level",
        "topic__lecturer__order",
        "topic",
        "language",
        "order",
    ]
    list_editable = ["order", "year", "event"]
    readonly_fields = ["file_hash"]

    def topic_with_lecturer(self, obj):
        return format_html(
            '{} <small style="color: #666;">- {}</small>',
            obj.topic.lecturer.name,
            obj.topic.title,
        )

    topic_with_lecturer.short_description = "Lecturer - Topic"

    def file_size_mb(self, obj):
        return f"{obj.file_size_mb} MB"

    file_size_mb.short_description = "Size"

    def file_hash_short(self, obj):
        if obj.file_hash:
            return f"{obj.file_hash[:8]}..."
        return "-"

    file_hash_short.short_description = "Hash"

    def get_queryset(self, request):
        return (
            super().get_queryset(request).select_related("topic__lecturer", "language")
        )


@admin.register(LectureProgress)
class LectureProgressAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title_with_level",
        "language",
        "progress_percentage_display",
        "completed",
        "listen_count",
        "current_time_display",
        "last_listened",
    ]
    list_filter = [
        "completed",
        "last_listened",
        "lecture__topic__lecturer__level",
        "lecture__topic__lecturer",
        "lecture__language",
    ]
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

    def lecture_title_with_level(self, obj):
        lecturer = obj.lecture.topic.lecturer
        return format_html(
            "{} {} - {} - {}",
            lecturer.get_level_display_with_icon(),
            lecturer.name,
            obj.lecture.topic.title,
            obj.lecture.title,
        )

    lecture_title_with_level.short_description = "Lecture"

    def language(self, obj):
        return obj.lecture.language.code

    language.short_description = "Lang"

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
            .select_related("user", "lecture__topic__lecturer", "lecture__language")
        )


@admin.register(CurrentLecture)
class CurrentLectureAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "topic_title_with_level",
        "lecture_title",
        "language",
        "updated_at",
    ]
    list_filter = [
        "topic__lecturer__level",
        "topic__lecturer",
        "topic",
        "lecture__language",
        "updated_at",
    ]
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

    def topic_title_with_level(self, obj):
        lecturer = obj.topic.lecturer
        return format_html(
            "{} {} - {}",
            lecturer.get_level_display_with_icon(),
            lecturer.name,
            obj.topic.title,
        )

    topic_title_with_level.short_description = "Topic"

    def lecture_title(self, obj):
        return obj.lecture.title

    lecture_title.short_description = "Current Lecture"

    def language(self, obj):
        return obj.lecture.language.code

    language.short_description = "Lang"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "topic__lecturer", "lecture__language")
        )


@admin.register(FavoriteLecture)
class FavoriteLectureAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title",
        "lecturer_with_level",
        "topic_title",
        "language",
        "created_at",
    ]
    list_filter = [
        "lecture__topic__lecturer__level",
        "lecture__topic__lecturer",
        "lecture__topic",
        "lecture__language",
        "created_at",
    ]
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

    def lecturer_with_level(self, obj):
        lecturer = obj.lecture.topic.lecturer
        return format_html(
            "{} {}", lecturer.get_level_display_with_icon(), lecturer.name
        )

    lecturer_with_level.short_description = "Lecturer"

    def topic_title(self, obj):
        return obj.lecture.topic.title

    topic_title.short_description = "Topic"

    def language(self, obj):
        return obj.lecture.language.code

    language.short_description = "Lang"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("user", "lecture__topic__lecturer", "lecture__language")
        )


@admin.register(LectureHistory)
class LectureHistoryAdmin(admin.ModelAdmin):
    list_display = [
        "user_email",
        "lecture_title_with_level",
        "language",
        "duration_listened_display",
        "completion_percentage_display",
        "listened_at",
    ]
    list_filter = [
        "listened_at",
        "lecture__topic__lecturer__level",
        "lecture__topic__lecturer",
        "lecture__topic",
        "lecture__language",
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

    def lecture_title_with_level(self, obj):
        lecturer = obj.lecture.topic.lecturer
        return format_html(
            "{} {} - {} - {}",
            lecturer.get_level_display_with_icon(),
            lecturer.name,
            obj.lecture.topic.title,
            obj.lecture.title,
        )

    lecture_title_with_level.short_description = "Lecture"

    def language(self, obj):
        return obj.lecture.language.code

    language.short_description = "Lang"

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
            .select_related("user", "lecture__topic__lecturer", "lecture__language")
        )


@admin.register(LectureMarker)
class LectureMarkerAdmin(admin.ModelAdmin):
    list_display = [
        'user_email', 
        'lecture_title', 
        'formatted_timestamp', 
        'text_preview',
        'created_at'
    ]
    list_filter = [
        'created_at',
        'lecture__topic__lecturer',
        'lecture__topic',
        'lecture__language'
    ]
    search_fields = [
        'user__email',
        'user__first_name', 
        'user__last_name',
        'lecture__title',
        'lecture__topic__title',
        'text'
    ]
    readonly_fields = ['created_at', 'updated_at', 'formatted_timestamp']
    raw_id_fields = ['user', 'lecture']
    ordering = ['-created_at']
    
    fieldsets = (
        (None, {
            'fields': ('user', 'lecture', 'timestamp', 'formatted_timestamp')
        }),
        ('Marker Content', {
            'fields': ('text',)
        }),
        ('Timestamps', {
            'fields': ('created_at', 'updated_at'),
            'classes': ('collapse',)
        }),
    )

    def user_email(self, obj):
        return obj.user.email
    user_email.short_description = 'User'
    user_email.admin_order_field = 'user__email'

    def lecture_title(self, obj):
        return obj.lecture.title
    lecture_title.short_description = 'Lecture'
    lecture_title.admin_order_field = 'lecture__title'

    def text_preview(self, obj):
        return obj.text[:100] + "..." if len(obj.text) > 100 else obj.text
    text_preview.short_description = 'Text Preview'

    def get_queryset(self, request):
        return super().get_queryset(request).select_related(
            'user', 
            'lecture__topic__lecturer'
        )
