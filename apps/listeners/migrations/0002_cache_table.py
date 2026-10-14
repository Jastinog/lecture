from django.core.management import call_command
from django.db import migrations


def create_cache_table(apps, schema_editor):
    """The table `CACHES` points at, so deploys need no extra step. Leaves an
    existing one alone."""
    call_command("createcachetable", database=schema_editor.connection.alias)


class Migration(migrations.Migration):

    dependencies = [
        ("listeners", "0001_listeners"),
    ]

    operations = [
        migrations.RunPython(create_cache_table, migrations.RunPython.noop),
    ]
