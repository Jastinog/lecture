"""
Django management command to create basic ISKCON lecturers with ordering

Place this file in: apps/lecture/management/commands/create_iskcon_lecturers.py

Also create the following folder structure:
apps/lecture/management/
├── __init__.py
├── commands/
│   ├── __init__.py
│   ├── create_iskcon_lecturers.py
│   └── lecturer_photos/
│       ├── srila_prabhupada.jpg
│       ├── bhakti_charu_swami.jpg
│       ├── indradyumna_swami.jpg
│       ├── radhanath_swami.jpg
│       ├── kadamba_kanana_swami.jpg
│       ├── sivarama_swami.jpg
│       ├── bhakti_vikasa_swami.jpg
│       ├── jayapataka_swami.jpg
│       ├── bhanu_swami.jpg
│       ├── yadunandana_swami.jpg
│       └── achyuta_priya.jpg
"""

import os
from django.core.management.base import BaseCommand
from django.core.files import File
from apps.lecture.models import Lecturer


class Command(BaseCommand):
    help = "Create basic ISKCON lecturers with photos and proper ordering"

    def add_arguments(self, parser):
        parser.add_argument(
            "--clear",
            action="store_true",
            help="Delete all existing lecturers before creating new ones",
        )
        parser.add_argument(
            "--update-order",
            action="store_true",
            help="Update order for existing lecturers without recreating them",
        )

    def handle(self, *args, **options):
        if options["clear"]:
            self.stdout.write("Deleting existing lecturers...")
            Lecturer.objects.all().delete()
            self.stdout.write(self.style.SUCCESS("All lecturers deleted."))

        # Path to lecturer photos folder
        photos_dir = os.path.join(os.path.dirname(__file__), "lecturer_photos")

        # ISKCON lecturers data with proper ordering
        lecturers_data = [
            {
                "name": "Srila Prabhupada",
                "code": "srila-prabhupada",
                "description": "Founder-Acharya of ISKCON, author of numerous translations of sacred scriptures. Spread Krishna consciousness worldwide.",
                "photo": "srila_prabhupada.jpg",
                "order": 1,  # Most important - founder
            },
            {
                "name": "Radhanath Swami",
                "code": "radhanath-swami",
                "description": 'Author of "The Journey Home", inspiring spiritual teacher and storyteller.',
                "photo": "radhanath_swami.jpg",
                "order": 2,  # Very popular and well-known
            },
            {
                "name": "Indradyumna Swami",
                "code": "indradyumna-swami",
                "description": "ISKCON sankirtana leader, organizer of festivals and spiritual programs worldwide.",
                "photo": "indradyumna_swami.jpg",
                "order": 3,  # Popular festival organizer
            },
            {
                "name": "Bhakti Charu Swami",
                "code": "bhakti-charu-swami",
                "description": "ISKCON spiritual teacher, known for inspiring lectures on devotion and spiritual practice.",
                "photo": "bhakti_charu_swami.jpg",
                "order": 4,  # Senior disciple
            },
            {
                "name": "Jayapataka Swami",
                "code": "jayapataka-swami",
                "description": "One of Prabhupada's senior disciples, GBC and experienced spiritual teacher.",
                "photo": "jayapataka_swami.jpg",
                "order": 5,  # Senior disciple and GBC
            },
            {
                "name": "Sivarama Swami",
                "code": "sivarama-swami",
                "description": "European GBC, author of many books on Vaishnava philosophy and practice.",
                "photo": "sivarama_swami.jpg",
                "order": 6,  # European leader
            },
            {
                "name": "Achyuta Priya",
                "code": "achyuta-priya",
                "description": "Head of ISKCON Ukraine, GBC member. Pioneer of Krishna consciousness in Soviet Ukraine since 1980, expert in devotee care and community development.",
                "photo": "achyuta_priya.jpg",
                "order": 7,  # Regional leader - Ukraine
            },
            {
                "name": "Bhakti Vikasa Swami",
                "code": "bhakti-vikasa-swami",
                "description": "Senior ISKCON teacher, author of multiple books on Vedic culture and Krishna consciousness.",
                "photo": "bhakti_vikasa_swami.jpg",
                "order": 8,
            },
            {
                "name": "Kadamba Kanana Swami",
                "code": "kadamba-kanana-swami",
                "description": "Senior ISKCON leader, known for deep philosophical lectures and spiritual guidance.",
                "photo": "kadamba_kanana_swami.jpg",
                "order": 9,
            },
            {
                "name": "Bhanu Swami",
                "code": "bhanu-swami",
                "description": "Scholar and translator of Vaishnava literature, expert in Sanskrit and philosophy.",
                "photo": "bhanu_swami.jpg",
                "order": 10,
            },
            {
                "name": "Yadunandana Swami",
                "code": "yadunandana-swami",
                "description": "European ISKCON leader, experienced in temple management and devotee training.",
                "photo": "yadunandana_swami.jpg",
                "order": 11,
            },
        ]

        # Handle update-order option
        if options["update_order"]:
            self.stdout.write("Updating order for existing lecturers...")
            updated_count = 0

            for lecturer_data in lecturers_data:
                try:
                    lecturer = Lecturer.objects.get(name=lecturer_data["name"])
                    if lecturer.order != lecturer_data["order"]:
                        lecturer.order = lecturer_data["order"]
                        lecturer.save()
                        self.stdout.write(
                            self.style.SUCCESS(
                                f'Updated order for {lecturer_data["name"]}: {lecturer_data["order"]}'
                            )
                        )
                        updated_count += 1
                    else:
                        self.stdout.write(
                            f'Order unchanged for {lecturer_data["name"]}'
                        )
                except Lecturer.DoesNotExist:
                    self.stdout.write(
                        self.style.WARNING(
                            f'Lecturer "{lecturer_data["name"]}" not found, skipping...'
                        )
                    )

            self.stdout.write(
                self.style.SUCCESS(f"Updated order for {updated_count} lecturers")
            )
            return

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

            # Create lecturer
            lecturer = Lecturer(
                name=lecturer_data["name"],
                code=lecturer_data["code"],
                description=lecturer_data["description"],
                order=lecturer_data["order"],
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
                        f'Created lecturer: {lecturer_data["name"]} (order: {lecturer_data["order"]})'
                    )
                )
            except Exception as e:
                self.stdout.write(
                    self.style.ERROR(
                        f'Error creating lecturer {lecturer_data["name"]}: {e}'
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
                self.style.WARNING("Create the folder and place lecturer photos there:")
            )
            for lecturer_data in lecturers_data:
                self.stdout.write(f'  - {lecturer_data["photo"]}')

        self.stdout.write("\nCommand usage:")
        self.stdout.write("python manage.py create_iskcon_lecturers")
        self.stdout.write("python manage.py create_iskcon_lecturers --clear")
        self.stdout.write("python manage.py create_iskcon_lecturers --update-order")

        # Show final ordering
        self.stdout.write("\nFinal lecturer ordering:")
        for lecturer in Lecturer.objects.all().order_by("order"):
            self.stdout.write(f"  {lecturer.order}. {lecturer.name}")
