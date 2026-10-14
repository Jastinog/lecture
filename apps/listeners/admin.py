from django.contrib import admin

from .models import Listener


@admin.register(Listener)
class ListenerAdmin(admin.ModelAdmin):
    """Who uses the app: read only, the app registers them."""

    list_display = ["id", "created_at", "last_seen", "platform", "app_version"]
    list_filter = ["platform", "app_version"]
    search_fields = ["id"]
    ordering = ["-last_seen"]
    date_hierarchy = "created_at"
    exclude = ["token_hash"]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False
