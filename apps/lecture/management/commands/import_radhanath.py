import os
import re
import subprocess
import tempfile
import threading
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import mutagen
from django.core.management.base import BaseCommand, CommandError
from django.db.models import Max

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

from .create_lecturers import create_lecture, fetch_audio, store_audio
from .import_prabhupada import ARCHIVE, natural_key, renumber, walk

# Radhanath Swami's recordings on the ISKCON Desire Tree archive: the originals
# by year, his yatras and series, and the Russian translations.
LECTURER_CODE = "hh-radhanath-swami"
ROOT = "/02_-_ISKCON_Swamis/ISKCON_Swamis_-_R_to_Y/His_Holiness_Radhanath_Swami/Lectures/"

# Archive folder -> (code, title, description, group, language, order).
SERIES = {
    "Gaura_Lila/": ("en-gaura-lila", "Gaura Lila", "Pastimes of Sri Caitanya Mahaprabhu", "lectures", "en", 60),
    "Ramayana/": ("en-ramayana", "Ramayana", "The pastimes of Lord Ramachandra", "lectures", "en", 61),
    "04_-_Brihad_Bhagavatamrata/": ("en-brihad-bhagavatamrita", "Brihad Bhagavatamrita", "Seminar on Brihad Bhagavatamrita, 1999", "lectures", "en", 62),
    "03_-_From_devotees/": ("en-recordings-from-devotees", "Recordings from Devotees", "Lectures recorded and shared by devotees", "lectures", "en", 63),
    "00_-_Year_wise/Gita_Nagari_Retreat_2014/": ("en-gita-nagari-retreat-2014", "Gita Nagari Retreat 2014", "Retreat at Gita Nagari", "lectures", "en", 64),
    "00_-_Year_wise/Gita_Nagari_Retreat_2015/": ("en-gita-nagari-retreat-2015", "Gita Nagari Retreat 2015", "Retreat at Gita Nagari", "lectures", "en", 65),
    "00_-_Year_wise/More/": ("en-more-lectures", "More Lectures", "Undated lectures", "lectures", "en", 66),
    "Russian_Translation/Brihad_Bhagvatmrita/": ("ru-brihad-bhagavatamrita", "Брихад-бхагаватамрита", "Семинар по «Брихад-бхагаватамрите», 1999", "lectures", "ru", 201),
    "Russian_Translation/Goswamis/": ("ru-goswamis", "Госвами Вриндавана", "Лекции о шести Госвами Вриндавана", "lectures", "ru", 202),
}
RU_PARIKRAMA_TITLES = {
    "2009_Mayapur_Yatra": "Маяпур-ятра 2009",
    "Gaur_mandal_parikrama-01": "Гаура-мандала парикрама 1997, часть 1",
    "Gaur_mandal_parikrama-02": "Гаура-мандала парикрама 1997, часть 2",
    "Jagannath_Puri": "Джаганнатха Пури",
    "Jaipur": "Джайпур",
    "South_India": "Южная Индия",
    "Vrindavan": "Вриндаван",
    "Vrindavan_Jaipur_Yatra": "Вриндаван и Джайпур",
}
YEARS = "00_-_Year_wise/"            # Devotional_Nectar_-_1989/ ... one topic a year
YATRAS = "02_-_Yatra/"               # one topic a yatra
RU_YEARS = "Russian_Translation/Yearwise/"
RU_PARIKRAMAS = "Russian_Translation/Parikramas/"
# Shorter files in the archive are broken stubs: a tag and a second of sound.
MIN_SECONDS = 30
# Folders where other speakers' talks sit next to his.
MIXED = (YATRAS, RU_PARIKRAMAS, "00_-_Year_wise/Gita_Nagari_Retreat_")

HIM = re.compile(r"Radha+na+th|Radhanth|\bRNS\b|HHRNSM|Radhanath", re.I)
OTHERS = re.compile(
    r"Prabhh?u|_Pr(?:_|$)|Swami|_Sw(?:_|$)|Maharaj|Mataji|Goswamiji|Babaji|_Dasa?(?:_|$)|Disciples?|"
    r"Devotees|All_Speakers|_HG[-_]|_H_G_|"
    # Unattributed kirtans, pujas and plays aren't his lectures either.
    r"Kirtan|Bhajans?|Puja|Drama|Welcome_Address",
    re.I,
)

PLACES = [
    "ISKCON Chowpatty", "Bhaktivedanta Manor", "Bhakti Center", "Prabhupadadesh Italy", "San Casciano",
    "New Vrindavan", "New York", "Los Angeles", "Laguna Beach", "Silicon Valley", "Gita Nagari",
    "Gopals Garden", "GEV Wada", "Jagannath Puri", "Radha Kunda", "Gupta Kunda", "Mumbai", "Pune",
    "Palghar", "Belgaum", "Kolhapur", "Kolkata", "Moscow", "Kiev", "Odessa", "London", "Italy", "Nepi",
    "Rome", "Athens", "Amsterdam", "Dallas", "Chicago", "Alachua", "California", "Rishikesh",
    "Vrindavan", "Mayapur", "Jaipur", "Juhu", "Chowpatty", "Dadar", "Coloba", "Wada", "GEV", "Udupi",
    "Kurukshetra", "Naimisharanya", "Nandigram", "Nigdi", "Bangalore", "Divnomorsk", "Pittsburgh",
    "Boston", "Seattle", "USA",
]
PLACE = re.compile(
    r"(?:^|\s)((?:ISKCON\s[A-Z][A-Za-z]+(?:\s[A-Z][a-z]+)?)|(?i:" + "|".join(re.escape(p) for p in PLACES) + r"))\s*$"
)

DATES = [
    (re.compile(r"(\d{4})-(\d{2})-(\d{2})"), lambda m: (m[1], m[2], m[3])),
    (re.compile(r"(?<!\d)(\d{1,2})-(\d{1,2})-(\d{4})(?!\d)"), lambda m: (m[3], m[2], m[1])),
    (re.compile(r"(?<![\d-])(\d{2})-(\d{2})-(\d{2})(?![\d-])"), lambda m: ("19" + m[3] if int(m[3]) > 50 else "20" + m[3], m[2], m[1])),
]
LILAS = {"AL": "Adi", "ADI": "Adi", "ML": "Madhya", "MADHYA": "Madhya", "ANTYA": "Antya", "AN": "Antya"}
TRANSLATIONS = {"MT": "with Marathi translation", "HT": "with Hindi translation"}
# "_" counts as a word character, so no \b around these.
REF = re.compile(
    r"(?<![A-Za-z])(SB|BG|CC)(?:[-_ ](Adi|Madhya|Antya|AL|ML|AN)(?:[-_ ]Lila)?)?[-_ ]?(\d+(?:[-_.]\d+){0,3})(?!\d)",
    re.I,
)
# Words that only repeat what the archive is or who speaks.
NOISE = [
    r"_?IDesire[Tt]ree", r"(?<![A-Za-z])HHRNS(?![A-Za-z])", r"(?<![A-Za-z])HH[-_ ]?",
    r"Radha+na+th[-_ ]?(?:Swami|Sw|Maharaj)?|Radhanth[-_ ]?Swami|(?<![A-Za-z])RNS(?![A-Za-z])",
    r"^(?:Various|Festivals?)(?:_Italian_Translation)?_-_", r"^Various_(?=\w)",
]
# In a yatra's folder, the yatra a talk belongs to is its topic already.
SERIES_NOISE = [
    r"^(?:\d{4}_)?(?:[A-Za-z]+_){0,3}(?:Kartik_)?[Yy]atra(?:_\d{4})?(?:_\d{1,2}(?=_))?_(?:-_)?",
    r"^(?:\d{4}_)?Gita_Nagari_Retreat_(?:-_)?",
    r"^(?:Bangladesh_\d{4}|SIY)_(?:[A-Za-z]+_)*?\d{2}_-_",
]
# Archive numbering in front: 1993-036_, 201540_, 2015-07_, 01_-_, Y04PU06_, and
# the Russian translations' 2001_02_ (the year, then the talk's number that day).
PREFIX = re.compile(r"^(?:\d{4}-\d{3}|\d{6}[ab]?|\d{4}-\d{2}|\d{4}_(\d{1,2})|\d{4}|\d{2}|Y\d\dPU\d\d)(?:_-_|_|\s)")


def ref_label(m):
    book = m[1].upper()
    nums = [str(int(n)) for n in re.split(r"[-_.]", m[3])]
    if book == "CC" and m[2]:
        lila = LILAS[m[2].upper()]
        return f"CC {lila} " + ".".join(nums[:2]) + (f"–{nums[-1]}" if len(nums) > 2 else "")
    depth = 3 if book == "SB" else 2
    return f"{book} " + ".".join(nums[:depth]) + (f"–{nums[-1]}" if len(nums) > depth else "")


def describe(filename, in_series=False):
    """Title, year, place and date of a recording from its archive filename, e.g.
    1993-036_Glories_Of_lord_Ramachandra_SB-09_10_04_-_Radhanath_Swami_1993-04-01_IDesireTree.mp3 ->
    ('SB 9.10.4 — Glories Of lord Ramachandra', 1993, '', '1993-04-01')."""
    name = os.path.splitext(filename)[0]
    date = year = ""
    for pattern, parts in DATES:
        if match := pattern.search(name):
            y, mo, d = parts(match)
            if 1 <= int(mo) <= 12 and 1 <= int(d) <= 31:
                date, year = f"{y}-{int(mo):02d}-{int(d):02d}", y
                name = name[: match.start()] + "_" + name[match.end():]
                break
    if not year and (match := re.search(r"(?<!\d)(19[89]\d|20[0-3]\d)(?!\d)", name)):
        year = match[1]
    number = match[1] if (match := re.match(r"^(\d{4}-\d{3})_", name)) else ""
    name = re.sub(r"Lecture(?=[A-Z])", "Lecture_", name)  # LectureMumbai
    name = name.strip("_- ")
    part = match[1] or "" if (match := PREFIX.match(name)) else ""
    name = PREFIX.sub("", name)
    for noise in NOISE + (SERIES_NOISE if in_series else []):
        name = re.sub(noise, "_", name.strip("_- "), flags=re.I)
        name = re.sub(r"_{2,}", "_", name)
    name = re.sub(r"(?<![A-Za-z])Part-0?(\d+)", r"Part_\1", name)
    # Parikrama days: 1997_Day-15_Part-01_... -> Day 15, Part 1 — ...
    name = re.sub(
        r"Day-0?(\d+)(?:_Part[-_]0?(\d+))?_?",
        lambda m: f"Day {m[1]}" + (f", Part {m[2]}" if m[2] else "") + "_-_",
        name,
    )

    label = ""
    if match := REF.search(name):
        label, name = ref_label(match), name[: match.start()] + "_-_" + name[match.end():]
    name = re.sub(r"(?<!\d)\d{1,2}-\d{1,2}-\d{2,4}(?!\d)", "_", name)  # a second date

    # What's left: title, place and filler, split on "_-_".
    parts = [p.replace("_", " ").strip(" -") for p in name.split("_-_")]
    # A lone digit or two is what a garbled date left behind.
    parts = [re.sub(r"\s+", " ", p) for p in parts if p.strip(" -_") and not re.fullmatch(r"\d{1,2}|\d{4}", p.strip())]
    place = ""
    for i in range(len(parts) - 1, -1, -1):
        if match := PLACE.search(parts[i]):
            place = match[1] if not match[1].islower() else match[1].title()
            parts[i] = parts[i][: match.start()].strip()
            break
    parts = [re.sub(r"\s(?:in|at)$", "", p) for p in parts]  # "Lecture in" once the place is gone
    subject = " — ".join(p for p in parts if p and not re.fullmatch(r"(?:Lecture|Lec|Class|SB|BG|CC)", p))
    if not place and (match := re.search(r"\s(?:Lecture|Lec)\s([A-Z][a-z]{3,})$", subject)):
        place, subject = match[1], subject[: match.start()]
    subject = re.sub(r"\s+(?:Lecture|Lec)$", "", subject).strip(" —-")
    subject = re.sub(r"\s(MT|HT|Mt|Ht)$", lambda m: f" ({TRANSLATIONS[m[1].upper()]})", subject)
    if not subject and not label:
        # Untitled recordings are told apart by place and date, or the
        # archive's number when there's neither.
        subject = ", ".join(filter(None, (place or "Lecture", date))) if (place or date) else f"Lecture {number}".strip()
        subject += f" ({int(part)})" if part else ""
    title = " — ".join(filter(None, (label, subject)))
    return title, int(year) if year else None, place, date


def topic_for(path):
    """The topic spec an archive path belongs to, or None to skip it."""
    rel = path[len(ROOT):]
    for prefix, spec in SERIES.items():
        if rel.startswith(prefix):
            return spec
    if rel.startswith(YEARS) and (match := re.match(r"Devotional_Nectar_-_(\d{4})/", rel[len(YEARS):])):
        y = int(match[1])
        return (f"en-{y}", str(y), f"Lectures of {y}", "lectures", "en", y - 1980)
    if rel.startswith(YATRAS):
        folder = rel[len(YATRAS):].split("/")[0]
        title = folder.replace("_", " ").replace("Jaganath", "Jagannath").replace("yatra", "Yatra")
        if "Yatra" not in title:
            title += " Yatra"
        # "1997 Mayapur Yatra" -> "Mayapur Yatra 1997"
        title = re.sub(r"^([\d-]+) (.+)$", r"\2 \1", title)
        return (f"en-yatra-{folder.lower().replace('_', '-')}", title, "Yatra with Radhanath Swami", "parikrams", "en", 100)
    if rel.startswith(RU_YEARS):
        y = rel[len(RU_YEARS):].split("/")[0]
        return (f"ru-{y}", f"{y}", f"Лекции {y} года с русским переводом", "lectures", "ru", 100 + int(y) - 1980) if y.isdigit() else None
    if rel.startswith(RU_PARIKRAMAS):
        folder = rel[len(RU_PARIKRAMAS):].split("/")[0]
        title = RU_PARIKRAMA_TITLES.get(folder, folder.replace("_", " "))
        return (f"ru-parikrama-{folder.lower().replace('_', '-')}", title, "Парикрама с Радханатхом Свами, русский перевод", "parikrams", "ru", 300)
    return None


def is_his(path):
    """In folders shared with other speakers, keep his talks and unattributed ones."""
    rel = path[len(ROOT):]
    if not rel.startswith(MIXED):
        return True
    name = os.path.splitext(os.path.basename(path))[0]
    return bool(HIM.search(name)) or not OTHERS.search(name)


def to_mp3(path):
    """Encodes an audio file as a temporary mp3 (closing deletes it)."""
    mp3 = tempfile.NamedTemporaryFile(suffix=".mp3")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", path, "-codec:a", "libmp3lame", "-b:a", "128k", mp3.name],
        check=True,
    )
    mp3.seek(0)
    return mp3


class Command(BaseCommand):
    help = (
        "Import Radhanath Swami's lectures (originals and Russian translations) from "
        "the ISKCON Desire Tree archive. Re-runs skip what's imported."
    )
    # What another lecturer's import overrides.
    root = ROOT
    lecturer_code = LECTURER_CODE
    topic_for = staticmethod(topic_for)
    is_his = staticmethod(is_his)
    skipped_label = "by other speakers"

    def add_arguments(self, parser):
        parser.add_argument("--topic", action="append", help="Only these topic codes, e.g. en-1989")
        parser.add_argument("--limit", type=int, help="Import at most this many lectures per topic")
        parser.add_argument("--dry-run", action="store_true", help="List titles without downloading")
        parser.add_argument("--workers", type=int, default=8, help="Parallel transfers (default 8)")

    def handle(self, *args, topic=None, limit=None, dry_run=False, workers=8, **options):
        by_topic, specs = {}, {}
        skipped = 0
        for path in walk(self.root):
            spec = self.topic_for(path)
            if not spec:
                continue
            if not self.is_his(path):
                skipped += 1
                continue
            specs[spec[0]] = spec
            by_topic.setdefault(spec[0], []).append(path)
        codes = list(dict.fromkeys(topic or sorted(specs, key=lambda c: (specs[c][5], c))))
        unknown = set(codes) - set(specs)
        if unknown:
            raise CommandError(f"Unknown topics: {', '.join(sorted(unknown))}")
        self.stdout.write(f"{sum(map(len, by_topic.values()))} recordings in {len(specs)} topics, {skipped} {self.skipped_label} skipped")

        lecturer = Lecturer.objects.get(code=self.lecturer_code)
        languages = {code: Language.objects.get(code=code) for code in ("en", "ru")}
        added = failed = duplicates = 0
        for code in codes:
            paths = sorted(by_topic[code], key=self.sort_key)
            self.stdout.write(self.style.MIGRATE_HEADING(f"{code}: {len(paths)} files"))
            if dry_run:
                for path in paths[:limit]:
                    title, year, place, date = self.describe(path)
                    self.stdout.write(f"  {title}  |  {place}  |  {date}")
                continue

            topic_obj = self.get_topic(lecturer, specs[code])
            known = set(topic_obj.lectures.values_list("file_hash", flat=True))
            # The same recording sometimes sits in a folder twice under two
            # names; byte-identical sizes give it away.
            self.sizes = set(topic_obj.lectures.values_list("file_size", flat=True))
            self.lock = threading.Lock()
            todo = [p for p in paths if Lecture.generate_file_hash(ARCHIVE + p) not in known][:limit]
            with ThreadPoolExecutor(workers) as pool:
                transfers = pool.map(lambda path: self.transfer(topic_obj, path), todo)
                for i, (path, stored) in enumerate(zip(todo, transfers), 1):
                    if stored is None:
                        duplicates += 1
                        continue
                    if stored == "short":
                        failed += 1
                        self.stdout.write(self.style.WARNING(f"  Skipped {ARCHIVE + path}: under {MIN_SECONDS}s, a broken file"))
                        continue
                    if isinstance(stored, Exception):
                        failed += 1
                        self.stdout.write(self.style.WARNING(f"  Failed {ARCHIVE + path}: {stored}"))
                        continue
                    title, year, place, date = self.describe(path)
                    last_order = topic_obj.lectures.aggregate(last=Max("order"))["last"] or 0
                    create_lecture(
                        topic_obj,
                        {"title": title, "year": year, "event": place, "description": date},
                        languages[specs[code][4]],
                        last_order + 1,
                        Lecture.generate_file_hash(ARCHIVE + path),
                        stored,
                    )
                    added += 1
                    self.stdout.write(f"  [{i}/{len(todo)}] {title}")
            self.update_details(topic_obj, paths)
            renumber(topic_obj, [Lecture.generate_file_hash(ARCHIVE + p) for p in paths])

        self.stdout.write(self.style.SUCCESS(f"Added {added}, duplicates skipped {duplicates}, failed {failed}"))

    @staticmethod
    def name_of(path):
        return urllib.parse.unquote(os.path.basename(path))

    @classmethod
    def describe(cls, path):
        return describe(cls.name_of(path), in_series=path[len(ROOT):].startswith(MIXED))

    @classmethod
    def sort_key(cls, path):
        """By date where the name has one, else by the archive's numbering."""
        title, year, place, date = cls.describe(path)
        return (date or str(year or ""), natural_key(urllib.parse.unquote(path)))

    def transfer(self, topic, path):
        """Downloads and uploads one recording: its stored fields, None for a
        duplicate, "short" for a broken stub, or the error."""
        try:
            with fetch_audio(ARCHIVE + path) as audio_file:
                size = os.path.getsize(audio_file.name)
                with self.lock:
                    if size in self.sizes:
                        return None
                    self.sizes.add(size)
                if audio_file.read(4) == b"RIFF":
                    # A WAV under an .mp3 name: encode it the way the rest are.
                    with to_mp3(audio_file.name) as mp3:
                        return self.store(topic, mp3)
                audio_file.seek(0)
                return self.store(topic, audio_file)
        except Exception as e:
            return e

    @staticmethod
    def store(topic, audio_file):
        audio = mutagen.File(audio_file.name)
        if audio is not None and audio.info and audio.info.length < MIN_SECONDS:
            return "short"
        return store_audio(topic, audio_file)

    def update_details(self, topic, paths):
        """Brings imported lectures' titles, places and dates up to date with
        describe(), so naming fixes reach them without a new download."""
        path_of = {Lecture.generate_file_hash(ARCHIVE + p): p for p in paths}
        changed = []
        for lecture in topic.lectures.all():
            path = path_of.get(lecture.file_hash)
            if not path:
                continue
            title, year, place, date = self.describe(path)
            new = {"title": title, "year": year, "event": place, "description": date}
            if any(getattr(lecture, field) != value for field, value in new.items()):
                for field, value in new.items():
                    setattr(lecture, field, value)
                changed.append(lecture)
        Lecture.objects.bulk_update(changed, ["title", "year", "event", "description"])
        if changed:
            self.stdout.write(f"  Updated details of {len(changed)} lectures")

    def get_topic(self, lecturer, spec):
        code, title, description, group, _, order = spec
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
        if created:
            self.stdout.write(f"Created topic {title}")
        return topic
