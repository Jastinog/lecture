import uuid
from datetime import timedelta

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.lecture.models import (
    Language,
    Lecture,
    Lecturer,
    Topic,
    TopicGroup,
    TopicPlays,
)
from apps.listeners.models import Listener, ListenerPlay, hash_token


class ListenerAPITests(TestCase):
    @classmethod
    def setUpTestData(cls):
        ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        lecturer = Lecturer.objects.create(
            code="sp", name="Prabhupada", level=1, order=1
        )
        group = TopicGroup.objects.create(code="lectures", name="Lectures", order=1)
        cls.topic = Topic.objects.create(
            lecturer=lecturer, group=group, code="gita", title="Gita", order=1
        )
        cls.lectures = [
            Lecture.objects.create(
                topic=cls.topic, title=f"Part {n}", language=ru, order=n
            )
            for n in (1, 2)
        ]

    def setUp(self):
        self.client = APIClient()
        cache.clear()

    def register(self, pk=None, **details):
        return self.client.post(
            "/api/v1/listeners/",
            {"id": str(pk or uuid.uuid4()), **details},
            format="json",
        )

    def play(self, lecture, token=None):
        headers = {"HTTP_AUTHORIZATION": f"Token {token}"} if token else {}
        return self.client.post(
            "/api/v1/plays/", {"lecture": lecture.pk}, format="json", **headers
        )

    def plays(self):
        return TopicPlays.objects.get(topic=self.topic).count

    def test_registration_issues_a_token_and_keeps_only_its_hash(self):
        pk = uuid.uuid4()
        response = self.register(pk, platform="ios", app_version="1.0 (7)")
        self.assertEqual(response.status_code, 201)
        token = response.json()["token"]
        listener = Listener.objects.get(pk=pk)
        self.assertEqual(listener.token_hash, hash_token(token))
        self.assertNotEqual(listener.token_hash, token)
        self.assertEqual((listener.platform, listener.app_version), ("ios", "1.0 (7)"))

    def test_a_taken_id_gets_no_new_token(self):
        pk = uuid.uuid4()
        first = self.register(pk).json()["token"]
        response = self.register(pk)
        self.assertEqual(response.status_code, 409)
        self.assertNotIn("token", response.json())
        self.assertEqual(Listener.objects.get(pk=pk).token_hash, hash_token(first))

    def test_registration_wants_a_uuid(self):
        self.assertEqual(
            self.client.post(
                "/api/v1/listeners/", {"id": "me"}, format="json"
            ).status_code,
            400,
        )
        self.assertEqual(
            self.client.post("/api/v1/listeners/", {}, format="json").status_code, 400
        )

    def test_registrations_are_throttled_per_address(self):
        for _ in range(10):
            self.assertEqual(self.register().status_code, 201)
        self.assertEqual(self.register().status_code, 429)

    def test_a_listener_counts_once_per_lecture_and_day(self):
        token = self.register().json()["token"]
        for _ in range(3):
            self.assertEqual(self.play(self.lectures[0], token).status_code, 204)
        self.assertEqual(self.plays(), 1)
        self.play(self.lectures[1], token)
        self.assertEqual(self.plays(), 2)
        # Someone else's play counts too.
        self.play(self.lectures[0], self.register().json()["token"])
        self.assertEqual(self.plays(), 3)
        self.assertEqual(ListenerPlay.objects.count(), 3)

    def test_a_play_without_a_token_counts_every_time(self):
        self.play(self.lectures[0])
        self.play(self.lectures[0])
        self.assertEqual(self.plays(), 2)
        self.assertFalse(ListenerPlay.objects.exists())

    def test_an_unknown_token_is_refused(self):
        response = self.play(self.lectures[0], "nope")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response["WWW-Authenticate"], "Token")
        self.assertFalse(TopicPlays.objects.exists())

    def test_a_bad_token_doesnt_break_the_catalog(self):
        response = self.client.get("/api/v1/groups/", HTTP_AUTHORIZATION="Token nope")
        self.assertEqual(response.status_code, 200)

    def test_last_seen_is_written_at_most_hourly(self):
        response = self.register()
        token = response.json()["token"]
        listener = Listener.objects.get()
        recently = timezone.now() - timedelta(minutes=10)
        Listener.objects.update(last_seen=recently)
        self.play(self.lectures[0], token)
        listener.refresh_from_db()
        self.assertEqual(listener.last_seen, recently)
        Listener.objects.update(last_seen=timezone.now() - timedelta(hours=2))
        self.play(self.lectures[0], token)
        listener.refresh_from_db()
        self.assertGreater(listener.last_seen, recently)

    def test_deleting_a_listener_keeps_the_counts(self):
        token = self.register().json()["token"]
        self.play(self.lectures[0], token)
        Listener.objects.all().delete()
        self.assertFalse(ListenerPlay.objects.exists())
        self.assertEqual(self.plays(), 1)
