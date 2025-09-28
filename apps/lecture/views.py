from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from django.db.models import Max

from apps.lecture.services import HomePageManager, TopicPlayerManager

from .models import (
    Lecturer,
    Topic,
    Lecture,
    LectureProgress,
    FavoriteLecture,
    LectureMarker
)


def home(request):
    """Main page with lecturers, topics, lectures, favorites and history"""
    manager = HomePageManager(request.user)
    context = manager.get_context_data()
    return render(request, "home.html", context)


def lecturers_list(request):
    """List all lecturers"""
    lecturers = Lecturer.objects.prefetch_related("topics").all()
    context = {
        "lecturers": lecturers,
    }
    return render(request, "lecturers_list.html", context)


def lecturer_detail(request, lecturer_id):
    """Show all topics for a lecturer"""
    lecturer = get_object_or_404(Lecturer, id=lecturer_id)
    topics = (
        lecturer.topics.select_related("group")
        .prefetch_related("lectures", "languages")
        .all()
    )

    context = {
        "lecturer": lecturer,
        "topics": topics,
    }
    return render(request, "lecturer_detail.html", context)


def topic_detail(request, topic_id):
    """Show all lectures for a topic"""
    topic = get_object_or_404(
        Topic.objects.select_related("lecturer", "group").prefetch_related("languages"),
        id=topic_id,
    )

    manager = TopicPlayerManager(request.user, topic)
    context = manager.get_context_data()

    # Remove player-specific data, keep only list data
    context.pop("current_lecture", None)
    context.pop("current_lecture_progress", None)

    return render(request, "topic_detail.html", context)


def lecture_player(request, lecture_id, start_time=None):
    """Single lecture player"""
    lecture = get_object_or_404(
        Lecture.objects.select_related("topic__lecturer", "language"), id=lecture_id
    )
    topic = lecture.topic

    lecture_progress = None
    is_favorite = False
    markers = []

    if request.user.is_authenticated:
        lecture_progress = LectureProgress.objects.filter(
            user=request.user, lecture=lecture
        ).first()

        is_favorite = FavoriteLecture.objects.filter(
            user=request.user, lecture=lecture
        ).exists()
        
        markers = LectureMarker.objects.filter(
            user=request.user, lecture=lecture
        ).order_by('timestamp')

    prev_lecture = (
        topic.lectures.filter(order__lt=lecture.order).order_by("-order").first()
    )
    next_lecture = (
        topic.lectures.filter(order__gt=lecture.order).order_by("order").first()
    )

    total_lectures = topic.lectures.count()

    context = {
        "lecture": lecture,
        "topic": topic,
        "lecture_progress": lecture_progress,
        "is_favorite": is_favorite,
        "markers": markers,
        "prev_lecture": prev_lecture,
        "next_lecture": next_lecture,
        "total_lectures": total_lectures,
        "target_start_time": start_time or 0,
    }

    return render(request, "lecture_player.html", context)


def topics_list(request):
    """All topics page"""
    topics = (
        Topic.objects.select_related("lecturer", "group")
        .prefetch_related("lectures", "languages")
        .all()
    )
    context = {
        "topics": topics,
        "page_title": "Все темы",
    }
    return render(request, "topics_list.html", context)


def recent_lectures(request):
    """Recent lectures page"""
    latest_topic_date = Topic.objects.aggregate(Max("created_at"))["created_at__max"]

    if latest_topic_date:
        latest_topics = Topic.objects.filter(created_at__date=latest_topic_date.date())
        lectures = (
            Lecture.objects.select_related("topic__lecturer", "language")
            .filter(topic__in=latest_topics)
            .order_by("-created_at")
        )
    else:
        lectures = Lecture.objects.none()

    context = {
        "lectures": lectures,
        "page_title": "Новые лекции",
    }
    return render(request, "lectures_list.html", context)


@login_required
def favorites_list(request):
    """User's favorites page"""
    lectures = (
        Lecture.objects.select_related("topic__lecturer", "language")
        .filter(favorited_by__user=request.user)
        .order_by("-favorited_by__created_at")
    )

    context = {
        "lectures": lectures,
        "page_title": "Избранные лекции",
    }
    return render(request, "lectures_list.html", context)


@login_required
def history_list(request):
    """User's listening history page"""
    lectures = (
        Lecture.objects.select_related("topic__lecturer", "language")
        .filter(history_records__user=request.user)
        .distinct()
        .order_by("-history_records__listened_at")
    )

    context = {
        "lectures": lectures,
        "page_title": "История прослушивания",
    }
    return render(request, "lectures_list.html", context)


@login_required
def now_listening_list(request):
    """What others are listening to page"""
    from .models import CurrentLecture

    current_sessions = (
        CurrentLecture.objects.select_related(
            "lecture__topic__lecturer", "lecture__language", "user"
        )
        .exclude(user=request.user)
        .order_by("-updated_at")
    )

    context = {
        "current_sessions": current_sessions,
        "page_title": "Сейчас слушают",
    }
    return render(request, "now_listening_list.html", context)
