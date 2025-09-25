from django.urls import path
from . import views

app_name = "lecture"

urlpatterns = [
    path("", views.home, name="home"),
    path("lecturers/", views.lecturers_list, name="lecturers_list"),
    path("lecturer/<int:lecturer_id>/", views.lecturer_detail, name="lecturer_detail"),
    path("topic/<int:topic_id>/", views.topic_detail, name="topic_detail"),
    path("lecture/<int:lecture_id>/", views.lecture_player, name="lecture_player"),
    path(
        "lecture/<int:lecture_id>/<int:start_time>/",
        views.lecture_player,
        name="lecture_player_with_time",
    ),
    # Section pages
    path("topics/", views.topics_list, name="topics_list"),
    path("recent-lectures/", views.recent_lectures, name="recent_lectures"),
    path("favorites/", views.favorites_list, name="favorites_list"),
    path("history/", views.history_list, name="history_list"),
    path("now-listening/", views.now_listening_list, name="now_listening_list"),
]
