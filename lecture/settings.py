# -*- coding: utf-8 -*-
"""
Django settings for the lecture project: the admin, where the catalog is
managed, and the public read-only API the iOS app plays from.
"""
from pathlib import Path

import environ

BASE_DIR = Path(__file__).resolve().parent.parent
APPS_DIR = BASE_DIR / "apps"

env = environ.Env()
env.read_env(str(BASE_DIR) + "/.env")

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = env.bool("DEBUG", default=False)
ENVIRONMENT = env.str("ENVIRONMENT")

ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=["127.0.0.1", "0.0.0.0"])

CSRF_TRUSTED_ORIGINS = env.list(
    "CSRF_TRUSTED_ORIGINS", default=["http://127.0.0.1", "http://0.0.0.0"]
)

# nginx terminates TLS; trust its header so absolute URLs come out as https.
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

AUTH_USER_MODEL = "users.User"

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.humanize",
    "rest_framework",
    "apps.users",
    "apps.lecture",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "lecture.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "lecture.wsgi.application"

SECRET_KEY = env.str("SECRET_KEY")

DEFAULT_ADMIN_EMAIL = env.str("DEFAULT_ADMIN_EMAIL")
DEFAULT_ADMIN_PASSWORD = env.str("DEFAULT_ADMIN_PASSWORD")

DATABASES = {"default": env.db("DATABASE_URL")}
DATABASES["default"]["ATOMIC_REQUESTS"] = True
DATABASES["default"]["CONN_MAX_AGE"] = env.int("CONN_MAX_AGE", default=60)

AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.CommonPasswordValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.NumericPasswordValidator",
    },
]

# The API is the public catalog: no accounts, listening data stays on the phone.
REST_FRAMEWORK = {
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.AllowAny",),
    "DEFAULT_AUTHENTICATION_CLASSES": (),
    "DEFAULT_RENDERER_CLASSES": ("rest_framework.renderers.JSONRenderer",),
    "UNAUTHENTICATED_USER": None,
}

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "console": {"format": "%(name)-12s %(levelname)-8s %(message)s"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "console"},
    },
    "loggers": {
        "": {"level": "WARNING", "handlers": ["console"]},
        "apps": {"level": "INFO", "handlers": ["console"], "propagate": False},
    },
}

LANGUAGE_CODE = "en-us"
TIME_ZONE = "Europe/Kyiv"
USE_I18N = True
USE_TZ = True

STATIC_ROOT = str(BASE_DIR / "staticfiles")
STATIC_URL = "/static/"

# Audio, covers and photos live on disk; nginx serves them in production.
MEDIA_ROOT = str(APPS_DIR / "media")
MEDIA_URL = "/media/"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Lectures are uploaded in batches through the admin.
DATA_UPLOAD_MAX_NUMBER_FILES = 2000
FILE_UPLOAD_MAX_MEMORY_SIZE = 500 * 1024 * 1024
DATA_UPLOAD_MAX_MEMORY_SIZE = 500 * 1024 * 1024
DATA_UPLOAD_MAX_NUMBER_FIELDS = 10000
