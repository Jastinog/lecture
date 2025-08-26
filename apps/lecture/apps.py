# -*- coding: utf-8 -*-
from django.apps import AppConfig


class LectureConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.lecture"

    def ready(self):
        """Import signal handlers when Django starts"""
        try:
            import apps.lecture.signals
        except ImportError:
            pass
