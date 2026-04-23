from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity, Message
from apps.common import upload_file
from apps.push.firebase_utils import send_push  # used in message_send
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

    try:
        url = upload_file(image, folder='images', resource_type='image')
        return Response({'url': url})
    except Exception:
        return Response({'detail': 'Upload failed. Please try again.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


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

    try:
        # Cloudinary uses resource_type='video' for all audio formats
        url = upload_file(audio, folder='audio', resource_type='video')
        return Response({'url': url})
    except Exception:
        return Response({'detail': 'Upload failed. Please try again.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
