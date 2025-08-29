from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from .models import Lecturer, Topic, LectureProgress


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


@login_required(login_url="/auth/login/")
def topic_player(request, topic_id):
    """Lecture player for a specific topic"""
    topic = get_object_or_404(Topic.objects.select_related("lecturer"), id=topic_id)
    lectures = topic.lectures.all()

    # Always attach progress data to each lecture
    if request.user.is_authenticated:
        progress_records = LectureProgress.objects.filter(
            user=request.user, lecture__in=lectures
        ).select_related("lecture")

        progress_dict = {record.lecture.id: record for record in progress_records}

        for lecture in lectures:
            progress = progress_dict.get(lecture.id)
            if progress:
                lecture.progress = progress
            else:
                # Create default progress object for display
                lecture.progress = type('obj', (object,), {
                    'progress_percentage': 0,
                    'completed': False,
                    'listen_count': 0,
                    'current_time': 0
                })()

    context = {
        "topic": topic,
        "lectures": lectures,
        "lecture_count": lectures.count(),
    }

    return render(request, "topic_player.html", context)
