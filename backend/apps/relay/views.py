from django.utils import timezone
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity, PendingMessage
from apps.push.firebase_utils import send_push
from .serializers import RelayMessageSerializer


# ── Relay ─────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([AllowAny])
def relay_message(request):
    """
    Internet-connected mesh device (C) forwards a BLE message it received
    but wasn't the intended recipient of. No auth required — relay is a public good.
    Idempotent on message_id.
    """
    serializer = RelayMessageSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=400)

    data = serializer.validated_data

    _, created = PendingMessage.objects.get_or_create(
        message_id=data['message_id'],
        defaults={
            'sender_pubkey':     data['sender_pubkey'],
            'receiver_pubkey':   data['receiver_pubkey'],
            'encrypted_content': data['encrypted_content'],
            'timestamp':         data['timestamp'],
            'message_type':      data.get('message_type', 'dm'),
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
                    data={'type': 'message', 'senderPubkey': data['sender_pubkey']},
                )
        except BitChatIdentity.DoesNotExist:
            pass

    return Response({'ok': True})


# ── Pending Messages ──────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def pending_messages(request):
    """Fetch pending mesh-relayed messages on app open. Marks them delivered."""
    pubkey = request.user.username

    cutoff = timezone.now() - timezone.timedelta(days=7)
    PendingMessage.objects.filter(created_at__lt=cutoff).delete()

    msgs = PendingMessage.objects.filter(
        receiver_pubkey=pubkey,
        delivered=False,
    ).order_by('timestamp')

    result = [
        {
            'message_id':        m.message_id,
            'sender_pubkey':     m.sender_pubkey,
            'receiver_pubkey':   m.receiver_pubkey,
            'encrypted_content': m.encrypted_content,
            'timestamp':         m.timestamp,
            'message_type':      m.message_type,
        }
        for m in msgs
    ]

    # NOT marked delivered on fetch — the client acks each row it actually
    # persisted via messages/pending/ack/. A crash mid-processing therefore
    # re-delivers instead of silently losing the message.
    return Response({'messages': result})


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def pending_ack(request):
    """Client confirms it persisted these pending messages. Body: {message_ids: []}"""
    ids = request.data.get('message_ids', [])
    if not isinstance(ids, list) or len(ids) > 500 \
            or not all(isinstance(i, str) for i in ids):
        return Response({'detail': 'Invalid payload.'}, status=400)
    if ids:
        PendingMessage.objects.filter(
            receiver_pubkey=request.user.username,
            message_id__in=ids,
        ).update(delivered=True)
    return Response({'ok': True})
