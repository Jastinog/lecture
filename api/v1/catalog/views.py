"""Public catalog for the iOS app: groups, lecturers, topics with their
lectures, the home page, and search. None of it needs a listener; the one
write is the play count, which ranks "Trending" and counts each listener once
per lecture and day.

Every list takes `?lang=en,ru`: only lectures in those languages count, and
topics and lecturers with none of them drop out. A topic's own `languages`
always lists all of them, so the app can offer the others."""

import hashlib
from dataclasses import dataclass, field
from datetime import timedelta
from itertools import groupby
from operator import itemgetter

from django.db import transaction
from django.db.models import Count, F, Max, Min, Q, Sum
from django.db.models.functions import Coalesce
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import generics, serializers, status
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response
from rest_framework.throttling import SimpleRateThrottle
from rest_framework.views import APIView

from apps.lecture.models import (
    Lecture,
    Lecturer,
    Selection,
    SelectionLecture,
    Topic,
    TopicGroup,
    LecturePlays,
)
from apps.listeners.authentication import ListenerTokenAuthentication
from apps.listeners.models import ListenerPlay

from .serializers import (
    GroupSerializer,
    LectureSerializer,
    LecturerRefSerializer,
    LecturerSerializer,
    SelectionSerializer,
    TopicRefSerializer,
    TopicSerializer,
)

SEARCH_LIMIT = 30
# Longer queries are cut: no title is that long, and each one is a table scan.
QUERY_LIMIT = 100
RELATED_LIMIT = 10
# Cards in each of the home page's rows.
HOME_LIMIT = 5
# The days whose plays rank "Trending".
TRENDING_DAYS = 14
# The lecture of the day is a whole talk, not a snippet: ten minutes at least.
LECTURE_OF_THE_DAY_MIN_SECONDS = 600
# The order lectures play in within a topic, whatever their language; search
# reports positions in it.
LECTURE_ORDER = ["order", "id"]


def query_param(request, name):
    """`?name=`, or "" when absent. NUL is dropped: Postgres refuses it in a
    string, which would be a 500 rather than an empty result."""
    return request.query_params.get(name, "").replace("\x00", "")


def requested_languages(request):
    """The language codes in `?lang=en,ru`, or None when it's absent or empty."""
    codes = [c.strip() for c in query_param(request, "lang").split(",")]
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


def lecture_hits(lectures, languages, context):
    """`lectures` as search and "Trending" send them: each with its position
    as its topic page lists it under the same `languages`, and the topic's
    card. Every topic's lectures are numbered in one query."""
    in_languages = lectures_in(languages)
    topic_ids = {lecture.topic_id for lecture in lectures}
    topics = {t.pk: t for t in topics_queryset(languages).filter(pk__in=topic_ids)}
    positions = {}
    ordered = (
        Lecture.objects.filter(in_languages, topic_id__in=topic_ids)
        .order_by("topic_id", *LECTURE_ORDER)
        .values_list("topic_id", "id")
    )
    for _, rows in groupby(ordered, key=itemgetter(0)):
        for index, (_, lecture_id) in enumerate(rows):
            positions[lecture_id] = index
    return [
        lecture_hit(lecture, positions[lecture.pk], topics[lecture.topic_id], context)
        for lecture in lectures
    ]


def lecture_hit(lecture, index, topic, context):
    """A lecture with its position in its topic and the topic's card, as
    search and the lecture of the day send it."""
    return {
        "lecture": LectureSerializer(lecture, context=context).data,
        "index": index,
        "topic": TopicSerializer(topic, context=context).data,
    }


def page_details(lecturer_id, all_lectures, lectures, context):
    """What a topic or selection page adds to its card: the lecturer, every
    language it has with its count (for the switcher), and the years its
    shown `lectures` span."""
    years = lectures.aggregate(first=Min("year"), last=Max("year"))
    return {
        "lecturer": LecturerSerializer(
            lecturers_queryset().get(pk=lecturer_id), context=context
        ).data,
        "languages": language_counts(all_lectures),
        "years": years if years["first"] else None,
    }


@dataclass
class SelectionNode:
    parent_id: int | None
    title: str
    children: list = field(default_factory=list)
    lectures_count: int = 0
    duration: int = 0
    languages: set = field(default_factory=set)
    # Counted once however many of its nested selections it's in.
    lecture_ids: set = field(default_factory=set)


class SelectionTree(dict):
    """A lecturer's selections by id, each with its parent and children, and
    its lectures in `languages` and their length, and every language it has,
    each taking in the selections nested in it. Two queries."""

    def __init__(self, lecturer_id, languages=None):
        super().__init__(
            (pk, SelectionNode(parent_id, title))
            for pk, parent_id, title in Selection.objects.filter(
                lecturer_id=lecturer_id
            ).values_list("id", "parent_id", "title")
        )
        for pk, node in self.items():
            if node.parent_id in self:
                self[node.parent_id].children.append(pk)
        rows = SelectionLecture.objects.filter(selection_id__in=self).values_list(
            "selection_id", "lecture_id", "lecture__language__code", "lecture__duration"
        )
        for selection_id, lecture_id, code, duration in rows:
            counted = not languages or code in languages
            for pk in self.ancestors(selection_id):
                node = self[pk]
                node.languages.add(code)
                if counted and lecture_id not in node.lecture_ids:
                    node.lecture_ids.add(lecture_id)
                    node.lectures_count += 1
                    node.duration += duration or 0

    def ancestors(self, pk):
        """Ids of the selection and the ones it sits in, innermost first. Stops
        at a loop, should one ever get past `Selection.clean`."""
        seen = set()
        while pk in self and pk not in seen:
            seen.add(pk)
            yield pk
            pk = self[pk].parent_id

    def nested_in(self, pk):
        """The selection and every one nested in it, at any depth."""
        found, stack = set(), [pk]
        while stack:
            pk = stack.pop()
            if pk not in found:
                found.add(pk)
                stack.extend(self[pk].children)
        return found

    def cards(self, selections, languages, context):
        """`selections` as list cards; with `?lang=`, those with no lectures
        in those languages left out."""
        shown = []
        for selection in selections:
            node = self[selection.pk]
            if languages and not node.lectures_count:
                continue
            selection.holds = "selections" if node.children else "lectures"
            selection.children_count = len(node.children)
            selection.lectures_count = node.lectures_count
            selection.duration = node.duration
            selection.language_codes = sorted(node.languages)
            shown.append(selection)
        return SelectionSerializer(shown, many=True, context=context).data


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
        group = query_param(self.request, "group")
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
        related = (
            topics_with_lectures_in(languages)
            .filter(lecturer=topic.lecturer_id)
            .exclude(pk=topic.pk)
            .order_by("group__order", "order", "id")[:RELATED_LIMIT]
        )
        context = {"request": request}
        data = TopicSerializer(topic, context=context).data
        data.update(page_details(topic.lecturer_id, all_lectures, lectures, context))
        data.update(
            {
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
            .order_by("group__order", "order", "id")
        )


class LecturerSelectionsView(APIView):
    """The lecturer's top-level selections."""

    def get(self, request, pk):
        lecturer = get_object_or_404(Lecturer, pk=pk)
        languages = requested_languages(request)
        top = Selection.objects.filter(lecturer=lecturer, parent=None).order_by("order", "id")
        return Response(
            SelectionTree(lecturer.pk, languages).cards(top, languages, {"request": request})
        )


class SelectionDetailView(APIView):
    """The selection page, shaped as the topic page (the app plays a selection
    of lectures as it plays a topic), plus the selections it sits in
    (outermost first), the ones nested in it, and each lecture's topic.
    `holds` says whether it's a folder of selections or a list of lectures."""

    def get(self, request, pk):
        selection = get_object_or_404(Selection, pk=pk)
        languages = requested_languages(request)
        tree = SelectionTree(selection.lecturer_id, languages)
        context = {"request": request}
        data = tree.cards([selection], [], context)[0]

        entries = (
            SelectionLecture.objects.filter(lectures_in(languages, "lecture__"), selection=selection)
            .select_related("lecture__language", "lecture__topic")
            .order_by("order", "id")
        )
        all_lectures = Lecture.objects.filter(
            pk__in=SelectionLecture.objects.filter(
                selection_id__in=tree.nested_in(selection.pk)
            ).values("lecture_id")
        )
        # A folder's years are its nested selections'.
        shown = all_lectures.filter(lectures_in(languages))
        children = Selection.objects.filter(parent=selection).order_by("order", "id")
        data.update(page_details(selection.lecturer_id, all_lectures, shown, context))
        data.update(
            {
                "created_at": selection.created_at,
                "path": [
                    {"id": outer, "title": tree[outer].title}
                    for outer in reversed(list(tree.ancestors(selection.pk))[1:])
                ],
                "children": tree.cards(children, languages, context),
                "lectures": [
                    {
                        **LectureSerializer(entry.lecture, context=context).data,
                        "topic": TopicRefSerializer(entry.lecture.topic).data,
                    }
                    for entry in entries
                ],
                "related": [],
            }
        )
        return Response(data)


class SearchView(APIView):
    """`?q=` across lecturer names, topic titles (and their lecturer) and
    lecture titles. Each lecture hit carries its position in its topic, as
    the topic page lists it under the same `?lang=`."""

    def get(self, request):
        q = query_param(request, "q").strip()[:QUERY_LIMIT]
        if not q:
            return Response({"lecturers": [], "topics": [], "lectures": []})
        context = {"request": request}
        languages = requested_languages(request)
        in_languages = lectures_in(languages)

        lecturers = lecturers_with_lectures_in(languages).filter(name__icontains=q).order_by(
            "level", "order"
        )[:SEARCH_LIMIT]
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

        return Response(
            {
                "lecturers": LecturerSerializer(lecturers, many=True, context=context).data,
                "topics": TopicSerializer(topics, many=True, context=context).data,
                "lectures": lecture_hits(hits, languages, context),
            }
        )


class HomeView(APIView):
    """The home page: the lecture of the day, the lectures most played lately,
    then rows of five cards: the newest topics and the newest selections of
    every lecturer, each naming its lecturer. `?lang=` narrows them all like
    the lists. `trending` (the topics of those lectures) is kept for apps
    from before `trending_lectures`."""

    def get(self, request):
        languages = requested_languages(request)
        context = {"request": request}
        since = timezone.localdate() - timedelta(days=TRENDING_DAYS - 1)
        # Filtered first, the sum counts only the recent plays.
        trending_lectures = list(
            Lecture.objects.filter(lectures_in(languages), plays__day__gte=since)
            .annotate(recent_plays=Sum("plays__count"))
            .select_related("language")
            .order_by("-recent_plays", "-id")[:HOME_LIMIT]
        )
        # Their topics, for apps from before: one grouped query over the
        # recent plays, not one per topic.
        ranked = list(
            LecturePlays.objects.filter(lectures_in(languages, "lecture__"), day__gte=since)
            .values("lecture__topic")
            .annotate(total=Sum("count"))
            .order_by("-total", "-lecture__topic")
            .values_list("lecture__topic", flat=True)[:HOME_LIMIT]
        )
        by_id = topics_queryset(languages).in_bulk(ranked)
        trending = [by_id[pk] for pk in ranked]
        topics = topics_with_lectures_in(languages)
        newest = topics.order_by("-created_at", "-id")[:HOME_LIMIT]
        return Response(
            {
                "trending_lectures": lecture_hits(trending_lectures, languages, context),
                "trending": TopicSerializer(trending, many=True, context=context).data,
                "new": TopicSerializer(newest, many=True, context=context).data,
                "selections": self.selections(languages, context),
                "lecture_of_the_day": self.lecture_of_the_day(languages, context),
            }
        )

    @staticmethod
    def lecture_of_the_day(languages, context):
        """A lecture picked by the date, the same for everyone all day (in the
        server's time zone), with its position as the topic page lists it
        under the same `?lang=`; None while there's none long enough."""
        in_languages = lectures_in(languages)
        candidates = (
            Lecture.objects.filter(in_languages, duration__gte=LECTURE_OF_THE_DAY_MIN_SECONDS)
            .exclude(audio_file="")
            .order_by("id")
        )
        count = candidates.count()
        if not count:
            return None
        seed = hashlib.sha256(timezone.localdate().isoformat().encode()).digest()
        lecture = candidates.select_related("language")[int.from_bytes(seed[:8]) % count]
        return lecture_hits([lecture], languages, context)[0]

    @staticmethod
    def selections(languages, context):
        """The newest top-level selections with lectures (in `languages`),
        each lecturer's tree built once."""
        trees, cards = {}, []
        newest = (
            Selection.objects.filter(parent=None)
            .select_related("lecturer")
            .order_by("-created_at", "-id")
        )
        for selection in newest.iterator():
            if selection.lecturer_id not in trees:
                trees[selection.lecturer_id] = SelectionTree(selection.lecturer_id, languages)
            for card in trees[selection.lecturer_id].cards([selection], languages, context):
                if not card["lectures_count"]:
                    continue
                card["lecturer"] = LecturerRefSerializer(selection.lecturer).data
                cards.append(card)
            if len(cards) == HOME_LIMIT:
                break
        return cards


class PlayThrottle(SimpleRateThrottle):
    """Per address, token or not: a throttle per listener would let one
    address multiply its plays by registering more listeners."""

    scope = "plays"

    def get_cache_key(self, request, view):
        return self.cache_format % {"scope": self.scope, "ident": self.get_ident(request)}


class PlaySerializer(serializers.Serializer):
    lecture = serializers.PrimaryKeyRelatedField(queryset=Lecture.objects.all())


class PlayView(APIView):
    """`POST {"lecture": id}`: a lecture was started. Counts towards its
    plays today, once per listener, lecture and day. Without a token
    (apps from before listeners) every play counts."""

    authentication_classes = [ListenerTokenAuthentication]
    throttle_classes = [PlayThrottle]

    def post(self, request):
        data = PlaySerializer(data=request.data)
        data.is_valid(raise_exception=True)
        lecture, day = data.validated_data["lecture"], timezone.localdate()
        with transaction.atomic():
            if request.user:
                _, first = ListenerPlay.objects.get_or_create(
                    listener=request.user, lecture=lecture, day=day
                )
                if not first:
                    return Response(status=status.HTTP_204_NO_CONTENT)
            plays, _ = LecturePlays.objects.get_or_create(lecture=lecture, day=day)
            LecturePlays.objects.filter(pk=plays.pk).update(count=F("count") + 1)
        return Response(status=status.HTTP_204_NO_CONTENT)
