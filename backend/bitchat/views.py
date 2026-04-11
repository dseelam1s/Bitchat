import os
import secrets
import uuid

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.files.storage import default_storage
from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.tokens import RefreshToken

from .crypto import verify_nostr_event
from .firebase_utils import send_push
from .models import AuthChallenge, BitChatIdentity, Message, PendingMessage, RestoreAttempt
from .serializers import (
    AuthRequestSerializer,
    BackupRequestSerializer,
    ProfileUpdateSerializer,
    PushTokenRequestSerializer,
    ReceiptSerializer,
    RegisterRequestSerializer,
    RelayMessageSerializer,
    RestoreRequestSerializer,
    SendMessageSerializer,
)

User = get_user_model()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _picture_url(identity):
    return identity.profile_picture_url or None


def _tokens(user):
    refresh = RefreshToken.for_user(user)
    return {'access': str(refresh.access_token), 'refresh': str(refresh)}


def _identity_or_404(pubkey):
    try:
        return BitChatIdentity.objects.get(pubkey=pubkey), None
    except BitChatIdentity.DoesNotExist:
        return None, Response(
            {'detail': 'Register first.'},
            status=status.HTTP_404_NOT_FOUND,
        )


# ── Challenge ─────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def health(request):
    """
    Simple health check — no auth required.
    GET /api/v1/bitchat/health/
    Returns {"status": "ok", "version": "1.0"}
    """
    return Response({'status': 'ok', 'version': '1.0'})


@api_view(['GET'])
@permission_classes([AllowAny])
def challenge(request):
    """
    Issue a one-time random challenge.
    The app signs this with the user's private key and sends it back via /auth/.
    """
    # Prune old challenges to keep table small
    cutoff = timezone.now() - timezone.timedelta(minutes=10)
    AuthChallenge.objects.filter(created_at__lt=cutoff).delete()

    value = secrets.token_hex(32)
    AuthChallenge.objects.create(challenge=value)
    return Response({'challenge': value})


# ── Auth ──────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def auth(request):
    """
    Authenticate by sending a signed Nostr event (kind 27235).
    Creates a Django user for the pubkey on first call.
    Returns JWT access + refresh tokens.
    """
    serializer = AuthRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    event = serializer.validated_data

    if event['kind'] != 27235:
        return Response(
            {'detail': 'Event kind must be 27235.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    # Extract challenge from tags
    challenge_value = None
    for tag in event['tags']:
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == 'challenge':
            challenge_value = tag[1]
            break

    if not challenge_value:
        return Response(
            {'detail': 'Missing challenge tag.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    # Validate challenge: must exist, unused, not expired
    try:
        ch = AuthChallenge.objects.get(challenge=challenge_value, used=False)
    except AuthChallenge.DoesNotExist:
        return Response(
            {'detail': 'Invalid or already used challenge.'},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    if ch.is_expired:
        ch.delete()
        return Response(
            {'detail': 'Challenge expired. Request a new one.'},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    # Verify Schnorr signature
    if not verify_nostr_event(event):
        return Response(
            {'detail': 'Invalid signature.'},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    # Mark challenge used (one-time only)
    ch.used = True
    ch.save(update_fields=['used'])

    pubkey = event['pubkey']

    # Find or create Django user for this pubkey (username = pubkey)
    user, _ = User.objects.get_or_create(
        username=pubkey,
        defaults={'is_active': True},
    )

    is_registered = BitChatIdentity.objects.filter(pubkey=pubkey).exists()
    return Response({**_tokens(user), 'is_registered': is_registered})


# ── Register ──────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def register(request):
    """
    Reserve a unique short ID for the authenticated pubkey.
    Returns recovery_code — shown to user once, must be saved.
    If already registered, returns existing details.
    """
    pubkey = request.user.username

    # Already registered — idempotent, return existing
    try:
        identity = BitChatIdentity.objects.get(pubkey=pubkey)
        return Response({
            'short_id': identity.short_id,
            'recovery_code': identity.recovery_code,
            'already_registered': True,
        })
    except BitChatIdentity.DoesNotExist:
        pass

    serializer = RegisterRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    short_id = serializer.validated_data['short_id']
    display_name = serializer.validated_data['display_name']

    # Short ID taken — Flutter will generate a new keypair and retry
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
        {
            'short_id': identity.short_id,
            'recovery_code': identity.recovery_code,
            'already_registered': False,
        },
        status=status.HTTP_201_CREATED,
    )


# ── Lookup ────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def lookup(request):
    """
    Look up a user by short_id — no auth required.
    GET /api/v1/bitchat/lookup/?short_id=729134
    Falls back to Nostr tag search on the client if this returns 404.
    """
    short_id = request.query_params.get('short_id', '').strip()
    if not short_id or not short_id.isdigit() or len(short_id) != 8:
        return Response(
            {'detail': 'Provide a valid 8-digit short_id.'},
            status=status.HTTP_400_BAD_REQUEST,
        )

    try:
        identity = BitChatIdentity.objects.get(short_id=short_id)
    except BitChatIdentity.DoesNotExist:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response({
        'pubkey': identity.pubkey,
        'short_id': identity.short_id,
        'display_name': identity.display_name,
        'profile_picture_url': _picture_url(identity),
    })


# ── Contacts Backup ───────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def contacts_backup_save(request):
    """
    Save encrypted contact list to server.
    Client encrypts the contact list with NIP-44 before sending — server stores
    ciphertext only and cannot read contact info.
    """
    identity, err = _identity_or_404(request.user.username)
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
    """
    Retrieve the encrypted contact list backup.
    Returns the ciphertext — decrypted on-device using the user's private key.
    """
    identity, err = _identity_or_404(request.user.username)
    if err:
        return err

    return Response({'contacts_backup': identity.contacts_backup or ''})


# ── Backup ────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def backup(request):
    """
    Store an encrypted key backup.
    The user encrypts their private key with their own backup password before
    sending — server stores ciphertext only and can never read the key.
    """
    identity, err = _identity_or_404(request.user.username)
    if err:
        return err

    serializer = BackupRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    identity.encrypted_backup = serializer.validated_data['encrypted_backup']
    identity.save(update_fields=['encrypted_backup', 'updated_at'])
    return Response({'detail': 'Backup stored.'})


# ── Restore ───────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def restore(request):
    """
    Retrieve encrypted backup using short_id only.
    No keypair needed — used after reinstall when the key is gone.
    The backup password (known only to the user) decrypts the blob on-device.
    Rate-limited: locked out for 1 hour after 5 attempts to prevent enumeration.
    """
    serializer = RestoreRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    short_id = serializer.validated_data['short_id']

    # Rate-limit per short_id to prevent bulk harvesting
    attempt, _ = RestoreAttempt.objects.get_or_create(short_id=short_id)
    if attempt.is_locked:
        return Response(
            {'detail': 'Too many attempts. Try again later.'},
            status=status.HTTP_429_TOO_MANY_REQUESTS,
        )

    try:
        identity = BitChatIdentity.objects.get(short_id=short_id)
    except BitChatIdentity.DoesNotExist:
        attempt.attempts += 1
        if attempt.attempts >= 5:
            attempt.locked_until = timezone.now() + timezone.timedelta(hours=1)
        attempt.save()
        return Response(
            {'detail': 'Short ID not found.'},
            status=status.HTTP_404_NOT_FOUND,
        )

    if not identity.encrypted_backup:
        return Response(
            {'detail': 'No backup found. Set up backup first.'},
            status=status.HTTP_404_NOT_FOUND,
        )

    attempt.attempts = 0
    attempt.locked_until = None
    attempt.save()

    return Response({'encrypted_backup': identity.encrypted_backup})


# ── Push Token ────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def push_token(request):
    """Register or update the FCM (Android) or APNs (iOS) push token."""
    identity, err = _identity_or_404(request.user.username)
    if err:
        return err

    serializer = PushTokenRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    platform = serializer.validated_data['platform']
    token = serializer.validated_data['token']

    if platform == 'fcm':
        identity.push_token_fcm = token
        identity.save(update_fields=['push_token_fcm', 'updated_at'])
    else:
        identity.push_token_apns = token
        identity.save(update_fields=['push_token_apns', 'updated_at'])

    return Response({'detail': 'Token registered.'})


# ── Profile ───────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
def profile_get(request, pubkey):
    """Get public profile for any pubkey — no auth required."""
    try:
        identity = BitChatIdentity.objects.get(pubkey=pubkey)
    except BitChatIdentity.DoesNotExist:
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

    return Response({
        'pubkey': identity.pubkey,
        'short_id': identity.short_id,
        'display_name': identity.display_name,
        'profile_picture_url': _picture_url(identity),
        'created_at': identity.created_at,
    })


@api_view(['PATCH'])
@permission_classes([IsAuthenticated])
def profile_update(request):
    """Update display_name or profile_picture for the authenticated user."""
    identity, err = _identity_or_404(request.user.username)
    if err:
        return err

    serializer = ProfileUpdateSerializer(identity, data=request.data, partial=True)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    serializer.save()
    return Response({
        'pubkey': identity.pubkey,
        'short_id': identity.short_id,
        'display_name': identity.display_name,
        'profile_picture_url': _picture_url(identity),
        'created_at': identity.created_at,
    })


# ── Profile Picture Upload ────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def profile_picture_upload(request):
    """Upload a profile picture. Returns the public URL."""
    identity, err = _identity_or_404(request.user.username)
    if err:
        return err

    image = request.FILES.get('image')
    if not image:
        return Response({'detail': 'No image provided.'}, status=status.HTTP_400_BAD_REQUEST)

    # Validate file type
    allowed = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'}
    if image.content_type not in allowed:
        return Response({'detail': 'Invalid image type.'}, status=status.HTTP_400_BAD_REQUEST)

    # Limit size to 2MB
    if image.size > 2 * 1024 * 1024:
        return Response({'detail': 'Image too large (max 2MB).'}, status=status.HTTP_400_BAD_REQUEST)

    # Save with a unique filename
    ext = os.path.splitext(image.name)[1].lower() or '.jpg'
    filename = f'profile_pictures/{uuid.uuid4().hex}{ext}'
    saved_path = default_storage.save(filename, image)

    # Build absolute URL
    url = request.build_absolute_uri(settings.MEDIA_URL + saved_path)

    # Update identity
    identity.profile_picture_url = url
    identity.save(update_fields=['profile_picture_url', 'updated_at'])

    return Response({'url': url})


# ── Message Image Upload ──────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_image_upload(request):
    """Upload an image to attach to a message. Returns the public URL.

    Images are stored at message_images/<uuid>.<ext>.
    The URL is embedded inside the NIP-44 encrypted DM payload on the client,
    so the server only stores the image bytes — never the association to sender/recipient.
    """
    image = request.FILES.get('image')
    if not image:
        return Response({'detail': 'No image provided.'}, status=status.HTTP_400_BAD_REQUEST)

    allowed = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'}
    if image.content_type not in allowed:
        return Response({'detail': 'Invalid image type.'}, status=status.HTTP_400_BAD_REQUEST)

    # 5MB limit — client already compresses to 800×800 before upload
    if image.size > 5 * 1024 * 1024:
        return Response({'detail': 'Image too large (max 5MB).'}, status=status.HTTP_400_BAD_REQUEST)

    ext = os.path.splitext(image.name)[1].lower() or '.jpg'
    filename = f'message_images/{uuid.uuid4().hex}{ext}'
    saved_path = default_storage.save(filename, image)
    url = request.build_absolute_uri(settings.MEDIA_URL + saved_path)

    return Response({'url': url})


# ── Message Audio Upload ──────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_audio_upload(request):
    """Upload a voice note to attach to a message. Returns the public URL.

    The URL is embedded inside the NIP-44 encrypted DM — server stores only
    the audio bytes, never the association to sender/recipient.
    Max 5MB. Voice notes at 16kbps are ~120KB for 60 seconds.
    """
    audio = request.FILES.get('audio')
    if not audio:
        return Response({'detail': 'No audio provided.'}, status=status.HTTP_400_BAD_REQUEST)

    allowed = {'audio/mp4', 'audio/m4a', 'audio/aac', 'audio/mpeg',
               'audio/ogg', 'audio/wav', 'audio/webm', 'application/octet-stream'}
    if audio.content_type not in allowed:
        return Response({'detail': 'Invalid audio type.'}, status=status.HTTP_400_BAD_REQUEST)

    if audio.size > 5 * 1024 * 1024:
        return Response({'detail': 'Audio too large (max 5MB).'}, status=status.HTTP_400_BAD_REQUEST)

    ext = os.path.splitext(audio.name)[1].lower() or '.m4a'
    filename = f'message_audio/{uuid.uuid4().hex}{ext}'
    saved_path = default_storage.save(filename, audio)
    url = request.build_absolute_uri(settings.MEDIA_URL + saved_path)

    return Response({'url': url})


# ── Push Notify ───────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def notify(request):
    """
    Send a push notification to a recipient.
    Called by the sender after sending a message.
    """
    recipient_pubkey = request.data.get('recipient_pubkey', '').strip()
    sender_name = request.data.get('sender_name', 'Someone').strip()
    notification_type = request.data.get('notification_type', 'message').strip()

    if not recipient_pubkey:
        return Response({'detail': 'recipient_pubkey required.'}, status=status.HTTP_400_BAD_REQUEST)

    try:
        identity = BitChatIdentity.objects.get(pubkey=recipient_pubkey)
    except BitChatIdentity.DoesNotExist:
        return Response({'ok': True})  # silent — don't leak whether pubkey exists

    # Use authenticated user's pubkey — never trust client-provided sender identity
    sender_pubkey = request.user.username
    if notification_type == 'call':
        title = 'Incoming Call'
        body = f'{sender_name} is calling you'
    else:
        title = 'New Message'
        body = f'{sender_name} sent you a message'

    if identity.push_token_fcm:
        send_push(
            token=identity.push_token_fcm,
            title=title,
            body=body,
            data={'type': notification_type, 'senderPubkey': sender_pubkey},
        )

    return Response({'ok': True})


# ── Mesh Relay ────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def relay_message(request):
    """
    Any internet-connected mesh device (C) posts a message here when it receives
    a BLE message not meant for it. Server stores the encrypted payload and sends
    a push to the receiver (B) if B has a registered push token.

    No auth required — relay is a public-good action.
    Content is NIP-44 ciphertext; server cannot read it.
    Idempotent: duplicate message_ids are silently ignored.
    Auto-cleaned after 7 days.
    """
    serializer = RelayMessageSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    data = serializer.validated_data

    # Idempotent — ignore duplicate relays from multiple C devices
    _, created = PendingMessage.objects.get_or_create(
        message_id=data['message_id'],
        defaults={
            'sender_pubkey': data['sender_pubkey'],
            'receiver_pubkey': data['receiver_pubkey'],
            'encrypted_content': data['encrypted_content'],
            'timestamp': data['timestamp'],
            'message_type': data.get('message_type', 'dm'),
        },
    )

    if created:
        # Try to push-notify B — silent if B has no token or isn't registered
        try:
            identity = BitChatIdentity.objects.get(pubkey=data['receiver_pubkey'])
            sender_name = data.get('sender_name') or 'Someone'
            if identity.push_token_fcm:
                send_push(
                    token=identity.push_token_fcm,
                    title='New Message',
                    body=f'{sender_name} sent you a message',
                    data={'type': 'message', 'senderPubkey': data['sender_pubkey']},
                )
        except BitChatIdentity.DoesNotExist:
            pass  # B not registered — message stored, no push

    return Response({'ok': True})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def pending_messages(request):
    """
    B fetches all pending mesh-relayed messages on app open (when internet available).
    Returns encrypted payloads — decrypted on-device.
    Messages are marked delivered after this call.
    Old messages (>7 days) are auto-cleaned on each fetch.
    """
    pubkey = request.user.username

    # Cleanup stale messages to keep DB lean
    cutoff = timezone.now() - timezone.timedelta(days=7)
    PendingMessage.objects.filter(created_at__lt=cutoff).delete()

    msgs = PendingMessage.objects.filter(
        receiver_pubkey=pubkey,
        delivered=False,
    ).order_by('timestamp')

    result = [
        {
            'message_id': m.message_id,
            'sender_pubkey': m.sender_pubkey,
            'receiver_pubkey': m.receiver_pubkey,
            'encrypted_content': m.encrypted_content,
            'timestamp': m.timestamp,
            'message_type': m.message_type,
        }
        for m in msgs
    ]

    # Mark all as delivered in one query
    msgs.update(delivered=True)

    return Response({'messages': result})


# ── Online Messaging (WhatsApp-style) ─────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_send(request):
    """
    Send a message via server. Authenticated sender only.
    Server stores NIP-44 ciphertext — cannot read content.
    Immediately pushes FCM notification to receiver if they have a token.
    Idempotent: duplicate message_ids are silently ignored.
    """
    serializer = SendMessageSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    data       = serializer.validated_data
    sender_pub = request.user.username  # pubkey is the Django username

    msg, created = Message.objects.get_or_create(
        message_id=data['message_id'],
        defaults={
            'sender_pubkey':     sender_pub,
            'receiver_pubkey':   data['receiver_pubkey'],
            'encrypted_content': data['encrypted_content'],
            'message_type':      data.get('message_type', 'dm'),
            'timestamp':         data['timestamp'],
            'sender_name':       data.get('sender_name', ''),
            'duration':          data.get('duration', 0),
            'status':            Message.STATUS_SENT,
        },
    )

    if created:
        # Push-notify receiver — fire and forget
        try:
            identity = BitChatIdentity.objects.get(pubkey=data['receiver_pubkey'])
            sender_name = data.get('sender_name') or 'Someone'
            if identity.push_token_fcm:
                send_push(
                    token=identity.push_token_fcm,
                    title='New Message',
                    body=f'{sender_name} sent you a message',
                    data={'type': 'message', 'senderPubkey': sender_pub},
                )
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'ok': True, 'status': msg.status}, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def message_fetch(request):
    """
    Fetch all undelivered messages for the authenticated user.
    Called on app open and when internet reconnects.
    Marks fetched messages as 'delivered' and sends delivery receipt push to sender.
    Auto-cleans messages older than 30 days.
    """
    pubkey = request.user.username

    # Cleanup old messages
    cutoff = timezone.now() - timezone.timedelta(days=30)
    Message.objects.filter(created_at__lt=cutoff).delete()

    msgs = Message.objects.filter(
        receiver_pubkey=pubkey,
        status=Message.STATUS_SENT,
    ).order_by('timestamp')

    result = [
        {
            'message_id':        m.message_id,
            'sender_pubkey':     m.sender_pubkey,
            'receiver_pubkey':   m.receiver_pubkey,
            'encrypted_content': m.encrypted_content,
            'message_type':      m.message_type,
            'timestamp':         m.timestamp,
            'sender_name':       m.sender_name,
            'duration':          m.duration,
            'status':            m.status,
        }
        for m in msgs
    ]

    # Mark as delivered + timestamp
    msgs.update(status=Message.STATUS_DELIVERED, delivered_at=timezone.now())

    # Push delivery receipts to senders
    for m in msgs:
        try:
            sender_identity = BitChatIdentity.objects.get(pubkey=m.sender_pubkey)
            if sender_identity.push_token_fcm:
                send_push(
                    token=sender_identity.push_token_fcm,
                    title='Message delivered',
                    body='Your message was delivered',
                )
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'messages': result})


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_receipt(request):
    """
    Mark a message as read. Sends a read receipt push to the sender.
    Called when receiver opens and reads a conversation.
    """
    serializer = ReceiptSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    pubkey     = request.user.username
    message_id = serializer.validated_data['message_id']
    new_status = serializer.validated_data['status']

    try:
        msg = Message.objects.get(message_id=message_id, receiver_pubkey=pubkey)
    except Message.DoesNotExist:
        return Response({'ok': True})  # silent — don't leak existence

    if new_status == 'read' and msg.status != Message.STATUS_READ:
        msg.status  = Message.STATUS_READ
        msg.read_at = timezone.now()
        msg.save(update_fields=['status', 'read_at'])

        # Push read receipt to sender
        try:
            sender_identity = BitChatIdentity.objects.get(pubkey=msg.sender_pubkey)
            if sender_identity.push_token_fcm:
                send_push(
                    token=sender_identity.push_token_fcm,
                    title='Message read',
                    body='Your message was read',
                )
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'ok': True})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def message_status(request):
    """
    Poll status of sent messages (delivered/read).
    Sender calls this to sync tick marks (✓ sent, ✓✓ delivered, blue ✓✓ read).
    Returns status for messages sent by the authenticated user in the last 7 days.
    """
    pubkey = request.user.username
    since  = timezone.now() - timezone.timedelta(days=7)

    msgs = Message.objects.filter(
        sender_pubkey=pubkey,
        created_at__gte=since,
    ).values('message_id', 'status')

    return Response({'statuses': list(msgs)})
