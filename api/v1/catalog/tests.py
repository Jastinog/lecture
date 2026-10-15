from datetime import timedelta

from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.lecture.models import (
    Language,
    Lecture,
    Lecturer,
    Selection,
    SelectionLecture,
    Topic,
    TopicGroup,
    LecturePlays,
)

LOCAL_STORAGE = {
    "default": {"BACKEND": "django.core.files.storage.InMemoryStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class CatalogAPITests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        cls.lectures_group = TopicGroup.objects.create(code="lectures", name="Лекции", order=1)
        cls.walks = TopicGroup.objects.create(code="walks", name="Прогулки", order=2)
        TopicGroup.objects.create(code="hidden", name="Скрытая", is_active=False)

        cls.prabhupada = Lecturer.objects.create(code="sp", name="Prabhupada", level=1, order=1)
        cls.disciple = Lecturer.objects.create(code="rs", name="Radhanath Swami", level=2, order=2)

        cls.gita = Topic.objects.create(
            lecturer=cls.prabhupada, code="gita", title="Бхагавад Гита",
            group=cls.lectures_group, order=1,
        )
        cls.walk = Topic.objects.create(
            lecturer=cls.prabhupada, code="walks", title="Прогулки",
            group=cls.walks, order=2,
        )
        cls.journey = Topic.objects.create(
            lecturer=cls.disciple, code="journey", title="Путешествие домой",
            group=cls.lectures_group, order=1,
        )
        for order, (title, duration, year) in enumerate(
            [("Глава 1", 1800, 1966), ("Глава 2 о бхакти", 2400, 1972)], start=1
        ):
            Lecture.objects.create(
                topic=cls.gita, title=title, language=cls.ru, order=order,
                duration=duration, year=year,
                audio_file=ContentFile(b"mp3", name="part.mp3"),
            )

    def setUp(self):
        self.client = APIClient()

    def test_groups_lists_only_active(self):
        response = self.client.get("/api/v1/groups/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual([g["code"] for g in response.json()], ["lectures", "walks"])

    def test_topics_paginated_with_card_fields(self):
        data = self.client.get("/api/v1/topics/").json()
        self.assertEqual((data["count"], data["page"], data["pages"]), (3, 1, 1))
        gita = next(t for t in data["results"] if t["id"] == self.gita.id)
        self.assertEqual(gita["lectures_count"], 2)
        self.assertEqual(gita["duration"], 4200)
        self.assertEqual(gita["lecturer"], {"id": self.prabhupada.id, "name": "Prabhupada"})
        self.assertEqual(gita["group"], {"code": "lectures", "name": "Лекции"})
        self.assertEqual(gita["languages"], ["ru"])

    def test_topics_filter_by_group(self):
        data = self.client.get("/api/v1/topics/", {"group": "walks"}).json()
        self.assertEqual([t["id"] for t in data["results"]], [self.walk.id])

    def test_topic_page(self):
        data = self.client.get(f"/api/v1/topics/{self.gita.id}/").json()
        self.assertEqual([l["title"] for l in data["lectures"]], ["Глава 1", "Глава 2 о бхакти"])
        self.assertTrue(data["lectures"][0]["url"].startswith("http://testserver/media/"))
        self.assertEqual(data["years"], {"first": 1966, "last": 1972})
        self.assertEqual(
            data["languages"], [{"code": "ru", "name": "Русский", "lectures_count": 2}]
        )
        self.assertEqual(data["lecturer"]["topics_count"], 2)
        self.assertEqual([t["id"] for t in data["related"]], [self.walk.id])

    def test_topic_page_missing(self):
        self.assertEqual(self.client.get("/api/v1/topics/999/").status_code, 404)

    def test_lecturers(self):
        data = self.client.get("/api/v1/lecturers/").json()
        self.assertEqual([l["id"] for l in data], [self.prabhupada.id, self.disciple.id])
        self.assertEqual((data[0]["topics_count"], data[0]["lectures_count"]), (2, 2))

        topics = self.client.get(f"/api/v1/lecturers/{self.disciple.id}/topics/").json()
        self.assertEqual([t["id"] for t in topics], [self.journey.id])

    def test_search(self):
        data = self.client.get("/api/v1/search/", {"q": "бхакти"}).json()
        self.assertEqual(len(data["lectures"]), 1)
        hit = data["lectures"][0]
        self.assertEqual((hit["index"], hit["topic"]["id"]), (1, self.gita.id))

        data = self.client.get("/api/v1/search/", {"q": "radhanath"}).json()
        self.assertEqual([l["id"] for l in data["lecturers"]], [self.disciple.id])
        self.assertEqual([t["id"] for t in data["topics"]], [self.journey.id])

    def test_nul_in_a_parameter_is_no_error(self):
        # Postgres refuses NUL in a string; it used to come back as a 500.
        for url in (
            "/api/v1/search/?q=%00", "/api/v1/search/?q=a&lang=%00",
            "/api/v1/topics/?group=%00", "/api/v1/topics/?lang=%00",
        ):
            self.assertEqual(self.client.get(url).status_code, 200, url)

    def test_empty_search(self):
        data = self.client.get("/api/v1/search/", {"q": "  "}).json()
        self.assertEqual(data, {"lecturers": [], "topics": [], "lectures": []})


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class LanguageTests(TestCase):
    """Each lecture has a language; a topic's languages are its lectures',
    and `?lang=` narrows every list to lectures in those languages."""

    @classmethod
    def setUpTestData(cls):
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        cls.en = Language.objects.create(code="en", name="English", native_name="English")
        cls.uk = Language.objects.create(code="uk", name="Ukrainian", native_name="Українська")
        group = TopicGroup.objects.create(code="lectures", name="Лекции", order=1)
        cls.lecturer = Lecturer.objects.create(code="sp", name="Prabhupada", level=1, order=1)
        cls.other = Lecturer.objects.create(code="rs", name="Radhanath Swami", level=2, order=2)

        cls.mixed = Topic.objects.create(
            lecturer=cls.lecturer, code="gita", title="Gita", group=group, order=1
        )
        cls.english = Topic.objects.create(
            lecturer=cls.lecturer, code="isopanisad", title="Isopanisad", group=group, order=2
        )
        cls.russian = Topic.objects.create(
            lecturer=cls.other, code="journey", title="Journey", group=group, order=1
        )
        # The mixed topic's order interleaves languages on purpose.
        cls.ch1 = cls.lecture(cls.mixed, "Chapter 1", cls.en, order=1, duration=100)
        cls.ch2 = cls.lecture(cls.mixed, "Глава 2", cls.ru, order=2, duration=200)
        cls.ch3 = cls.lecture(cls.mixed, "Chapter 3 bhakti", cls.en, order=3, duration=300)
        cls.lecture(cls.english, "Mantra 1 bhakti", cls.en, order=1, duration=50)
        cls.lecture(cls.russian, "День 1", cls.ru, order=1, duration=70)

    @staticmethod
    def lecture(topic, title, language, order, duration=0):
        return Lecture.objects.create(
            topic=topic, title=title, language=language, order=order,
            duration=duration, audio_file=ContentFile(b"mp3", name="part.mp3"),
        )

    def setUp(self):
        self.client = APIClient()

    def codes(self, topic):
        return sorted(topic.languages.values_list("code", flat=True))

    def test_topic_languages_follow_lectures(self):
        self.assertEqual(self.codes(self.mixed), ["en", "ru"])

        lecture = self.lecture(self.mixed, "Лекція", self.uk, order=4)
        self.assertEqual(self.codes(self.mixed), ["en", "ru", "uk"])

        lecture.language = self.ru
        lecture.save()
        self.assertEqual(self.codes(self.mixed), ["en", "ru"])

        self.ch2.delete()
        lecture.delete()
        self.assertEqual(self.codes(self.mixed), ["en"])

    def test_catalog_languages(self):
        self.assertEqual(
            self.client.get("/api/v1/languages/").json(),
            [
                {"code": "en", "name": "English", "lectures_count": 3},
                {"code": "ru", "name": "Русский", "lectures_count": 2},
            ],
        )

    def test_moving_a_lecture_resyncs_both_topics(self):
        self.ch2.topic = self.english
        self.ch2.order = 2
        self.ch2.save()
        self.assertEqual(self.codes(self.mixed), ["en"])
        self.assertEqual(self.codes(self.english), ["en", "ru"])

    def test_mixed_topic_plays_in_its_own_order(self):
        data = self.client.get(f"/api/v1/topics/{self.mixed.id}/").json()
        self.assertEqual(
            [(x["title"], x["language"]) for x in data["lectures"]],
            [("Chapter 1", "en"), ("Глава 2", "ru"), ("Chapter 3 bhakti", "en")],
        )
        self.assertEqual(
            data["languages"],
            [
                {"code": "en", "name": "English", "lectures_count": 2},
                {"code": "ru", "name": "Русский", "lectures_count": 1},
            ],
        )

    def test_topic_page_in_one_language(self):
        data = self.client.get(f"/api/v1/topics/{self.mixed.id}/", {"lang": "en"}).json()
        self.assertEqual([x["title"] for x in data["lectures"]], ["Chapter 1", "Chapter 3 bhakti"])
        self.assertEqual((data["lectures_count"], data["duration"]), (2, 400))
        # The switcher still sees every language the topic has.
        self.assertEqual([x["code"] for x in data["languages"]], ["en", "ru"])

    def test_topics_list_by_language(self):
        def topics(**params):
            results = self.client.get("/api/v1/topics/", params).json()["results"]
            return {t["id"]: (t["lectures_count"], t["languages"]) for t in results}

        self.assertEqual(
            topics(lang="ru"),
            {self.mixed.id: (1, ["en", "ru"]), self.russian.id: (1, ["ru"])},
        )
        self.assertEqual(
            topics(lang="en,uk"),
            {self.mixed.id: (2, ["en", "ru"]), self.english.id: (1, ["en"])},
        )
        self.assertEqual(len(topics()), 3)
        self.assertEqual(len(topics(lang=" , ")), 3)
        self.assertEqual(topics(lang="uk"), {})

    def test_lecturer_by_language(self):
        data = self.client.get(f"/api/v1/lecturers/{self.lecturer.id}/").json()
        self.assertEqual((data["topics_count"], data["lectures_count"]), (2, 4))
        self.assertEqual(
            data["languages"],
            [
                {"code": "en", "name": "English", "lectures_count": 3},
                {"code": "ru", "name": "Русский", "lectures_count": 1},
            ],
        )

        data = self.client.get(f"/api/v1/lecturers/{self.lecturer.id}/", {"lang": "ru"}).json()
        self.assertEqual((data["topics_count"], data["lectures_count"]), (1, 1))
        self.assertEqual(len(data["languages"]), 2)

        topics = self.client.get(
            f"/api/v1/lecturers/{self.lecturer.id}/topics/", {"lang": "ru"}
        ).json()
        self.assertEqual([t["id"] for t in topics], [self.mixed.id])

        lecturers = self.client.get("/api/v1/lecturers/", {"lang": "en"}).json()
        self.assertEqual([x["id"] for x in lecturers], [self.lecturer.id])

    def test_search_positions_follow_the_language(self):
        data = self.client.get("/api/v1/search/", {"q": "bhakti", "lang": "en"}).json()
        hits = {h["lecture"]["title"]: h["index"] for h in data["lectures"]}
        # Chapter 3 is third in the topic but second among its English lectures.
        self.assertEqual(hits, {"Chapter 3 bhakti": 1, "Mantra 1 bhakti": 0})

        data = self.client.get("/api/v1/search/", {"q": "bhakti", "lang": "ru"}).json()
        self.assertEqual(data["lectures"], [])

        data = self.client.get("/api/v1/search/", {"q": "radhanath", "lang": "en"}).json()
        self.assertEqual((data["lecturers"], data["topics"]), ([], []))


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class SelectionAPITests(TestCase):
    """A lecturer's selections nest (Gita -> chapters), take lectures from any
    of their topics, and count what's nested in them."""

    @classmethod
    def setUpTestData(cls):
        cls.en = Language.objects.create(code="en", name="English", native_name="English")
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        group = TopicGroup.objects.create(code="lectures", name="Lectures", order=1)
        cls.sp = Lecturer.objects.create(code="sp", name="Prabhupada", level=1, order=1)
        cls.other = Lecturer.objects.create(code="rs", name="Radhanath Swami", level=2, order=2)
        london = Topic.objects.create(lecturer=cls.sp, code="london", title="London", group=group, order=1)
        bombay = Topic.objects.create(lecturer=cls.sp, code="bombay", title="Bombay", group=group, order=2)
        theirs = Topic.objects.create(lecturer=cls.other, code="t", title="Theirs", group=group, order=1)

        def lecture(topic, title, language, order):
            return Lecture.objects.create(
                topic=topic, title=title, language=language, order=order, duration=600,
                audio_file=ContentFile(b"mp3", name="part.mp3"),
            )

        cls.bg_2_13 = lecture(london, "BG 2.13", cls.en, 1)
        cls.bg_2_13_ru = lecture(bombay, "BG 2.13", cls.ru, 1)
        cls.bg_1_1 = lecture(bombay, "BG 1.1", cls.en, 2)
        cls.foreign = lecture(theirs, "BG 2.13", cls.en, 1)

        cls.gita = Selection.objects.create(lecturer=cls.sp, title="Bhagavad-gita", order=1)
        cls.ch1 = Selection.objects.create(lecturer=cls.sp, parent=cls.gita, title="Chapter 1", order=1)
        cls.ch2 = Selection.objects.create(lecturer=cls.sp, parent=cls.gita, title="Chapter 2", order=2)
        SelectionLecture.objects.create(selection=cls.ch1, lecture=cls.bg_1_1, order=1)
        # Bombay's lecture first: the selection keeps its own order.
        SelectionLecture.objects.create(selection=cls.ch2, lecture=cls.bg_2_13_ru, order=1)
        SelectionLecture.objects.create(selection=cls.ch2, lecture=cls.bg_2_13, order=2)

    def setUp(self):
        self.client = APIClient()

    def test_lecturer_selections_count_what_is_nested(self):
        data = self.client.get(f"/api/v1/lecturers/{self.sp.id}/selections/").json()
        self.assertEqual(len(data), 1)
        gita = data[0]
        self.assertEqual(gita["title"], "Bhagavad-gita")
        self.assertEqual(
            (gita["children_count"], gita["lectures_count"], gita["duration"], gita["languages"]),
            (2, 3, 1800, ["en", "ru"]),
        )
        self.assertEqual(self.client.get(f"/api/v1/lecturers/{self.other.id}/selections/").json(), [])

    def test_folder_lists_its_selections(self):
        data = self.client.get(f"/api/v1/selections/{self.gita.id}/").json()
        self.assertEqual([c["title"] for c in data["children"]], ["Chapter 1", "Chapter 2"])
        self.assertEqual([c["lectures_count"] for c in data["children"]], [1, 2])
        self.assertEqual((data["kind"], data["holds"]), ("selection", "selections"))
        self.assertEqual(data["lectures"], [])
        self.assertEqual(data["path"], [])
        self.assertEqual(data["lecturer"]["id"], self.sp.id)
        self.assertEqual([x["code"] for x in data["languages"]], ["en", "ru"])

    def test_leaf_plays_its_lectures_in_its_own_order(self):
        data = self.client.get(f"/api/v1/selections/{self.ch2.id}/").json()
        self.assertEqual(data["path"], [{"id": self.gita.id, "title": "Bhagavad-gita"}])
        self.assertEqual(data["holds"], "lectures")
        self.assertEqual(data["children"], [])
        # Shaped as a topic page, so the app can play it as one.
        self.assertEqual(data["related"], [])
        self.assertIn("created_at", data)
        self.assertEqual(
            [(x["id"], x["topic"]["title"]) for x in data["lectures"]],
            [(self.bg_2_13_ru.id, "Bombay"), (self.bg_2_13.id, "London")],
        )

    def test_language_narrows_counts_children_and_lectures(self):
        top = self.client.get(f"/api/v1/lecturers/{self.sp.id}/selections/", {"lang": "ru"}).json()
        self.assertEqual(top[0]["lectures_count"], 1)
        # The card's languages still list every one, for the switcher.
        self.assertEqual(top[0]["languages"], ["en", "ru"])
        folder = self.client.get(f"/api/v1/selections/{self.gita.id}/", {"lang": "ru"}).json()
        self.assertEqual([c["title"] for c in folder["children"]], ["Chapter 2"])
        leaf = self.client.get(f"/api/v1/selections/{self.ch2.id}/", {"lang": "ru"}).json()
        self.assertEqual([x["id"] for x in leaf["lectures"]], [self.bg_2_13_ru.id])

    def test_selection_missing(self):
        self.assertEqual(self.client.get("/api/v1/selections/999999/").status_code, 404)

    def test_holds_lectures_or_selections_not_both(self):
        with self.assertRaises(ValidationError):
            SelectionLecture(selection=self.gita, lecture=self.bg_2_13).full_clean()
        with self.assertRaises(ValidationError):
            Selection(lecturer=self.sp, parent=self.ch2, title="Verse 13").full_clean()

    def test_only_the_lecturers_own_lectures(self):
        with self.assertRaises(ValidationError):
            SelectionLecture(selection=self.ch2, lecture=self.foreign).full_clean()

    def test_moving_to_another_lecturers_selection(self):
        theirs = Selection.objects.create(lecturer=self.other, title="Theirs")
        self.ch1.parent = theirs
        with self.assertRaises(ValidationError):
            self.ch1.full_clean()

    def test_no_selection_inside_itself(self):
        self.gita.parent = self.ch1
        with self.assertRaises(ValidationError):
            self.gita.full_clean()


    def test_lecture_in_two_selections_counts_once(self):
        SelectionLecture.objects.create(selection=self.ch1, lecture=self.bg_2_13, order=2)
        gita = self.client.get(f"/api/v1/selections/{self.gita.id}/").json()
        self.assertEqual((gita["lectures_count"], gita["duration"]), (3, 1800))
        self.assertEqual(sum(x["lectures_count"] for x in gita["languages"]), 3)

    def test_folder_spans_the_years_of_whats_nested(self):
        Lecture.objects.filter(pk=self.bg_1_1.pk).update(year=1973)
        gita = self.client.get(f"/api/v1/selections/{self.gita.id}/").json()
        self.assertEqual(gita["years"], {"first": 1973, "last": 1973})

    def test_new_selection_takes_only_the_lecturers_lectures(self):
        # As the admin checks it: the selection isn't saved yet.
        new = Selection(lecturer=self.sp, title="Srimad-Bhagavatam")
        with self.assertRaises(ValidationError):
            SelectionLecture(selection=new, lecture=self.foreign).full_clean(exclude=["selection"])
        SelectionLecture(selection=new, lecture=self.bg_1_1).full_clean(exclude=["selection"])

    def test_filled_selection_keeps_its_lecturer(self):
        self.gita.lecturer = self.other
        with self.assertRaises(ValidationError):
            self.gita.full_clean()


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class HomeAPITests(TestCase):
    """The home page's rows, and the anonymous play count behind "Trending"."""

    @classmethod
    def setUpTestData(cls):
        cls.en = Language.objects.create(code="en", name="English", native_name="English")
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        group = TopicGroup.objects.create(code="lectures", name="Lectures", order=1)
        cls.sp = Lecturer.objects.create(code="sp", name="Prabhupada", level=1, order=1)
        cls.rs = Lecturer.objects.create(code="rs", name="Radhanath Swami", level=2, order=2)
        cls.topics, cls.lectures = [], []
        for order in range(1, 8):
            topic = Topic.objects.create(
                lecturer=cls.rs if order == 6 else cls.sp, code=f"t{order}", title=f"Topic {order}", group=group, order=order
            )
            cls.topics.append(topic)
            cls.lectures.append(
                Lecture.objects.create(
                    topic=topic, title="Part 1", language=cls.ru if order == 7 else cls.en,
                    order=1, duration=600, audio_file=ContentFile(b"mp3", name="part.mp3"),
                )
            )
        for title, lecturer, lecture in [
            ("Gita", cls.sp, cls.lectures[0]),
            ("Bhagavatam", cls.rs, cls.lectures[5]),
            ("Empty", cls.sp, None),
            ("Russian", cls.sp, cls.lectures[6]),
        ]:
            selection = Selection.objects.create(lecturer=lecturer, title=title)
            if lecture:
                SelectionLecture.objects.create(selection=selection, lecture=lecture)

    def setUp(self):
        self.client = APIClient()
        cache.clear()

    def home(self, **params):
        response = self.client.get("/api/v1/home/", params)
        self.assertEqual(response.status_code, 200)
        return response.json()

    def play(self, lecture):
        return self.client.post("/api/v1/plays/", {"lecture": lecture.pk}, format="json")

    def test_new_topics_are_the_five_newest(self):
        titles = [t["title"] for t in self.home()["new"]]
        self.assertEqual(titles, ["Topic 7", "Topic 6", "Topic 5", "Topic 4", "Topic 3"])

    def test_trending_ranks_recent_plays(self):
        self.assertEqual(self.home()["trending_lectures"], [])
        self.assertEqual(self.home()["trending"], [])
        for _ in range(3):
            self.assertEqual(self.play(self.lectures[1]).status_code, 204)
        self.play(self.lectures[0])
        # Long ago: no longer trending.
        LecturePlays.objects.create(
            lecture=self.lectures[2], day=timezone.localdate() - timedelta(days=60), count=50
        )
        home = self.home()
        hits = home["trending_lectures"]
        self.assertEqual([h["topic"]["title"] for h in hits], ["Topic 2", "Topic 1"])
        self.assertEqual(hits[0]["lecture"]["id"], self.lectures[1].pk)
        self.assertEqual(hits[0]["index"], 0)
        # The topics of those lectures, for apps from before; the plays don't
        # multiply the card's own counts.
        trending = home["trending"]
        self.assertEqual([t["title"] for t in trending], ["Topic 2", "Topic 1"])
        self.assertEqual(trending[0]["lectures_count"], 1)
        self.assertEqual(trending[0]["duration"], 600)
        self.assertEqual(LecturePlays.objects.get(lecture=self.lectures[1]).count, 3)

    def test_play_of_a_missing_lecture(self):
        self.assertEqual(self.client.post("/api/v1/plays/", {"lecture": 0}, format="json").status_code, 400)
        self.assertEqual(self.client.get("/api/v1/plays/").status_code, 405)

    def test_selections_with_lectures_name_their_lecturer(self):
        selections = self.home()["selections"]
        self.assertEqual([s["title"] for s in selections], ["Russian", "Bhagavatam", "Gita"])
        self.assertEqual(selections[1]["lecturer"], {"id": self.rs.pk, "name": "Radhanath Swami"})

    def test_lecture_of_the_day_holds_all_day(self):
        pick = self.home()["lecture_of_the_day"]
        self.assertEqual(pick, self.home()["lecture_of_the_day"])
        self.assertEqual(pick["index"], 0)
        self.assertEqual(pick["lecture"]["title"], "Part 1")
        self.assertEqual(pick["topic"]["lectures_count"], 1)
        self.assertEqual(self.home(lang="ru")["lecture_of_the_day"]["topic"]["title"], "Topic 7")

    def test_no_lecture_of_the_day_without_a_long_one(self):
        Lecture.objects.update(duration=60)
        self.assertIsNone(self.home()["lecture_of_the_day"])

    def test_language_narrows_every_row(self):
        home = self.home(lang="en")
        self.assertNotIn("Topic 7", [t["title"] for t in home["new"]])
        self.assertEqual([s["title"] for s in home["selections"]], ["Bhagavatam", "Gita"])
        self.play(self.lectures[6])
        self.assertEqual(self.home(lang="en")["trending"], [])
        self.assertEqual(self.home(lang="en")["trending_lectures"], [])
