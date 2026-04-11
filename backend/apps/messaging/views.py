import os
import uuid

from django.conf import settings
from django.core.files.storage import default_storage
from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity, Message
from apps.push.firebase_utils import send_push
from .serializers import ReceiptSerializer, SendMessageSerializer


# ── Send ──────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_send(request):
    """Send a message via server. Idempotent on message_id."""
    serializer = SendMessageSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    data       = serializer.validated_data
    sender_pub = request.user.username

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
        try:
            identity    = BitChatIdentity.objects.get(pubkey=data['receiver_pubkey'])
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

    return Response(
        {'ok': True, 'status': msg.status},
        status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
    )


# ── Fetch ─────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def message_fetch(request):
    """Fetch undelivered messages for the authenticated user."""
    pubkey = request.user.username

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

    msgs.update(status=Message.STATUS_DELIVERED, delivered_at=timezone.now())

    for m in msgs:
        try:
            sender_identity = BitChatIdentity.objects.get(pubkey=m.sender_pubkey)
            if sender_identity.push_token_fcm:
                send_push(token=sender_identity.push_token_fcm, title='Message delivered', body='Your message was delivered')
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'messages': result})


# ── Receipt ───────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_receipt(request):
    """Mark a message as read. Sends read receipt push to sender."""
    serializer = ReceiptSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    pubkey     = request.user.username
    message_id = serializer.validated_data['message_id']
    new_status = serializer.validated_data['status']

    try:
        msg = Message.objects.get(message_id=message_id, receiver_pubkey=pubkey)
    except Message.DoesNotExist:
        return Response({'ok': True})

    if new_status == 'read' and msg.status != Message.STATUS_READ:
        msg.status  = Message.STATUS_READ
        msg.read_at = timezone.now()
        msg.save(update_fields=['status', 'read_at'])

        try:
            sender_identity = BitChatIdentity.objects.get(pubkey=msg.sender_pubkey)
            if sender_identity.push_token_fcm:
                send_push(token=sender_identity.push_token_fcm, title='Message read', body='Your message was read')
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'ok': True})


# ── Status ────────────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def message_status(request):
    """Poll delivery/read status of sent messages (for tick marks)."""
    pubkey = request.user.username
    since  = timezone.now() - timezone.timedelta(days=7)

    msgs = Message.objects.filter(
        sender_pubkey=pubkey,
        created_at__gte=since,
    ).values('message_id', 'status')

    return Response({'statuses': list(msgs)})


# ── Image Upload ──────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_image_upload(request):
    """Upload an image to attach to a message. URL embedded in NIP-44 payload."""
    image = request.FILES.get('image')
    if not image:
        return Response({'detail': 'No image provided.'}, status=status.HTTP_400_BAD_REQUEST)

    allowed = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'}
    if image.content_type not in allowed:
        return Response({'detail': 'Invalid image type.'}, status=status.HTTP_400_BAD_REQUEST)

    if image.size > 5 * 1024 * 1024:
        return Response({'detail': 'Image too large (max 5MB).'}, status=status.HTTP_400_BAD_REQUEST)

    ext      = os.path.splitext(image.name)[1].lower() or '.jpg'
    filename = f'message_images/{uuid.uuid4().hex}{ext}'
    saved    = default_storage.save(filename, image)
    url      = request.build_absolute_uri(settings.MEDIA_URL + saved)
    return Response({'url': url})


# ── Audio Upload ──────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def message_audio_upload(request):
    """Upload a voice note. URL embedded in NIP-44 payload."""
    audio = request.FILES.get('audio')
    if not audio:
        return Response({'detail': 'No audio provided.'}, status=status.HTTP_400_BAD_REQUEST)

    allowed = {'audio/mp4', 'audio/m4a', 'audio/aac', 'audio/mpeg',
               'audio/ogg', 'audio/wav', 'audio/webm', 'application/octet-stream'}
    if audio.content_type not in allowed:
        return Response({'detail': 'Invalid audio type.'}, status=status.HTTP_400_BAD_REQUEST)

    if audio.size > 5 * 1024 * 1024:
        return Response({'detail': 'Audio too large (max 5MB).'}, status=status.HTTP_400_BAD_REQUEST)

    ext      = os.path.splitext(audio.name)[1].lower() or '.m4a'
    filename = f'message_audio/{uuid.uuid4().hex}{ext}'
    saved    = default_storage.save(filename, audio)
    url      = request.build_absolute_uri(settings.MEDIA_URL + saved)
    return Response({'url': url})
