import django.db.models.deletion
from django.db import migrations, models
from django.db.models import Count


def count_listener_plays(apps, schema_editor):
    """Plays were counted by topic; those of listeners are kept by lecture, so
    "Trending" starts from them."""
    ListenerPlay = apps.get_model("listeners", "ListenerPlay")
    LecturePlays = apps.get_model("lecture", "LecturePlays")
    totals = ListenerPlay.objects.values("lecture", "day").annotate(count=Count("id"))
    LecturePlays.objects.bulk_create(
        LecturePlays(lecture_id=row["lecture"], day=row["day"], count=row["count"])
        for row in totals.iterator()
    )


class Migration(migrations.Migration):

    dependencies = [
        ("lecture", "0007_topic_plays"),
        ("listeners", "0001_listeners"),
    ]

    operations = [
        migrations.CreateModel(
            name="LecturePlays",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("day", models.DateField()),
                ("count", models.PositiveIntegerField(default=0)),
                (
                    "lecture",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="plays",
                        to="lecture.lecture",
                    ),
                ),
            ],
            options={
                "verbose_name_plural": "lecture plays",
                "indexes": [
                    models.Index(fields=["day"], name="lecture_lec_day_1efce1_idx")
                ],
                "constraints": [
                    models.UniqueConstraint(
                        fields=("lecture", "day"), name="lecture_plays_per_day"
                    )
                ],
            },
        ),
        migrations.RunPython(count_listener_plays, migrations.RunPython.noop),
        migrations.DeleteModel(name="TopicPlays"),
    ]
