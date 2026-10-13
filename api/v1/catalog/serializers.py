from rest_framework import serializers

from apps.lecture.models import Lecture, Lecturer, Selection, Topic, TopicGroup


def file_url(request, field):
    """Absolute URL of a stored file, or None when the field is empty."""
    if not field:
        return None
    url = field.url
    if url.startswith("http"):
        return url
    return request.build_absolute_uri(url) if request else url


class GroupSerializer(serializers.ModelSerializer):
    class Meta:
        model = TopicGroup
        fields = ["code", "name"]


class LecturerRefSerializer(serializers.ModelSerializer):
    class Meta:
        model = Lecturer
        fields = ["id", "name"]


class LecturerSerializer(serializers.ModelSerializer):
    """Expects `topics_count` and `lectures_count` annotations (see views)."""

    photo_url = serializers.SerializerMethodField()
    bio = serializers.CharField(source="description")
    topics_count = serializers.IntegerField(default=0)
    lectures_count = serializers.IntegerField(default=0)

    class Meta:
        model = Lecturer
        fields = [
            "id",
            "name",
            "photo_url",
            "level",
            "bio",
            "topics_count",
            "lectures_count",
        ]

    def get_photo_url(self, obj):
        return file_url(self.context.get("request"), obj.photo)


class TopicSerializer(serializers.ModelSerializer):
    """A topic as lists show it. Expects `lectures_count` and `total_duration`
    annotations (see views)."""

    cover_url = serializers.SerializerMethodField()
    lecturer = LecturerRefSerializer()
    group = GroupSerializer()
    languages = serializers.SerializerMethodField()
    lectures_count = serializers.IntegerField(default=0)
    duration = serializers.IntegerField(source="total_duration", default=0)
    about = serializers.CharField(source="description")

    class Meta:
        model = Topic
        fields = [
            "id",
            "title",
            "cover_url",
            "lecturer",
            "group",
            "languages",
            "lectures_count",
            "duration",
            "about",
        ]

    def get_cover_url(self, obj):
        return file_url(self.context.get("request"), obj.cover)

    def get_languages(self, obj):
        # Uses the prefetched languages instead of a query per topic.
        return [language.code for language in obj.languages.all()]


class LectureSerializer(serializers.ModelSerializer):
    url = serializers.SerializerMethodField()
    duration = serializers.SerializerMethodField()
    language = serializers.CharField(source="language.code")

    class Meta:
        model = Lecture
        fields = ["id", "title", "url", "duration", "year", "event", "language"]

    def get_url(self, obj):
        return file_url(self.context.get("request"), obj.audio_file)

    def get_duration(self, obj):
        return obj.duration or 0


class TopicRefSerializer(serializers.ModelSerializer):
    class Meta:
        model = Topic
        fields = ["id", "title"]


class SelectionSerializer(serializers.ModelSerializer):
    """A selection as lists show it. Expects `holds`, `children_count`,
    `lectures_count`, `duration` and `language_codes`, set by
    `SelectionTree.cards` (see views): counts take in nested selections.
    `kind` tells the app it's not a topic, whose ids it shares."""

    kind = serializers.SerializerMethodField()
    cover_url = serializers.SerializerMethodField()
    about = serializers.CharField(source="description")
    holds = serializers.CharField()
    children_count = serializers.IntegerField()
    lectures_count = serializers.IntegerField()
    duration = serializers.IntegerField()
    languages = serializers.ListField(source="language_codes")

    class Meta:
        model = Selection
        fields = [
            "id",
            "kind",
            "title",
            "cover_url",
            "about",
            "holds",
            "children_count",
            "lectures_count",
            "duration",
            "languages",
        ]

    def get_kind(self, obj):
        return "selection"

    def get_cover_url(self, obj):
        return file_url(self.context.get("request"), obj.cover)
