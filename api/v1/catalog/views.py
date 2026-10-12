"""Public, read-only catalog for the iOS app: groups, lecturers, topics with
their lectures, and search. Listening data stays on the device, so nothing
here needs a user.

Every list takes `?lang=en,ru`: only lectures in those languages count, and
topics and lecturers with none of them drop out. A topic's own `languages`
always lists all of them, so the app can offer the others."""

from itertools import groupby
from operator import itemgetter

from django.db.models import Count, Max, Min, Q, Sum
from django.db.models.functions import Coalesce
from django.shortcuts import get_object_or_404
from rest_framework import generics
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.lecture.models import Lecture, Lecturer, Topic, TopicGroup

from .serializers import (
    GroupSerializer,
    LectureSerializer,
    LecturerSerializer,
    TopicSerializer,
)

SEARCH_LIMIT = 30
RELATED_LIMIT = 10
# The order lectures play in within a topic, whatever their language; search
# reports positions in it.
LECTURE_ORDER = ["order", "id"]


def requested_languages(request):
    """The language codes in `?lang=en,ru`, or None when it's absent or empty."""
    codes = [c.strip() for c in request.query_params.get("lang", "").split(",")]
    return [c for c in codes if c] or None


def lectures_in(languages, prefix=""):
    """A filter keeping lectures (reached through `prefix`) in `languages`."""
    return Q(**{f"{prefix}language__code__in": languages}) if languages else Q()


def topics_queryset(languages=None):
    """Topics with what the list cards show: lecture count and total length,
    both over the lectures in `languages`."""
    in_languages = lectures_in(languages, "lectures__")
    return (
        Topic.objects.select_related("lecturer", "group")
        .prefetch_related("languages")
        .annotate(
            lectures_count=Count("lectures", filter=in_languages),
            total_duration=Coalesce(Sum("lectures__duration", filter=in_languages), 0),
        )
    )


def topics_with_lectures_in(languages):
    """Topics counted over `languages`, those with none of them left out."""
    topics = topics_queryset(languages)
    return topics.filter(lectures_count__gt=0) if languages else topics


def lecturers_queryset(languages=None):
    """Lecturers with their topic and lecture counts over `languages`."""
    in_languages = lectures_in(languages, "topics__lectures__")
    return Lecturer.objects.annotate(
        topics_count=Count("topics", distinct=True, filter=in_languages),
        lectures_count=Count("topics__lectures", distinct=True, filter=in_languages),
    )


def lecturers_with_lectures_in(languages):
    """Lecturers counted over `languages`, those with none of them left out."""
    lecturers = lecturers_queryset(languages)
    return lecturers.filter(lectures_count__gt=0) if languages else lecturers


def language_counts(lectures):
    """The languages of `lectures`, each with how many are in it."""
    return [
        {"code": row["language__code"], "name": row["language__native_name"],
         "lectures_count": row["count"]}
        for row in lectures.values("language__code", "language__native_name")
        .annotate(count=Count("id"))
        .order_by("language__name")
    ]


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


class LanguageListView(APIView):
    """The languages the catalog has lectures in, with how many, for the
    app's language switcher."""

    def get(self, request):
        return Response(language_counts(Lecture.objects.all()))


class TopicListView(generics.ListAPIView):
    """Newest first; `?group=<code>` narrows to a group."""

    serializer_class = TopicSerializer
    pagination_class = TopicPagination

    def get_queryset(self):
        languages = requested_languages(self.request)
        qs = topics_with_lectures_in(languages)
        group = self.request.query_params.get("group")
        if group:
            qs = qs.filter(group__code=group)
        return qs.order_by("-created_at", "-id")


class TopicDetailView(APIView):
    """The topic page: the card, its lectures, lecturer and related topics.
    With `?lang=` the lectures are only those languages, while `languages`
    still lists every one the topic has, with its count, for the switcher."""

    def get(self, request, pk):
        languages = requested_languages(request)
        topic = get_object_or_404(topics_queryset(languages), pk=pk)
        all_lectures = Lecture.objects.filter(topic=topic)
        lectures = (
            all_lectures.filter(lectures_in(languages))
            .select_related("language")
            .order_by(*LECTURE_ORDER)
        )
        years = lectures.aggregate(first=Min("year"), last=Max("year"))
        related = (
            topics_with_lectures_in(languages)
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
                "languages": language_counts(all_lectures),
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
        languages = requested_languages(self.request)
        return lecturers_with_lectures_in(languages).order_by("level", "order", "name")


class LecturerDetailView(generics.RetrieveAPIView):
    """The lecturer, with counts over `?lang=`, and every language they have
    lectures in, with its count, for the switcher."""

    serializer_class = LecturerSerializer

    def get_queryset(self):
        # Counted over `?lang=` but not narrowed by it: the page always opens.
        return lecturers_queryset(requested_languages(self.request))

    def retrieve(self, request, *args, **kwargs):
        lecturer = self.get_object()
        data = self.get_serializer(lecturer).data
        data["languages"] = language_counts(
            Lecture.objects.filter(topic__lecturer=lecturer)
        )
        return Response(data)


class LecturerTopicsView(generics.ListAPIView):
    serializer_class = TopicSerializer
    pagination_class = None

    def get_queryset(self):
        lecturer = get_object_or_404(Lecturer, pk=self.kwargs["pk"])
        languages = requested_languages(self.request)
        return (
            topics_with_lectures_in(languages)
            .filter(lecturer=lecturer)
            .order_by("group__order", "order")
        )


class SearchView(APIView):
    """`?q=` across lecturer names, topic titles (and their lecturer) and
    lecture titles. Each lecture hit carries its position in its topic, as
    the topic page lists it under the same `?lang=`."""

    def get(self, request):
        q = request.query_params.get("q", "").strip()
        if not q:
            return Response({"lecturers": [], "topics": [], "lectures": []})
        context = {"request": request}
        languages = requested_languages(request)
        in_languages = lectures_in(languages)

        lecturers = lecturers_with_lectures_in(languages).filter(name__icontains=q).order_by(
            "level", "order"
        )
        topics = (
            topics_with_lectures_in(languages)
            .filter(Q(title__icontains=q) | Q(lecturer__name__icontains=q))
            .order_by("lecturer__level", "lecturer__order", "order")[:SEARCH_LIMIT]
        )

        hits = list(
            Lecture.objects.filter(in_languages, title__icontains=q)
            .select_related("language")
            .order_by("topic_id", *LECTURE_ORDER)[:SEARCH_LIMIT]
        )
        topic_ids = {hit.topic_id for hit in hits}
        hit_topics = {
            t.pk: t for t in topics_queryset(languages).filter(pk__in=topic_ids)
        }
        # Every hit topic's lectures in one query, numbered per topic.
        positions = {}
        ordered = (
            Lecture.objects.filter(in_languages, topic_id__in=topic_ids)
            .order_by("topic_id", *LECTURE_ORDER)
            .values_list("topic_id", "id")
        )
        for _, rows in groupby(ordered, key=itemgetter(0)):
            for index, (_, lecture_id) in enumerate(rows):
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
