import json
import requests

from django.conf import settings
from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods
from django.http import StreamingHttpResponse, Http404, JsonResponse

from .models import (
    Lecture,
    Lecturer,
    Topic,
    LectureProgress,
    CurrentLecture,
    FavoriteLecture,
)


@login_required
def serve_audio(request, lecture_id):
    """Load and serve audio file"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    if not lecture.audio_file:
        raise Http404("Audio file not found")

    # Check if using S3 or local storage
    if settings.USE_S3_MEDIA:
        file_url = lecture.audio_file.url
    else:
        file_url = f"{settings.BACKEND_URL}{lecture.audio_file.url}"

    try:
        headers = {}
        if "HTTP_RANGE" in request.META:
            headers["Range"] = request.META["HTTP_RANGE"]

        file_response = requests.get(file_url, headers=headers, stream=True)
        file_response.raise_for_status()

        response = StreamingHttpResponse(
            file_response.iter_content(chunk_size=8192),
            content_type=file_response.headers.get("Content-Type", "audio/mpeg"),
            status=file_response.status_code,
        )

        for header in ["Content-Length", "Content-Range", "Accept-Ranges"]:
            if header in file_response.headers:
                response[header] = file_response.headers[header]

        return response

    except requests.RequestException:
        raise Http404("Failed to load audio file")


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

    # Get current lecture for this topic
    current_lecture = None
    current_lecture_progress = None
    if request.user.is_authenticated:
        current_lecture_obj = CurrentLecture.objects.filter(
            user=request.user, topic=topic
        ).first()
        if current_lecture_obj:
            current_lecture = current_lecture_obj.lecture
            # Get progress for current lecture
            current_lecture_progress = LectureProgress.objects.filter(
                user=request.user, lecture=current_lecture
            ).first()

    # Always attach progress data to each lecture
    if request.user.is_authenticated:
        progress_records = LectureProgress.objects.filter(
            user=request.user, lecture__in=lectures
        ).select_related("lecture")

        progress_dict = {record.lecture.id: record for record in progress_records}

        # Get favorite lectures
        from .models import FavoriteLecture

        favorite_lectures = set(
            FavoriteLecture.objects.filter(
                user=request.user, lecture__in=lectures
            ).values_list("lecture_id", flat=True)
        )

        for lecture in lectures:
            progress = progress_dict.get(lecture.id)
            if progress:
                lecture.progress = progress
            else:
                # Create default progress object for display
                lecture.progress = type(
                    "obj",
                    (object,),
                    {
                        "progress_percentage": 0,
                        "completed": False,
                        "listen_count": 0,
                        "current_time": 0,
                    },
                )()

            # Add favorite status
            lecture.is_favorite = lecture.id in favorite_lectures

    context = {
        "topic": topic,
        "lectures": lectures,
        "lecture_count": lectures.count(),
        "current_lecture": current_lecture,
        "current_lecture_progress": current_lecture_progress,
    }

    return render(request, "topic_player.html", context)


@login_required
@csrf_exempt
@require_http_methods(["POST", "GET"])
def update_progress(request):
    """Get or update lecture progress"""
    if request.method == "GET":
        lecture_id = request.GET.get("lecture_id")
        if not lecture_id:
            return JsonResponse({"error": "lecture_id required"}, status=400)

        try:
            lecture = get_object_or_404(Lecture, id=lecture_id)
            progress = LectureProgress.objects.filter(
                user=request.user, lecture=lecture
            ).first()

            if progress:
                return JsonResponse(
                    {
                        "current_time": progress.current_time,
                        "progress_percentage": progress.progress_percentage,
                        "completed": progress.completed,
                        "listen_count": progress.listen_count,
                    }
                )
            else:
                return JsonResponse(
                    {
                        "current_time": 0,
                        "progress_percentage": 0,
                        "completed": False,
                        "listen_count": 0,
                    }
                )
        except Exception as e:
            return JsonResponse({"error": str(e)}, status=500)

    elif request.method == "POST":
        try:
            data = json.loads(request.body)
            lecture_id = data.get("lecture_id")
            current_time = data.get("current_time", 0)
            duration = data.get("duration", 0)
            completed = data.get("completed", False)

            if not lecture_id:
                return JsonResponse({"error": "lecture_id required"}, status=400)

            lecture = get_object_or_404(Lecture, id=lecture_id)

            progress, created = LectureProgress.objects.update_or_create(
                user=request.user,
                lecture=lecture,
                defaults={
                    "current_time": current_time, 
                    "completed": completed
                },
            )

            if completed:
                progress.listen_count += 1
                progress.save(update_fields=["listen_count"])

            return JsonResponse(
                {
                    "success": True,
                    "current_time": progress.current_time,
                    "progress_percentage": progress.progress_percentage,
                    "completed": progress.completed,
                    "listen_count": progress.listen_count,
                }
            )

        except Exception as e:
            return JsonResponse({"error": str(e)}, status=500)


@login_required
@csrf_exempt
@require_http_methods(["POST"])
def set_current_lecture(request):
    """Set current lecture for a topic and save to history"""
    try:
        data = json.loads(request.body)
        lecture_id = data.get("lecture_id")

        if not lecture_id:
            return JsonResponse({"error": "lecture_id required"}, status=400)

        lecture = get_object_or_404(Lecture, id=lecture_id)

        # Update or create current lecture
        current_lecture, created = CurrentLecture.objects.update_or_create(
            user=request.user, topic=lecture.topic, defaults={"lecture": lecture}
        )

        # Save to lecture history
        from .models import LectureHistory

        # Get current progress to calculate completion percentage
        progress = LectureProgress.objects.filter(
            user=request.user, lecture=lecture
        ).first()

        completion_percentage = 0.0
        duration_listened = 0

        if progress:
            completion_percentage = progress.progress_percentage
            duration_listened = int(progress.current_time)

        # Update or create history record for today
        from django.utils import timezone

        today = timezone.now().date()

        LectureHistory.objects.update_or_create(
            user=request.user,
            lecture=lecture,
            listened_at__date=today,
            defaults={
                "duration_listened": duration_listened,
                "completion_percentage": completion_percentage,
            },
        )

        return JsonResponse(
            {"success": True, "current_lecture_id": current_lecture.lecture.id}
        )

    except Exception as e:
        return JsonResponse({"error": str(e)}, status=500)


@login_required
@csrf_exempt
@require_http_methods(["POST"])
def toggle_favorite(request):
    """Add or remove lecture from favorites"""
    try:
        data = json.loads(request.body)
        lecture_id = data.get("lecture_id")
        action = data.get("action")  # 'add' or 'remove'

        if not lecture_id or not action:
            return JsonResponse({"error": "lecture_id and action required"}, status=400)

        lecture = get_object_or_404(Lecture, id=lecture_id)

        if action == "add":
            favorite, created = FavoriteLecture.objects.get_or_create(
                user=request.user, lecture=lecture
            )
            is_favorite = True
        elif action == "remove":
            deleted_count, _ = FavoriteLecture.objects.filter(
                user=request.user, lecture=lecture
            ).delete()
            is_favorite = False
        else:
            return JsonResponse(
                {"error": "action must be 'add' or 'remove'"}, status=400
            )

        return JsonResponse(
            {"success": True, "is_favorite": is_favorite, "lecture_id": lecture.id}
        )

    except Exception as e:
        return JsonResponse({"error": str(e)}, status=500)
