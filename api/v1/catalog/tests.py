from django.core.files.base import ContentFile
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

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
