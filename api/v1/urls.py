from django.urls import include, path

urlpatterns = [
    path("", include("api.v1.catalog.urls")),
    path("", include("api.v1.listeners.urls")),
]
