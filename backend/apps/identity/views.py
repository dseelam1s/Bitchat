import secrets

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from bitchat.models import AuthChallenge, BitChatIdentity, RestoreAttempt
from apps.common import identity_or_404, make_tokens, picture_url
from .crypto import verify_nostr_event
from .serializers import (
    AuthRequestSerializer,
    BackupRequestSerializer,
    RegisterRequestSerializer,
    RestoreRequestSerializer,
)

User = get_user_model()


# ── Health ────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def health(request):
    """GET /api/v1/bitchat/health/"""
    return Response({'status': 'ok', 'version': '1.0'})


# ── Challenge ─────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def challenge(request):
    """Issue a one-time random challenge for Nostr auth."""
    cutoff = timezone.now() - timezone.timedelta(minutes=10)
    AuthChallenge.objects.filter(created_at__lt=cutoff).delete()

    value = secrets.token_hex(32)
    AuthChallenge.objects.create(challenge=value)
    return Response({'challenge': value})


# ── Auth ──────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def auth(request):
    """Authenticate via signed Nostr event (kind 27235). Returns JWT tokens."""
    serializer = AuthRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    event = serializer.validated_data

    if event['kind'] != 27235:
        return Response({'detail': 'Event kind must be 27235.'}, status=status.HTTP_400_BAD_REQUEST)

    challenge_value = None
    for tag in event['tags']:
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == 'challenge':
            challenge_value = tag[1]
            break

    if not challenge_value:
        return Response({'detail': 'Missing challenge tag.'}, status=status.HTTP_400_BAD_REQUEST)

    try:
        ch = AuthChallenge.objects.get(challenge=challenge_value, used=False)
    except AuthChallenge.DoesNotExist:
        return Response({'detail': 'Invalid or already used challenge.'}, status=status.HTTP_401_UNAUTHORIZED)

    if ch.is_expired:
        ch.delete()
        return Response({'detail': 'Challenge expired. Request a new one.'}, status=status.HTTP_401_UNAUTHORIZED)

    if not verify_nostr_event(event):
        return Response({'detail': 'Invalid signature.'}, status=status.HTTP_401_UNAUTHORIZED)

    ch.used = True
    ch.save(update_fields=['used'])

    pubkey = event['pubkey']
    user, _ = User.objects.get_or_create(username=pubkey, defaults={'is_active': True})
    is_registered = BitChatIdentity.objects.filter(pubkey=pubkey).exists()
    return Response({**make_tokens(user), 'is_registered': is_registered})


# ── Register ──────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def register(request):
    """Reserve a unique 8-digit short ID for the authenticated pubkey."""
    pubkey = request.user.username

    try:
        identity = BitChatIdentity.objects.get(pubkey=pubkey)
        return Response({
            'short_id': identity.short_id,
            'already_registered': True,
        })
    except BitChatIdentity.DoesNotExist:
        pass

    serializer = RegisterRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    short_id     = serializer.validated_data['short_id']
    display_name = serializer.validated_data['display_name']

    if BitChatIdentity.objects.filter(short_id=short_id).exists():
        return Response(
            {'detail': 'short_id_taken', 'short_id': short_id},
            status=status.HTTP_409_CONFLICT,
        )

    identity = BitChatIdentity.objects.create(
        user=request.user,
        pubkey=pubkey,
        short_id=short_id,
        display_name=display_name,
    )
    return Response(
        {'short_id': identity.short_id, 'already_registered': False},
        status=status.HTTP_201_CREATED,
    )


# ── Lookup ────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def lookup(request):
    """GET /api/v1/bitchat/lookup/?short_id=12345678"""
    short_id = request.query_params.get('short_id', '').strip()
    if not short_id or not short_id.isdigit() or len(short_id) != 8:
        return Response({'detail': 'Provide a valid 8-digit short_id.'}, status=status.HTTP_400_BAD_REQUEST)

    try:
        identity = BitChatIdentity.objects.get(short_id=short_id)
    except BitChatIdentity.DoesNotExist:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response({
        'pubkey': identity.pubkey,
        'short_id': identity.short_id,
        'display_name': identity.display_name,
        'profile_picture_url': picture_url(identity),
    })


# ── Key Backup ────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def backup(request):
    """Store client-encrypted key backup (ciphertext only)."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    serializer = BackupRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    identity.encrypted_backup = serializer.validated_data['encrypted_backup']
    identity.save(update_fields=['encrypted_backup', 'updated_at'])
    return Response({'detail': 'Backup stored.'})


@api_view(['POST'])
@permission_classes([AllowAny])
def restore(request):
    """Retrieve encrypted backup by short_id (no auth — key is gone on reinstall)."""
    serializer = RestoreRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    short_id = serializer.validated_data['short_id']
    attempt, _ = RestoreAttempt.objects.get_or_create(short_id=short_id)
    if attempt.is_locked:
        return Response({'detail': 'Too many attempts. Try again later.'}, status=status.HTTP_429_TOO_MANY_REQUESTS)

    try:
        identity = BitChatIdentity.objects.get(short_id=short_id)
    except BitChatIdentity.DoesNotExist:
        attempt.attempts += 1
        if attempt.attempts >= 5:
            attempt.locked_until = timezone.now() + timezone.timedelta(hours=1)
        attempt.save()
        return Response({'detail': 'Short ID not found.'}, status=status.HTTP_404_NOT_FOUND)

    if not identity.encrypted_backup:
        return Response({'detail': 'No backup found.'}, status=status.HTTP_404_NOT_FOUND)

    attempt.attempts = 0
    attempt.locked_until = None
    attempt.save()
    return Response({'encrypted_backup': identity.encrypted_backup})


# ── Contacts Backup ───────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def contacts_backup_save(request):
    """Save encrypted contact list (client encrypts before sending)."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    blob = request.data.get('contacts_backup', '')
    if not isinstance(blob, str) or len(blob) > 500_000:
        return Response({'detail': 'Invalid payload.'}, status=status.HTTP_400_BAD_REQUEST)

    identity.contacts_backup = blob
    identity.save(update_fields=['contacts_backup', 'updated_at'])
    return Response({'detail': 'Contacts backed up.'})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def contacts_backup_fetch(request):
    """Retrieve encrypted contact list backup."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err
    return Response({'contacts_backup': identity.contacts_backup or ''})
