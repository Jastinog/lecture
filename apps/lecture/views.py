from django.shortcuts import render, get_object_or_404
from .models import Lecturer, Course


def lecturers_list(request):
    """List all lecturers"""
    lecturers = Lecturer.objects.prefetch_related("courses").all()
    context = {
        "lecturers": lecturers,
    }
    return render(request, "lecturers_list.html", context)


def lecturer_detail(request, lecturer_id):
    """Show all courses for a lecturer"""
    lecturer = get_object_or_404(Lecturer, id=lecturer_id)
    courses = lecturer.courses.prefetch_related("lectures").all()

    context = {
        "lecturer": lecturer,
        "courses": courses,
    }
    return render(request, "lecturer_detail.html", context)


def course_player(request, course_id):
    """Lecture player for a specific course"""
    course = get_object_or_404(Course.objects.select_related("lecturer"), id=course_id)
    lectures = course.lectures.all()

    context = {
        "course": course,
        "lectures": lectures,
        "lecture_count": lectures.count(),
    }
    return render(request, "course_player.html", context)
