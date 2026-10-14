from django.urls import path

from . import views

urlpatterns = [
    path("listeners/", views.ListenerListView.as_view(), name="listeners"),
    path("sync/", views.SyncView.as_view(), name="sync"),
]
