from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.test import TestCase, override_settings

from apps.lecture.models import Language, Lecture, Lecturer, Topic, TopicGroup

LOCAL_STORAGE = {
    "default": {"BACKEND": "django.core.files.storage.InMemoryStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class SetLanguageActionTests(TestCase):
    """The admin's "Set language → …" actions relabel lectures in bulk and keep
    their topics' languages in step."""

    @classmethod
    def setUpTestData(cls):
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        cls.en = Language.objects.create(code="en", name="English", native_name="English")
        Language.objects.create(code="xx", name="Old", native_name="Old", is_active=False)
        group = TopicGroup.objects.create(code="lectures", name="Лекции")
        lecturer = Lecturer.objects.create(code="sp", name="Prabhupada", order=1)
        cls.gita = Topic.objects.create(
            lecturer=lecturer, code="gita", title="Gita", group=group, order=1
        )
        cls.walks = Topic.objects.create(
            lecturer=lecturer, code="walks", title="Walks", group=group, order=2
        )
        cls.lectures = [
            Lecture.objects.create(
                topic=topic, title=f"{topic.code} {order}", language=cls.ru, order=order,
                audio_file=ContentFile(b"mp3", name="part.mp3"),
            )
            for topic in (cls.gita, cls.walks)
            for order in (1, 2)
        ]
        cls.admin = get_user_model().objects.create_superuser("admin@example.com", "pw")

    def setUp(self):
        self.client.force_login(self.admin)

    def run_action(self, model, action, objects):
        return self.client.post(
            f"/admin/lecture/{model}/",
            {"action": action, "_selected_action": [o.pk for o in objects]},
            follow=True,
        )

    def codes(self, topic):
        return sorted(topic.languages.values_list("code", flat=True))

    def test_actions_offered_for_active_languages(self):
        for model in ("lecture", "topic"):
            choices = self.client.get(f"/admin/lecture/{model}/").context[
                "action_form"
            ].fields["action"].choices
            names = [name for name, _ in choices]
            self.assertIn("set_language_en", names)
            self.assertIn("set_language_ru", names)
            self.assertNotIn("set_language_xx", names)

    def test_hidden_without_change_permission(self):
        from django.contrib.auth.models import Permission

        staff = get_user_model().objects.create_user("staff@example.com", "pw")
        staff.is_staff = staff.is_active = True
        staff.save()
        staff.user_permissions.add(
            *Permission.objects.filter(codename__in=["view_lecture", "view_topic", "change_topic"])
        )
        self.client.force_login(staff)
        for model in ("lecture", "topic"):
            response = self.client.get(f"/admin/lecture/{model}/")
            self.assertEqual(response.status_code, 200)
            self.assertNotContains(response, "set_language_")
        response = self.run_action("lecture", "set_language_en", self.lectures[:1])
        self.lectures[0].refresh_from_db()
        self.assertEqual(self.lectures[0].language, self.ru)

    def test_on_lectures(self):
        first = self.lectures[0]
        response = self.run_action("lecture", "set_language_en", [first])
        self.assertContains(response, "1 lecture(s) set to English")
        first.refresh_from_db()
        self.assertEqual(first.language, self.en)
        self.assertEqual(self.codes(self.gita), ["en", "ru"])
        self.assertEqual(self.codes(self.walks), ["ru"])

    def test_on_topics_relabels_all_their_lectures(self):
        response = self.run_action("topic", "set_language_en", [self.gita])
        self.assertContains(response, "2 lecture(s) set to English")
        self.assertEqual(
            set(self.gita.lectures.values_list("language__code", flat=True)), {"en"}
        )
        self.assertEqual(self.codes(self.gita), ["en"])
        self.assertEqual(self.codes(self.walks), ["ru"])

    def test_counts_only_lectures_that_changed(self):
        response = self.run_action("lecture", "set_language_ru", self.lectures)
        self.assertContains(response, "0 lecture(s) set to Русский")


class DescribeArchiveFileTests(TestCase):
    """import_prabhupada names lectures after the archive's filenames."""

    def test_names(self):
        from apps.lecture.management.commands.import_prabhupada import describe

        cases = [
            ("Bhagavad_Gita", "SP_BG_06-11-19_New_York_1966-09-07_Yoga_System--Chant_the_Holy--etc.mp3",
             ("BG 6.11–19 — Yoga System, Chant the Holy…", 1966, "New York", "1966-09-07")),
            ("Srimad_Bhagavatam", "SP_SB_6-01-09_Los_Angeles_1975-06-22.MP3",
             ("SB 6.1.9 — Los Angeles, 1975-06-22", 1975, "Los Angeles", "1975-06-22")),
            ("Chaitanya_Charitamrita", "SP_CC_M_20-119_New_York_1966-11-24_Are_We_Krishna's_Competitors.mp3",
             ("CC Madhya 20.119 — Are We Krishna's Competitors", 1966, "New York", "1966-11-24")),
            ("Isopanishad", "SP_Isopanisad_00_Los_Angeles_1970-05-02_Matter_Has_No_Power.mp3",
             ("Invocation — Matter Has No Power", 1970, "Los Angeles", "1970-05-02")),
            ("Nectar_Of_Devotion", "SP_NOD_Pg-12_Bombay_1972-12-27_-_Real_Liberation_Is_Bhakti_Yoga.mp3",
             ("NOD p. 12 — Real Liberation Is Bhakti Yoga", 1972, "Bombay", "1972-12-27")),
            ("Morning_Walk", "SP_Morning_Walk_-_Rome_1974-05-27.mp3",
             ("Rome, 1974-05-27", 1974, "Rome", "1974-05-27")),
            ("Departure_Address", "SP_Departure_Address_1974-07-25_New_York.mp3",
             ("New York, 1974-07-25", 1974, "New York", "1974-07-25")),
            ("Krishna_Book", "SP_Krsna_Book_Dict_08_-_Vision_of_the_Universal_Form.mp3",
             ("8 — Vision of the Universal Form", None, "", "")),
            ("Bhagavad_Gita_Recitation", "SP_BG_Recitation_Chapter-04_-_Sanskrit.mp3",
             ("Chapter 4", None, "", "")),
        ]
        for folder, filename, expected in cases:
            with self.subTest(filename):
                self.assertEqual(describe(folder, filename), expected)


class DescribeRussianArchiveFileTests(TestCase):
    """import_prabhupada_ru sorts and names recordings after the cloud's filenames."""

    def test_names(self):
        from apps.lecture.management.commands.import_prabhupada_ru import describe, topic_of

        cases = [
            ("74-11-21 Bom SB 3.25.21 — Кто такой садху", "ru-srimad-bhagavatam",
             ("ШБ 3.25.21 — Кто такой садху", 1974, "Бомбей", "1974-11-21")),
            ("66-07-18 Бг 4.3-6 (NY)", "ru-bhagavad-gita",
             ("БГ 4.3–6", 1966, "Нью-Йорк", "1966-07-18")),
            ("66-11-17 CC 2.20.121-124 (NY)", "ru-chaitanya-charitamrita",
             ("ЧЧ Мадхья 20.121–124", 1966, "Нью-Йорк", "1966-11-17")),
            ("70-04-29 LA Iso1-3 — Как кошки и собаки", "ru-sri-ishopanishad",
             ("Мантры 1–3 — Как кошки и собаки", 1970, "Лос-Анджелес", "1970-04-29")),
            ("75-04-05 Mayapur Mwalk — Цивилизация кошек и собак", "ru-morning-walks",
             ("Цивилизация кошек и собак", 1975, "Майяпур", "1975-04-05")),
            ("68-03-23 SF Mwalk", "ru-morning-walks",
             ("Сан-Франциско, 1968-03-23", 1968, "Сан-Франциско", "1968-03-23")),
            ("67-04-05 SF Беседа с Хаягривой 1 (Caitanya Play)", "ru-conversations",
             ("Беседа с Хаягривой 1 (Caitanya Play)", 1967, "Сан-Франциско", "1967-04-05")),
            ("75-10-29 #4 Nairobi Беседа — Мы дети Господа", "ru-conversations",
             ("Мы дети Господа", 1975, "Найроби", "1975-10-29")),
            ("67-xx-xx About Kurukshetra", "ru-lectures",
             ("About Kurukshetra", 1967, "", "1967")),
        ]
        for name, topic, expected in cases:
            with self.subTest(name):
                self.assertEqual(topic_of(name), topic)
                self.assertEqual(describe(name), expected)


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class RenumberTests(TestCase):
    """A lecture a re-run adds late takes its archive place, not the last one."""

    def test_late_lecture_moves_into_place(self):
        from apps.lecture.management.commands.import_prabhupada import ARCHIVE, Command

        en = Language.objects.create(code="en", name="English", native_name="English")
        group = TopicGroup.objects.create(code="lectures", name="Лекции")
        lecturer = Lecturer.objects.create(code="sp", name="Prabhupada", order=1)
        topic = Topic.objects.create(lecturer=lecturer, code="gita", title="Gita", group=group, order=1)
        paths = ["/a.mp3", "/b.mp3", "/c.mp3"]
        # b came in last, after a failed first run.
        for order, path in enumerate(["/a.mp3", "/c.mp3", "/b.mp3"], 1):
            Lecture.objects.create(
                topic=topic, title=path, language=en, order=order,
                audio_file=ContentFile(b"mp3", name="part.mp3"),
                file_hash=Lecture.generate_file_hash(ARCHIVE + path),
            )

        Command.renumber(topic, paths)

        self.assertEqual(list(topic.lectures.values_list("title", flat=True)), paths)
        self.assertEqual(list(topic.lectures.values_list("order", flat=True)), [1, 2, 3])
