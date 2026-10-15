import uuid
import os
import hashlib
from django.core.exceptions import ValidationError
from django.core.validators import FileExtensionValidator
from django.db import models, transaction
from django.db.models.signals import post_delete
from django.dispatch import receiver
from django.conf import settings



def get_lecturers_folder():
    """Get lecturers folder name based on environment"""
    env = getattr(settings, "ENVIRONMENT", "dev")
    return "lecturers_dev" if env != "prod" else "lecturers"


def lecture_upload_path(instance, filename):
    """Generate nested upload path for lecture files using IDs"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.topic.lecturer.id}/topics/{instance.topic.id}/lectures/{short_name}"


def lecturer_photo_path(instance, filename):
    """Upload path for lecturer photos using ID"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.id}/photo/{short_name}"


def topic_cover_path(instance, filename):
    """Upload path for topic covers using IDs"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.lecturer.id}/topics/{instance.id}/cover/{short_name}"


def selection_cover_path(instance, filename):
    """Upload path for selection covers using IDs"""
    ext = os.path.splitext(filename)[1].lower()
    short_name = f"{uuid.uuid4().hex[:8]}{ext}"
    folder = get_lecturers_folder()
    return f"{folder}/{instance.lecturer.id}/selections/{instance.id}/cover/{short_name}"


# What a lecture's file may be; anything else uploaded to the public bucket
# could be served as a page.
AUDIO_EXTENSIONS = ["mp3", "m4a", "wav", "flac", "ogg", "aac"]


class Language(models.Model):
    code = models.CharField(
        max_length=10, unique=True, help_text="Language code (e.g., 'en', 'ru')"
    )
    name = models.CharField(
        max_length=100, help_text="Language name (e.g., 'English', 'Russian')"
    )
    native_name = models.CharField(
        max_length=100, help_text="Native language name (e.g., 'English', 'Русский')"
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.native_name} ({self.code})"

    class Meta:
        ordering = ["name"]


class TopicGroup(models.Model):
    name = models.CharField(
        max_length=100,
        unique=True,
        help_text="Group name (e.g., 'Lectures', 'Kirtans', 'Conversations')",
    )
    code = models.CharField(
        max_length=50,
        unique=True,
        help_text="Group code (e.g., 'lectures', 'kirtans', 'conversations')",
    )
    description = models.TextField(
        blank=True, help_text="Description of the topic group"
    )
    order = models.PositiveIntegerField(
        default=0, help_text="Order for displaying groups"
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    class Meta:
        ordering = ["order", "name"]


class Lecturer(models.Model):
    LEVEL_CHOICES = [
        (1, "Founder-Acharya"),
        (2, "Direct Disciple"),
        (3, "Grand Disciple"),
    ]

    code = models.CharField(max_length=255, unique=True)
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    photo = models.ImageField(upload_to=lecturer_photo_path, blank=True, null=True)
    order = models.PositiveIntegerField(
        default=0, help_text="Order for displaying lecturers"
    )
    level = models.PositiveSmallIntegerField(
        choices=LEVEL_CHOICES,
        default=2,
        help_text="Spiritual hierarchy level: 1=Founder-Acharya, 2=Direct Disciple, 3=Grand Disciple",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    def get_level_display_with_icon(self):
        """Return level display with appropriate icon"""
        level_icons = {
            1: "👑",  # Founder
            2: "🙏",  # Direct disciple
            3: "📿",  # Grand disciple
        }
        return f"{level_icons.get(self.level, '')} {self.get_level_display()}"

    class Meta:
        ordering = ["level", "order", "name"]
        unique_together = ["order"]
        indexes = [
            models.Index(fields=["level", "order"]),
        ]


class Topic(models.Model):
    lecturer = models.ForeignKey(
        Lecturer, on_delete=models.CASCADE, related_name="topics"
    )
    code = models.CharField(max_length=255)
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=topic_cover_path, blank=True, null=True)
    group = models.ForeignKey(
        TopicGroup,
        on_delete=models.PROTECT,
        related_name="topics",
        help_text="Group this topic belongs to",
    )
    languages = models.ManyToManyField(
        Language,
        related_name="topics",
        blank=True,
        help_text="Languages of this topic's lectures, kept in sync from them",
    )
    order = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.lecturer.name} - {self.title}"

    def sync_languages(self):
        """Set the topic's languages to those its lectures are in."""
        self.languages.set(Language.objects.filter(lectures__topic=self).distinct())

    def get_languages_display(self):
        """Return comma-separated list of language names"""
        return ", ".join(self.languages.values_list("native_name", flat=True))

    class Meta:
        ordering = ["lecturer", "group", "order"]
        unique_together = ["lecturer", "order", "code"]
        constraints = [
            # Importers find a lecturer's topic by its code.
            models.UniqueConstraint(fields=["lecturer", "code"], name="topic_code_per_lecturer"),
        ]
        indexes = [
            models.Index(fields=["lecturer", "group"]),
        ]


class Lecture(models.Model):
    topic = models.ForeignKey(Topic, on_delete=models.CASCADE, related_name="lectures")
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    audio_file = models.FileField(
        upload_to=lecture_upload_path, validators=[FileExtensionValidator(AUDIO_EXTENSIONS)]
    )
    language = models.ForeignKey(
        Language,
        on_delete=models.PROTECT,
        related_name="lectures",
        help_text="Language of this lecture",
    )
    file_size = models.BigIntegerField(null=True, blank=True)
    duration = models.IntegerField(null=True, blank=True)
    order = models.PositiveIntegerField()
    year = models.PositiveIntegerField(
        null=True, blank=True, help_text="Year of the lecture"
    )
    event = models.CharField(
        max_length=255, blank=True, help_text="Event or occasion of the lecture"
    )
    file_hash = models.CharField(
        max_length=64,
        blank=True,
        help_text="SHA256 hash of original filename for duplicate detection",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.topic.title} - {self.title} ({self.language.code})"

    class Meta:
        # One order across the topic, whatever each lecture's language, so a
        # mixed topic plays in its own sequence.
        ordering = ["topic", "order"]
        unique_together = ["topic", "order"]
        constraints = [
            # Importers skip a file whose hash is in the topic already; this
            # keeps two runs at once from both adding it.
            models.UniqueConstraint(
                fields=["topic", "file_hash"],
                condition=~models.Q(file_hash=""),
                name="lecture_file_once_per_topic",
            ),
        ]
        indexes = [
            models.Index(fields=["topic", "language", "file_hash"]),
        ]

    def save(self, *args, **kwargs):
        # Re-sync the topics' languages: this one, and the one it left if moved.
        previous = (
            Lecture.objects.filter(pk=self.pk).values_list("topic_id", flat=True).first()
            if self.pk
            else None
        )
        super().save(*args, **kwargs)
        sync_topics_languages({self.topic_id, previous})

    @property
    def file_size_mb(self):
        if self.file_size:
            return round(self.file_size / (1024 * 1024), 1)
        return 0.0

    @staticmethod
    def generate_file_hash(filename):
        """Generate SHA256 hash from filename"""
        return hashlib.sha256(filename.encode("utf-8")).hexdigest()


class Selection(models.Model):
    """A lecturer's own grouping of their lectures across topics, e.g. every
    lecture on the Bhagavad-gita. Selections nest: one holds either further
    selections (its chapters, say) or lectures, never both, so the app shows
    it as a folder or as a playable list."""

    lecturer = models.ForeignKey(
        Lecturer,
        on_delete=models.CASCADE,
        related_name="selections",
        help_text="A nested selection always takes its parent's",
    )
    parent = models.ForeignKey(
        "self",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="children",
        help_text="The selection this one sits in; empty for a top-level one",
    )
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=selection_cover_path, blank=True, null=True)
    order = models.PositiveIntegerField(
        default=0, help_text="Order among the selections next to it"
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return " / ".join(s.title for s in self.path())

    def path(self):
        """This selection and the ones it sits in, outermost first. Stops at a
        loop, so `clean` can catch one being made."""
        chain, seen = [self], {self.pk}
        while chain[-1].parent_id and chain[-1].parent_id not in seen:
            seen.add(chain[-1].parent_id)
            chain.append(chain[-1].parent)
        return chain[::-1]

    def clean(self):
        if not self.parent_id:
            moved = (
                self.pk
                and Selection.objects.filter(pk=self.pk).exclude(lecturer_id=self.lecturer_id).exists()
            )
            if moved and (self.children.exists() or self.entries.exists()):
                # What's in it would stay with the old lecturer.
                raise ValidationError({"lecturer": "Empty it before giving it to another lecturer."})
            return
        if self.pk and self.pk in {s.pk for s in self.parent.path()}:
            raise ValidationError({"parent": "A selection can't sit inside itself."})
        if self.pk and self.parent.lecturer_id != self.lecturer_id:
            # Its nested selections would stay with the old lecturer.
            raise ValidationError({"parent": "It belongs to another lecturer."})
        if self.parent.entries.exists():
            raise ValidationError(
                {"parent": "It holds lectures; a selection holds lectures or selections."}
            )

    def save(self, *args, **kwargs):
        if self.parent_id:
            self.lecturer_id = self.parent.lecturer_id
        super().save(*args, **kwargs)

    class Meta:
        # Siblings together, in their order.
        ordering = ["lecturer", "parent_id", "order", "id"]
        indexes = [models.Index(fields=["lecturer", "parent"])]


class SelectionLecture(models.Model):
    """A lecture in a selection, in the selection's own order. The lecture
    stays in its topic."""

    selection = models.ForeignKey(
        Selection, on_delete=models.CASCADE, related_name="entries"
    )
    lecture = models.ForeignKey("Lecture", on_delete=models.CASCADE)
    order = models.PositiveIntegerField(default=0)

    def __str__(self):
        return f"{self.selection} - {self.lecture.title}"

    def clean(self):
        # The selection may be unsaved yet: one added with its lectures.
        try:
            selection = self.selection
        except Selection.DoesNotExist:
            return
        if not self.lecture_id:
            return
        theirs = Lecture.objects.filter(pk=self.lecture_id, topic__lecturer_id=selection.lecturer_id)
        if not theirs.exists():
            raise ValidationError({"lecture": "It's another lecturer's lecture."})
        if selection.pk and selection.children.exists():
            raise ValidationError(
                {"selection": "It holds selections; a selection holds lectures or selections."}
            )

    class Meta:
        ordering = ["selection", "order", "id"]
        unique_together = ["selection", "lecture"]


def set_lectures_language(lectures, language):
    """Puts every lecture in the queryset in `language` with one update, then
    re-syncs the languages of the topics they're in. Returns how many changed."""
    topic_ids = set(lectures.values_list("topic_id", flat=True))
    changed = lectures.exclude(language=language).update(language=language)
    sync_topics_languages(topic_ids)
    return changed


# A topic's languages follow its lectures: saving (Lecture.save) or deleting a
# lecture re-syncs the topics it touched. Bulk queryset writes skip both, so
# code using them calls sync_topics_languages itself (or goes through
# set_lectures_language).


def sync_topics_languages(topic_ids):
    """Re-syncs the languages of the topics with these ids that still exist."""
    for topic in Topic.objects.filter(pk__in=set(topic_ids) - {None}):
        topic.sync_languages()


class LecturePlays(models.Model):
    """How many times a lecture was started on a day, for "Trending".
    A listener counts once per lecture and day (`listeners.ListenerPlay`)."""

    lecture = models.ForeignKey(Lecture, on_delete=models.CASCADE, related_name="plays")
    day = models.DateField()
    count = models.PositiveIntegerField(default=0)

    def __str__(self):
        return f"{self.lecture} - {self.day}: {self.count}"

    class Meta:
        verbose_name_plural = "lecture plays"
        constraints = [models.UniqueConstraint(fields=["lecture", "day"], name="lecture_plays_per_day")]
        indexes = [models.Index(fields=["day"])]


# Files go with their rows, once the delete is committed: a rolled-back delete
# keeps its file. Each upload gets a name of its own, so no other row shares it.
FILE_FIELDS = {Lecture: "audio_file", Lecturer: "photo", Topic: "cover", Selection: "cover"}


def delete_file_with_row(sender, instance, **kwargs):
    file = getattr(instance, FILE_FIELDS[sender])
    if file:
        storage, name = file.storage, file.name
        transaction.on_commit(lambda: storage.delete(name))


for model in FILE_FIELDS:
    post_delete.connect(delete_file_with_row, sender=model, dispatch_uid=f"delete_file_{model.__name__}")


@receiver(post_delete, sender=Lecture)
def sync_topic_languages_on_delete(sender, instance, **kwargs):
    # Sent for queryset and cascade deletes too, which skip Lecture.delete();
    # when the topic itself is going, it's gone already and nothing syncs.
    sync_topics_languages({instance.topic_id})
