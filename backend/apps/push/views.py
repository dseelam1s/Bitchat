from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity
from apps.common import identity_or_404
from .serializers import PushTokenRequestSerializer
from .firebase_utils import send_push


# ── Push Token ────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def push_token(request):
    """Register or update FCM / APNs push token."""
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    serializer = PushTokenRequestSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    platform = serializer.validated_data['platform']
    token    = serializer.validated_data['token']

    if platform == 'fcm':
        identity.push_token_fcm = token
        identity.save(update_fields=['push_token_fcm', 'updated_at'])
    else:
        identity.push_token_apns = token
        identity.save(update_fields=['push_token_apns', 'updated_at'])

    return Response({'detail': 'Token registered.'})


# ── Notify ────────────────────────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def notify(request):
    """Send a push notification to a recipient (message or call)."""
    recipient_pubkey    = request.data.get('recipient_pubkey', '').strip()
    sender_name         = request.data.get('sender_name', 'Someone').strip()
    notification_type   = request.data.get('notification_type', 'message').strip()

    if not recipient_pubkey:
        return Response({'detail': 'recipient_pubkey required.'}, status=status.HTTP_400_BAD_REQUEST)

    try:
        identity = BitChatIdentity.objects.get(pubkey=recipient_pubkey)
    except BitChatIdentity.DoesNotExist:
        return Response({'ok': True})  # silent — don't leak existence

    # Use authenticated user's pubkey — never trust client-provided sender identity
    sender_pubkey = request.user.username

    if notification_type == 'call':
        title = 'Incoming Call'
        body  = f'{sender_name} is calling you'
    else:
        title = 'New Message'
        body  = f'{sender_name} sent you a message'

    if identity.push_token_fcm:
        send_push(
            token=identity.push_token_fcm,
            title=title,
            body=body,
            data={'type': notification_type, 'senderPubkey': sender_pubkey},
        )

    return Response({'ok': True})
