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
        for topic in (cls.gita, cls.walk, cls.journey):
            topic.languages.add(cls.ru)

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
        self.assertEqual(data["languages"], [{"code": "ru", "name": "Русский"}])
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
