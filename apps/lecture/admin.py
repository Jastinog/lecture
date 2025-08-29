from django.contrib import admin
from django.urls import path
from django.shortcuts import render, get_object_or_404
from django.contrib import messages
from django.http import HttpResponseRedirect
from django.utils.html import format_html
from apps.system.services import Logger
from apps.lecture.models import Lecturer, Topic, Lecture
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
