from django.db.models.signals import post_save
from django.dispatch import receiver
from django.core.files.base import ContentFile
from PIL import Image, ImageOps
import io
import os
from .models import Lecturer, Course


def resize_image(image_field, size=(512, 512), quality=85):
    """
    Resize image to specified size maintaining aspect ratio with center crop

    Args:
        image_field: Django ImageField
        size: tuple (width, height) for target size
        quality: JPEG quality (1-100)

    Returns:
        ContentFile with resized image or None if error
    """
    if not image_field:
        return None

    try:
        # Open the image
        image = Image.open(image_field)

        # Convert to RGB if necessary (handles RGBA, P, etc.)
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

        # Save to BytesIO
        output = io.BytesIO()

        # Determine format based on original file extension
        original_format = "JPEG"
        if hasattr(image_field, "name") and image_field.name:
            ext = os.path.splitext(image_field.name)[1].lower()
            if ext in [".png"]:
                original_format = "PNG"
                quality = None  # PNG doesn't use quality parameter

        # Save with appropriate format and quality
        if original_format == "PNG":
            image.save(output, format="PNG", optimize=True)
        else:
            image.save(output, format="JPEG", quality=quality, optimize=True)

        output.seek(0)

        return ContentFile(output.getvalue())

    except Exception as e:
        print(f"Error resizing image: {e}")
        return None


@receiver(post_save, sender=Lecturer)
def resize_lecturer_photo(sender, instance, created, **kwargs):
    """
    Resize lecturer photo to 512x512 after saving
    """
    if instance.photo and hasattr(instance.photo, "path"):
        try:
            # Get original file name and extension
            original_name = os.path.basename(instance.photo.name)
            name, ext = os.path.splitext(original_name)

            # Resize the image
            resized_content = resize_image(instance.photo, size=(512, 512))

            if resized_content:
                # Save the resized image back to the field
                # We need to prevent infinite recursion, so we disconnect the signal temporarily
                post_save.disconnect(resize_lecturer_photo, sender=Lecturer)

                try:
                    # Save the resized image
                    instance.photo.save(original_name, resized_content, save=True)
                finally:
                    # Reconnect the signal
                    post_save.connect(resize_lecturer_photo, sender=Lecturer)

        except Exception as e:
            print(f"Error processing lecturer photo for {instance.name}: {e}")


@receiver(post_save, sender=Course)
def resize_course_cover(sender, instance, created, **kwargs):
    """
    Resize course cover to 512x512 after saving
    """
    if instance.cover and hasattr(instance.cover, "path"):
        try:
            # Get original file name and extension
            original_name = os.path.basename(instance.cover.name)
            name, ext = os.path.splitext(original_name)

            # Resize the image
            resized_content = resize_image(instance.cover, size=(512, 512))

            if resized_content:
                # Save the resized image back to the field
                # We need to prevent infinite recursion, so we disconnect the signal temporarily
                post_save.disconnect(resize_course_cover, sender=Course)

                try:
                    # Save the resized image
                    instance.cover.save(original_name, resized_content, save=True)
                finally:
                    # Reconnect the signal
                    post_save.connect(resize_course_cover, sender=Course)

        except Exception as e:
            print(f"Error processing course cover for {instance.title}: {e}")


# Alternative signal that works on pre_save to avoid double saving
# Uncomment this and comment out the post_save signals above if you prefer

# from django.db.models.signals import pre_save

# @receiver(pre_save, sender=Lecturer)
# def resize_lecturer_photo_pre_save(sender, instance, **kwargs):
#     """
#     Resize lecturer photo to 512x512 before saving
#     """
#     if instance.photo and hasattr(instance.photo, 'file'):
#         try:
#             resized_content = resize_image(instance.photo, size=(512, 512))
#             if resized_content:
#                 # Get original name
#                 original_name = os.path.basename(instance.photo.name)
#                 instance.photo.save(
#                     original_name,
#                     resized_content,
#                     save=False  # Don't save the model again
#                 )
#         except Exception as e:
#             print(f"Error processing lecturer photo for {instance.name}: {e}")

# @receiver(pre_save, sender=Course)
# def resize_course_cover_pre_save(sender, instance, **kwargs):
#     """
#     Resize course cover to 512x512 before saving
#     """
#     if instance.cover and hasattr(instance.cover, 'file'):
#         try:
#             resized_content = resize_image(instance.cover, size=(512, 512))
#             if resized_content:
#                 # Get original name
#                 original_name = os.path.basename(instance.cover.name)
#                 instance.cover.save(
#                     original_name,
#                     resized_content,
#                     save=False  # Don't save the model again
#                 )
#         except Exception as e:
#             print(f"Error processing course cover for {instance.title}: {e}")
