import os
import re
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

from django.core.files import File
from django.core.management.base import BaseCommand, CommandError
from django.db.models import Max

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

from .create_lecturers import fetch_audio, save_lecture
from .import_prabhupada import ARCHIVE, COVERS_DIR, LECTURER_CODE, list_dir, natural_key, renumber

ROOT = "/01_-_Srila_Prabhupada/"
BHAJANS = ROOT + "02_-_Bhajans/"

BOMBAY_KIRTANS = BHAJANS + "Vol-01/15_-_Bombay_Kirtans/"

# Topic -> (title, description, group, order, archive folders). An album is a
# folder of mp3s; its name goes to each recording's event. Vol-04 repeats
# Vol-01's first two albums, so it's left out.
TOPICS = {
    "en-bhajans": (
        "Bhajans", "Srila Prabhupada sings bhajans and explains them", "bhajans", 117,
        [BHAJANS + "Vol-01/", BHAJANS + "Vol-02/"],
    ),
    "en-kirtans": (
        "Kirtans", "Kirtans led by Srila Prabhupada", "kirtans", 118,
        [BOMBAY_KIRTANS, BHAJANS + "Vol-03/"],
    ),
    "en-japa": ("Japa", "Chanting japa with Srila Prabhupada", "japa", 119, [ROOT + "03_-_Japa/"]),
}
FIXES = {"PurusamTvadyam": "Purusam Tvadyam", "[Hindi]": "(Hindi)"}


def albums(path, skip=(BOMBAY_KIRTANS,)):
    """Yields (album path, its mp3 names) under `path`: `path` itself when it
    holds mp3s, else each folder in it. Folders inside an album are the
    archive's misplaced copies of other albums and are skipped, as are the
    kirtans filed among the bhajans unless asked for by name."""
    names = list_dir(path)
    mp3s = [n for n in names if n.lower().endswith(".mp3")]
    if mp3s:
        yield path, sorted(mp3s, key=natural_key)
        return
    for name in sorted((n for n in names if n.endswith("/")), key=natural_key):
        if path + name not in skip:
            yield from albums(path + name)


def album_title(path):
    """'.../Vol-02/02_-_The_Vintage_Series_-_Dusta_Mane/' -> 'The Vintage
    Series — Dusta Mane'; Vol-03's untitled ones are told apart by number."""
    folder = urllib.parse.unquote(path.rstrip("/").rsplit("/", 1)[-1])
    number, _, name = folder.partition("_-_")
    if not name:
        return ""
    title = name.replace("_-_", " — ").replace("_", " ")
    return f"{title}, Part {int(number)}" if title == "The Vintage Series" else title


def describe(filename):
    """Title of a recording from its archive filename, e.g.
    SP_Bhajans_02_-_Gaura_Pahu_-_Gaura_Pahu_Na_Bhajiya_Goinu.mp3 ->
    'Gaura Pahu — Gaura Pahu Na Bhajiya Goinu'."""
    name = os.path.splitext(filename)[0]
    name = re.sub(r"^SP_(?:Bhajans_)?\d+(?:_-_|[-_])", "", name)
    for wrong, right in FIXES.items():
        name = name.replace(wrong, right)
    name = name.replace("_-_", " — ").replace("_", " ")
    # 'Jiv Jago 'Soft' Arunodaya-kirtana II' -> 'Jiv Jago “Soft” Arunodaya-kirtana II'
    return re.sub(r"(?<= )'([^']+)'", r"“\1”", name).strip()


class Command(BaseCommand):
    help = (
        "Import Srila Prabhupada's bhajans, kirtans and japa from the ISKCON "
        "Desire Tree archive into en-* topics. Re-runs skip what's imported."
    )

    def add_arguments(self, parser):
        parser.add_argument("--topic", action="append", help="Only these topics, e.g. en-japa")
        parser.add_argument("--limit", type=int, help="Import at most this many recordings per topic")
        parser.add_argument("--dry-run", action="store_true", help="List titles without downloading")
        parser.add_argument("--workers", type=int, default=6, help="Parallel downloads (default 6)")

    def handle(self, *args, topic=None, limit=None, dry_run=False, workers=6, **options):
        codes = list(dict.fromkeys(topic or TOPICS))
        unknown = set(codes) - set(TOPICS)
        if unknown:
            raise CommandError(f"Unknown topics: {', '.join(sorted(unknown))}")

        lecturer = Lecturer.objects.get(code=LECTURER_CODE)
        english = Language.objects.get(code="en")
        added = failed = 0
        for code in codes:
            # (archive path, title, album), in album order.
            tracks = [
                (path + name, describe(urllib.parse.unquote(name)), album_title(path))
                for root in TOPICS[code][4]
                for path, names in albums(root)
                for name in names
            ]
            self.stdout.write(self.style.MIGRATE_HEADING(f"{code}: {len(tracks)} files"))
            if dry_run:
                for _, title, album in tracks[:limit]:
                    self.stdout.write(f"  {title}  |  {album}")
                continue

            topic_ = self.get_topic(lecturer, code)
            known = set(topic_.lectures.values_list("file_hash", flat=True))
            todo = [t for t in tracks if Lecture.generate_file_hash(ARCHIVE + t[0]) not in known][:limit]
            # As import_prabhupada: parallel downloads a batch at a time,
            # sequential saves to keep the archive's order.
            with ThreadPoolExecutor(workers) as pool:
                for start in range(0, len(todo), workers):
                    batch = todo[start : start + workers]
                    fetched_all = pool.map(self.fetch, [t[0] for t in batch])
                    for i, ((path, title, album), fetched) in enumerate(zip(batch, fetched_all), start + 1):
                        url = ARCHIVE + path
                        if isinstance(fetched, Exception):
                            failed += 1
                            self.stdout.write(self.style.WARNING(f"  Failed {url}: {fetched}"))
                            continue
                        last_order = topic_.lectures.aggregate(last=Max("order"))["last"] or 0
                        try:
                            with fetched:
                                save_lecture(
                                    topic_,
                                    {"title": title, "event": album},
                                    english,
                                    last_order + 1,
                                    Lecture.generate_file_hash(url),
                                    fetched,
                                )
                        except Exception as e:
                            failed += 1
                            self.stdout.write(self.style.WARNING(f"  Failed saving {url}: {e}"))
                            continue
                        added += 1
                        self.stdout.write(f"  [{i}/{len(todo)}] {title}")

            renumber(topic_, [Lecture.generate_file_hash(ARCHIVE + t[0]) for t in tracks])

        self.stdout.write(self.style.SUCCESS(f"Added {added}, failed {failed}"))

    @staticmethod
    def fetch(path):
        try:
            return fetch_audio(ARCHIVE + path)
        except Exception as e:
            return e

    def get_topic(self, lecturer, code):
        title, description, group, order, _ = TOPICS[code]
        topic, created = Topic.objects.get_or_create(
            lecturer=lecturer,
            code=code,
            defaults={
                "title": title,
                "description": description,
                "group": TopicGroup.objects.get(code=group),
                "order": order,
            },
        )
        cover_path = os.path.join(COVERS_DIR, code, "cover", "cover.jpg")
        if not topic.cover and os.path.exists(cover_path):
            with open(cover_path, "rb") as f:
                topic.cover.save("cover.jpg", File(f), save=True)
        if created:
            self.stdout.write(f"Created topic {title}")
        return topic
