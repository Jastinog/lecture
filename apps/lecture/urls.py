from django.urls import path
from . import views

app_name = "lecture"

urlpatterns = [
    path("", views.lecturers_list, name="lecturers_list"),
    path("lecturer/<int:lecturer_id>/", views.lecturer_detail, name="lecturer_detail"),
    path("topic/<int:topic_id>/", views.topic_player, name="topic_player"),
    path("api/audio/<int:lecture_id>/", views.serve_audio, name="serve_audio"),
    path("api/progress/", views.update_progress, name="update_progress"),
    path("api/current-lecture/", views.set_current_lecture, name="set_current_lecture"),
    path("api/favorite/", views.toggle_favorite, name="toggle_favorite"),
]
