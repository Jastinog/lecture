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

# Served over https only (nginx redirects plain http): the admin's cookies
# never go out unencrypted, and browsers remember to use https.
SESSION_COOKIE_SECURE = CSRF_COOKIE_SECURE = not DEBUG
SECURE_HSTS_SECONDS = env.int("SECURE_HSTS_SECONDS", default=0 if DEBUG else 31536000)
# nginx redirects to https; HSTS covers this host only, not its siblings.
SILENCED_SYSTEM_CHECKS = ["security.W005", "security.W008", "security.W021"]

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
    "apps.listeners",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    # ETags: an unchanged catalog page answers 304, and the app can keep it.
    "django.middleware.http.ConditionalGetMiddleware",
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

# The catalog is public. Listeners (`apps.listeners`) authenticate with a token
# only on the views that take one, so a bad token never breaks the catalog.
REST_FRAMEWORK = {
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.AllowAny",),
    "DEFAULT_AUTHENTICATION_CLASSES": (),
    "DEFAULT_RENDERER_CLASSES": ("rest_framework.renderers.JSONRenderer",),
    "UNAUTHENTICATED_USER": None,
    # Plays and registrations are throttled per address, syncs per listener;
    # the catalog is read-only.
    "DEFAULT_THROTTLE_RATES": {
        "plays": "120/hour",
        "listeners": "10/hour",
        "sync": "600/hour",
    },
    # nginx adds the client to X-Forwarded-For: throttle by that, not by nginx.
    "NUM_PROXIES": env.int("NUM_PROXIES", default=1),
}

# In Postgres, so throttles count across every gunicorn worker. The table is
# made by a migration (`listeners.0002_cache_table`).
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.db.DatabaseCache",
        "LOCATION": "cache",
    }
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

# Audio, covers and photos: on DigitalOcean Spaces when SPACES_BUCKET is set,
# public and served from its domain (the CDN's, given SPACES_DOMAIN); otherwise
# on disk, served by nginx.
MEDIA_ROOT = str(APPS_DIR / "media")
MEDIA_URL = "/media/"

SPACES_BUCKET = env.str("SPACES_BUCKET", default="")
if SPACES_BUCKET:
    SPACES_REGION = env.str("SPACES_REGION", default="fra1")
    STORAGES = {
        "default": {
            "BACKEND": "storages.backends.s3.S3Storage",
            "OPTIONS": {
                "bucket_name": SPACES_BUCKET,
                "region_name": SPACES_REGION,
                "endpoint_url": f"https://{SPACES_REGION}.digitaloceanspaces.com",
                "access_key": env.str("SPACES_KEY"),
                "secret_key": env.str("SPACES_SECRET"),
                "custom_domain": env.str(
                    "SPACES_DOMAIN",
                    default=f"{SPACES_BUCKET}.{SPACES_REGION}.digitaloceanspaces.com",
                ),
                "default_acl": "public-read",
                "querystring_auth": False,
                "file_overwrite": False,
                "object_parameters": {"CacheControl": "public, max-age=2592000"},
            },
        },
        "staticfiles": {
            "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage",
        },
    }

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Lectures are uploaded in batches through the admin. Files over Django's
# 2.5MB default go to a temp file rather than staying in memory.
DATA_UPLOAD_MAX_NUMBER_FILES = 2000
DATA_UPLOAD_MAX_NUMBER_FIELDS = 10000
