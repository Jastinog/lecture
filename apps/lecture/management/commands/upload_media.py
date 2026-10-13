from django.conf import settings
from django.core.files.storage import FileSystemStorage, default_storage
from django.core.management.base import BaseCommand, CommandError

from apps.lecture.models import FILE_FIELDS


class Command(BaseCommand):
    help = (
        "Copy media files from the local disk (MEDIA_ROOT) to the configured "
        "storage, e.g. Spaces. Files already there are skipped; local copies stay."
    )

    def handle(self, *args, **options):
        local = FileSystemStorage(location=settings.MEDIA_ROOT)
        if isinstance(default_storage, FileSystemStorage):
            raise CommandError("Media storage is the local disk: set SPACES_BUCKET first.")

        copied = skipped = missing = 0
        for model, field in FILE_FIELDS.items():
            for obj in model.objects.exclude(**{field: ""}).iterator():
                name = getattr(obj, field).name
                if default_storage.exists(name):
                    skipped += 1
                    continue
                if not local.exists(name):
                    missing += 1
                    self.stdout.write(self.style.WARNING(f"Missing locally: {name}"))
                    continue

                with local.open(name) as f:
                    saved = default_storage.save(name, f)
                if saved != name:
                    # The storage picked another name; point the record at it.
                    setattr(obj, field, saved)
                    obj.save(update_fields=[field])
                copied += 1
                self.stdout.write(f"Copied {saved}")

        self.stdout.write(
            self.style.SUCCESS(f"Copied {copied}, already there {skipped}, missing {missing}")
        )
