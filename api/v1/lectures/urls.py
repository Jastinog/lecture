from django.urls import path
from . import views

urlpatterns = [
    # Lecture progress endpoints
    path("<int:lecture_id>/progress/", views.lecture_progress, name="lecture_progress"),
    # Set current lecture
    path(
        "<int:lecture_id>/set-current/",
        views.set_current_lecture,
        name="set_current_lecture",
    ),
    # Toggle favorite
    path("<int:lecture_id>/favorite/", views.toggle_favorite, name="toggle_favorite"),
    path("<int:lecture_id>/markers/", views.lecture_markers, name="lecture_markers"),
    path("markers/<int:marker_id>/", views.marker_detail, name="marker_detail"),
]
