# apps/system/models.py
import hashlib
from django.db import models
from django.contrib.auth import get_user_model

from apps.users.models import User


class UserActivity(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, null=True, blank=True)
    session_hash = models.CharField(max_length=64, unique=True, db_index=True)
    ip_address = models.GenericIPAddressField()
    user_agent = models.TextField()
    last_url = models.URLField(max_length=500)
    visit_count = models.PositiveIntegerField(default=1)
    first_visit = models.DateTimeField(auto_now_add=True)
    last_visit = models.DateTimeField(auto_now=True)
    
    class Meta:
        ordering = ['-last_visit']
        indexes = [
            models.Index(fields=['session_hash']),
            models.Index(fields=['user', '-last_visit']),
            models.Index(fields=['-last_visit']),
        ]
    
    def __str__(self):
        user_info = self.user.email if self.user else f"Anonymous ({self.ip_address})"
        return f"{user_info} - {self.visit_count} visits"
    
    @staticmethod
    def generate_session_hash(ip_address, user_agent):
        """Generate hash from IP and User Agent"""
        data = f"{ip_address}:{user_agent}".encode('utf-8')
        return hashlib.sha256(data).hexdigest()
    
    @classmethod
    def track_activity(cls, request):
        """Track user activity from request"""
        ip = cls.get_client_ip(request)
        user_agent = request.META.get('HTTP_USER_AGENT', '')
        session_hash = cls.generate_session_hash(ip, user_agent)
        
        # Get or create activity record
        activity, created = cls.objects.get_or_create(
            session_hash=session_hash,
            defaults={
                'user': request.user if request.user.is_authenticated else None,
                'ip_address': ip,
                'user_agent': user_agent,
                'last_url': request.get_full_path(),
            }
        )
        
        if not created:
            # Update existing record
            activity.visit_count += 1
            activity.last_url = request.get_full_path()
            if request.user.is_authenticated and not activity.user:
                activity.user = request.user
            activity.save(update_fields=['visit_count', 'last_url', 'user', 'last_visit'])
        
        return activity
    
    @staticmethod
    def get_client_ip(request):
        """Get client IP from request"""
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0].strip()
        return request.META.get('REMOTE_ADDR', '127.0.0.1')
