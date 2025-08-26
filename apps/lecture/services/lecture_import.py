import os
import re
from apps.lecture.models import Lecture

try:
    import mutagen

    MUTAGEN_AVAILABLE = True
except ImportError:
    MUTAGEN_AVAILABLE = False


class LectureImportService:

    def __init__(self, course):
        self.course = course

    def import_files(self, uploaded_files):
        """Import lectures from uploaded files"""
        if not uploaded_files:
            raise ValueError("No files provided")

        # Sort files by name
        files_list = list(uploaded_files)
        files_list.sort(key=lambda f: self._natural_sort_key(f.name))

        imported_count = 0
        next_order = self._get_next_order()

        for file in files_list:
            if self._is_audio_file(file.name):
                if self._create_lecture(file, next_order):
                    imported_count += 1
                    next_order += 1

        return imported_count

    def _is_audio_file(self, filename):
        """Check if file is audio"""
        audio_extensions = [".mp3", ".wav", ".m4a", ".flac", ".ogg"]
        return any(filename.lower().endswith(ext) for ext in audio_extensions)

    def _natural_sort_key(self, filename):
        """Natural sorting key for filenames with numbers"""
        return [
            int(text) if text.isdigit() else text.lower()
            for text in re.split("([0-9]+)", filename)
        ]

    def _get_next_order(self):
        """Get next order number for lectures in course"""
        last_lecture = self.course.lectures.order_by("-order").first()
        return (last_lecture.order + 1) if last_lecture else 1

    def _create_lecture(self, uploaded_file, order):
        """Create lecture from uploaded file"""
        try:
            title = self._extract_title(uploaded_file.name)
            file_size = uploaded_file.size
            duration = self._get_duration_from_file(uploaded_file)

            Lecture.objects.create(
                course=self.course,
                title=title,
                audio_file=uploaded_file,
                file_size=file_size,
                duration=duration,
                order=order,
            )
            return True

        except Exception as e:
            print(f"Failed to import {uploaded_file.name}: {e}")
            return False

    def _extract_title(self, filename):
        """Extract title from filename"""
        title = os.path.splitext(filename)[0]
        return title.strip() or filename

    def _get_duration_from_file(self, uploaded_file):
        """Get audio duration from uploaded file"""
        if not MUTAGEN_AVAILABLE:
            return ""

        try:
            # Create temporary file-like object
            file_data = uploaded_file.read()
            uploaded_file.seek(0)  # Reset file pointer

            # Try to get duration with mutagen
            from io import BytesIO

            audio_file = mutagen.File(BytesIO(file_data))

            if audio_file and hasattr(audio_file.info, "length"):
                seconds = int(audio_file.info.length)
                minutes = seconds // 60
                seconds = seconds % 60
                return f"{minutes}:{seconds:02d}"

        except Exception:
            pass

        return ""
