import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "lecture.settings")

app = Celery("django_celery")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()

app.conf.timezone = "Europe/Kiev"
app.conf.enable_utc = False
