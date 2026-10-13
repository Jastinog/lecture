"""Builds a lecturer's selection for a scripture from the verse in their
lectures' titles: the Bhagavad-gita and a selection per chapter, each holding
every lecture on it, whatever topic or language it's in.

    manage.py build_selection gita --lecturer hg-a-c-bhaktivedanta-swami-prabhupada

Re-runs refill the chapters from the lectures there are now. Selections are
found by title, so covers and descriptions set in the admin stay; a renamed
one is made again."""

import re

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.lecture.models import Lecture, Lecturer, Selection, SelectionLecture

# Verse ranges: "BG 2.19–25", "BG 8.28–9.1"; the first verse places a lecture.
GITA_VERSE = re.compile(r"^(?:BG|БГ) (\d+)\.(\d+)")
GITA_INTRO = re.compile(r"^(?:BG Introduction|БГ, введение)")

GITA_CHAPTERS = [
    "Observing the Armies on the Battlefield of Kuruksetra",
    "Contents of the Gita Summarized",
    "Karma-yoga",
    "Transcendental Knowledge",
    "Karma-yoga — Action in Krsna Consciousness",
    "Dhyana-yoga",
    "Knowledge of the Absolute",
    "Attaining the Supreme",
    "The Most Confidential Knowledge",
    "The Opulence of the Absolute",
    "The Universal Form",
    "Devotional Service",
    "Nature, the Enjoyer, and Consciousness",
    "The Three Modes of Material Nature",
    "The Yoga of the Supreme Person",
    "The Divine and Demoniac Natures",
    "The Divisions of Faith",
    "Conclusion — The Perfection of Renunciation",
]


def gita_place(title):
    """(section title, verse key) for a lecture title, or None if it isn't on
    the Gita. The introduction comes before chapter 1."""
    if GITA_INTRO.match(title):
        return "Introduction", (0, 0)
    m = GITA_VERSE.match(title)
    if not m:
        return None
    chapter, verse = int(m[1]), int(m[2])
    if not 1 <= chapter <= len(GITA_CHAPTERS):
        return None
    return f"Chapter {chapter}", (chapter, verse)


def gita_sections():
    """(title, description) of each section, in order."""
    return [("Introduction", "")] + [
        (f"Chapter {n}", name) for n, name in enumerate(GITA_CHAPTERS, start=1)
    ]


SCRIPTURES = {
    "gita": ("Bhagavad-gita", gita_sections, gita_place),
}


class Command(BaseCommand):
    help = "Builds a lecturer's selection for a scripture from their lectures' verses"

    def add_arguments(self, parser):
        parser.add_argument("scripture", choices=SCRIPTURES)
        parser.add_argument("--lecturer", required=True, help="Lecturer code")
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, scripture, lecturer, dry_run=False, **options):
        lecturer = Lecturer.objects.filter(code=lecturer).first()
        if not lecturer:
            raise CommandError("No lecturer with that code")
        title, sections, place = SCRIPTURES[scripture]

        placed = {}
        lectures = Lecture.objects.filter(topic__lecturer=lecturer).select_related("language")
        for lecture in lectures:
            spot = place(lecture.title)
            if spot:
                section, verse = spot
                # On one verse: by year, then as the lecture's topic orders them.
                key = (verse, lecture.year or 0, lecture.order, lecture.language.code)
                placed.setdefault(section, []).append((key, lecture.pk))

        for section, _ in sections():
            self.stdout.write(f"{section}: {len(placed.get(section, []))} lectures")
        if dry_run:
            return
        with transaction.atomic():
            self.build(lecturer, title, sections(), placed)
        self.stdout.write(self.style.SUCCESS(f"Built {title} for {lecturer.name}"))

    def build(self, lecturer, title, sections, placed):
        root, _ = Selection.objects.get_or_create(lecturer=lecturer, parent=None, title=title)
        # Numbered over every chapter, so one getting its first lecture later
        # falls into place; until then it isn't made.
        for order, (section, description) in enumerate(sections, start=1):
            if section not in placed:
                continue
            child, created = Selection.objects.get_or_create(
                parent=root, title=section,
                defaults={"lecturer": lecturer, "description": description, "order": order},
            )
            if not created and child.order != order:
                child.order = order
                child.save(update_fields=["order"])
            child.entries.all().delete()
            SelectionLecture.objects.bulk_create(
                SelectionLecture(selection=child, lecture_id=pk, order=n)
                for n, (_, pk) in enumerate(sorted(placed.get(section, [])), start=1)
            )
