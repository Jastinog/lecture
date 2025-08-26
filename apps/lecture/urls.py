from django.urls import path
from . import views

app_name = "lecture"

urlpatterns = [
    path("", views.lecturers_list, name="lecturers_list"),
    path("lecturer/<int:lecturer_id>/", views.lecturer_detail, name="lecturer_detail"),
    path("course/<int:course_id>/", views.course_player, name="course_player"),
]
