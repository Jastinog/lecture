import os
import re

from . import import_radhanath

# Niranjana Swami's recordings on the ISKCON Desire Tree archive, one folder a
# year, 1986-2021. Most are English; those translated into Russian on the spot
# say so in the name and go to Russian topics of their year.
LECTURER_CODE = "hh-niranjana-swami"
ROOT = "/02_-_ISKCON_Swamis/ISKCON_Swamis_-_D_to_P/His_Holiness_Niranjana_Swami/Lectures/"
# The years before 1992 hold a handful of recordings between them.
EARLY = 1992

YEAR = r"(19[89]\d|20[0-3]\d)"
MONTHS = {m: i for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split(), 1)}
# 1992-03-26, 1993-12, 1997-Aug, 1990-oct, 2006
DATE = re.compile(rf"(?<![\d-]){YEAR}(?:-(\d{{1,2}}|[A-Za-z]{{3}})(?:-(\d{{1,2}}))?)?(?!\d)")
# 89-05-27, 97-Aug, 92-sep (but not 03-26, a day and month)
SHORT_DATE = re.compile(r"(?<![\d-])(\d{2})-(?:([A-Za-z]{3})|(\d{2})-(\d{2}))(?![\d-])")
# The 1998-2001 tapes: NRS_1999_59_10May_SB_4-30-31_Xarikov, NRS_2000_056l_..., NRS_018_...
TAPE = re.compile(r"^(?:(\d{4})_)?(\d{2,3})l?_(?:(\d{2})([A-Z][a-z]{2})(?:_|(?=[A-Z])|$))?")

# _Russian_Translation, with the archive's misspellings, or a bare _Russian_ tag.
TRANSLATION = re.compile(
    r"_([A-Z][a-z]+?)s?_T(?:ranslation|ransaltion|anslation|ranslaion|raslation)(?=_|$)"
    r"|_(Russian|Hungarian)(?=_-_)"
    r"|_engru(?=_|$)"
)
LANGUAGES = {"Russiam": "Russian"}
# The 1992-93 tour tapes' numbering: _Russian_9, _Russian8, _4Russian_10, _Russian_Name_3, _Russian-12
TAPE_LABEL = re.compile(r"(?<=_)\d?Russian(?:_Name_\d+|[-_]?\d+|$)")

BOOKS = {"SB": "Srimad-Bhagavatam", "BG": "Bhagavad-gita", "CC": "Caitanya-caritamrta", "CB": "Caitanya-bhagavata"}
DEPTH = {"SB": 3, "BB": 3, "BG": 2, "CC": 2, "NOI": 1}
REF = re.compile(
    r"(?<![A-Za-z])(SB|BG|CC|BB|NOI)(?:_?(Adi|Madhya|Antya)(?:_?Lila)?)?_(\d+(?:-\d+){0,4})(?!\d)",
    re.I,
)
CATEGORIES = re.compile(r"^(?:Various|Festivals|Seminars?|Lectures?|Lec)$", re.I)
# Kirtans and bhajans aren't lectures.
KIRTAN = re.compile(
    r"^(?:\d{2}_-_)?NRS_Bhajans|(?:^|_-_|-)(?:Hare_Krishna_|Evening_)?Kirtans?(?:_\d+)?(?=_-_|$)|Mangala_Arati(?=_-_|$)",
    re.I,
)
PLACE_NAMES = {"StPete": "St. Petersburg", "St.Petersburg": "St. Petersburg", "SPB": "St. Petersburg", "Xarikov": "Kharkov", "Doneck": "Donetsk", "Manhatten": "Manhattan", "NVD": "New Vrindavan", "US": "USA"}


def language_of(filename):
    match = TRANSLATION.search(filename)
    return "ru" if match and (match[0] == "_engru" or LANGUAGES.get(match[1], match[1] or match[2]) == "Russian") else "en"


def words(text):
    """Archive spelling -> words: '_' is a space, Lecture-02 is Lecture 2, and a
    dash before a title of several words separates it: Sunday_Feast-The_Perfect_Yogi."""
    text = re.sub(r"(?<=[A-Za-z])-0?(\d+)(?!\d)", r" \1", text)
    text = re.sub(r"(?<=[a-z])-(?=[A-Z][A-Za-z']*_)", " — ", text)
    text = re.sub(r"(?<=[a-z])(?=[A-Z][a-z])", " ", text) if "_" not in text and len(text) > 14 else text  # CamelCaseRun
    return re.sub(r"\s+", " ", text.replace("_", " ")).strip(" -")


def ref_label(m):
    book = m[1].upper()
    nums = [str(int(n)) for n in m[3].split("-")]
    if len(nums) > 1 and nums[-1] == "0":  # SB 02-03-00: the chapter's start
        nums.pop()
    depth = DEPTH[book]
    lila = f" {m[2].title()}" if m[2] else ""
    return f"{book}{lila} " + ".".join(nums[:depth]) + (f"–{nums[-1]}" if len(nums) > depth else "")


def parse_date(match, short=False):
    y, mo, d = (match[1], match[2] or match[3], match[4]) if short else (match[1], match[2], match[3])
    if short:
        y = ("19" if int(y) > 50 else "20") + y
    if mo and not mo.isdigit():
        mo = MONTHS.get(mo.lower())
    mo, d = int(mo) if mo else 0, int(d) if d else 0
    if d and 1 <= mo <= 12 and 1 <= d <= 31:
        return y, f"{y}-{mo:02d}-{d:02d}"
    return y, ""


def describe(filename):
    """Title, year, place and date of a recording from its archive filename, e.g.
    NRS_SB_01-02-19_Russian_Translation_-_Becoming_Free_from_the_three_Modes_of_Nature_-_2014-06-15_Ukraine.mp3 ->
    ('SB 1.2.19 — Becoming Free from the three Modes of Nature', 2014, 'Ukraine', '2014-06-15')."""
    name = os.path.splitext(filename)[0].strip().replace(" ", "_")
    name = re.sub(r"^\d{2}_-_", "", name)
    name = re.sub(r"^NRS_", "", name, flags=re.I)
    translation = ""
    if match := TRANSLATION.search(name):
        language = "Russian" if match[0] == "_engru" else LANGUAGES.get(match[1], match[1] or match[2])
        if language != "Russian":
            translation = f" (with {language} translation)"
        name = name[: match.start()] + name[match.end():]
    name = TAPE_LABEL.sub("", name)
    name = re.sub(r"_{2,}", "_", name).strip("_")

    year = date = place = part = number = ""
    parts = name.split("_-_")
    if match := TAPE.match(name):
        # NRS_1999_59_10May_SB_4-30-31_Xarikov: year, tape, day and month, the rest.
        number = str(int(match[2]))
        if match[1]:
            year = match[1]
            if match[3] and (mo := MONTHS.get(match[4].lower())):
                date = f"{year}-{mo:02d}-{int(match[3]):02d}"
        parts = name[match.end():].split("_-_")
        if year and parts[0].startswith(year + "_"):
            parts[0] = parts[0][len(year) + 1:]
        if parts[0] == "engru" or re.fullmatch(r"\d{1,2}-\d{2}(?:-\d{2})?", parts[0]):  # the tape's length
            parts[0] = ""
    # The date sits at the end, the place right after it.
    last = parts[-1]
    match = DATE.search(last) or (not number and SHORT_DATE.search(last))
    if match and not date:
        year, date = parse_date(match, short=match.re is SHORT_DATE)
    if match:
        before, after = last[: match.start()].strip("_"), last[match.end():].strip("_")
        if m := re.match(r"[Pp]art-?0?(\d+)_?", after):
            part, after = m[1], after[m.end():]
        place = after
        parts[-1] = before
    elif len(parts) > 1 and re.fullmatch(r"[A-Z][a-z]+(?:_[A-Z][a-z]+)?", last):
        place, parts[-1] = last, ""
    elif number and (m := re.search(r"(?:^|_)([A-Z][a-z]{3,})$", last)):
        # The tapes end with the city: SB_4-30-31_Xarikov, BG_Voronezh, Kiev.
        place, parts[-1] = m[1], last[: m.start()]
    place = PLACE_NAMES.get(place) or (words(place.title() if place.isupper() else place) if place else "")

    label = book = ""
    for i, p in enumerate(parts):
        if match := REF.search(p):
            label = label or ref_label(match)
            parts[i] = (p[: match.start()] + "_" + p[match.end():]).strip("_")
            break
    if (match := re.match(r"(SB|BG|CC|CB)(?:_|$)", parts[0])) and not label:
        book, parts[0] = match[1], parts[0][match.end():]
    parts[0] = parts[0].strip("_")
    if CATEGORIES.match(parts[0]) or re.fullmatch(r"(?:SB|BG|CC|CB)", parts[0]):
        parts[0] = ""
    titles = [words(p) for p in parts if p.strip("_ ")]
    titles = [t for t in titles if not CATEGORIES.match(t)]
    subject = " — ".join(titles)
    if re.fullmatch(r"Lecture \d+", subject):  # the archive's count, not a title
        number, subject = subject.split()[1], ""
    if not subject and not label:
        # Untitled recordings are told apart by place and date, or the tape's number.
        what = BOOKS.get(book) or f"Lecture {number}".strip()
        subject = ", ".join(filter(None, (what, place, date or year)))
    title = " — ".join(filter(None, (label, subject))) + (f" (part {int(part)})" if part else "") + translation
    return title, int(year) if year else None, place, date


def topic_for(path):
    folder = path[len(ROOT):].split("/")[0]
    if not folder.isdigit():
        return None
    language = language_of(os.path.basename(path))
    y = int(folder)
    if y < EARLY:
        code, title, y = f"{1986}-{EARLY - 1}", f"1986–{EARLY - 1}", 1986
    else:
        code, title = str(y), str(y)
    if language == "ru":
        return (f"ru-{code}", title, f"Лекции {title} года с русским переводом", "lectures", "ru", 100 + y - 1980)
    return (f"en-{code}", title, f"Lectures of {title}", "lectures", "en", y - 1980)


def is_his(path):
    return not KIRTAN.search(os.path.basename(path))


class Command(import_radhanath.Command):
    help = (
        "Import Niranjana Swami's lectures (English, and those with Russian translation) "
        "from the ISKCON Desire Tree archive. Re-runs skip what's imported."
    )
    root = ROOT
    lecturer_code = LECTURER_CODE
    topic_for = staticmethod(topic_for)
    is_his = staticmethod(is_his)
    skipped_label = "kirtans and bhajans"

    @classmethod
    def describe(cls, path):
        return describe(cls.name_of(path))
