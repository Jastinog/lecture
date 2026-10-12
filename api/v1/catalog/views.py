"""Public, read-only catalog for the iOS app: groups, lecturers, topics with
their lectures, and search. Listening data stays on the device, so nothing
here needs a user."""

from django.db.models import Count, Max, Min, Q, Sum
from django.db.models.functions import Coalesce
from django.shortcuts import get_object_or_404
from rest_framework import generics
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

from .serializers import (
    GroupSerializer,
    LectureSerializer,
    LecturerSerializer,
    TopicSerializer,
)

SEARCH_LIMIT = 30
RELATED_LIMIT = 10
# The order lectures play in within a topic; search reports positions in it.
LECTURE_ORDER = ["language__name", "order", "id"]


def topics_queryset():
    """Topics with what the list cards show: lecture count and total length."""
    return (
        Topic.objects.select_related("lecturer", "group")
        .prefetch_related("languages")
        .annotate(
            lectures_count=Count("lectures"),
            total_duration=Coalesce(Sum("lectures__duration"), 0),
        )
    )


def lecturers_queryset():
    return Lecturer.objects.annotate(
        topics_count=Count("topics", distinct=True),
        lectures_count=Count("topics__lectures", distinct=True),
    )


class TopicPagination(PageNumberPagination):
    page_size = 20

    def get_paginated_response(self, data):
        return Response(
            {
                "count": self.page.paginator.count,
                "page": self.page.number,
                "pages": self.page.paginator.num_pages,
                "results": data,
            }
        )


class GroupListView(generics.ListAPIView):
    serializer_class = GroupSerializer
    pagination_class = None
    queryset = TopicGroup.objects.filter(is_active=True)


class TopicListView(generics.ListAPIView):
    """Newest first; `?group=<code>` narrows to a group."""

    serializer_class = TopicSerializer
    pagination_class = TopicPagination

    def get_queryset(self):
        qs = topics_queryset()
        group = self.request.query_params.get("group")
        if group:
            qs = qs.filter(group__code=group)
        return qs.order_by("-created_at", "-id")


class TopicDetailView(APIView):
    """The topic page: the card, its lectures, lecturer and related topics."""

    def get(self, request, pk):
        topic = get_object_or_404(topics_queryset(), pk=pk)
        lectures = (
            Lecture.objects.filter(topic=topic)
            .select_related("language")
            .order_by(*LECTURE_ORDER)
        )
        years = lectures.aggregate(first=Min("year"), last=Max("year"))
        related = (
            topics_queryset()
            .filter(lecturer=topic.lecturer_id)
            .exclude(pk=topic.pk)
            .order_by("group__order", "order")[:RELATED_LIMIT]
        )
        context = {"request": request}
        data = TopicSerializer(topic, context=context).data
        data.update(
            {
                "lecturer": LecturerSerializer(
                    lecturers_queryset().get(pk=topic.lecturer_id), context=context
                ).data,
                "languages": [
                    {"code": language.code, "name": language.native_name}
                    for language in Language.objects.filter(
                        Q(topics=topic) | Q(lectures__topic=topic)
                    ).distinct()
                ],
                "years": years if years["first"] else None,
                "created_at": topic.created_at,
                "lectures": LectureSerializer(lectures, many=True, context=context).data,
                "related": TopicSerializer(related, many=True, context=context).data,
            }
        )
        return Response(data)


class LecturerListView(generics.ListAPIView):
    serializer_class = LecturerSerializer
    pagination_class = None

    def get_queryset(self):
        return lecturers_queryset().order_by("level", "order", "name")


class LecturerDetailView(generics.RetrieveAPIView):
    serializer_class = LecturerSerializer

    def get_queryset(self):
        return lecturers_queryset()


class LecturerTopicsView(generics.ListAPIView):
    serializer_class = TopicSerializer
    pagination_class = None

    def get_queryset(self):
        lecturer = get_object_or_404(Lecturer, pk=self.kwargs["pk"])
        return (
            topics_queryset()
            .filter(lecturer=lecturer)
            .order_by("group__order", "order")
        )


class SearchView(APIView):
    """`?q=` across lecturer names, topic titles (and their lecturer) and
    lecture titles. Each lecture hit carries its position in its topic."""

    def get(self, request):
        q = request.query_params.get("q", "").strip()
        if not q:
            return Response({"lecturers": [], "topics": [], "lectures": []})
        context = {"request": request}

        lecturers = lecturers_queryset().filter(name__icontains=q).order_by(
            "level", "order"
        )
        topics = (
            topics_queryset()
            .filter(Q(title__icontains=q) | Q(lecturer__name__icontains=q))
            .order_by("lecturer__level", "lecturer__order", "order")[:SEARCH_LIMIT]
        )

        hits = list(
            Lecture.objects.filter(title__icontains=q)
            .select_related("language")
            .order_by("topic_id", *LECTURE_ORDER)[:SEARCH_LIMIT]
        )
        topic_ids = {hit.topic_id for hit in hits}
        hit_topics = {t.pk: t for t in topics_queryset().filter(pk__in=topic_ids)}
        positions = {}
        for topic_id in topic_ids:
            ordered = Lecture.objects.filter(topic_id=topic_id).order_by(*LECTURE_ORDER)
            for index, lecture_id in enumerate(ordered.values_list("id", flat=True)):
                positions[lecture_id] = index

        return Response(
            {
                "lecturers": LecturerSerializer(lecturers, many=True, context=context).data,
                "topics": TopicSerializer(topics, many=True, context=context).data,
                "lectures": [
                    {
                        "lecture": LectureSerializer(hit, context=context).data,
                        "index": positions[hit.pk],
                        "topic": TopicSerializer(hit_topics[hit.topic_id], context=context).data,
                    }
                    for hit in hits
                ],
            }
        )
