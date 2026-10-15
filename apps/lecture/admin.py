import logging

from django.contrib import admin
from django.core.exceptions import ValidationError
from django.db.models import Count
from django.forms.models import BaseInlineFormSet
from django.urls import path
from django.shortcuts import render, get_object_or_404
from django.contrib import messages
from django.http import HttpResponseRedirect
from django.utils.html import format_html
from apps.lecture.models import (
    Language,
    TopicGroup,
    Lecturer,
    Topic,
    Lecture,
    Selection,
    SelectionLecture,
    LecturePlays,
    set_lectures_language,
)

from .services import LectureImport

logger = logging.getLogger(__name__)


def thumbnail(image):
    """A 40px preview of an image field for list pages, or "-"."""
    if not image:
        return "-"
    return format_html(
        '<img src="{}" width="40" height="40" style="border-radius: 4px; object-fit: cover;" />',
        image.url,
    )


def language_actions(lectures_of):
    """One "Set language → …" action per active language. `lectures_of` maps
    the selected objects to the lectures the action relabels."""

    def make(language):
        def action(modeladmin, request, queryset):
            changed = set_lectures_language(lectures_of(queryset), language)
            modeladmin.message_user(
                request,
                f"{changed} lecture(s) set to {language.native_name}",
                messages.SUCCESS,
            )

        name = f"set_language_{language.code}"
        return name, (action, name, f"Set language → {language.native_name}")

    return dict(make(language) for language in Language.objects.filter(is_active=True))


@admin.register(Language)
class LanguageAdmin(admin.ModelAdmin):
    list_display = ["code", "name", "native_name", "is_active", "created_at"]
    list_filter = ["is_active"]
    search_fields = ["code", "name", "native_name"]
    ordering = ["name"]
    list_editable = ["is_active"]


@admin.register(LecturePlays)
class LecturePlaysAdmin(admin.ModelAdmin):
    """What ranks "Trending": read only, the app counts them."""

    list_display = ["day", "lecture", "count"]
    list_filter = ["day"]
    search_fields = ["lecture__title", "lecture__topic__title", "lecture__topic__lecturer__name"]
    ordering = ["-day", "-count"]
    list_select_related = ["lecture__topic", "lecture__language"]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False


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
        return thumbnail(obj.photo)

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
    # Languages follow the topic's lectures; set each lecture's instead.
    exclude = ["languages"]
    readonly_fields = ["languages_display"]

    def cover_thumbnail(self, obj):
        return thumbnail(obj.cover)

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

    def get_actions(self, request):
        # On topics, the actions relabel every lecture of the selected topics,
        # so they need the right to change lectures.
        actions = super().get_actions(request)
        if request.user.has_perm("lecture.change_lecture"):
            actions.update(
                language_actions(lambda topics: Lecture.objects.filter(topic__in=topics))
            )
        return actions

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
        languages = Language.objects.filter(is_active=True)
        context = {"topic": topic, "languages": languages}

        if request.method == "POST":
            uploaded_files = request.FILES.getlist("lecture_files")
            language = languages.filter(pk=request.POST.get("language")).first()

            if not uploaded_files:
                messages.error(request, "Please select files to import")
                return render(request, "admin/import_lectures.html", context)
            if not language:
                messages.error(request, "Please choose the lectures' language")
                return render(request, "admin/import_lectures.html", context)

            logger.info(
                f"Files received for import: {[f.name for f in uploaded_files]}"
            )

            try:
                service = LectureImport(topic, language)
                imported_count = service.import_files(uploaded_files)

                messages.success(
                    request, f"Successfully imported {imported_count} lectures"
                )
                return HttpResponseRedirect("../")

            except Exception as e:
                messages.error(request, f"Import failed: {str(e)}")

        return render(request, "admin/import_lectures.html", context)

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

    def get_actions(self, request):
        # Added after Django's permission filtering, so checked here.
        actions = super().get_actions(request)
        if self.has_change_permission(request):
            actions.update(language_actions(lambda lectures: lectures))
        return actions

    def get_queryset(self, request):
        return (
            super().get_queryset(request).select_related("topic__lecturer", "language")
        )


class ChildSelectionInline(admin.TabularInline):
    model = Selection
    fk_name = "parent"
    extra = 0
    fields = ["title", "order"]
    show_change_link = True
    verbose_name = "Nested selection"


def posts_rows(data, prefix, field):
    """Whether the admin form posted rows with `field` filled, not marked for
    deletion, in the inline formset `prefix`."""
    try:
        total = int(data.get(f"{prefix}-TOTAL_FORMS") or 0)
    except ValueError:
        return False
    return any(
        data.get(f"{prefix}-{i}-{field}") and not data.get(f"{prefix}-{i}-DELETE")
        for i in range(total)
    )


class SelectionEntriesFormSet(BaseInlineFormSet):
    def clean(self):
        super().clean()
        # An empty selection offers both inlines; each row's own check looks
        # at the database, where neither kind is yet.
        adding = any(
            form.cleaned_data.get("lecture") and not form.cleaned_data.get("DELETE")
            for form in self.forms
            if hasattr(form, "cleaned_data")
        )
        if adding and posts_rows(self.data, "children", "title"):
            raise ValidationError("A selection holds lectures or selections, not both.")


class SelectionLectureInline(admin.TabularInline):
    model = SelectionLecture
    formset = SelectionEntriesFormSet
    extra = 0
    fields = ["lecture", "order", "topic", "language"]
    readonly_fields = ["topic", "language"]
    autocomplete_fields = ["lecture"]
    verbose_name = "Lecture"

    def topic(self, obj):
        return obj.lecture.topic.title if obj.lecture_id else "-"

    def language(self, obj):
        return obj.lecture.language.code if obj.lecture_id else "-"

    def get_queryset(self, request):
        return super().get_queryset(request).select_related("lecture__topic", "lecture__language")


@admin.register(Selection)
class SelectionAdmin(admin.ModelAdmin):
    list_display = ["cover_thumbnail", "title", "parent_title", "lecturer", "order", "contents", "created_at"]
    list_display_links = ["title"]
    list_filter = ["lecturer", ("parent", admin.EmptyFieldListFilter)]
    search_fields = ["title", "parent__title", "lecturer__name"]
    list_editable = ["order"]
    autocomplete_fields = ["parent"]
    fields = ["lecturer", "parent", "title", "description", "cover", "order"]

    def get_inlines(self, request, obj):
        # A selection holds selections or lectures: once it has one, only that
        # kind can be added; an empty one offers both.
        if obj and obj.children.exists():
            return [ChildSelectionInline]
        if obj and obj.entries.exists():
            return [SelectionLectureInline]
        return [ChildSelectionInline, SelectionLectureInline]

    def get_readonly_fields(self, request, obj=None):
        # Chosen once: nested selections follow their parent's.
        return ["lecturer"] if obj else []

    def cover_thumbnail(self, obj):
        return thumbnail(obj.cover)

    cover_thumbnail.short_description = "Cover"

    def parent_title(self, obj):
        return obj.parent.title if obj.parent_id else "-"

    parent_title.short_description = "Inside"

    def contents(self, obj):
        if obj.children_count:
            return f"{obj.children_count} selections"
        return f"{obj.entries_count} lectures"

    contents.short_description = "Holds"

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("lecturer", "parent")
            .annotate(
                children_count=Count("children", distinct=True),
                entries_count=Count("entries", distinct=True),
            )
        )
