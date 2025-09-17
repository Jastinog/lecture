from django.urls import path
from . import views

app_name = "lecture"

urlpatterns = [
    path("", views.home, name="home"),
    path("lecturers/", views.lecturers_list, name="lecturers_list"),
    path("lecturer/<int:lecturer_id>/", views.lecturer_detail, name="lecturer_detail"),
    path("topic/<int:topic_id>/", views.topic_player, name="topic_player"),
    
    # Section pages
    path("topics/", views.topics_list, name="topics_list"),
    path("recent-lectures/", views.recent_lectures, name="recent_lectures"),
    path("favorites/", views.favorites_list, name="favorites_list"),
    path("history/", views.history_list, name="history_list"),
    path("now-listening/", views.now_listening_list, name="now_listening_list"),
]
