import shutil
import tempfile
from concurrent.futures import ThreadPoolExecutor

import mutagen
from django.core.management.base import BaseCommand

from apps.lecture.models import Lecture


class Command(BaseCommand):
    help = "Read the duration of every lecture that has none from its audio file."

    def add_arguments(self, parser):
        parser.add_argument("--workers", type=int, default=8, help="Parallel downloads (default 8)")

    def handle(self, *args, workers=8, **options):
        lectures = list(Lecture.objects.filter(duration__isnull=True).only("id", "audio_file"))
        self.stdout.write(f"{len(lectures)} lectures without a duration")
        filled = failed = 0
        with ThreadPoolExecutor(workers) as pool:
            for lecture, duration in zip(lectures, pool.map(self.read_duration, lectures)):
                if isinstance(duration, Exception) or duration is None:
                    failed += 1
                    self.stdout.write(self.style.WARNING(f"  {lecture.audio_file.name}: {duration}"))
                    continue
                Lecture.objects.filter(pk=lecture.pk).update(duration=duration)
                filled += 1
        self.stdout.write(self.style.SUCCESS(f"Filled {filled}, failed {failed}"))

    @staticmethod
    def read_duration(lecture):
        try:
            with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
                with lecture.audio_file.open("rb") as f:
                    shutil.copyfileobj(f, tmp)
                tmp.flush()
                audio = mutagen.File(tmp.name)
                return int(audio.info.length) if audio is not None and audio.info else None
        except Exception as e:
            return e
