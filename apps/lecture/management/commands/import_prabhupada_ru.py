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

from .create_lecturers import fetch_audio, save_lecture
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
FILLER = re.compile(r"^(?:M ?[Ww]alk|Беседа|Интервью|Interview)(?:\s*[—–-]\s*|$)")


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
    title = re.sub(r"^(\w+) — \1, ", r"\1 — ", title)  # "Обращение — Обращение, ..."
    return title or ", ".join(filter(None, (place, date))), year, place, date


def sort_key(code, name):
    """Scriptures go in verse order, lectures on one verse and everything else
    by date."""
    title, _, _, date = describe(name)
    if code in ("ru-bhagavad-gita", "ru-srimad-bhagavatam", "ru-chaitanya-charitamrita"):
        return (natural_key(title.split(" — ")[0]), date, natural_key(name))
    return (date, natural_key(name))


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
        parser.add_argument("--workers", type=int, default=6, help="Parallel downloads (default 6)")

    def handle(self, *args, topic=None, limit=None, dry_run=False, workers=6, **options):
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
            # Downloads run in parallel a batch at a time, so only a batch sits
            # on disk; saving stays sequential to keep the topic's order.
            with ThreadPoolExecutor(workers) as pool:
                for start in range(0, len(todo), workers):
                    batch = todo[start : start + workers]
                    for i, (link, fetched) in enumerate(zip(batch, pool.map(self.fetch, batch)), start + 1):
                        if isinstance(fetched, Exception):
                            failed += 1
                            self.stdout.write(self.style.WARNING(f"  Failed {link}: {fetched}"))
                            continue
                        title, year, place, date = describe(self.name_of(link))
                        last_order = topic_obj.lectures.aggregate(last=Max("order"))["last"] or 0
                        try:
                            with fetched:
                                save_lecture(
                                    topic_obj,
                                    {"title": title, "year": year, "event": place, "description": date},
                                    russian,
                                    last_order + 1,
                                    self.hash_of(link),
                                    fetched,
                                )
                        except Exception as e:
                            failed += 1
                            self.stdout.write(self.style.WARNING(f"  Failed saving {link}: {e}"))
                            continue
                        added += 1
                        self.stdout.write(f"  [{i}/{len(todo)}] {title}")

            renumber(topic_obj, [self.hash_of(link) for link in links])

        self.stdout.write(self.style.SUCCESS(f"Added {added}, failed {failed}"))

    @staticmethod
    def name_of(link):
        return os.path.splitext(link.rsplit("/", 1)[1])[0]

    @staticmethod
    def hash_of(link):
        return Lecture.generate_file_hash(f"{CLOUD}/public/{link}")

    def fetch(self, link):
        try:
            return fetch_audio(f"{self.base}/{urllib.parse.quote(link)}")
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
