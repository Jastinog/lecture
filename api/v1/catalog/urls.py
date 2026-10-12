from django.urls import path

from . import views

urlpatterns = [
    path("groups/", views.GroupListView.as_view(), name="catalog_groups"),
    path("topics/", views.TopicListView.as_view(), name="catalog_topics"),
    path("topics/<int:pk>/", views.TopicDetailView.as_view(), name="catalog_topic"),
    path("lecturers/", views.LecturerListView.as_view(), name="catalog_lecturers"),
    path(
        "lecturers/<int:pk>/",
        views.LecturerDetailView.as_view(),
        name="catalog_lecturer",
    ),
    path(
        "lecturers/<int:pk>/topics/",
        views.LecturerTopicsView.as_view(),
        name="catalog_lecturer_topics",
    ),
    path("search/", views.SearchView.as_view(), name="catalog_search"),
]
