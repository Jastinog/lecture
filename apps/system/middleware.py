# apps/system/middleware.py
from apps.system.models import UserActivity
from apps.system.services import Logger

logger = Logger(app_name="activity_middleware")


class ActivityTrackingMiddleware:
    """Middleware to track user activity"""
    
    def __init__(self, get_response):
        self.get_response = get_response
    
    def __call__(self, request):
        # Track activity before processing request
        self.track_user_activity(request)
        
        response = self.get_response(request)
        return response
    
    def track_user_activity(self, request):
        """Track user activity from request"""
        try:
            # Only track exact main lecture app pages
            track_paths = [
                '/',  # lecturers_list (exact match)
            ]
            
            # Check exact path or lecturer/topic patterns
            should_track = (
                request.path == '/' or
                request.path.startswith('/lecturer/') or
                request.path.startswith('/topic/')
            ) and not request.path.startswith('/admin/')
            
            if not should_track:
                return
            
            # Track activity
            activity = UserActivity.track_activity(request)
            
            logger.debug(
                f"Activity tracked: {activity.session_hash[:8]}...",
                f"IP: {activity.ip_address}",
                f"URL: {activity.last_url}",
                f"Visits: {activity.visit_count}",
                f"User: {activity.user.email if activity.user else 'Anonymous'}"
            )
            
        except Exception as e:
            logger.error(f"Error tracking activity: {str(e)}")
            # Don't break the request if tracking fails
