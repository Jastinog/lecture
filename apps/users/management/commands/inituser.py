from django.core.management.base import BaseCommand
from django.conf import settings

from apps.users.models import User


class Command(BaseCommand):
    help = "Init user"

    def handle(self, *args, **options):
        def init_admin():
            try:
                User.objects.get(email=settings.DEFAULT_ADMIN_EMAIL)
            except User.DoesNotExist:
                user = User.objects.create_superuser(
                    email=settings.DEFAULT_ADMIN_EMAIL,
                    password=settings.DEFAULT_ADMIN_PASSWORD,
                )

                user.is_superuser = True
                user.is_active = True
                user.is_staff = True
                user.is_admin = True

                user.save()

        init_admin()
