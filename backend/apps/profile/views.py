from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from django.db import models
from bitchat.models import BitChatIdentity
from apps.common import identity_or_404, picture_url, upload_file
from .serializers import ProfileUpdateSerializer


# ── Profile Search ────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def profile_search(request):
    """Search public profiles by display_name or short_id.
    GET /profiles/search/?q=alice
    Returns up to 20 matches ordered by display_name.
    """
    q = request.query_params.get('q', '').strip()
    if len(q) < 2:
        return Response({'detail': 'Query must be at least 2 characters.'}, status=status.HTTP_400_BAD_REQUEST)

    results = BitChatIdentity.objects.filter(
        is_public=True,
    ).filter(
        models.Q(display_name__icontains=q) | models.Q(short_id__icontains=q)
    ).order_by('display_name')[:20]

    return Response([{
        'pubkey':               r.pubkey,
        'short_id':             r.short_id,
        'display_name':         r.display_name,
        'bio':                  r.bio,
        'profile_picture_url':  picture_url(r),
    } for r in results])


# ── Profile Get ───────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def profile_get(request, pubkey):
    """Get public profile for any pubkey — no auth required."""
    try:
        identity = BitChatIdentity.objects.get(pubkey=pubkey)
    except BitChatIdentity.DoesNotExist:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    if not identity.is_public:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response({
        'pubkey':                  identity.pubkey,
        'short_id':                identity.short_id,
        'display_name':            identity.display_name,
        'bio':                     identity.bio,
        'profile_picture_url':     picture_url(identity),
        'is_discoverable_nearby':  identity.is_discoverable_nearby,
        'created_at':              identity.created_at,
    })


# ── Own Profile (authenticated read) ─────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def profile_me(request):
    """Return the authenticated user's own full profile — skips is_public check.
    GET /profile/me/
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    return Response({
        'pubkey':                  identity.pubkey,
        'short_id':                identity.short_id,
        'display_name':            identity.display_name,
        'bio':                     identity.bio,
        'profile_picture_url':     picture_url(identity),
        'is_public':               identity.is_public,
        'is_discoverable_nearby':  identity.is_discoverable_nearby,
        'created_at':              identity.created_at,
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
        'pubkey':                  identity.pubkey,
        'short_id':                identity.short_id,
        'display_name':            identity.display_name,
        'bio':                     identity.bio,
        'profile_picture_url':     picture_url(identity),
        'is_public':               identity.is_public,
        'is_discoverable_nearby':  identity.is_discoverable_nearby,
        'created_at':              identity.created_at,
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

    try:
        url = upload_file(image, folder='profiles', resource_type='image')
    except Exception:
        return Response({'detail': 'Upload failed. Please try again.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    identity.profile_picture_url = url
    identity.save(update_fields=['profile_picture_url', 'updated_at'])
    return Response({'url': url})
