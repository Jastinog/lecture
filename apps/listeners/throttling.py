from rest_framework.throttling import SimpleRateThrottle


class ListenerRateThrottle(SimpleRateThrottle):
    """Per listener; for views that require one."""

    def get_cache_key(self, request, view):
        return self.cache_format % {"scope": self.scope, "ident": request.user.pk}
