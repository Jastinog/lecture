from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.files.base import ContentFile
from django.test import TestCase, override_settings

from apps.lecture.management.commands.create_lecturers import create_lecture
from apps.lecture.models import (
    Language,
    Lecture,
    Lecturer,
    Selection,
    SelectionLecture,
    Topic,
    TopicGroup,
)

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
            ("Bhagavad_Gita", "SP_BG_00-01_New_York_1966-02-19_-20_Intro_1_to_Bhagavad_Gita.mp3",
             ("BG Introduction — Intro 1 to Bhagavad Gita", 1966, "New York", "1966-02-19")),
            ("Bhagavad_Gita", "SP_BG_08-28_09-01_New_York_1966-11-21_This_Knowledge_Is_the_King_of--etc.mp3",
             ("BG 8.28–9.1 — This Knowledge Is the King of…", 1966, "New York", "1966-11-21")),
            ("Bhagavad_Gita", "SP_BG_07-01_Los_Angeles_1969-02_Bhagavad-gita_As_It_Is--Not--etc.mp3",
             ("BG 7.1 — Bhagavad-gita As It Is, Not…", 1969, "Los Angeles", "1969-02")),
            ("Srimad_Bhagavatam", "SP_SB_6-01-13=14_Honolulu_1976-05-14_Sex_and_the_Sober.mp3",
             ("SB 6.1.13–14 — Sex and the Sober", 1976, "Honolulu", "1976-05-14")),
            ("Chaitanya_Charitamrita", "SP_CC_A_Intro_San_Francisco_1967-03-18_Introduction.mp3",
             ("CC Adi, Introduction", 1967, "San Francisco", "1967-03-18")),
            ("Arrival_Address", "SP_Arrival_Address_Calcutta_1975-03-20.MP3",
             ("Calcutta, 1975-03-20", 1975, "Calcutta", "1975-03-20")),
            ("Room_Conversation", "SP_Room_Converstion_04_Honolulu_1975-06-15.MP3",
             ("Honolulu, 1975-06-15 (4)", 1975, "Honolulu", "1975-06-15")),
            ("Various", "SP_Lecture_Purport_to_Parama_Karuna_1975-02-28_Atlanta.MP3",
             ("Purport to Parama Karuna", 1975, "Atlanta", "1975-02-28")),
            ("Festivals", "SP_Festivals_Hawaii_1969-03-05_Day_After_Gaura_Purnima-01.mp3",
             ("Day After Gaura Purnima, Part 1", 1969, "Hawaii", "1969-03-05")),
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
        from apps.lecture.management.commands.import_prabhupada import ARCHIVE, renumber

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

        renumber(topic, [Lecture.generate_file_hash(ARCHIVE + p) for p in paths])

        self.assertEqual(list(topic.lectures.values_list("title", flat=True)), paths)
        self.assertEqual(list(topic.lectures.values_list("order", flat=True)), [1, 2, 3])


class DescribeRadhanathFileTests(TestCase):
    """import_radhanath names lectures after the archive's filenames."""

    def test_names(self):
        from apps.lecture.management.commands.import_radhanath import describe

        cases = [
            ("1993-036_Glories_Of_lord_Ramachandra_SB-09_10_04_-_Radhanath_Swami_1993-04-01_IDesireTree.mp3", False,
             ("SB 9.10.4 — Glories Of lord Ramachandra", 1993, "", "1993-04-01")),
            ("1990-079_Comitting_To_This_Great_Mission_SB-08_07_24_Mumbai_-_05-09-90_IDesireTree.mp3", False,
             ("SB 8.7.24 — Comitting To This Great Mission", 1990, "Mumbai", "1990-09-05")),
            ("1992-034_Prayers_By_Advaita_Acharya_CC_AL-02_Mumbai_-_Radhanath_Swami_1992-02-20_IDesireTree.mp3", False,
             ("CC Adi 2 — Prayers By Advaita Acharya", 1992, "Mumbai", "1992-02-20")),
            ("2015-10-18_SB_04-30-08_-_Importance_of_Co-operation_among_Devotees_-_Radhanath_Swami_GEV_Wada.mp3", False,
             ("SB 4.30.8 — Importance of Co-operation among Devotees", 2015, "GEV Wada", "2015-10-18")),
            ("2010-01-09_DADAR_Ratha_Yatra_Lecture_-_Radhanath_Swami_ISKCON_Chowpatty.mp3", False,
             ("DADAR Ratha Yatra", 2010, "ISKCON Chowpatty", "2010-01-09")),
            ("Mayapur_Yatra_2003_15_-_Childhood_Pastimes_of_Nimai-3_Day-04_Radhanath_Swami.mp3", True,
             ("Childhood Pastimes of Nimai-3 Day 4", 2003, "", "")),
            ("1997_Day-15_Part-01_Vishnupriya_Devi_-_Radhanath_Swami_Mayapur.mp3", True,
             ("Day 15, Part 1 — Vishnupriya Devi", 1997, "Mayapur", "")),
            ("1996-016_Prabhupada_Premanjali_MT_-_Lecture_Belgaum_-_Radhanath_Swami_1996-01-10_IDesireTree.mp3", False,
             ("Prabhupada Premanjali (with Marathi translation)", 1996, "Belgaum", "1996-01-10")),
            ("1996-105_SB_-_Radhanath_Swami_1996-07-25_IDesireTree.mp3", False,
             ("Lecture, 1996-07-25", 1996, "", "1996-07-25")),
            ("1999_01_Vrindavan_Radhanath_Swami_1999-11-06.mp3", False,
             ("Vrindavan, 1999-11-06 (1)", 1999, "Vrindavan", "1999-11-06")),
        ]
        for filename, in_series, expected in cases:
            with self.subTest(filename):
                self.assertEqual(describe(filename, in_series), expected)

    def test_other_speakers_skipped(self):
        from apps.lecture.management.commands.import_radhanath import ROOT, YATRAS, is_his

        yatra = ROOT + YATRAS + "2009_Mayapur_Yatra/"
        self.assertTrue(is_his(yatra + "2009-10-23_-_Yadi_Gaur_Na_Hoite_-_Radhanath_Swami_ISKCON_Mayapur.mp3"))
        self.assertTrue(is_his(yatra + "Mayapur_Yatra_1997_16_Pastimes_at_Ramkeli.mp3"))
        self.assertFalse(is_his(yatra + "2009-10-22_-_Ohe_Vaishnava_Thakur_-_Murari_Hari_Prabhu_ISKCON_Mayapur.mp3"))
        self.assertFalse(is_his(yatra + "2009-10-17_Invite_EU_-_Jayapataka_Sw.mp3"))


class DescribeNiranjanaFileTests(TestCase):
    """import_niranjana names lectures after the archive's filenames."""

    def test_names(self):
        from apps.lecture.management.commands.import_niranjana import describe

        cases = [
            ("NRS_SB_01-02-19_Russian_Translation_-_Becoming_Free_from_the_three_Modes_of_Nature_-_2014-06-15_Ukraine.mp3",
             ("SB 1.2.19 — Becoming Free from the three Modes of Nature", 2014, "Ukraine", "2014-06-15")),
            ("NRS_CC_Adi_Lila_02-90-92_Russian_Translation_-_2013-05-04_Moscow.mp3",
             ("CC Adi 2.90–92", 2013, "Moscow", "2013-05-04")),
            ("NRS_BG_10-04-05_ Hungarian_Translation_-_2014-04-06_Budapest.mp3",
             ("BG 10.4–5 (with Hungarian translation)", 2014, "Budapest", "2014-04-06")),
            ("NRS_Various_Chinese_Translation_-_Morning_Talk-Controlling_the_Mind_-_2015-12-16_Taipei.mp3",
             ("Morning Talk — Controlling the Mind (with Chinese translation)", 2015, "Taipei", "2015-12-16")),
            ("NRS_SB_04-16-23_-_Real_pleasure_means_Sankirtan_-_89-05-27_US.mp3",
             ("SB 4.16.23 — Real pleasure means Sankirtan", 1989, "USA", "1989-05-27")),
            ("NRS_Various_-_Lecture-13_-_1993-07-28_Russian-23_Kiev.mp3",
             ("Lecture 13, Kiev, 1993-07-28", 1993, "Kiev", "1993-07-28")),
            ("NRS_SB_-_95-10-03.mp3", ("Srimad-Bhagavatam, 1995-10-03", 1995, "", "1995-10-03")),
            ("NRS_SB_04-02-24_-_1998-11-20_Part-02.mp3", ("SB 4.2.24 (part 2)", 1998, "", "1998-11-20")),
            ("NRS_1999_59_10May_SB_4-30-31_Xarikov.mp3", ("SB 4.30.31", 1999, "Kharkov", "1999-05-10")),
            ("NRS_1998_191_engru_1-20-46.mp3", ("Lecture 191, 1998", 1998, "", "")),
        ]
        for filename, expected in cases:
            with self.subTest(filename):
                self.assertEqual(describe(filename), expected)

    def test_topics(self):
        from apps.lecture.management.commands.import_niranjana import ROOT, is_his, topic_for

        self.assertEqual(topic_for(ROOT + "2014/NRS_SB_03-16-19_Russian_Translation_-_2014-04-26_Minsk.mp3")[0], "ru-2014")
        self.assertEqual(topic_for(ROOT + "2020/NRS_Various_Russian_-_Invoking_Mercy_-_2020-07-20_Mayapur.mp3")[0], "ru-2020")
        self.assertEqual(topic_for(ROOT + "2018/NRS_Various_-_Talk_given_to_Russian_Devotees_-_2018-12-28_New_York.mp3")[0], "en-2018")
        self.assertEqual(topic_for(ROOT + "1993/NRS_BG_03-08_-_1993-08-03_Russian_25.mp3")[0], "en-1993")
        self.assertEqual(topic_for(ROOT + "1990/NRS_Various_-_Kaunas_lecture_-_1990-oct.mp3")[0], "en-1986-1991")
        self.assertFalse(is_his(ROOT + "2018/NRS_Bhajans_-_Hare_Krishna_Kirtan_-_2018-06-06_Boston.mp3"))
        self.assertFalse(is_his(ROOT + "2016/NRS_Gauranga_Festival_-_Evening_Kirtan_01_-_2016-06-09.mp3"))
        self.assertTrue(is_his(ROOT + "2011/NRS_BG_04-14_-_Sunday_Lecture_and_Kirtan_-_2011-03-13.mp3"))


class DescribePrabhupadaMusicFileTests(TestCase):
    """Titles and albums of Srila Prabhupada's bhajans, kirtans and japa."""

    def test_names(self):
        from apps.lecture.management.commands.import_prabhupada_music import describe

        cases = [
            ("SP_Bhajans_02_-_Gaura_Pahu_-_Gaura_Pahu_Na_Bhajiya_Goinu.mp3", "Gaura Pahu — Gaura Pahu Na Bhajiya Goinu"),
            ("SP_Bhajans_04_-_Jiv_Jago_'Soft'_Arunodaya-kirtana_II.mp3", "Jiv Jago “Soft” Arunodaya-kirtana II"),
            ("SP_Bhajans_04_-_Vande_'ham_-_Hare_Krsna_Kirtana.mp3", "Vande 'ham — Hare Krsna Kirtana"),
            ("SP_Bhajans_02_-_Namasye_PurusamTvadyam_-_Prayers_by_Queen_Kunti.mp3",
             "Namasye Purusam Tvadyam — Prayers by Queen Kunti"),
            ("SP_Bhajans_07_-_Purport_on_Hare_Krishna_Mantra_[Hindi].mp3", "Purport on Hare Krishna Mantra (Hindi)"),
            ("SP_01_Group_Japa.mp3", "Group Japa"),
        ]
        for filename, expected in cases:
            with self.subTest(filename):
                self.assertEqual(describe(filename), expected)

    def test_albums(self):
        from apps.lecture.management.commands.import_prabhupada_music import BHAJANS, album_title

        self.assertEqual(album_title(BHAJANS + "Vol-01/01_-_Krsna_Meditations/"), "Krsna Meditations")
        self.assertEqual(
            album_title(BHAJANS + "Vol-02/01_-_The_Vintage_Series_-_Bhajahu%20Re%20Mana/"),
            "The Vintage Series — Bhajahu Re Mana",
        )
        self.assertEqual(album_title(BHAJANS + "Vol-03/04_-_The_Vintage_Series/"), "The Vintage Series, Part 4")


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class SelectionAdminTests(TestCase):
    """Selections are built in the admin: nested ones and lectures go in as
    rows on the selection's page."""

    @classmethod
    def setUpTestData(cls):
        ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        group = TopicGroup.objects.create(code="lectures", name="Лекции")
        cls.lecturer = Lecturer.objects.create(code="sp", name="Prabhupada", order=1)
        topic = Topic.objects.create(lecturer=cls.lecturer, code="gita", title="Gita", group=group, order=1)
        cls.lecture = Lecture.objects.create(
            topic=topic, title="BG 2.13", language=ru, order=1,
            audio_file=ContentFile(b"mp3", name="part.mp3"),
        )
        cls.gita = Selection.objects.create(lecturer=cls.lecturer, title="Bhagavad-gita")
        cls.chapter = Selection.objects.create(parent=cls.gita, title="Chapter 2")
        SelectionLecture.objects.create(selection=cls.chapter, lecture=cls.lecture)
        cls.admin = get_user_model().objects.create_superuser("admin@example.com", "pw")

    def setUp(self):
        self.client.force_login(self.admin)

    def test_nested_selection_takes_its_parents_lecturer(self):
        other = Lecturer.objects.create(code="rs", name="Radhanath Swami", order=2)
        verse = Selection.objects.create(lecturer=other, parent=self.gita, title="Chapter 3")
        self.assertEqual(verse.lecturer, self.lecturer)

    def test_only_the_kind_it_holds_can_be_added(self):
        def inlines(selection):
            response = self.client.get(f"/admin/lecture/selection/{selection.id}/change/")
            return {formset.formset.prefix for formset in response.context["inline_admin_formsets"]}

        self.assertEqual(inlines(self.gita), {"children"})
        self.assertEqual(inlines(self.chapter), {"entries"})
        empty = Selection.objects.create(lecturer=self.lecturer, title="Srimad-Bhagavatam")
        self.assertEqual(inlines(empty), {"children", "entries"})

    def test_pages_open(self):
        for url in (
            "/admin/lecture/selection/",
            f"/admin/lecture/selection/{self.gita.id}/change/",
            f"/admin/lecture/selection/{self.chapter.id}/change/",
        ):
            self.assertEqual(self.client.get(url).status_code, 200, url)

    def test_new_rows_of_both_kinds_refused(self):
        empty = Selection.objects.create(lecturer=self.lecturer, title="Srimad-Bhagavatam")
        form = {
            "parent": "", "title": "Srimad-Bhagavatam", "description": "", "order": 0,
            "children-TOTAL_FORMS": 1, "children-INITIAL_FORMS": 0,
            "children-0-parent": empty.id, "children-0-title": "Canto 1", "children-0-order": 1,
            "entries-TOTAL_FORMS": 1, "entries-INITIAL_FORMS": 0,
            "entries-0-selection": empty.id, "entries-0-lecture": self.lecture.id,
            "entries-0-order": 1,
        }
        response = self.client.post(f"/admin/lecture/selection/{empty.id}/change/", form)
        self.assertContains(response, "holds lectures or selections, not both")
        self.assertFalse(empty.children.exists() or empty.entries.exists())

    def test_nested_selection_row_takes_the_lecturer(self):
        form = {
            "parent": "", "title": "Bhagavad-gita",
            "description": "", "order": 0,
            "children-TOTAL_FORMS": 2, "children-INITIAL_FORMS": 1,
            "children-0-id": self.chapter.id, "children-0-parent": self.gita.id,
            "children-0-title": "Chapter 2", "children-0-order": 2,
            "children-1-parent": self.gita.id, "children-1-title": "Chapter 3",
            "children-1-order": 3,
        }
        response = self.client.post(f"/admin/lecture/selection/{self.gita.id}/change/", form)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(Selection.objects.get(title="Chapter 3").lecturer, self.lecturer)


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class BuildSelectionTests(TestCase):
    """`build_selection gita` files a lecturer's Gita lectures by chapter,
    from every topic and language, and re-runs refill it in place."""

    @classmethod
    def setUpTestData(cls):
        en = Language.objects.create(code="en", name="English", native_name="English")
        ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        group = TopicGroup.objects.create(code="lectures", name="Lectures")
        cls.sp = Lecturer.objects.create(code="sp", name="Prabhupada", order=1)
        en_gita = Topic.objects.create(lecturer=cls.sp, code="en-bg", title="BG", group=group, order=1)
        ru_gita = Topic.objects.create(lecturer=cls.sp, code="ru-bg", title="БГ", group=group, order=2)

        def lecture(topic, title, language, year, order):
            return Lecture.objects.create(
                topic=topic, title=title, language=language, year=year, order=order,
                audio_file=ContentFile(b"mp3", name="part.mp3"),
            )

        cls.later = lecture(en_gita, "BG 2.13 — Later", en, 1974, 1)
        cls.earlier = lecture(ru_gita, "БГ 2.13 — Раньше", ru, 1966, 1)
        cls.verse_1 = lecture(en_gita, "BG 2.1–10", en, 1975, 2)
        cls.span = lecture(en_gita, "BG 8.28–9.1 — Across", en, 1973, 3)
        cls.intro = lecture(ru_gita, "БГ, введение 1", ru, 1966, 2)
        lecture(en_gita, "SB 1.1.1", en, 1972, 4)

    def build(self):
        call_command("build_selection", "gita", lecturer="sp", stdout=StringIO())
        return Selection.objects.get(lecturer=self.sp, parent=None, title="Bhagavad-gita")

    def lectures(self, gita, title):
        return list(gita.children.get(title=title).entries.values_list("lecture_id", flat=True))

    def test_files_lectures_by_chapter_and_verse(self):
        gita = self.build()
        self.assertEqual(
            list(gita.children.values_list("title", flat=True)),
            ["Introduction", "Chapter 2", "Chapter 8"],
        )
        self.assertEqual(self.lectures(gita, "Introduction"), [self.intro.id])
        # Verse first, then year, whatever the language.
        self.assertEqual(
            self.lectures(gita, "Chapter 2"), [self.verse_1.id, self.earlier.id, self.later.id]
        )
        # A lecture running into the next chapter goes where it starts.
        self.assertEqual(self.lectures(gita, "Chapter 8"), [self.span.id])

    def test_rerun_refills_in_place(self):
        gita = self.build()
        chapter = gita.children.get(title="Chapter 2")
        chapter.description = "Edited"
        chapter.save()
        self.later.delete()
        again = self.build()
        self.assertEqual(again.pk, gita.pk)
        self.assertEqual(Selection.objects.filter(lecturer=self.sp).count(), 4)
        chapter.refresh_from_db()
        self.assertEqual(chapter.description, "Edited")
        self.assertEqual(self.lectures(again, "Chapter 2"), [self.verse_1.id, self.earlier.id])

    def test_chapter_left_without_lectures_goes(self):
        self.build()
        self.span.title = "BG 2.20 — Retitled"
        self.span.save()
        gita = self.build()
        self.assertEqual(
            list(gita.children.values_list("title", flat=True)), ["Introduction", "Chapter 2"]
        )
        self.assertIn(self.span.id, self.lectures(gita, "Chapter 2"))


@override_settings(STORAGES=LOCAL_STORAGE, MEDIA_URL="/media/")
class MediaFileTests(TestCase):
    """Files in storage go with their rows."""

    @classmethod
    def setUpTestData(cls):
        cls.ru = Language.objects.create(code="ru", name="Russian", native_name="Русский")
        group = TopicGroup.objects.create(code="lectures", name="Лекции")
        lecturer = Lecturer.objects.create(code="sp", name="Prabhupada", order=1)
        cls.topic = Topic.objects.create(lecturer=lecturer, code="gita", title="Gita", group=group, order=1)

    def lecture(self, order=1):
        return Lecture.objects.create(
            topic=self.topic, title="BG 2.13", language=self.ru, order=order,
            audio_file=ContentFile(b"mp3", name="part.mp3"),
        )

    def test_deleting_a_lecture_or_its_topic_deletes_the_audio(self):
        lecture = self.lecture()
        storage, name = lecture.audio_file.storage, lecture.audio_file.name
        with self.captureOnCommitCallbacks(execute=True):
            lecture.delete()
        self.assertFalse(storage.exists(name))

        lecture = self.lecture()
        name = lecture.audio_file.name
        with self.captureOnCommitCallbacks(execute=True):
            self.topic.delete()
        self.assertFalse(storage.exists(name))

    def test_imported_upload_removed_when_the_lecture_fails(self):
        self.lecture(order=1)
        field = Lecture._meta.get_field("audio_file")
        name = field.storage.save("lecturers_dev/x.mp3", ContentFile(b"mp3"))
        with self.assertRaises(Exception):
            # Order 1 is taken.
            create_lecture(self.topic, {"title": "Dup"}, self.ru, 1, "hash", {"audio_file": name})
        self.assertFalse(field.storage.exists(name))
