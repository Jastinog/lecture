from django.core.management.base import BaseCommand
from apps.lecture.models import Language, TopicGroup


class Command(BaseCommand):
    help = "Initialize languages and topic groups"

    def handle(self, *args, **options):
        # Create languages
        languages = [
            {"code": "ru", "name": "Russian", "native_name": "Русский"},
            {"code": "en", "name": "English", "native_name": "English"},
            {"code": "uk", "name": "Ukrainian", "native_name": "Українська"},
        ]

        for lang_data in languages:
            language, created = Language.objects.get_or_create(
                code=lang_data["code"],
                defaults={
                    "name": lang_data["name"],
                    "native_name": lang_data["native_name"],
                    "is_active": True,
                },
            )
            if created:
                self.stdout.write(f"Created language: {language.native_name}")
            else:
                self.stdout.write(f"Language already exists: {language.native_name}")

        # Create topic groups
        groups = [
            {"name": "Киртаны", "code": "kirtans", "order": 1},
            {"name": "Лекции", "code": "lectures", "order": 2},
            {"name": "Прогулки", "code": "walks", "order": 3},
            {"name": "Джапа", "code": "japa", "order": 4},
            {"name": "Баджаны", "code": "bhajans", "order": 5},
            {"name": "Интервью", "code": "interviews", "order": 6},
            {"name": "Беседы", "code": "conversations", "order": 7},
            {"name": "Книги", "code": "books", "order": 8},
            {"name": "Парикрамы", "code": "parikrams", "order": 9},
        ]

        for group_data in groups:
            group, created = TopicGroup.objects.get_or_create(
                code=group_data["code"],
                defaults={
                    "name": group_data["name"],
                    "order": group_data["order"],
                    "is_active": True,
                },
            )
            if created:
                self.stdout.write(f"Created topic group: {group.name}")
            else:
                self.stdout.write(f"Topic group already exists: {group.name}")

        self.stdout.write(self.style.SUCCESS("Successfully initialized data"))
