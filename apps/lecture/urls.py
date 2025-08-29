from django.urls import path
from . import views

app_name = "lecture"

urlpatterns = [
    path("", views.lecturers_list, name="lecturers_list"),
    path("lecturer/<int:lecturer_id>/", views.lecturer_detail, name="lecturer_detail"),
    path("topic/<int:topic_id>/", views.topic_player, name="topic_player"),
    path("progress/", views.update_progress, name="update_progress"),
]
