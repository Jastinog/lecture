from django.urls import path, include

urlpatterns = [
    path("", include("api.v1.catalog.urls")),
    path("lectures/", include("api.v1.lectures.urls")),
]
