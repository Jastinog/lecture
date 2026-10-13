import html
import os
import re
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from django.core.files import File
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.db.models import F, Max

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

from .create_lecturers import fetch_audio, save_lecture

ARCHIVE = "https://audio.iskcondesiretree.com"
ROOT = "/01_-_Srila_Prabhupada/01_-_Lectures/01_-_English/01_-_Topic_wise/"
LECTURER_CODE = "hg-a-c-bhaktivedanta-swami-prabhupada"
COVERS_DIR = os.path.join(os.path.dirname(__file__), "lecturers", LECTURER_CODE, "topics")

# Archive folder -> topic. "cover" names the ru topic whose cover it shares.
TOPICS = {
    "Bhagavad_Gita": ("en-bhagavad-gita", "Bhagavad-gita", "Lectures on Bhagavad-gita As It Is", "lectures", "ru-bhagavad-gita"),
    "Srimad_Bhagavatam": ("en-srimad-bhagavatam", "Srimad-Bhagavatam", "Lectures on Srimad-Bhagavatam", "lectures", "ru-srimad-bhagavatam"),
    "Chaitanya_Charitamrita": ("en-chaitanya-charitamrita", "Sri Caitanya-caritamrta", "Lectures on Sri Caitanya-caritamrta", "lectures", "ru-chaitanya-charitamrita"),
    "Nectar_Of_Devotion": ("en-nectar-of-devotion", "The Nectar of Devotion", "Lectures on The Nectar of Devotion", "lectures", "ru-nectar-of-devotion"),
    "Isopanishad": ("en-sri-isopanisad", "Sri Isopanisad", "Lectures on Sri Isopanisad", "lectures", "ru-sri-ishopanishad"),
    "Festivals": ("en-festivals", "Festivals", "Lectures on festival days", "lectures", "ru-festivals"),
    "Arrival_Address": ("en-addresses", "Arrival Addresses", "Arrival addresses and public talks", "lectures", "ru-lectures"),
    "Departure_Address": ("en-departure-addresses", "Departure Addresses", "Departure addresses and talks", "lectures", "ru-lectures"),
    "Various": ("en-lectures", "Lectures", "Various lectures of Srila Prabhupada", "lectures", "ru-lectures"),
    "Happening": ("en-happening", "The Happening Album", "Srila Prabhupada's 1966 Happening album", "lectures", "ru-miscellaneous"),
    "Bhagavad_Gita_Recitation": ("en-bhagavad-gita-recitation", "Bhagavad-gita Recitation", "Srila Prabhupada recites the Bhagavad-gita in Sanskrit", "lectures", "ru-bhagavad-gita"),
    "Krishna_Book": ("en-krsna-book", "Krsna Book Dictations", "Srila Prabhupada dictating the Krsna book", "books", "ru-miscellaneous"),
    "Stories": ("en-stories", "Stories", "Stories told by Srila Prabhupada", "lectures", "ru-miscellaneous"),
    "Morning_Walk": ("en-morning-walks", "Morning Walks", "Morning walks with Srila Prabhupada", "walks", "ru-morning-walks"),
    "Room_Conversation": ("en-conversations", "Room Conversations", "Conversations with Srila Prabhupada", "conversations", "ru-conversations"),
    "Interview": ("en-interviews", "Interviews", "Interviews with Srila Prabhupada", "interviews", "ru-interviews"),
}
# English topics come after the Russian ones (orders 3-14).
FIRST_ORDER = 101

ROW = re.compile(r'<a href="([^"?/][^"]*)">')
# A day is sometimes missing: ..._1969-02_...
DATE = re.compile(r"(\d{4})-(\d{2})(?:-(\d{2}))?")
LILAS = {"A": "Adi", "M": "Madhya", "Antya": "Antya", "AN": "Antya"}


def list_dir(path):
    request = urllib.request.Request(ARCHIVE + path, headers={"User-Agent": "lecture-catalog"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return [html.unescape(href) for href in ROW.findall(response.read().decode("utf-8", "replace"))]


def walk(path):
    """Yields the archive path of every mp3 under `path`."""
    for href in list_dir(path):
        if href.endswith("/"):
            yield from walk(path + href)
        elif href.lower().endswith(".mp3"):
            yield path + href


def natural_key(text):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", text)]


def words(text):
    """Archive spelling -> words: '_' is a space, '--etc' trails off, '--' was punctuation."""
    text = text.replace("--etc", "…").replace("-etc", "…").replace("--", ", ").replace("_", " ")
    return re.sub(r"\s+", " ", text).strip(" -,")


def verse(ref, depth):
    """Verse reference from archive numbers: the first `depth` numbers are the
    path, a further one ends a range. verse('06-11-19', 2) -> '6.11–19'."""
    nums = [str(int(n)) for n in re.split(r"[-=]", ref)]
    return ".".join(nums[:depth]) + (f"–{nums[-1]}" if len(nums) > depth else "")


def bg_label(m):
    if int(m[1].split("-")[0]) == 0:
        return "BG Introduction"
    # A lecture running into the next chapter: BG_08-28_09-01.
    return f"BG {verse(m[1], 2)}" + (f"–{verse(m[2], 2)}" if m[2] else "")


def cc_label(m):
    lila = LILAS[m[1]]
    return f"CC {lila}, Introduction" if m[2] == "Intro" else f"CC {lila} {verse(m[2], 2)}"


# Archive folder -> (filename prefix, reference after it, its label).
REFS = {
    "Bhagavad_Gita": (r"BG_", r"(\d+(?:-\d+)+)(?:_(\d+-\d+))?_", bg_label),
    "Srimad_Bhagavatam": (r"SB_", r"(\d+(?:[-=]\d+)+)_", lambda m: f"SB {verse(m[1], 3)}"),
    "Chaitanya_Charitamrita": (r"CC_", r"(A|M|AN|Antya)_(\d+(?:-\d+)*|Intro)_", cc_label),
    "Isopanishad": (r"Isopanisad_", r"(\d+)_", lambda m: "Invocation" if int(m[1]) == 0 else f"Mantra {int(m[1])}"),
    "Nectar_Of_Devotion": (r"NOD_", r"(?:Pg-(\d+)_|(\d+)_)?", lambda m: f"NOD p. {int(m[1])}" if m[1] else f"NOD {int(m[2])}" if m[2] else "NOD"),
}
PREFIXES = {
    "Arrival_Address": r"(?:Arrival_|Address_)+(?:Lecture_|Talk_)?(?:-_)?",
    "Departure_Address": r"Departure_(?:Address|Lecture)_",
    "Festivals": r"Festivals_",
    "Interview": r"Interview_(?:-_)?",
    "Morning_Walk": r"Morning_Walk_(?:-_)?",
    "Room_Conversation": r"Room_Conversa?tion_(?:-_)?",
    "Various": r"(?:Questions_and_Answers|[A-Za-z]+)_(?:-_)?",
}
# What kind of talk it was, when the name puts that before the place.
KINDS = {
    "Public_Lecture": "Public Lecture",
    "Press_Conference": "Press Conference",
    "and_Initiation": "Lecture and Initiation",
    "with_Sannyasis": "With Sannyasis",
    "Purport_to_Parama_Karuna": "Purport to Parama Karuna",
}
KIND = re.compile(r"^(" + "|".join(KINDS) + r")_")
# Several recordings of one day: Room_Conversation_02_Atlanta_...
PART = re.compile(r"^(\d{2})_")
PLACE_TYPOS = {"Los Los Angeles": "Los Angeles", "Sanand Francisco": "San Francisco", "Los Angles": "Los Angeles"}


def tidy(subject):
    subject = re.sub(r"\.\.\.(?=\w)", "… ", subject).replace("...", "…")
    subject = re.sub(r"…+", "…", subject)
    # Day After Gaura Purnima-01 -> Day After Gaura Purnima, Part 1
    return re.sub(r"(?<=[a-z])-0?(\d)$", r", Part \1", subject)


def describe(folder, filename):
    """Title, year, place and date of a lecture from its archive filename, e.g.
    SP_BG_07-11_Bombay_1974-02-25_Unplanned_Unwanted_Children.mp3 ->
    ('BG 7.11 — Unplanned Unwanted Children', 1974, 'Bombay', '1974-02-25')."""
    name = re.sub(r"^SP_", "", os.path.splitext(filename)[0])
    date = DATE.search(name)
    if not date:
        # Undated: recitations, dictations, stories, the Happening album.
        name = re.sub(r"^(BG_Recitation_|Krsna_Book_Dict_|Story_|\d+-AC_Bhaktivedanta_Swami_-_)", "", name)
        name = re.sub(r"^Chapter-(\d+)_-_Sanskrit$", lambda m: f"Chapter {int(m[1])}", name)
        name = re.sub(r"^(\d+)_-?_?", lambda m: f"{int(m[1])} — ", name)
        return words(name.replace("_-_", " — ")), None, "", ""

    # A day range (1966-02-19_-20) belongs to the date, not the subject.
    before, after = name[: date.start()], re.sub(r"^[-_]+(?:\d{1,2}_)?", "", name[date.end():])
    label = kind = part = ""
    if folder in REFS:
        prefix, ref, make = REFS[folder]
        before = re.sub("^" + prefix, "", before)
        match = re.match(ref, before)
        if match:
            label, before = make(match), before[match.end():]
    elif folder in PREFIXES:
        before = re.sub("^" + PREFIXES[folder], "", before)
    if match := KIND.match(before):
        kind, before = KINDS[match[1]], before[match.end():]
    if match := PART.match(before):
        part, before = str(int(match[1])), before[match.end():]

    place, subject = words(before), tidy(words(after.replace("_-_", " ")))
    if not place and subject:
        # Some names put the place after the date: ..._1974-07-25_New_York.
        place, subject = subject, ""
    place = PLACE_TYPOS.get(place, place)
    subject = " ".join(filter(None, (kind, subject)))
    if not subject:
        # Untitled recordings are told apart by place, date and part.
        subject = ", ".join(filter(None, (place, date[0]))) + (f" ({part})" if part else "")
    if label and subject.lower() in label.lower():
        subject = ""  # CC Adi, Introduction — Introduction
    title = " — ".join(filter(None, (label, subject)))
    return title, int(date[1]), place, date[0]


def renumber(topic, hashes):
    """Puts the topic's lectures in the order of their file hashes, so ones a
    re-run added late land in their place rather than at the end."""
    position = {file_hash: i for i, file_hash in enumerate(hashes)}
    lectures = sorted(topic.lectures.all(), key=lambda l: (position.get(l.file_hash, len(hashes)), l.order))
    if [l.order for l in lectures] == list(range(1, len(lectures) + 1)):
        return
    for order, lecture in enumerate(lectures, 1):
        lecture.order = order
    # Move everyone out of the way first: (topic, order) is unique. Together,
    # so an interrupted run doesn't leave them there.
    with transaction.atomic():
        topic.lectures.update(order=F("order") + 1_000_000)
        Lecture.objects.bulk_update(lectures, ["order"])


class Command(BaseCommand):
    help = (
        "Import Srila Prabhupada's original English recordings from the ISKCON "
        "Desire Tree archive into en-* topics. Re-runs skip what's imported."
    )

    def add_arguments(self, parser):
        parser.add_argument("--folder", action="append", help="Only these archive folders, e.g. Isopanishad")
        parser.add_argument("--limit", type=int, help="Import at most this many lectures per folder")
        parser.add_argument("--dry-run", action="store_true", help="List titles without downloading")
        parser.add_argument("--workers", type=int, default=6, help="Parallel downloads (default 6)")

    def handle(self, *args, folder=None, limit=None, dry_run=False, workers=6, **options):
        folders = list(dict.fromkeys(folder or TOPICS))
        unknown = set(folders) - set(TOPICS)
        if unknown:
            raise CommandError(f"Unknown folders: {', '.join(sorted(unknown))}")

        lecturer = Lecturer.objects.get(code=LECTURER_CODE)
        english = Language.objects.get(code="en")
        added = failed = 0
        for name in folders:
            paths = sorted(walk(ROOT + name + "/"), key=lambda p: self.sort_key(name, p))
            self.stdout.write(self.style.MIGRATE_HEADING(f"{name}: {len(paths)} files"))
            if dry_run:
                for path in paths[:limit]:
                    title, year, place, date = describe(name, urllib.parse.unquote(os.path.basename(path)))
                    self.stdout.write(f"  {title}  |  {place}  |  {date}")
                continue

            topic = self.get_topic(lecturer, name)
            known = set(topic.lectures.values_list("file_hash", flat=True))
            todo = [p for p in paths if Lecture.generate_file_hash(ARCHIVE + p) not in known][:limit]
            # Downloads run in parallel a batch at a time, so only a batch sits
            # on disk; saving stays sequential to keep the archive's order.
            with ThreadPoolExecutor(workers) as pool:
                for start in range(0, len(todo), workers):
                    batch = todo[start : start + workers]
                    for i, (path, fetched) in enumerate(zip(batch, pool.map(self.fetch, batch)), start + 1):
                        url = ARCHIVE + path
                        if isinstance(fetched, Exception):
                            failed += 1
                            self.stdout.write(self.style.WARNING(f"  Failed {url}: {fetched}"))
                            continue
                        title, year, place, date = describe(name, urllib.parse.unquote(os.path.basename(path)))
                        last_order = topic.lectures.aggregate(last=Max("order"))["last"] or 0
                        try:
                            with fetched:
                                save_lecture(
                                    topic,
                                    {"title": title, "year": year, "event": place, "description": date},
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

            self.update_details(topic, name, paths)
            renumber(topic, [Lecture.generate_file_hash(ARCHIVE + p) for p in paths])

        self.stdout.write(self.style.SUCCESS(f"Added {added}, failed {failed}"))

    def update_details(self, topic, folder, paths):
        """Brings imported lectures' titles, places and dates up to date with
        describe(), so naming fixes reach them without a new download."""
        path_of = {Lecture.generate_file_hash(ARCHIVE + p): p for p in paths}
        changed = []
        for lecture in topic.lectures.all():
            path = path_of.get(lecture.file_hash)
            if not path:
                continue
            title, year, place, date = describe(folder, urllib.parse.unquote(os.path.basename(path)))
            new = {"title": title, "year": year, "event": place, "description": date}
            if any(getattr(lecture, field) != value for field, value in new.items()):
                for field, value in new.items():
                    setattr(lecture, field, value)
                changed.append(lecture)
        Lecture.objects.bulk_update(changed, ["title", "year", "event", "description"])
        if changed:
            self.stdout.write(f"  Updated details of {len(changed)} lectures")

    @staticmethod
    def fetch(path):
        try:
            return fetch_audio(ARCHIVE + path)
        except Exception as e:
            return e

    @staticmethod
    def sort_key(folder, path):
        """Scriptures go in verse order, lectures on one verse and everything
        else by date."""
        date = DATE.search(path)
        date = date[0] if date else ""
        if folder in REFS:
            label = describe(folder, urllib.parse.unquote(os.path.basename(path)))[0].split(" — ")[0]
            # Introductions come before the first verse.
            label = label.replace("Introduction", "0").replace(", 0", " 0")
            return (natural_key(label), date, natural_key(path))
        return (date, natural_key(path))

    def get_topic(self, lecturer, folder):
        code, title, description, group, cover = TOPICS[folder]
        topic, created = Topic.objects.get_or_create(
            lecturer=lecturer,
            code=code,
            defaults={
                "title": title,
                "description": description,
                "group": TopicGroup.objects.get(code=group),
                "order": FIRST_ORDER + list(TOPICS).index(folder),
            },
        )
        cover_path = os.path.join(COVERS_DIR, cover, "cover", "cover.jpg")
        if not topic.cover and os.path.exists(cover_path):
            with open(cover_path, "rb") as f:
                topic.cover.save("cover.jpg", File(f), save=True)
        if created:
            self.stdout.write(f"Created topic {title}")
        return topic
