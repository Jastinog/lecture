from django import template

register = template.Library()

@register.filter
def format_duration(seconds):
    """Convert seconds to MM:SS format"""
    if not seconds:
        return "--:--"
    
    minutes = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{minutes}:{secs:02d}"
