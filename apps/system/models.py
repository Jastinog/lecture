import hashlib
from django.db import models
from django.utils import timezone
from apps.users.models import User


class UserActivity(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, null=True, blank=True)
    session_hash = models.CharField(max_length=64, unique=True, db_index=True)
    ip_address = models.GenericIPAddressField()
    user_agent = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]
        indexes = [
            models.Index(fields=["session_hash"]),
            models.Index(fields=["user", "-updated_at"]),
            models.Index(fields=["-updated_at"]),
        ]
        verbose_name = "User Activity"
        verbose_name_plural = "User Activities"

    def __str__(self):
        user_info = self.user.email if self.user else f"Anonymous ({self.ip_address})"
        return f"{user_info} - Session: {self.session_hash[:8]}..."

    @property
    def visit_count(self):
        return self.logs.count()

    @property
    def last_url(self):
        last_log = self.logs.first()
        return last_log.url if last_log else None

    @property
    def first_visit(self):
        return self.created_at

    @property
    def last_visit(self):
        last_log = self.logs.first()
        return last_log.timestamp if last_log else self.updated_at

    @staticmethod
    def generate_session_hash(ip_address, user_agent):
        data = f"{ip_address}:{user_agent}".encode("utf-8")
        return hashlib.sha256(data).hexdigest()

    @classmethod
    def track_activity(cls, request):
        ip = cls.get_client_ip(request)
        user_agent = request.META.get("HTTP_USER_AGENT", "")
        session_hash = cls.generate_session_hash(ip, user_agent)

        activity, created = cls.objects.get_or_create(
            session_hash=session_hash,
            defaults={
                "user": request.user if request.user.is_authenticated else None,
                "ip_address": ip,
                "user_agent": user_agent,
            },
        )

        if not created:
            if request.user.is_authenticated and not activity.user:
                activity.user = request.user
                activity.save(update_fields=["user", "updated_at"])

        return activity

    @staticmethod
    def get_client_ip(request):
        x_forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR")
        if x_forwarded_for:
            return x_forwarded_for.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "127.0.0.1")


class ActivityLog(models.Model):
    activity = models.ForeignKey(
        UserActivity, on_delete=models.CASCADE, related_name="logs"
    )

    url = models.URLField(max_length=500)
    full_path = models.CharField(max_length=500)
    view_name = models.CharField(max_length=100)
    http_method = models.CharField(max_length=10)

    url_kwargs = models.JSONField(default=dict, blank=True)
    query_params = models.JSONField(default=dict, blank=True)

    referer = models.URLField(max_length=500, blank=True, null=True)

    timestamp = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-timestamp"]
        indexes = [
            models.Index(fields=["activity", "-timestamp"]),
            models.Index(fields=["view_name", "-timestamp"]),
            models.Index(fields=["-timestamp"]),
        ]
        verbose_name = "Activity Log"
        verbose_name_plural = "Activity Logs"

    def __str__(self):
        user = self.activity.user.email if self.activity.user else "Anonymous"
        return f"{user} - {self.view_name} - {self.timestamp}"

    @classmethod
    def create_log(cls, activity, request, view_name, url_kwargs=None):
        query_params = dict(request.GET.items())

        return cls.objects.create(
            activity=activity,
            url=request.path,
            full_path=request.get_full_path(),
            view_name=view_name,
            http_method=request.method,
            url_kwargs=url_kwargs or {},
            query_params=query_params,
            referer=request.META.get("HTTP_REFERER"),
        )

    @classmethod
    def get_user_activity_timeline(cls, session_hash, days=30):
        from datetime import timedelta

        cutoff_date = timezone.now() - timedelta(days=days)

        return (
            cls.objects.filter(
                activity__session_hash=session_hash, timestamp__gte=cutoff_date
            )
            .select_related("activity")
            .order_by("-timestamp")
        )

    @classmethod
    def get_popular_pages(cls, days=7):
        from datetime import timedelta
        from django.db.models import Count

        cutoff_date = timezone.now() - timedelta(days=days)

        return (
            cls.objects.filter(timestamp__gte=cutoff_date)
            .values("view_name", "url")
            .annotate(visits=Count("id"))
            .order_by("-visits")
        )
