import os
import json
from django.core.management.base import BaseCommand
from django.core.files import File
from apps.lecture.models import Lecturer, Topic, TopicGroup, Language


class LecturerSyncService:
    """Service for syncing lecturers from JSON file"""

    def __init__(self, json_file_path, lecturers_dir_path):
        self.json_file_path = json_file_path
        self.lecturers_dir_path = lecturers_dir_path
        self.created_count = 0
        self.updated_count = 0
        self.topics_created_count = 0
        self.topics_updated_count = 0
        self.messages = []

    def add_message(self, message, level="info"):
        """Add message to log"""
        self.messages.append({"message": message, "level": level})

    def load_json_data(self):
        """Load lecturers data from JSON file"""
        if not os.path.exists(self.json_file_path):
            raise FileNotFoundError(f"JSON file not found: {self.json_file_path}")

        try:
            with open(self.json_file_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            raise Exception(f"Error reading JSON file: {e}")

    def get_photo_path(self, lecturer_code):
        """Get full path to photo file: lecturers_dir/{lecturer_code}/photo/photo.jpg"""
        return os.path.join(
            self.lecturers_dir_path, lecturer_code, "photo", "photo.jpg"
        )

    def get_topic_cover_path(self, lecturer_code, topic_code):
        """Get full path to topic cover: lecturers_dir/{lecturer_code}/topics/{topic_code}/cover/cover.jpg"""
        return os.path.join(
            self.lecturers_dir_path,
            lecturer_code,
            "topics",
            topic_code,
            "cover",
            "cover.jpg",
        )

    def update_lecturer_photo(self, lecturer):
        """Update lecturer photo if photo.jpg exists - ONLY after lecturer is saved and has ID"""
        if not lecturer.id:
            self.add_message(f"Cannot update photo for unsaved lecturer: {lecturer.name}", "warning")
            return False
            
        photo_path = self.get_photo_path(lecturer.code)

        if not os.path.exists(photo_path):
            self.add_message(f"Photo not found: {photo_path}", "warning")
            return False

        try:
            with open(photo_path, "rb") as photo_file:
                lecturer.photo.save("photo.jpg", File(photo_file), save=True)
            return True
        except Exception as e:
            self.add_message(
                f"Error updating photo for {lecturer.name}: {e}", "warning"
            )
            return False

    def update_topic_cover(self, topic):
        """Update topic cover if cover.jpg exists - ONLY after topic is saved and has ID"""
        if not topic.id:
            self.add_message(f"Cannot update cover for unsaved topic: {topic.title}", "warning")
            return False
            
        cover_path = self.get_topic_cover_path(topic.lecturer.code, topic.code)

        if not os.path.exists(cover_path):
            self.add_message(f"Cover not found: {cover_path}", "warning")
            return False

        try:
            with open(cover_path, "rb") as cover_file:
                topic.cover.save("cover.jpg", File(cover_file), save=True)
            return True
        except Exception as e:
            self.add_message(f"Error updating cover for {topic.title}: {e}", "warning")
            return False

    def create_lecturer(self, lecturer_data):
        """Create new lecturer from data"""
        # Create lecturer without photo first
        lecturer = Lecturer(
            name=lecturer_data["name"],
            code=lecturer_data["code"],
            description=lecturer_data["description"],
            order=lecturer_data["order"],
            level=lecturer_data["level"],
        )

        # Save to get ID
        lecturer.save()
        self.created_count += 1
        self.add_message(f"Created lecturer: {lecturer.name}")

        # Now add photo after lecturer has ID
        if self.update_lecturer_photo(lecturer):
            self.add_message(f"Added photo for lecturer: {lecturer.name}")

        return lecturer

    def update_lecturer(self, lecturer, lecturer_data):
        """Update existing lecturer with new data"""
        updated = False

        # Update basic fields
        fields_to_update = ["name", "description", "order", "level"]
        for field in fields_to_update:
            if getattr(lecturer, field) != lecturer_data[field]:
                setattr(lecturer, field, lecturer_data[field])
                updated = True

        if updated:
            lecturer.save()
            self.updated_count += 1
            self.add_message(f"Updated lecturer: {lecturer.name}")

        # Update photo (lecturer already has ID)
        if self.update_lecturer_photo(lecturer):
            self.add_message(f"Updated photo for lecturer: {lecturer.name}")

        return updated

    def create_topic(self, lecturer, topic_data):
        """Create new topic for lecturer"""
        # Get group and languages from JSON
        group_code = topic_data["group"]
        language_codes = topic_data["languages"]

        try:
            group = TopicGroup.objects.get(code=group_code)
        except TopicGroup.DoesNotExist:
            self.add_message(f"Topic group not found: {group_code}", "error")
            return None

        # Create topic without cover first
        topic = Topic(
            lecturer=lecturer,
            code=topic_data["code"],
            title=topic_data["title"],
            description=topic_data["description"],
            group=group,
            order=topic_data["order"],
        )

        # Save to get ID
        topic.save()

        # Add languages to topic
        for lang_code in language_codes:
            try:
                language = Language.objects.get(code=lang_code)
                topic.languages.add(language)
            except Language.DoesNotExist:
                self.add_message(f"Language not found: {lang_code}", "warning")

        self.topics_created_count += 1
        self.add_message(f"Created topic: {lecturer.name} - {topic.title}")

        # Now add cover after topic has ID
        if self.update_topic_cover(topic):
            self.add_message(f"Added cover for topic: {topic.title}")

        return topic

    def update_topic(self, topic, topic_data):
        """Update existing topic with new data"""
        updated = False

        # Update basic fields
        fields_to_update = ["title", "description", "order"]
        for field in fields_to_update:
            if getattr(topic, field) != topic_data[field]:
                setattr(topic, field, topic_data[field])
                updated = True

        # Update group if needed
        group_code = topic_data["group"]
        try:
            group = TopicGroup.objects.get(code=group_code)
            if topic.group != group:
                topic.group = group
                updated = True
        except TopicGroup.DoesNotExist:
            self.add_message(f"Topic group not found: {group_code}", "warning")

        # Update languages
        language_codes = topic_data["languages"]
        current_languages = set(topic.languages.values_list("code", flat=True))
        new_languages = set(language_codes)

        if current_languages != new_languages:
            topic.languages.clear()
            for lang_code in language_codes:
                try:
                    language = Language.objects.get(code=lang_code)
                    topic.languages.add(language)
                    updated = True
                except Language.DoesNotExist:
                    self.add_message(f"Language not found: {lang_code}", "warning")

        if updated:
            topic.save()
            self.topics_updated_count += 1
            self.add_message(f"Updated topic: {topic.lecturer.name} - {topic.title}")

        # Update cover (topic already has ID)
        if self.update_topic_cover(topic):
            self.add_message(f"Updated cover for topic: {topic.title}")

        return updated

    def sync_topics(self, lecturer, topics_data):
        """Sync topics for lecturer"""
        if not topics_data:
            return

        for topic_data in topics_data:
            try:
                topic = Topic.objects.get(lecturer=lecturer, code=topic_data["code"])
                self.update_topic(topic, topic_data)
            except Topic.DoesNotExist:
                self.create_topic(lecturer, topic_data)

    def sync_lecturers_data(self, lecturers_data):
        """Sync lecturers data (create/update with topics)"""
        for lecturer_data in lecturers_data:
            try:
                lecturer = Lecturer.objects.get(code=lecturer_data["code"])
                self.update_lecturer(lecturer, lecturer_data)
            except Lecturer.DoesNotExist:
                lecturer = self.create_lecturer(lecturer_data)

            # Sync topics for this lecturer
            if "topics" in lecturer_data:
                self.sync_topics(lecturer, lecturer_data["topics"])

    def sync(self):
        """Main sync method"""
        try:
            # Load data from JSON
            lecturers_data = self.load_json_data()

            # Sync lecturers data (with topics)
            self.sync_lecturers_data(lecturers_data)

            # Add summary
            self.add_message("\nSync completed:")
            self.add_message(
                f"Lecturers - Created: {self.created_count}, Updated: {self.updated_count}"
            )
            self.add_message(
                f"Topics - Created: {self.topics_created_count}, Updated: {self.topics_updated_count}"
            )

            return True

        except Exception as e:
            self.add_message(f"Sync failed: {e}", "error")
            return False

    def get_summary(self):
        """Get sync summary"""
        return {
            "created_count": self.created_count,
            "updated_count": self.updated_count,
            "topics_created_count": self.topics_created_count,
            "topics_updated_count": self.topics_updated_count,
            "messages": self.messages,
        }


class Command(BaseCommand):
    help = "Sync ISKCON lecturers and topics from lecturers.json file"

    def handle(self, *args, **options):
        # Setup paths
        json_file = os.path.join(os.path.dirname(__file__), "lecturers.json")
        lecturers_dir = os.path.join(os.path.dirname(__file__), "lecturers")

        # Create service instance
        sync_service = LecturerSyncService(json_file, lecturers_dir)

        # Run sync
        success = sync_service.sync()

        # Output results
        summary = sync_service.get_summary()

        for message_data in summary["messages"]:
            message = message_data["message"]
            level = message_data["level"]

            if level == "error":
                self.stdout.write(self.style.ERROR(message))
            elif level == "warning":
                self.stdout.write(self.style.WARNING(message))
            else:
                self.stdout.write(message)

        if success:
            self.stdout.write("\n" + "=" * 50)
            self.stdout.write(
                self.style.SUCCESS(
                    f"Sync completed: Lecturers {summary['created_count']}/{summary['updated_count']}, "
                    f"Topics {summary['topics_created_count']}/{summary['topics_updated_count']}"
                )
            )
