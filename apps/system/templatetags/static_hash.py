from django import template
from django.templatetags.static import static
from django.conf import settings
import hashlib
from pathlib import Path

register = template.Library()


@register.simple_tag
def static_hash(path: str) -> str:
    url = static(path)

    static_root = Path(settings.STATIC_ROOT or (settings.BASE_DIR / "static"))
    file_path = static_root / path

    if file_path.exists():
        with open(file_path, "rb") as f:
            file_hash = hashlib.md5(f.read()).hexdigest()[:8]
        return f"{url}?v={file_hash}"

    return f"{url}?v=0"
