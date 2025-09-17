"""
Django management command to create ISKCON lecturers with spiritual hierarchy

Place this file in: apps/lecture/management/commands/create_iskcon_lecturers.py

Photo folder structure:
apps/lecture/management/commands/lecturer_photos/
"""

import os
from django.core.management.base import BaseCommand
from django.core.files import File
from apps.lecture.models import Lecturer


class Command(BaseCommand):
    help = "Create ISKCON lecturers with photos and spiritual hierarchy"

    def add_arguments(self, parser):
        parser.add_argument(
            "--clear",
            action="store_true",
            help="Delete all existing lecturers before creating new ones",
        )
        parser.add_argument(
            "--update-hierarchy",
            action="store_true",
            help="Update hierarchy for existing lecturers without recreating them",
        )

    def handle(self, *args, **options):
        if options["clear"]:
            self.stdout.write("Deleting existing lecturers...")
            Lecturer.objects.all().delete()
            self.stdout.write(self.style.SUCCESS("All lecturers deleted."))

        photos_dir = os.path.join(os.path.dirname(__file__), "lecturer_photos")

        # ISKCON lecturers data with spiritual hierarchy
        lecturers_data = [
            {
                "name": "A. C. Bhaktivedanta Swami Prabhupada",
                "code": "hg-srila-prabhupada",
                "description": "Founder-Acharya of ISKCON, author of numerous translations of sacred scriptures. Spread Krishna consciousness worldwide.",
                "photo": "srila_prabhupada.jpg",
                "order": 1,
                "level": 1,
                "guru": None,
            },
            {
                "name": "HH Radhanath Swami",
                "code": "hh-radhanath-swami",
                "description": 'Author of "The Journey Home", inspiring spiritual teacher and storyteller.',
                "photo": "radhanath_swami.jpg",
                "order": 2,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Indradyumna Swami",
                "code": "hh-indradyumna-swami",
                "description": "ISKCON sankirtana leader, organizer of festivals and spiritual programs worldwide.",
                "photo": "indradyumna_swami.jpg",
                "order": 3,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhakti Charu Swami",
                "code": "hh-bhakti-charu-swami",
                "description": "ISKCON spiritual teacher, known for inspiring lectures on devotion and spiritual practice.",
                "photo": "bhakti_charu_swami.jpg",
                "order": 4,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Jayapataka Swami",
                "code": "hh-jayapataka-swami",
                "description": "One of Prabhupada's senior disciples, GBC and experienced spiritual teacher.",
                "photo": "jayapataka_swami.jpg",
                "order": 5,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Sivarama Swami",
                "code": "hh-sivarama-swami",
                "description": "European GBC, author of many books on Vaishnava philosophy and practice.",
                "photo": "sivarama_swami.jpg",
                "order": 6,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhakti Vikasa Swami",
                "code": "hh-bhakti-vikasa-swami",
                "description": "Senior ISKCON teacher, author of multiple books on Vedic culture and Krishna consciousness.",
                "photo": "bhakti_vikasa_swami.jpg",
                "order": 7,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Kadamba Kanana Swami",
                "code": "hh-kadamba-kanana-swami",
                "description": "Senior ISKCON leader, known for deep philosophical lectures and spiritual guidance.",
                "photo": "kadamba_kanana_swami.jpg",
                "order": 8,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhanu Swami",
                "code": "hh-bhanu-swami",
                "description": "Scholar and translator of Vaishnava literature, expert in Sanskrit and philosophy.",
                "photo": "bhanu_swami.jpg",
                "order": 9,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Achyuta Priya",
                "code": "hh-achyuta-priya",
                "description": "Head of ISKCON Ukraine, GBC member. Pioneer of Krishna consciousness in Soviet Ukraine since 1980.",
                "photo": "achyuta_priya.jpg",
                "order": 10,
                "level": 3,
                "guru": "hh-radhanath-swami",
            },
            {
                "name": "HH Yadunandana Swami",
                "code": "hh-yadunandana-swami",
                "description": "European ISKCON leader, experienced in temple management and devotee training.",
                "photo": "yadunandana_swami.jpg",
                "order": 11,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhakti Tirtha Swami",
                "code": "hh-bhakti-tirtha-swami",
                "description": "Author and spiritual teacher, known for his compassionate approach to Krishna consciousness.",
                "photo": "bhakti_tirtha_swami.jpg",
                "order": 12,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Gopal Krishna Goswami",
                "code": "hh-gopal-krishna-goswami",
                "description": "Senior ISKCON leader and GBC member, active in India and worldwide preaching.",
                "photo": "gopal_krishna_goswami.jpg",
                "order": 13,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhakti Vaibhava Swami",
                "code": "hh-bhakti-vaibhava-swami",
                "description": "Australian-based ISKCON leader, active in preaching and temple development.",
                "photo": "bhakti_vaibhava_swami.jpg",
                "order": 14,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Lokanath Swami",
                "code": "hh-lokanath-swami",
                "description": "Padayatra leader, organizer of walking pilgrimages across India.",
                "photo": "lokanath_swami.jpg",
                "order": 15,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Niranjana Swami",
                "code": "hh-niranjana-swami",
                "description": "ISKCON leader active in Russia and Eastern Europe, known for philosophical depth.",
                "photo": "niranjana_swami.jpg",
                "order": 16,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Devamrita Swami",
                "code": "hh-devamrita-swami",
                "description": "Author and teacher, known for books on spiritual practice and philosophy.",
                "photo": "devamrita_swami.jpg",
                "order": 17,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Bhakti Caitanya Swami",
                "code": "hh-bhakti-caitanya-swami",
                "description": "Senior ISKCON leader, experienced in spiritual guidance and community development.",
                "photo": "bhakti_caitanya_swami.jpg",
                "order": 18,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
            {
                "name": "HH Sacinandana Swami",
                "code": "hh-sacinandana-swami",
                "description": "German-based spiritual teacher, known for retreats and deep spiritual guidance.",
                "photo": "sacinandana_swami.jpg",
                "order": 19,
                "level": 2,
                "guru": "hg-srila-prabhupada",
            },
        ]

        # Handle update-hierarchy option
        if options["update_hierarchy"]:
            self.stdout.write("Updating hierarchy for existing lecturers...")
            updated_count = 0

            for lecturer_data in lecturers_data:
                try:
                    lecturer = Lecturer.objects.get(name=lecturer_data["name"])
                    updated = False
                    
                    if lecturer.level != lecturer_data["level"]:
                        lecturer.level = lecturer_data["level"]
                        updated = True
                    
                    if lecturer.order != lecturer_data["order"]:
                        lecturer.order = lecturer_data["order"]
                        updated = True
                    
                    if updated:
                        lecturer.save()
                        updated_count += 1
                        self.stdout.write(
                            self.style.SUCCESS(
                                f'Updated {lecturer_data["name"]}: level={lecturer_data["level"]}, order={lecturer_data["order"]}'
                            )
                        )
                        
                except Lecturer.DoesNotExist:
                    self.stdout.write(
                        self.style.WARNING(
                            f'Lecturer "{lecturer_data["name"]}" not found, skipping...'
                        )
                    )

            # Set guru relationships
            for lecturer_data in lecturers_data:
                if lecturer_data["guru"]:
                    try:
                        lecturer = Lecturer.objects.get(code=lecturer_data["code"])
                        guru = Lecturer.objects.get(code=lecturer_data["guru"])
                        if lecturer.guru != guru:
                            lecturer.guru = guru
                            lecturer.save()
                            self.stdout.write(
                                self.style.SUCCESS(f'Set guru for {lecturer.name}: {guru.name}')
                            )
                    except Lecturer.DoesNotExist:
                        pass

            self.stdout.write(
                self.style.SUCCESS(f"Updated hierarchy for {updated_count} lecturers")
            )
            return

        # First pass: Create lecturers without guru relationships
        self.stdout.write("Creating lecturers...")
        created_count = 0
        for lecturer_data in lecturers_data:
            # Check if lecturer already exists by name
            if Lecturer.objects.filter(name=lecturer_data["name"]).exists():
                self.stdout.write(
                    self.style.WARNING(
                        f'Lecturer "{lecturer_data["name"]}" already exists, skipping...'
                    )
                )
                continue

            # Create lecturer without guru first
            lecturer = Lecturer(
                name=lecturer_data["name"],
                code=lecturer_data["code"],
                description=lecturer_data["description"],
                order=lecturer_data["order"],
                level=lecturer_data["level"],
            )

            # Add photo if file exists
            photo_path = os.path.join(photos_dir, lecturer_data["photo"])
            if os.path.exists(photo_path):
                try:
                    with open(photo_path, "rb") as photo_file:
                        lecturer.photo.save(
                            lecturer_data["photo"], File(photo_file), save=False
                        )
                    self.stdout.write(f'✓ Photo added for {lecturer_data["name"]}')
                except Exception as e:
                    self.stdout.write(
                        self.style.WARNING(
                            f'Error loading photo for {lecturer_data["name"]}: {e}'
                        )
                    )
            else:
                self.stdout.write(self.style.WARNING(f"Photo not found: {photo_path}"))

            try:
                lecturer.save()
                created_count += 1
                self.stdout.write(
                    self.style.SUCCESS(
                        f'Created lecturer: {lecturer_data["name"]} (level: {lecturer_data["level"]}, order: {lecturer_data["order"]})'
                    )
                )
            except Exception as e:
                self.stdout.write(
                    self.style.ERROR(
                        f'Error creating lecturer {lecturer_data["name"]}: {e}'
                    )
                )

        # Second pass: Set guru relationships
        self.stdout.write("\nSetting guru relationships...")
        for lecturer_data in lecturers_data:
            if lecturer_data["guru"]:
                try:
                    lecturer = Lecturer.objects.get(code=lecturer_data["code"])
                    guru = Lecturer.objects.get(code=lecturer_data["guru"])
                    lecturer.guru = guru
                    lecturer.save()
                    self.stdout.write(
                        self.style.SUCCESS(
                            f'✓ Set guru for {lecturer.name}: {guru.name}'
                        )
                    )
                except Lecturer.DoesNotExist as e:
                    self.stdout.write(
                        self.style.WARNING(
                            f'Could not set guru for {lecturer_data["name"]}: {e}'
                        )
                    )

        self.stdout.write("\n" + "=" * 50)
        self.stdout.write(
            self.style.SUCCESS(f"Successfully created lecturers: {created_count}")
        )

        if not os.path.exists(photos_dir):
            self.stdout.write(
                "\n"
                + self.style.WARNING(f"WARNING: Photos folder not found: {photos_dir}")
            )
            self.stdout.write(
                self.style.WARNING("Create the folder and place lecturer photos:")
            )
            for lecturer_data in lecturers_data:
                self.stdout.write(f'  - {lecturer_data["photo"]}')

        self.stdout.write("\nCommand usage:")
        self.stdout.write("python manage.py create_iskcon_lecturers")
        self.stdout.write("python manage.py create_iskcon_lecturers --clear")
        self.stdout.write("python manage.py create_iskcon_lecturers --update-hierarchy")

        # Show final ordering with hierarchy
        self.stdout.write("\nFinal lecturer ordering with hierarchy:")
        for lecturer in Lecturer.objects.all().order_by("level", "order"):
            guru_info = f" (guru: {lecturer.guru.name})" if lecturer.guru else ""
            level_icon = {1: "👑", 2: "🙏", 3: "📿"}.get(lecturer.level, "")
            self.stdout.write(
                f"  {level_icon} Level {lecturer.level} - {lecturer.order}. {lecturer.name}{guru_info}"
            )
