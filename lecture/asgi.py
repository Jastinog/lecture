# -*- coding: utf-8 -*-
import os

from channels.auth import AuthMiddlewareStack
from channels.routing import ProtocolTypeRouter, URLRouter
from django.core.asgi import get_asgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "camera.settings")


def get_websocket_routes():
    from apps.websocket.routing import websocket_urlpatterns

    return websocket_urlpatterns


application = ProtocolTypeRouter(
    {
        "http": get_asgi_application(),
        "websocket": AuthMiddlewareStack(URLRouter(get_websocket_routes())),
    }
)
