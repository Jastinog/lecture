from django.shortcuts import render, get_object_or_404
from .models import Lecturer, Topic


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
    lectures = topic.lectures.all()

    context = {
        "topic": topic,
        "lectures": lectures,
        "lecture_count": lectures.count(),
    }
    return render(request, "topic_player.html", context)
