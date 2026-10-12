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
