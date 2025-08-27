from django.db.models.signals import pre_save
from django.dispatch import receiver
from django.core.files.base import ContentFile
from PIL import Image, ImageOps
import io
import os
from .models import Lecturer, Course


def resize_image(image_field, size=(512, 512), quality=80):
    """
    Resize image to specified size maintaining aspect ratio with center crop
    Compatible with both local storage and S3
    Converts all images to JPEG format

    Args:
        image_field: Django ImageField
        size: tuple (width, height) for target size
        quality: JPEG quality (1-100)

    Returns:
        ContentFile with resized JPEG image or None if error
    """
    if not image_field:
        return None

    try:
        # For S3, we need to read the file content
        if hasattr(image_field, "read"):
            # File is already open
            image_field.seek(0)
            image_data = image_field.read()
            image_field.seek(0)  # Reset for any further operations
        else:
            # File needs to be opened
            image_field.open()
            image_data = image_field.read()
            image_field.close()

        # Open the image from bytes
        image = Image.open(io.BytesIO(image_data))

        # Convert to RGB (required for JPEG)
        if image.mode in ("RGBA", "LA", "P"):
            # Create white background for transparency
            background = Image.new("RGB", image.size, (255, 255, 255))
            if image.mode == "P":
                image = image.convert("RGBA")
            if image.mode in ("RGBA", "LA"):
                background.paste(
                    image, mask=image.split()[-1]
                )  # Use alpha channel as mask
                image = background
        elif image.mode != "RGB":
            image = image.convert("RGB")

        # Resize with aspect ratio maintained and center crop
        image = ImageOps.fit(
            image, size, Image.Resampling.LANCZOS, centering=(0.5, 0.5)
        )

        # Save to BytesIO as JPEG
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=quality, optimize=True)
        output.seek(0)

        return ContentFile(output.getvalue())

    except Exception as e:
        print(f"Error resizing image: {e}")
        return None


@receiver(pre_save, sender=Lecturer)
def resize_lecturer_photo(sender, instance, **kwargs):
    """
    Resize lecturer photo to 512x512 before saving
    Converts to JPEG format with quality 80
    """
    if instance.photo and hasattr(instance.photo, "file"):
        try:
            # Check if this is a new upload (not just a model save)
            if instance.pk:
                # Get existing instance to compare
                try:
                    existing = Lecturer.objects.get(pk=instance.pk)
                    if existing.photo == instance.photo:
                        # Photo hasn't changed, skip processing
                        return
                except Lecturer.DoesNotExist:
                    pass

            resized_content = resize_image(instance.photo, size=(512, 512), quality=80)
            if resized_content:
                # Get original name and force .jpg extension
                original_name = os.path.basename(instance.photo.name)
                name, _ = os.path.splitext(original_name)

                # Force JPEG extension
                new_name = f"{name}_resized.jpg"

                instance.photo.save(
                    new_name, resized_content, save=False  # Don't save the model again
                )
        except Exception as e:
            print(f"Error processing lecturer photo for {instance.name}: {e}")


@receiver(pre_save, sender=Course)
def resize_course_cover(sender, instance, **kwargs):
    """
    Resize course cover to 512x512 before saving
    Converts to JPEG format with quality 80
    """
    if instance.cover and hasattr(instance.cover, "file"):
        try:
            # Check if this is a new upload (not just a model save)
            if instance.pk:
                # Get existing instance to compare
                try:
                    existing = Course.objects.get(pk=instance.pk)
                    if existing.cover == instance.cover:
                        # Cover hasn't changed, skip processing
                        return
                except Course.DoesNotExist:
                    pass

            resized_content = resize_image(instance.cover, size=(512, 512), quality=80)
            if resized_content:
                # Get original name and force .jpg extension
                original_name = os.path.basename(instance.cover.name)
                name, _ = os.path.splitext(original_name)

                # Force JPEG extension
                new_name = f"{name}_resized.jpg"

                instance.cover.save(
                    new_name, resized_content, save=False  # Don't save the model again
                )
        except Exception as e:
            print(f"Error processing course cover for {instance.title}: {e}")
