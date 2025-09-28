from django.shortcuts import get_object_or_404
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from apps.lecture.models import (
    Lecture,
    LectureProgress,
    CurrentLecture,
    FavoriteLecture,
    LectureHistory,
    LectureMarker,
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

@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def lecture_markers(request, lecture_id):
    """Get or create lecture markers"""
    lecture = get_object_or_404(Lecture, id=lecture_id)

    if request.method == "GET":
        markers = LectureMarker.objects.filter(
            user=request.user, lecture=lecture
        ).order_by("timestamp")
        
        data = []
        for marker in markers:
            data.append({
                "id": marker.id,
                "timestamp": marker.timestamp,
                "text": marker.text,
                "formatted_timestamp": marker.formatted_timestamp,
            })
        
        return Response({"markers": data})

    elif request.method == "POST":
        timestamp = request.data.get("timestamp")
        text = request.data.get("text", "").strip()

        if timestamp is None or timestamp < 0:
            return Response(
                {"error": "Timestamp required"}, 
                status=400
            )

        if not text:
            return Response(
                {"error": "Text required"}, 
                status=400
            )

        marker = LectureMarker.objects.create(
            user=request.user,
            lecture=lecture,
            timestamp=timestamp,
            text=text
        )

        return Response({
            "success": True,
            "marker": {
                "id": marker.id,
                "timestamp": marker.timestamp,
                "text": marker.text,
                "formatted_timestamp": marker.formatted_timestamp,
            }
        })


@api_view(["PUT", "DELETE"])
@permission_classes([IsAuthenticated])
def marker_detail(request, marker_id):
    """Update or delete marker"""
    marker = get_object_or_404(
        LectureMarker, 
        id=marker_id, 
        user=request.user
    )

    if request.method == "PUT":
        text = request.data.get("text", "").strip()
        
        if not text:
            return Response(
                {"error": "Text required"}, 
                status=400
            )

        marker.text = text
        marker.save()

        return Response({
            "success": True,
            "marker": {
                "id": marker.id,
                "timestamp": marker.timestamp,
                "text": marker.text,
                "formatted_timestamp": marker.formatted_timestamp,
            }
        })

    elif request.method == "DELETE":
        marker.delete()
        return Response({"success": True})
