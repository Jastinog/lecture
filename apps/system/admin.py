from django.contrib import admin
from django.utils.html import format_html
from django.urls import reverse
from django.utils.safestring import mark_safe
from apps.system.models import UserActivity, ActivityLog


class ActivityLogInline(admin.TabularInline):
    model = ActivityLog
    extra = 0
    can_delete = False
    readonly_fields = ["timestamp", "view_name", "url", "http_method", "referer"]
    fields = ["timestamp", "view_name", "url", "http_method"]
    ordering = ["-timestamp"]

    def has_add_permission(self, request, obj=None):
        return False


@admin.register(UserActivity)
class UserActivityAdmin(admin.ModelAdmin):
    list_display = [
        "user_info",
        "ip_address",
        "visit_count_display",
        "last_url_display",
        "session_hash_short",
        "last_visit_display",
        "created_at",
    ]
    list_filter = ["user", "created_at", "updated_at"]
    search_fields = ["user__email", "ip_address", "session_hash"]
    readonly_fields = [
        "session_hash",
        "ip_address",
        "user_agent",
        "created_at",
        "updated_at",
        "visit_count_display",
        "last_url_display",
        "last_visit_display",
        "first_visit_display",
        "user_agent_display",
    ]
    ordering = ["-updated_at"]
    inlines = [ActivityLogInline]

    fieldsets = (
        ("User Information", {"fields": ("user", "session_hash")}),
        ("Request Details", {"fields": ("ip_address", "user_agent_display")}),
        (
            "Activity Stats",
            {
                "fields": (
                    "visit_count_display",
                    "last_url_display",
                    "first_visit_display",
                    "last_visit_display",
                    "created_at",
                    "updated_at",
                )
            },
        ),
    )

    def user_info(self, obj):
        if obj.user:
            return format_html("<strong>{}</strong>", obj.user.email)
        return format_html('<span style="color: #888;">Anonymous</span>')

    user_info.short_description = "User"
    user_info.admin_order_field = "user"

    def session_hash_short(self, obj):
        return f"{obj.session_hash[:8]}..."

    session_hash_short.short_description = "Session"
    session_hash_short.admin_order_field = "session_hash"

    def visit_count_display(self, obj):
        count = obj.visit_count
        return format_html("<strong>{}</strong> visits", count)

    visit_count_display.short_description = "Visits"

    def last_url_display(self, obj):
        url = obj.last_url
        if not url:
            return "-"
        if len(url) > 50:
            return f"{url[:47]}..."
        return url

    last_url_display.short_description = "Last URL"

    def last_visit_display(self, obj):
        return obj.last_visit

    last_visit_display.short_description = "Last Visit"
    last_visit_display.admin_order_field = "updated_at"

    def first_visit_display(self, obj):
        return obj.first_visit

    first_visit_display.short_description = "First Visit"

    def user_agent_display(self, obj):
        return obj.user_agent

    user_agent_display.short_description = "User Agent"

    def has_add_permission(self, request):
        return False


@admin.register(ActivityLog)
class ActivityLogAdmin(admin.ModelAdmin):
    list_display = [
        "timestamp",
        "user_info",
        "view_name",
        "url_short",
        "http_method",
        "session_link",
    ]
    list_filter = [
        "http_method",
        "view_name",
        "timestamp",
        "activity__user",
    ]
    search_fields = [
        "activity__user__email",
        "activity__ip_address",
        "url",
        "full_path",
        "view_name",
    ]
    readonly_fields = [
        "activity",
        "url",
        "full_path",
        "view_name",
        "http_method",
        "url_kwargs_display",
        "query_params_display",
        "referer",
        "timestamp",
    ]
    ordering = ["-timestamp"]
    date_hierarchy = "timestamp"

    fieldsets = (
        ("Session", {"fields": ("activity",)}),
        (
            "Request Info",
            {
                "fields": (
                    "timestamp",
                    "view_name",
                    "http_method",
                    "url",
                    "full_path",
                )
            },
        ),
        (
            "Parameters",
            {
                "fields": (
                    "url_kwargs_display",
                    "query_params_display",
                    "referer",
                )
            },
        ),
    )

    def user_info(self, obj):
        if obj.activity.user:
            return format_html("<strong>{}</strong>", obj.activity.user.email)
        return format_html(
            '<span style="color: #888;">Anonymous ({})</span>', obj.activity.ip_address
        )

    user_info.short_description = "User"
    user_info.admin_order_field = "activity__user"

    def url_short(self, obj):
        url = obj.url
        if len(url) > 60:
            return f"{url[:57]}..."
        return url

    url_short.short_description = "URL"
    url_short.admin_order_field = "url"

    def session_link(self, obj):
        url = reverse("admin:system_useractivity_change", args=[obj.activity.id])
        return format_html(
            '<a href="{}">{}</a>', url, obj.activity.session_hash[:8] + "..."
        )

    session_link.short_description = "Session"

    def url_kwargs_display(self, obj):
        if not obj.url_kwargs:
            return "-"
        return mark_safe(
            "<br>".join(
                [f"<strong>{k}:</strong> {v}" for k, v in obj.url_kwargs.items()]
            )
        )

    url_kwargs_display.short_description = "URL Parameters"

    def query_params_display(self, obj):
        if not obj.query_params:
            return "-"
        return mark_safe(
            "<br>".join(
                [f"<strong>{k}:</strong> {v}" for k, v in obj.query_params.items()]
            )
        )

    query_params_display.short_description = "Query Parameters"

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser
