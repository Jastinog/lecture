import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "camera.settings")

app = Celery("django_celery")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()

app.conf.beat_schedule = {
    "refresh-camera-session": {
        "task": "apps.dahua.tasks.refresh_camera_session",
        "schedule": 300.0,
    },
    "execute-preset-schedules": {
        "task": "apps.dahua.tasks.execute_preset_schedules",
        "schedule": 60.0,
    },
    "execute-droplet-schedules": {
        "task": "apps.digitalocean.tasks.execute_droplet_schedules",
        "schedule": 60.0,
    },
    "execute-youtube-schedules": {
        "task": "apps.youtube.tasks.execute_youtube_stream_schedules",
        "schedule": 60.0,
    },
    "refresh-youtube-tokens": {
        "task": "apps.youtube.tasks.refresh_youtube_tokens",
        "schedule": 1800.0,
    },
}

app.conf.timezone = "Europe/Kiev"
app.conf.enable_utc = False
