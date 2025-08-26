from django.contrib import admin
from django.urls import path
from django.shortcuts import render, get_object_or_404
from django.contrib import messages
from django.http import HttpResponseRedirect
from django.utils.html import format_html
from .models import Lecturer, Course, Lecture
from .services import LectureImportService


@admin.register(Lecturer)
class LecturerAdmin(admin.ModelAdmin):
    list_display = ["name", "order", "created_at"]
    search_fields = ["name"]
    ordering = ["order", "name"]
    list_editable = ["order"]
    list_display_links = ["name"]

    def get_queryset(self, request):
        return super().get_queryset(request).order_by("order", "name")


class LectureInline(admin.TabularInline):
    model = Lecture
    extra = 0
    fields = ["title", "order", "audio_file", "duration", "file_size_mb"]
    readonly_fields = ["file_size_mb"]


@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display = [
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
                name="lecture_course_import_lectures",
            ),
        ]
        return custom_urls + urls

    def import_lectures_view(self, request, object_id):
        course = get_object_or_404(Course, id=object_id)

        if request.method == "POST":
            uploaded_files = request.FILES.getlist("lecture_files")

            if not uploaded_files:
                messages.error(request, "Please select files to import")
                return render(request, "admin/import_lectures.html", {"course": course})

            try:
                service = LectureImportService(course)
                imported_count = service.import_files(uploaded_files)
                messages.success(
                    request, f"Successfully imported {imported_count} lectures"
                )
                return HttpResponseRedirect("../")
            except Exception as e:
                messages.error(request, f"Import failed: {str(e)}")

        return render(request, "admin/import_lectures.html", {"course": course})


@admin.register(Lecture)
class LectureAdmin(admin.ModelAdmin):
    list_display = [
        "title",
        "course",
        "order",
        "file_size_mb",
        "duration",
        "created_at",
    ]
    list_filter = ["course__lecturer", "course", "created_at"]
    search_fields = ["title", "course__title", "course__lecturer__name"]
    ordering = ["course__lecturer__order", "course", "order"]
    list_editable = ["order"]

    def file_size_mb(self, obj):
        return f"{obj.file_size_mb} MB"

    file_size_mb.short_description = "Size"
