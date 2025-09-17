import requests
from django.conf import settings
from django.http import StreamingHttpResponse, Http404
from django.shortcuts import get_object_or_404
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from apps.lecture.models import (
    Lecture,
    LectureProgress,
    CurrentLecture,
    FavoriteLecture,
    LectureHistory,
)


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def lecture_progress(request, lecture_id):
    """Get or update lecture progress"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    if request.method == "GET":
        progress = LectureProgress.objects.filter(
            user=request.user, lecture=lecture
        ).first()

        if progress:
            return Response(
                {
                    "current_time": progress.current_time,
                    "progress_percentage": progress.progress_percentage,
                    "completed": progress.completed,
                    "listen_count": progress.listen_count,
                }
            )
        else:
            return Response(
                {
                    "current_time": 0,
                    "progress_percentage": 0,
                    "completed": False,
                    "listen_count": 0,
                }
            )

    elif request.method == "POST":
        current_time = request.data.get("current_time", 0)
        completed = request.data.get("completed", False)

        progress, created = LectureProgress.objects.update_or_create(
            user=request.user,
            lecture=lecture,
            defaults={"current_time": current_time, "completed": completed},
        )

        if completed:
            progress.listen_count += 1
            progress.save(update_fields=["listen_count", "updated_at"])
        else:
            progress.save(update_fields=["updated_at"])

        return Response(
            {
                "success": True,
                "current_time": progress.current_time,
                "progress_percentage": progress.progress_percentage,
                "completed": progress.completed,
                "listen_count": progress.listen_count,
            }
        )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def set_current_lecture(request, lecture_id):
    """Set current lecture for a topic and save to history"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    # Update or create current lecture
    current_lecture, created = CurrentLecture.objects.update_or_create(
        user=request.user, topic=lecture.topic, defaults={"lecture": lecture}
    )

    # Save to lecture history
    from django.utils import timezone

    progress = LectureProgress.objects.filter(
        user=request.user, lecture=lecture
    ).first()

    completion_percentage = progress.progress_percentage if progress else 0.0
    duration_listened = int(progress.current_time) if progress else 0

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

    return Response({"success": True, "current_lecture_id": current_lecture.lecture.id})


@api_view(["POST", "DELETE"])
@permission_classes([IsAuthenticated])
def toggle_favorite(request, lecture_id):
    """Add or remove lecture from favorites"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    if request.method == "POST":
        favorite, created = FavoriteLecture.objects.get_or_create(
            user=request.user, lecture=lecture
        )
        is_favorite = True
    elif request.method == "DELETE":
        deleted_count, _ = FavoriteLecture.objects.filter(
            user=request.user, lecture=lecture
        ).delete()
        is_favorite = False

    return Response(
        {"success": True, "is_favorite": is_favorite, "lecture_id": lecture.id}
    )


@api_view(["GET"])
@permission_classes([AllowAny])
def serve_audio(request, lecture_id):
    """Stream audio file for authenticated users"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    if not lecture.audio_file:
        raise Http404("Audio file not found")

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
