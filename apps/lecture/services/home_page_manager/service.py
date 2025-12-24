from django.utils import timezone
from django.core.cache import cache
from django.conf import settings
from datetime import timedelta

from django.db.models import Max, Prefetch
from apps.lecture.models import (
    Lecturer,
    Topic,
    Lecture,
    LectureProgress,
)


class HomePageManager:
    """Manager class for home page data logic"""

    # Cache keys
    CACHE_KEY_FIRST_LECTURER = "home:first_lecturer"
    CACHE_KEY_RANDOM_LECTURERS = "home:random_lecturers"
    CACHE_KEY_RANDOM_TOPICS = "home:random_topics"
    CACHE_KEY_RECENT_LECTURES = "home:recent_lectures"

    def __init__(self, user):
        self.user = user

    @property
    def is_authenticated(self):
        return self.user.is_authenticated

    def get_lecturers_data(self):
        """Get lecturers with order=1 first, then 4 random others"""
        # Get the first lecturer from cache or DB
        first_lecturer = cache.get(self.CACHE_KEY_FIRST_LECTURER)
        if first_lecturer is None:
            first_lecturer = (
                Lecturer.objects.prefetch_related("topics").filter(order=1).first()
            )
            cache.set(
                self.CACHE_KEY_FIRST_LECTURER,
                first_lecturer,
                settings.CACHE_TIMEOUT_LONG,
            )

        # Random lecturers - shorter cache (they change each load)
        other_lecturers = cache.get(self.CACHE_KEY_RANDOM_LECTURERS)
        if other_lecturers is None:
            other_lecturers = list(
                Lecturer.objects.prefetch_related("topics")
                .exclude(id=first_lecturer.id if first_lecturer else None)
                .order_by("?")[:4]
            )
            cache.set(
                self.CACHE_KEY_RANDOM_LECTURERS,
                other_lecturers,
                settings.CACHE_TIMEOUT_SHORT,
            )

        # Combine them
        lecturers = []
        if first_lecturer:
            lecturers.append(first_lecturer)
        lecturers.extend(other_lecturers)

        return lecturers

    def get_random_topics(self):
        """Get 5 random topics with their lecturers"""
        topics = cache.get(self.CACHE_KEY_RANDOM_TOPICS)
        if topics is None:
            topics = list(
                Topic.objects.select_related("lecturer")
                .prefetch_related("lectures")
                .order_by("?")[:5]
            )
            cache.set(self.CACHE_KEY_RANDOM_TOPICS, topics, settings.CACHE_TIMEOUT_SHORT)
        return topics

    def get_recent_lectures_from_latest_topics(self):
        """Get random lectures from the most recently created topics"""
        recent_lectures = cache.get(self.CACHE_KEY_RECENT_LECTURES)
        if recent_lectures is None:
            # Get the latest topic creation date
            latest_topic_date = Topic.objects.aggregate(Max("created_at"))[
                "created_at__max"
            ]

            if not latest_topic_date:
                return Lecture.objects.none()

            # Get topics created in the last period (same day as the latest)
            latest_topics = Topic.objects.filter(created_at__date=latest_topic_date.date())

            # Get random lectures from these latest topics
            recent_lectures = list(
                Lecture.objects.select_related("topic", "topic__lecturer")
                .filter(topic__in=latest_topics)
                .order_by("?")[:5]
            )
            cache.set(
                self.CACHE_KEY_RECENT_LECTURES,
                recent_lectures,
                settings.CACHE_TIMEOUT_SHORT,
            )

        return recent_lectures

    def get_favorite_lectures(self):
        """Get user's favorite lectures"""
        if not self.is_authenticated:
            return Lecture.objects.none()

        return (
            Lecture.objects.select_related("topic", "topic__lecturer", "language")
            .prefetch_related("favorited_by")
            .filter(favorited_by__user=self.user)[:5]
        )

    def get_history_lectures(self):
        """Get user's recent listening history"""
        if not self.is_authenticated:
            return Lecture.objects.none()

        return (
            Lecture.objects.select_related("topic", "topic__lecturer", "language")
            .filter(history_records__user=self.user)
            .distinct()
            .order_by("-history_records__listened_at")[:5]
        )

    def get_now_listening(self):
        """Get what users are currently listening to (updated within last minute)"""
        if not self.is_authenticated:
            return LectureProgress.objects.none()

        one_minute_ago = timezone.now() - timedelta(minutes=1)

        return (
            LectureProgress.objects.select_related(
                "lecture",
                "lecture__topic",
                "lecture__topic__lecturer",
                "lecture__language",
                "user",
            )
            .exclude(user=self.user)
            .filter(current_time__gt=0, updated_at__gte=one_minute_ago)
            .order_by("-updated_at")[:5]
        )

    def get_context_data(self):
        """Get all context data for home template"""
        context = {
            "lecturers": self.get_lecturers_data(),
            "topics": self.get_random_topics(),
            "recent_lectures": self.get_recent_lectures_from_latest_topics(),
        }

        # Add user-specific data if authenticated
        if self.is_authenticated:
            context.update(
                {
                    "favorite_lectures": self.get_favorite_lectures(),
                    "history_lectures": self.get_history_lectures(),
                    "now_listening": self.get_now_listening(),
                }
            )

        return context
