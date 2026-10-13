import logging
import os
import re
import mutagen

from django.db import transaction
from django.core.files.storage import default_storage
from apps.lecture.models import Lecture
logger = logging.getLogger(__name__)


class LectureImport:

    def __init__(self, topic, language):
        self.topic = topic
        # Every file in one import is in this language.
        self.language = language

    def import_files(self, uploaded_files):
        """Import lectures from uploaded files"""
        logger.info(
            f"Starting import for topic: {self.topic.title}, "
            f"files: {len(uploaded_files)}"
        )

        if not uploaded_files:
            logger.error("No files provided for import")
            raise ValueError("No files provided")

        # Sort files by name
        files_list = list(uploaded_files)
        files_list.sort(key=lambda f: self._natural_sort_key(f.name))

        logger.info(f"Files sorted: {[f.name for f in files_list]}")

        imported_count = 0
        failed_count = 0
        skipped_count = 0
        next_order = self._get_next_order()

        logger.info(f"Starting order number: {next_order}")

        for idx, file in enumerate(files_list, 1):
            logger.info(
                f"[{idx}/{len(files_list)}] Processing file: {file.name}, "
                f"size: {file.size} bytes, order: {next_order}"
            )

            if self._is_audio_file(file.name):
                # Check for duplicate hash
                if self._check_duplicate_by_hash(file.name):
                    skipped_count += 1
                    logger.warning(
                        f"Duplicate file found by hash, skipping: {file.name}"
                    )
                    continue

                if self._create_lecture(file, next_order):
                    imported_count += 1
                    logger.info(
                        f"[{imported_count}] Successfully imported: {file.name} (order: {next_order})"
                    )
                    next_order += 1
                else:
                    failed_count += 1
                    logger.error(f"Failed to import: {file.name}")
            else:
                skipped_count += 1
                logger.warning(f"Skipped non-audio file: {file.name}")

        logger.info(
            f"Import completed: imported {imported_count}, failed {failed_count}, "
            f"skipped {skipped_count}, processed {len(files_list)}"
        )
        return imported_count

    def _is_audio_file(self, filename):
        """Check if file is audio"""
        audio_extensions = [".mp3", ".wav", ".m4a", ".flac", ".ogg"]
        is_audio = any(filename.lower().endswith(ext) for ext in audio_extensions)

        if not is_audio:
            logger.debug(f"File {filename} is not audio file")

        return is_audio

    def _natural_sort_key(self, filename):
        """Natural sorting key for filenames with numbers"""
        return [
            int(text) if text.isdigit() else text.lower()
            for text in re.split("([0-9]+)", filename)
        ]

    def _get_next_order(self):
        """Get next order number for lectures in topic"""
        try:
            existing_orders = list(
                self.topic.lectures.values_list("order", flat=True).order_by("order")
            )

            logger.debug(
                f"Existing orders for topic '{self.topic.title}': {existing_orders}"
            )

            if not existing_orders:
                next_order = 1
            else:
                next_order = max(existing_orders) + 1

            logger.debug(f"Next available order: {next_order}")
            return next_order

        except Exception as e:
            logger.error(f"Error calculating next order: {str(e)}")
            return 1

    def _check_duplicate_by_hash(self, filename):
        """Check if lecture with same file hash already exists"""
        file_hash = Lecture.generate_file_hash(filename)
        exists = self.topic.lectures.filter(file_hash=file_hash).exists()

        if exists:
            logger.warning(
                f"Lecture with hash '{file_hash}' for file '{filename}' already exists"
            )

        return exists

    def _create_lecture(self, uploaded_file, order):
        """Create lecture from uploaded file"""
        lecture = None
        try:
            with transaction.atomic():
                logger.debug(f"Creating lecture from file: {uploaded_file.name}")

                # Debug storage information
                logger.debug(f"Using storage: {type(default_storage)}")

                title = self._extract_title(uploaded_file.name)
                file_size = uploaded_file.size
                file_hash = Lecture.generate_file_hash(uploaded_file.name)

                # Get duration before any file operations
                duration = self._get_duration_from_file(uploaded_file)
                logger.debug(f"Duration extracted: '{duration}'")

                # Double-check for duplicates before creating
                if self.topic.lectures.filter(file_hash=file_hash).exists():
                    logger.error(
                        f"Cannot create lecture - file hash '{file_hash}' already exists"
                    )
                    return False

                logger.debug("About to create Lecture object...")
                lecture = Lecture.objects.create(
                    topic=self.topic,
                    title=title,
                    audio_file=uploaded_file,
                    language=self.language,
                    file_size=file_size,
                    duration=duration,
                    order=order,
                    file_hash=file_hash,
                )

                # Verify the file was saved correctly
                logger.debug(f"File saved to storage: {lecture.audio_file.name}")
                logger.debug(f"File URL: {lecture.audio_file.url}")

                # Verify file exists in storage
                if not default_storage.exists(lecture.audio_file.name):
                    # Raised, not returned, so the row is rolled back too.
                    raise RuntimeError(
                        f"File was not saved to storage: {lecture.audio_file.name}"
                    )

                logger.info(
                    f"Lecture created: id {lecture.id}, order {lecture.order}, "
                    f"file {lecture.audio_file.name}"
                )
                return True

        except Exception:
            logger.exception(f"Exception creating lecture from {uploaded_file.name}")
            # The row was rolled back; don't leave its file behind.
            if lecture is not None and lecture.audio_file.name:
                try:
                    default_storage.delete(lecture.audio_file.name)
                except Exception:
                    logger.exception(f"Couldn't remove {lecture.audio_file.name}")
            return False

    def _extract_title(self, filename):
        """Extract title from filename and remove unwanted patterns"""
        title = os.path.splitext(filename)[0]

        # Patterns to remove from title
        patterns_to_remove = [
            r"\(текст в ID3 теге\)",  # Remove "(текст в ID3 теге)"
            # Add more patterns here as needed:
            # r'\(pattern2\)',
            # r'\[pattern3\]',
        ]

        # Remove patterns
        for pattern in patterns_to_remove:
            title = re.sub(pattern, "", title, flags=re.IGNORECASE)

        # Clean up extra spaces
        title = " ".join(title.split())

        cleaned_title = title.strip() or filename

        # Limit title length
        if len(cleaned_title) > 250:
            cleaned_title = cleaned_title[:250] + "..."
            logger.debug(f"Title too long, truncated to: {cleaned_title}")

        logger.debug(f"Title extracted from {filename}: {cleaned_title}")
        return cleaned_title

    def _get_duration_from_file(self, uploaded_file):
        """Get audio duration from uploaded file in seconds"""
        try:
            logger.debug(f"Extracting duration from: {uploaded_file.name}")

            # Read in place: a large upload sits in a temp file, not memory.
            audio_file = mutagen.File(uploaded_file)
            uploaded_file.seek(0)

            if audio_file and hasattr(audio_file.info, "length"):
                seconds = int(audio_file.info.length)
                logger.debug(f"Duration extracted: {seconds} seconds")
                return seconds
            else:
                logger.warning(f"Could not extract duration from {uploaded_file.name}")

        except Exception as e:
            logger.error(
                f"Error extracting duration from {uploaded_file.name}: {str(e)}"
            )

        return None
