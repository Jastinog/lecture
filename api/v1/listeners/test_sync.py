import uuid

from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from apps.listeners import sync
from apps.listeners.models import (
    Bookmark,
    HistoryEntry,
    ListeningDay,
    Listener,
    Progress,
    Setting,
)

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
        self.assertFalse(any(self.sync(other)["changes"].values()))

    def test_deleting_the_listener_deletes_what_it_synced(self):
        self.sync(
            self.phone,
            progress=[progress(5, 100)],
            history=[{"topic_id": 5, "updated_at": 100, "topic": CARD}],
        )
        self.listener.delete()
        self.assertFalse(Progress.objects.exists() or HistoryEntry.objects.exists())

    def test_every_kind_reaches_the_other_device(self):
        mark = str(uuid.uuid4())
        sent = {
            "bookmarks": [
                {
                    "id": mark,
                    "topic_id": 5,
                    "lecture_id": 7,
                    "index": 2,
                    "time": 61.5,
                    "chapter_title": "Lecture 3",
                    "note": "Bhakti ",
                    "created_at": 90,
                    "updated_at": 100,
                }
            ],
            "shelf": [
                {
                    "topic_id": -4,
                    "status": "onHold",
                    "topic": CARD,
                    "added_at": 90,
                    "updated_at": 100,
                }
            ],
            "rates": [{"topic_id": 5, "rate": 1.25, "updated_at": 100}],
            "pins": [
                {
                    "lecturer_id": 1,
                    "name": "Prabhupada",
                    "photo_url": "https://x.org/p.jpg",
                    "updated_at": 100,
                }
            ],
            "languages": [{"lecturer_id": 1, "language": "ru", "updated_at": 100}],
            "settings": [{"name": "default_rate", "value": 1.5, "updated_at": 100}],
        }
        self.sync(self.phone, **sent)
        got = self.sync(self.pad)["changes"]
        for kind, records in sent.items():
            self.assertEqual(got[kind], [{"deleted": False, **records[0]}], kind)

    def test_a_setting_must_be_known_and_sensible(self):
        self.sync(
            self.phone,
            settings=[
                {"name": "default_rate", "value": 9, "updated_at": 1},
                {"name": "theme", "value": "dark", "updated_at": 1},
            ],
        )
        self.assertFalse(Setting.objects.exists())

    def test_a_bookmark_id_is_the_listeners_own(self):
        mark = {
            "id": str(uuid.uuid4()),
            "topic_id": 5,
            "note": "mine",
            "updated_at": 100,
        }
        self.sync(self.phone, bookmarks=[mark])
        _, token = Listener.register(uuid.uuid4())
        other = APIClient()
        other.credentials(HTTP_AUTHORIZATION=f"Token {token}")
        self.sync(other, bookmarks=[{**mark, "note": "theirs", "updated_at": 200}])
        self.assertEqual(Bookmark.objects.get(listener=self.listener).note, "mine")

    def listening(self, seconds, last_heard=100, **fields):
        return {
            "day": "2026-10-15",
            "topic_id": -4,
            "lecture_id": 7,
            "seconds": seconds,
            "last_heard": last_heard,
            "sessions": [],
            "topic": CARD,
            "lecture_title": "Lecture 3",
            **fields,
        }

    def test_listening_time_adds_up_across_devices(self):
        first = self.sync(self.phone, listening=[self.listening(30)])
        # The sender gets the total back too.
        self.assertEqual([r["seconds"] for r in first["changes"]["listening"]], [30])
        got = self.sync(
            self.pad, listening=[self.listening(20, 200), self.listening(5, 150)]
        )
        self.assertEqual(
            got["changes"]["listening"],
            [
                {
                    **self.listening(55, 200),
                    "deleted": False,
                }
            ],
        )
        self.assertEqual(ListeningDay.objects.get().seconds, 55)

    def test_a_reset_starts_the_day_over(self):
        self.sync(self.phone, listening=[self.listening(30)])
        cursor = self.sync(self.pad, listening=[self.listening(0, reset=True)])[
            "cursor"
        ]
        self.assertTrue(ListeningDay.objects.get().deleted)
        # Heard again after the reset, on the same request or a later one.
        got = self.sync(
            self.phone,
            listening=[self.listening(0, reset=True), self.listening(10, 300)],
        )
        self.assertEqual(ListeningDay.objects.get().seconds, 10)
        self.sync(self.pad, since=cursor, listening=[self.listening(4, 400)])
        self.assertEqual(ListeningDay.objects.get().seconds, 14)
        self.assertFalse(got["changes"]["listening"][0]["deleted"])

    def test_a_listener_holds_a_bounded_number_of_records(self):
        with mock.patch.dict(
            sync.KINDS,
            progress=sync.Kind(Progress, sync.ProgressSerializer, "topic_id", 3),
        ):
            self.sync(
                self.phone,
                progress=[progress(n, 100) for n in range(2)]
                + [{"topic_id": 9, "updated_at": 50, "deleted": True}],
            )
            self.sync(
                self.phone, progress=[progress(n, 200 + n) for n in range(10, 14)]
            )
            # The tombstone made room for one, the newest.
            self.assertEqual(
                sorted(Progress.objects.values_list("topic_id", flat=True)), [0, 1, 13]
            )
            # Keys held still update.
            self.sync(self.phone, progress=[progress(0, 300, time=5)])
            self.assertEqual(Progress.objects.get(topic_id=0).time, 5)

    def test_listening_sessions_join_across_devices(self):
        self.sync(
            self.phone, listening=[self.listening(60, 160, sessions=[[100, 160]])]
        )
        self.sync(
            self.pad,
            listening=[
                self.listening(60, 1060, sessions=[[1000, 1060]]),
                self.listening(30, 220, sessions=[[190, 220]]),
            ],
        )
        # 160 and 190 are close enough to be one stretch.
        self.assertEqual(
            ListeningDay.objects.get().sessions, [[100, 220], [1000, 1060]]
        )
        self.sync(self.phone, listening=[self.listening(0, reset=True)])
        self.assertEqual(ListeningDay.objects.get().sessions, [])
