import uuid

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from apps.listeners.models import HistoryEntry, Listener, Progress

CARD = {"id": -4, "title": "Gita 2", "lecturer": {"id": 1, "name": "Prabhupada"}}


def progress(topic_id, updated_at, **fields):
    return {
        "topic_id": topic_id,
        "updated_at": updated_at,
        "index": 1,
        "time": 30.5,
        "fraction": 0.25,
        "lecture_id": 7,
        **fields,
    }


class SyncAPITests(TestCase):
    def setUp(self):
        cache.clear()
        self.phone, self.pad = APIClient(), APIClient()
        self.listener, token = Listener.register(uuid.uuid4())
        for device in (self.phone, self.pad):
            device.credentials(HTTP_AUTHORIZATION=f"Token {token}")

    def sync(self, device, since=0, **changes):
        response = device.post(
            "/api/v1/sync/", {"since": since, "changes": changes}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def test_needs_a_listener(self):
        self.assertEqual(
            APIClient().post("/api/v1/sync/", {}, format="json").status_code, 401
        )

    def test_a_change_reaches_the_other_device(self):
        sent = self.sync(self.phone, progress=[progress(5, 100)])
        # Not echoed back to the device that sent it.
        self.assertEqual(sent["changes"]["progress"], [])
        got = self.sync(self.pad)
        self.assertEqual(
            got["changes"]["progress"], [{**progress(5, 100), "deleted": False}]
        )
        self.assertEqual(got["cursor"], sent["cursor"])
        # Nothing new since.
        self.assertEqual(
            self.sync(self.pad, since=got["cursor"])["changes"]["progress"], []
        )

    def test_the_newest_change_wins(self):
        self.sync(self.phone, progress=[progress(5, 200, time=60)])
        self.sync(self.pad, progress=[progress(5, 100, time=10)])
        self.assertEqual(Progress.objects.get().time, 60)
        self.sync(self.pad, progress=[progress(5, 300, time=90)])
        self.assertEqual(Progress.objects.get().time, 90)

    def test_an_older_change_gets_the_newer_one_back(self):
        cursor = self.sync(self.phone, progress=[progress(5, 200, time=60)])["cursor"]
        got = self.sync(self.pad, since=0, progress=[progress(5, 100, time=10)])
        self.assertEqual([r["time"] for r in got["changes"]["progress"]], [60])
        self.assertEqual(got["cursor"], cursor)

    def test_a_removal_reaches_the_other_device(self):
        cursor = self.sync(self.pad, progress=[progress(5, 100)])["cursor"]
        self.sync(
            self.phone, progress=[{"topic_id": 5, "updated_at": 150, "deleted": True}]
        )
        got = self.sync(self.pad, since=cursor)["changes"]["progress"]
        self.assertEqual([(r["topic_id"], r["deleted"]) for r in got], [(5, True)])

    def test_history_keeps_the_card_of_a_selection(self):
        self.sync(
            self.phone, history=[{"topic_id": -4, "updated_at": 100, "topic": CARD}]
        )
        got = self.sync(self.pad)["changes"]["history"]
        self.assertEqual(
            got, [{"topic_id": -4, "updated_at": 100, "deleted": False, "topic": CARD}]
        )
        self.assertEqual(HistoryEntry.objects.get().topic, CARD)

    def test_a_bad_record_doesnt_stop_the_rest(self):
        self.sync(
            self.phone,
            progress=[progress(5, 100, fraction=3), progress(6, 100)],
            history=[{"topic_id": 1, "updated_at": 1, "topic": "x" * 10}],
        )
        self.assertEqual(list(Progress.objects.values_list("topic_id", flat=True)), [6])
        self.assertFalse(HistoryEntry.objects.exists())

    def test_the_newest_of_a_topic_sent_twice_wins(self):
        self.sync(
            self.phone, progress=[progress(5, 200, time=60), progress(5, 100, time=10)]
        )
        self.assertEqual(Progress.objects.get().time, 60)

    def test_a_cursor_ahead_of_the_server_gets_everything(self):
        self.sync(self.phone, progress=[progress(5, 100)])
        self.assertEqual(len(self.sync(self.pad, since=999)["changes"]["progress"]), 1)

    def test_listeners_dont_see_each_other(self):
        self.sync(self.phone, progress=[progress(5, 100)])
        _, token = Listener.register(uuid.uuid4())
        other = APIClient()
        other.credentials(HTTP_AUTHORIZATION=f"Token {token}")
        self.assertEqual(self.sync(other)["changes"], {"progress": [], "history": []})

    def test_deleting_the_listener_deletes_what_it_synced(self):
        self.sync(
            self.phone,
            progress=[progress(5, 100)],
            history=[{"topic_id": 5, "updated_at": 100, "topic": CARD}],
        )
        self.listener.delete()
        self.assertFalse(Progress.objects.exists() or HistoryEntry.objects.exists())
