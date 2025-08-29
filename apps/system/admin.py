# Add to apps/system/admin.py
from django.contrib import admin
from django.utils.html import format_html
from apps.system.models import UserActivity


@admin.register(UserActivity)
class UserActivityAdmin(admin.ModelAdmin):
    list_display = [
        "user_info",
        "ip_address",
        "visit_count",
        "last_url_short",
        "session_hash_short",
        "last_visit",
        "first_visit",
    ]
    list_filter = ["user", "first_visit", "last_visit"]
    search_fields = ["user__email", "ip_address", "last_url", "session_hash"]
    readonly_fields = ["session_hash", "first_visit", "user_agent_display"]
    ordering = ["-last_visit"]

    fieldsets = (
        ("User Information", {"fields": ("user", "session_hash")}),
        (
            "Request Details",
            {"fields": ("ip_address", "user_agent_display", "last_url")},
        ),
        ("Activity Stats", {"fields": ("visit_count", "first_visit", "last_visit")}),
    )

    def user_info(self, obj):
        if obj.user:
            return format_html("<strong>{}</strong>", obj.user.email)
        return format_html('<span style="color: #888;">Anonymous</span>')

    user_info.short_description = "User"

    def session_hash_short(self, obj):
        return f"{obj.session_hash[:8]}..."

    session_hash_short.short_description = "Session"

    def last_url_short(self, obj):
        url = obj.last_url
        if len(url) > 50:
            return f"{url[:47]}..."
        return url

    last_url_short.short_description = "Last URL"

    def user_agent_display(self, obj):
        return obj.user_agent

    user_agent_display.short_description = "User Agent"

    def has_add_permission(self, request):
        return False  # Disable manual creation
