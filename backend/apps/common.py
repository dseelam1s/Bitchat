"""Shared helpers used across multiple domain apps."""
import os
import uuid

from django.conf import settings
from django.core.files.storage import default_storage
from rest_framework.response import Response
from rest_framework import status
from rest_framework_simplejwt.tokens import RefreshToken

from bitchat.models import BitChatIdentity


def upload_file(file, folder: str, resource_type: str = 'auto') -> str:
    """Upload a file and return its permanent public URL.

    Uses Cloudinary when CLOUDINARY_CLOUD_NAME is configured (production).
    Falls back to local disk storage for local development only — not suitable
    for production because Render's filesystem is ephemeral.

    Args:
        file: InMemoryUploadedFile from request.FILES
        folder: logical folder name, e.g. 'images', 'audio', 'profiles'
        resource_type: 'image', 'video' (covers audio too), or 'auto'

    Returns:
        Absolute HTTPS URL to the uploaded file.

    Raises:
        Exception: if the upload fails (caller should return 500).
    """
    if settings.CLOUDINARY_CLOUD_NAME:
        import cloudinary.uploader
        result = cloudinary.uploader.upload(
            file,
            folder=f'bitchat/{folder}',
            resource_type=resource_type,
        )
        return result['secure_url']

    # ── Local-disk fallback (dev only) ────────────────────────────────────────
    ext      = os.path.splitext(file.name)[1].lower() or '.bin'
    filename = f'{folder}/{uuid.uuid4().hex}{ext}'
    saved    = default_storage.save(filename, file)
    # Return a server-relative URL — works for local testing via browser,
    # but will break on mobile unless you set MEDIA_URL to your LAN IP.
    return f'{settings.MEDIA_URL}{saved}'


def picture_url(identity):
    return identity.profile_picture_url or None


def make_tokens(user):
    refresh = RefreshToken.for_user(user)
    return {'access': str(refresh.access_token), 'refresh': str(refresh)}


def identity_or_404(pubkey):
    """Return (identity, None) or (None, 404 Response)."""
    try:
        return BitChatIdentity.objects.get(pubkey=pubkey), None
    except BitChatIdentity.DoesNotExist:
        return None, Response(
            {'detail': 'Register first.'},
            status=status.HTTP_404_NOT_FOUND,
        )
