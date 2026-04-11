import os
import uuid

from django.conf import settings
from django.core.files.storage import default_storage
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity
from apps.common import identity_or_404, picture_url
from .serializers import ProfileUpdateSerializer


# ── Profile Get ───────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def profile_get(request, pubkey):
    """Get public profile for any pubkey — no auth required."""
    try:
        identity = BitChatIdentity.objects.get(pubkey=pubkey)
    except BitChatIdentity.DoesNotExist:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response({
        'pubkey':               identity.pubkey,
        'short_id':             identity.short_id,
        'display_name':         identity.display_name,
        'profile_picture_url':  picture_url(identity),
        'created_at':           identity.created_at,
    })


# ── Profile Update ────────────────────────────────────────────────────────────

@api_view(['PATCH'])
@permission_classes([IsAuthenticated])
def profile_update(request):
    """Update display_name or profile_picture_url."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    serializer = ProfileUpdateSerializer(identity, data=request.data, partial=True)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    serializer.save()
    return Response({
        'pubkey':               identity.pubkey,
        'short_id':             identity.short_id,
        'display_name':         identity.display_name,
        'profile_picture_url':  picture_url(identity),
        'created_at':           identity.created_at,
    })


# ── Profile Picture Upload ────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def profile_picture_upload(request):
    """Upload a profile picture. Returns the public URL."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    image = request.FILES.get('image')
    if not image:
        return Response({'detail': 'No image provided.'}, status=status.HTTP_400_BAD_REQUEST)

    allowed = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'}
    if image.content_type not in allowed:
        return Response({'detail': 'Invalid image type.'}, status=status.HTTP_400_BAD_REQUEST)

    if image.size > 2 * 1024 * 1024:
        return Response({'detail': 'Image too large (max 2MB).'}, status=status.HTTP_400_BAD_REQUEST)

    ext      = os.path.splitext(image.name)[1].lower() or '.jpg'
    filename = f'profile_pictures/{uuid.uuid4().hex}{ext}'
    saved    = default_storage.save(filename, image)
    url      = request.build_absolute_uri(settings.MEDIA_URL + saved)

    identity.profile_picture_url = url
    identity.save(update_fields=['profile_picture_url', 'updated_at'])
    return Response({'url': url})
