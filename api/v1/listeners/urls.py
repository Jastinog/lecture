from django.urls import path

from . import views

urlpatterns = [
    path("listeners/", views.ListenerListView.as_view(), name="listeners"),
]
