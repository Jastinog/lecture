from functools import wraps
from apps.system.models import UserActivity, ActivityLog
from apps.system.services import Logger

logger = Logger(app_name="activity_decorator")


def track_activity(view_func):
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        try:
            activity = UserActivity.track_activity(request)

            ActivityLog.create_log(
                activity=activity,
                request=request,
                view_name=view_func.__name__,
                url_kwargs=kwargs,
            )

            logger.debug(
                f"Activity tracked: {activity.session_hash[:8]}...",
                f"View: {view_func.__name__}",
                f"URL: {request.path}",
                f"User: {activity.user.email if activity.user else 'Anonymous'}",
            )

        except Exception as e:
            logger.error(f"Error tracking activity in {view_func.__name__}: {str(e)}")

        return view_func(request, *args, **kwargs)

    return wrapper
