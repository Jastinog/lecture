from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from django.db.models import Max

from apps.lecture.services import HomePageManager, TopicPlayerManager

from .models import (
    Lecturer,
    Topic,
    Lecture,
    CurrentLecture,
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
    topics = lecturer.topics.prefetch_related("lectures").all()

    context = {
        "lecturer": lecturer,
        "topics": topics,
    }
    return render(request, "lecturer_detail.html", context)


def topic_player(request, topic_id):
    """Lecture player for a specific topic"""
    topic = get_object_or_404(Topic.objects.select_related("lecturer"), id=topic_id)

    manager = TopicPlayerManager(request.user, topic)
    context = manager.get_context_data()

    return render(request, "topic_player.html", context)


def topics_list(request):
    """All topics page"""
    topics = Topic.objects.select_related("lecturer").prefetch_related("lectures").all()
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
            Lecture.objects.select_related("topic__lecturer")
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
        Lecture.objects.select_related("topic__lecturer")
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
        Lecture.objects.select_related("topic__lecturer")
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
    current_sessions = (
        CurrentLecture.objects.select_related("lecture__topic__lecturer", "user")
        .exclude(user=request.user)
        .order_by("-updated_at")
    )

    context = {
        "current_sessions": current_sessions,
        "page_title": "Сейчас слушают",
    }
    return render(request, "now_listening_list.html", context)
