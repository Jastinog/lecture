import json
import os
import re
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from django.core.files import File
from django.core.management.base import BaseCommand, CommandError
from django.db.models import Max

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

from .create_lecturers import create_lecture, fetch_audio, store_audio
from .import_prabhupada import COVERS_DIR, LECTURER_CODE, natural_key, renumber

# Srila Prabhupada's lectures and conversations with Russian voice-over
# (translation and reading by Prema Vardhana das, kadr108.ru), shared as a
# public cloud.mail.ru folder by nagoloku.ru, laid out by period.
CLOUD = "https://cloud.mail.ru"
FOLDER = "YBSH/BgujSVAih"
UA = {"User-Agent": "Mozilla/5.0"}

# Topic -> (title, description, group, order). The ru-* codes match the covers
# in lecturers/<code>/topics/.
TOPICS = {
    "ru-bhagavad-gita": ("Бхагавад-гита", "Лекции по «Бхагавад-гите как она есть»", "lectures", 1),
    "ru-srimad-bhagavatam": ("Шримад-Бхагаватам", "Лекции по «Шримад-Бхагаватам»", "lectures", 2),
    "ru-chaitanya-charitamrita": ("Шри Чайтанья-чаритамрита", "Лекции по «Шри Чайтанья-чаритамрите»", "lectures", 3),
    "ru-nectar-of-devotion": ("Нектар преданности", "Лекции по «Нектару преданности»", "lectures", 4),
    "ru-sri-ishopanishad": ("Шри Ишопанишад", "Лекции по «Шри Ишопанишад»", "lectures", 5),
    "ru-festivals": ("Праздники", "Лекции на праздники", "lectures", 6),
    "ru-lectures": ("Лекции", "Лекции, обращения и инициации", "lectures", 7),
    "ru-morning-walks": ("Утренние прогулки", "Утренние прогулки со Шрилой Прабхупадой", "walks", 8),
    "ru-conversations": ("Беседы", "Беседы со Шрилой Прабхупадой", "conversations", 9),
    "ru-interviews": ("Интервью", "Интервью и пресс-конференции", "interviews", 10),
}

# First match wins: a Gita lecture on Vyasa-puja is still a Gita lecture.
RULES = [
    ("ru-bhagavad-gita", r"\b(?:Бг|БГ|BG|Bg)\b"),
    ("ru-srimad-bhagavatam", r"\b(?:SB|ШБ)\s?\d"),
    ("ru-chaitanya-charitamrita", r"\b(?:CC|ЧЧ)\s?\d"),
    ("ru-nectar-of-devotion", r"\bNOD\b|Нектар Преданно"),
    ("ru-sri-ishopanishad", r"\bIso\s?\d|Ишопанишад"),
    ("ru-morning-walks", r"\bM ?walk\b|рогулка"),
    ("ru-interviews", r"Интервью|Interview|Пресс-конф|Press"),
    ("ru-conversations", r"Беседа|беседа|Conversation|Conference|Даршан|Встреча"),
    (
        "ru-festivals",
        r"Джанмаштами|Janmastami|Вь?я?й?аса-пудж|Vyasa|Гаура-пурним|Gaura Purnima|Rama Navami|"
        r"Раманавами|Нрисимха-чатурдаши|Ratha-yatra|Ратха-ятр|Govardhana Puja|Disapp|Appearance|"
        r"Явление|Уход",
    ),
]

PLACES = {
    "Ahm": "Ахмедабад", "Atlanta": "Атланта", "Auckland": "Окленд", "Bhuvanesvar": "Бхуванешвар",
    "Bom": "Бомбей", "Boston": "Бостон", "Calcutta": "Калькутта", "Caracas": "Каракас",
    "Chicago": "Чикаго", "Columbus": "Колумбус", "Dallas": "Даллас", "Delhi": "Дели",
    "Denver": "Денвер", "Detroit": "Детройт", "Durban": "Дурбан", "Fiji": "Фиджи",
    "Geneva": "Женева", "Ger": "Германия", "HKong": "Гонконг", "Hamburg": "Гамбург",
    "Hawaii": "Гавайи", "Honolulu": "Гонолулу", "Hyderabad": "Хайдарабад",
    "Johannesburg": "Йоханнесбург", "LA": "Лос-Анджелес", "LagunaBeach": "Лагуна-Бич",
    "Laguna Beach": "Лагуна-Бич", "London": "Лондон", "Madras": "Мадрас", "Mauritius": "Маврикий",
    "Mayapur": "Майяпур", "Melb": "Мельбурн", "Mexico": "Мехико", "Miami": "Майами",
    "Montreal": "Монреаль", "Moscow": "Москва", "Nairobi": "Найроби", "Nellore": "Неллор",
    "NOrleans": "Новый Орлеан", "NVr": "Нью-Вриндаван", "NY": "Нью-Йорк", "Paris": "Париж",
    "Perth": "Перт", "Phil": "Филадельфия", "Philadelphia": "Филадельфия", "Rome": "Рим",
    "Sanand": "Сананд", "SanDiego": "Сан-Диего", "San Diego": "Сан-Диего",
    "Seattle": "Сиэтл", "SF": "Сан-Франциско", "San Francisco": "Сан-Франциско",
    "Stockholm": "Стокгольм", "Tehran": "Тегеран", "Tirupati": "Тирупати", "Tokyo": "Токио",
    "Toronto": "Торонто", "Vr": "Вриндаван", "Мelb": "Мельбурн", "Auckland,": "Окленд",
}
LILAS = {"1": "Ади", "2": "Мадхья", "3": "Антья"}
NAME = re.compile(r"^(\d\d)-(\d\d|xx)-(\d\d|xx)\S*\s+(?:#\d+\s+)?(.*)$")
# Scripture references, rewritten the Russian way: SB 3.25.5-6 -> ШБ 3.25.5–6.
REFS = [
    (re.compile(r"\b(?:Бг|БГ|BG|Bg)\.?\s?(\d+)\.(\d+)(?:-(\d+))?"), lambda m: f"БГ {int(m[1])}.{int(m[2])}" + (f"–{int(m[3])}" if m[3] else "")),
    (re.compile(r"\b(?:Бг|БГ|BG|Bg)\.?\s+Введение"), lambda m: "БГ, введение"),
    (re.compile(r"\b(?:SB|ШБ)\s?(\d+)\.(\d+)\.(\d+)(?:-(\d+))?"), lambda m: f"ШБ {int(m[1])}.{int(m[2])}.{int(m[3])}" + (f"–{int(m[4])}" if m[4] else "")),
    (re.compile(r"\b(?:CC|ЧЧ)\s?([123])\.(\d+)\.(\d+)(?:-(\d+))?"), lambda m: f"ЧЧ {LILAS[m[1]]} {int(m[2])}.{int(m[3])}" + (f"–{int(m[4])}" if m[4] else "")),
    (re.compile(r"\bIso\s?(\d+)(?:-(\d+))?"), lambda m: f"Мантры {int(m[1])}–{int(m[2])}" if m[2] else f"Мантра {int(m[1])}" if int(m[1]) else "Обращение"),
    (re.compile(r"Нектар Преданно[cс]ти\s*(?:Предисл\b)?"), lambda m: "Предисловие" if "Предисл" in m[0] else ""),
]
PAGES = re.compile(r"\b(Гл|стр)\s?(\d+)")
# Words that only say what the topic already does.
FILLER = re.compile(r"^M ?[Ww]alk(?:\s*[—–-]\s*|\s+|$)|^(?:Беседа|Интервью|Interview)(?:\s*[—–-]\s*|$)")
# A scripture reference anywhere in a title: "Rotary club БГ 2.11 — ...".
REF = re.compile(r"БГ, введение|(БГ|ШБ|ЧЧ)(?: (Ади|Мадхья|Антья))? (\d+(?:[.–]\d+)*)")
LILA_ORDER = {"Ади": 1, "Мадхья": 2, "Антья": 3}
# Talks on a whole chapter: "Чтение и обсуждение Бг 9 главы", "16 гл Бг", "SB 7.5".
CHAPTER = re.compile(r"(?:Бг|БГ) (\d+)\s?(?:гл|главы)|(\d+) гл\.? (?:Бг|БГ)|\bSB (\d+)\.(\d+)\b")


def topic_of(name):
    return next((code for code, rule in RULES if re.search(rule, name)), "ru-lectures")


def describe(name):
    """Title, year, place and date of a recording from its filename, e.g.
    '74-11-21 Bom SB 3.25.21 — Кто такой садху' ->
    ('ШБ 3.25.21 — Кто такой садху', 1974, 'Бомбей', '1974-11-21')."""
    match = NAME.match(name)
    if not match:
        return name, None, "", ""
    yy, mm, dd, rest = match.groups()
    year = 1900 + int(yy)
    date = "-".join([str(year)] + ([mm] if mm != "xx" else []) + ([dd] if mm != "xx" and dd != "xx" else []))

    place = ""
    first, _, tail = rest.partition(" ")
    if first in PLACES:
        place, rest = PLACES[first], re.sub(r"^(?:NZel\s+)?#\d+\s+|^NZel\s+", "", tail)
    for paren in re.findall(r"\(([^)]+)\)", rest):
        if paren in PLACES:
            place = place or PLACES[paren]
            rest = rest.replace(f"({paren})", "")
    for pattern, make in REFS:
        rest = pattern.sub(make, rest, count=1)
    rest = PAGES.sub(lambda m: f"{m[1]}. {m[2]}", rest)

    title = FILLER.sub("", re.sub(r"\s+", " ", rest).strip(" —-–")).strip(" —-–")
    title = title.replace(" – ", " — ")
    title = re.sub(r"\s*_?\(?incomplete\)?", " (запись неполная)", title)
    title = re.sub(r"^(\w+) — \1, ", r"\1 — ", title)  # "Обращение — Обращение, ..."
    return title or ", ".join(filter(None, (place, date))), year, place, date


def sort_key(code, name):
    """Scriptures go in verse order, lectures on one verse and everything else
    by date."""
    title, _, _, date = describe(name)
    if code in ("ru-bhagavad-gita", "ru-srimad-bhagavatam", "ru-chaitanya-charitamrita"):
        return (verse_key(title), date, natural_key(name))
    return (date, natural_key(name))


def verse_key(title):
    """Where a title's verse falls in its book: the introduction first, Adi
    before Madhya before Antya, titles without a reference last."""
    match = REF.search(title)
    if not match:
        # A chapter talk goes after that chapter's verses.
        chapter = CHAPTER.search(title)
        if chapter and chapter[3]:
            return [0, int(chapter[3]), int(chapter[4]), 9999]
        if chapter:
            return [0, int(chapter[1] or chapter[2]), 9999]
        return [9999]
    if not match[1]:
        return [0]
    return [LILA_ORDER.get(match[2], 0)] + [int(n) for n in re.findall(r"\d+", match[3])]


def api(path, **params):
    url = f"{CLOUD}/api/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as response:
        return json.load(response)


def walk(link):
    """Yields the weblink of every mp3 under `link`, listed 500 at a time."""
    page = api("v4/public/list", weblink=link, limit=500)
    items = page["list"]
    while len(items) < page["count"]["folders"] + page["count"]["files"]:
        items += api("v4/public/list", weblink=link, limit=500, offset=len(items))["list"]
    for item in items:
        if item["type"] == "folder":
            yield from walk(item["weblink"])
        elif item["name"].lower().endswith(".mp3"):
            yield item["weblink"]


class Command(BaseCommand):
    help = (
        "Import Srila Prabhupada's lectures with Russian voice-over from a public "
        "cloud.mail.ru archive into ru-* topics. Re-runs skip what's imported."
    )

    def add_arguments(self, parser):
        parser.add_argument("--topic", action="append", help="Only these topics, e.g. ru-sri-ishopanishad")
        parser.add_argument("--limit", type=int, help="Import at most this many lectures per topic")
        parser.add_argument("--dry-run", action="store_true", help="List titles without downloading")
        parser.add_argument("--workers", type=int, default=8, help="Parallel transfers (default 8)")

    def handle(self, *args, topic=None, limit=None, dry_run=False, workers=8, **options):
        codes = list(dict.fromkeys(topic or TOPICS))
        unknown = set(codes) - set(TOPICS)
        if unknown:
            raise CommandError(f"Unknown topics: {', '.join(sorted(unknown))}")

        by_topic = {code: [] for code in TOPICS}
        for link in walk(FOLDER):
            by_topic[topic_of(self.name_of(link))].append(link)
        # Files come from whichever download server the cloud hands out now.
        self.base = api("v2/dispatcher")["body"]["weblink_get"][0]["url"]

        lecturer = Lecturer.objects.get(code=LECTURER_CODE)
        russian = Language.objects.get(code="ru")
        added = failed = 0
        for code in codes:
            links = sorted(by_topic[code], key=lambda link: sort_key(code, self.name_of(link)))
            self.stdout.write(self.style.MIGRATE_HEADING(f"{code}: {len(links)} files"))
            if dry_run:
                for link in links[:limit]:
                    title, year, place, date = describe(self.name_of(link))
                    self.stdout.write(f"  {title}  |  {place}  |  {date}")
                continue

            topic_obj = self.get_topic(lecturer, code)
            known = set(topic_obj.lectures.values_list("file_hash", flat=True))
            todo = [link for link in links if self.hash_of(link) not in known][:limit]
            # Each worker downloads a file, uploads it to storage and deletes
            # its copy, so only files in flight sit on disk; creating the
            # lectures stays here, in the topic's order.
            with ThreadPoolExecutor(workers) as pool:
                transfers = pool.map(lambda link: self.transfer(topic_obj, link), todo)
                for i, (link, stored) in enumerate(zip(todo, transfers), 1):
                    if isinstance(stored, Exception):
                        failed += 1
                        self.stdout.write(self.style.WARNING(f"  Failed {link}: {stored}"))
                        continue
                    title, year, place, date = describe(self.name_of(link))
                    last_order = topic_obj.lectures.aggregate(last=Max("order"))["last"] or 0
                    create_lecture(
                        topic_obj,
                        {"title": title, "year": year, "event": place, "description": date},
                        russian,
                        last_order + 1,
                        self.hash_of(link),
                        stored,
                    )
                    added += 1
                    self.stdout.write(f"  [{i}/{len(todo)}] {title}", ending="\n")
                    self.stdout.flush()

            self.update_details(topic_obj, links)
            renumber(topic_obj, [self.hash_of(link) for link in links])

        self.stdout.write(self.style.SUCCESS(f"Added {added}, failed {failed}"))

    def update_details(self, topic, links):
        """Brings imported lectures' titles, places and dates up to date with
        describe(), so naming fixes reach them without a new download."""
        link_of = {self.hash_of(link): link for link in links}
        changed = []
        for lecture in topic.lectures.all():
            link = link_of.get(lecture.file_hash)
            if not link:
                continue
            title, year, place, date = describe(self.name_of(link))
            new = {"title": title, "year": year, "event": place, "description": date}
            if any(getattr(lecture, field) != value for field, value in new.items()):
                for field, value in new.items():
                    setattr(lecture, field, value)
                changed.append(lecture)
        Lecture.objects.bulk_update(changed, ["title", "year", "event", "description"])
        if changed:
            self.stdout.write(f"  Updated details of {len(changed)} lectures")

    @staticmethod
    def name_of(link):
        return os.path.splitext(link.rsplit("/", 1)[1])[0]

    @staticmethod
    def hash_of(link):
        return Lecture.generate_file_hash(f"{CLOUD}/public/{link}")

    def transfer(self, topic, link):
        try:
            with fetch_audio(f"{self.base}/{urllib.parse.quote(link)}") as audio_file:
                return store_audio(topic, audio_file)
        except Exception as e:
            return e

    def get_topic(self, lecturer, code):
        title, description, group, order = TOPICS[code]
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
