from django.urls import path, include

urlpatterns = [
    path("lectures/", include("api.v1.lectures.urls")),
]
