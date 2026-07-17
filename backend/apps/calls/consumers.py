import json
from urllib.parse import parse_qs

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncWebsocketConsumer
from django.contrib.auth import get_user_model
from django.utils import timezone
from datetime import timedelta
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.tokens import AccessToken

from bitchat.models import BitChatIdentity, Group, Message, PendingCallOffer, PendingMessage
from apps.push.firebase_utils import send_push

User = get_user_model()

_ROUTABLE_TYPES = {
    'call_offer', 'call_answer', 'call_ice',
    'call_ended', 'call_declined', 'call_busy',
}

_MESSAGE_TYPES = {'dm', 'image', 'voice_note', 'reaction', 'delivery_receipt', 'read_receipt', 'typing'}

# Types that should be saved to DB and push-notified
_STORABLE_TYPES = {'dm', 'image', 'voice_note'}


class SignalingConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for real-time WebRTC call signaling and online messaging.

    Authentication: JWT access token passed as query param:
        wss://server/ws/signal/?token=<access_token>
    """

    async def connect(self):
        import logging
        logger = logging.getLogger(__name__)

        query_string = self.scope.get('query_string', b'').decode()
        params    = parse_qs(query_string)
        token_str = params.get('token', [None])[0]

        if not token_str:
            logger.warning('WS rejected: no token in query string')
            await self.close(code=4001)
            return

        try:
            user_id = await self._validate_token(token_str)
            user    = await self._get_user(user_id)
            if user is None:
                await self.close(code=4001)
                return
            self.pubkey = user.username
        except Exception:
            await self.close(code=4001)
            return

        self.group_name = f'user_{self.pubkey}'
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

        # Replay any pending call offers that arrived while app was backgrounded/killed
        await self._replay_pending_call_offers()

    async def disconnect(self, close_code):
        if hasattr(self, 'group_name'):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)

    async def receive(self, text_data):
        try:
            data = json.loads(text_data)
        except (json.JSONDecodeError, ValueError):
            return

        msg_type      = data.get('type') or data.get('__type', '')
        recipient_pub = data.get('recipientPubkey', '')

        # ── Group message fan-out ─────────────────────────────────────────────
        # Content is encrypted with the group key (server can't read it).
        # In blind groups (members_visible=False) the sender label is
        # rewritten to 'Member N' for everyone except the admin, so members
        # never learn each other's identities.
        if msg_type == 'group_dm':
            await self._fanout_group_message(data)
            return

        # ── Real-time message routing ─────────────────────────────────────────
        if msg_type in _MESSAGE_TYPES:
            if not recipient_pub or len(recipient_pub) > 128:
                return

            data['senderPubkey'] = self.pubkey

            await self.channel_layer.group_send(
                f'user_{recipient_pub}',
                {'type': 'signal.message', 'payload': data},
            )

            if msg_type in _STORABLE_TYPES:
                message_id        = data.get('messageId', '')
                encrypted_content = data.get('encryptedContent', '')
                timestamp         = data.get('timestamp', 0)
                sender_name       = data.get('senderName', '')
                message_type      = data.get('messageType', msg_type)
                duration          = data.get('duration', 0)

                if message_id and encrypted_content:
                    saved = await self._save_message(
                        message_id, self.pubkey, recipient_pub,
                        encrypted_content, message_type, timestamp, sender_name, duration,
                    )
                    if saved:
                        await self._push_notify(recipient_pub, sender_name or 'Someone')

                    await self.send(text_data=json.dumps({
                        'type': 'message_ack',
                        'messageId': message_id,
                        'status': 'sent',
                    }))

            elif msg_type in ('delivery_receipt', 'read_receipt'):
                message_id = data.get('messageId', '')
                new_status = 'delivered' if msg_type == 'delivery_receipt' else 'read'
                if message_id:
                    await self._update_message_status(message_id, recipient_pub, new_status)
            return

        # ── Call signal routing ───────────────────────────────────────────────
        if msg_type not in _ROUTABLE_TYPES or not recipient_pub or len(recipient_pub) > 128:
            return

        data['senderPubkey'] = self.pubkey
        await self.channel_layer.group_send(
            f'user_{recipient_pub}',
            {'type': 'signal.message', 'payload': data},
        )

        if msg_type == 'call_offer':
            # Store offer so it can be replayed if receiver's WS wasn't connected
            call_id = data.get('callId', '')
            if call_id:
                await self._store_call_offer(call_id, recipient_pub, data)
            # FCM push wakes app in background/killed — WS replay delivers the SDP
            caller_name = data.get('callerName') or 'Someone'
            await self._push_notify_call(recipient_pub, caller_name)

        elif msg_type in ('call_answer', 'call_ended', 'call_declined', 'call_busy'):
            # Call resolved — delete pending offer so it isn't replayed on reconnect
            call_id = data.get('callId', '')
            if call_id:
                await self._delete_call_offer(call_id)

    async def signal_message(self, event):
        await self.send(text_data=json.dumps(event['payload']))

    # ── Groups ────────────────────────────────────────────────────────────────

    async def _fanout_group_message(self, data):
        group_id = data.get('groupId', '')
        message_id = data.get('messageId', '')
        ct = data.get('encryptedContent', '')
        ts = data.get('timestamp', 0)
        sender_name = data.get('senderName', '')
        if not group_id or not message_id or not ct:
            return

        info = await self._group_fanout_info(group_id, self.pubkey)
        if info is None:
            return  # not a member — drop
        members, visible, admin_pub, sender_alias, group_name, members_can_message = info

        # Announcement mode: only the admin may post — drop member messages.
        if not members_can_message and self.pubkey != admin_pub:
            return

        for member_pub in members:
            if member_pub == self.pubkey:
                continue
            # Blind group: only the admin sees the real sender.
            reveal = visible or member_pub == admin_pub or self.pubkey == admin_pub
            payload = {
                'type': 'group_dm',
                'groupId': group_id,
                'groupName': group_name,
                'messageId': message_id,
                'encryptedContent': ct,
                'timestamp': ts,
                'senderPubkey': self.pubkey if reveal else '',
                'senderLabel': sender_name if reveal else f'Member {sender_alias}',
            }
            await self.channel_layer.group_send(
                f'user_{member_pub}',
                {'type': 'signal.message', 'payload': payload},
            )
            # Store-and-forward for offline members: the plaintext wrapper
            # carries only the label; the body stays group-key encrypted.
            await self._store_group_pending(member_pub, group_id, message_id,
                                            payload, member_pub == admin_pub or visible or self.pubkey == admin_pub)

    @database_sync_to_async
    def _group_fanout_info(self, group_id, sender_pub):
        try:
            group = Group.objects.get(group_id=group_id)
        except Group.DoesNotExist:
            return None
        rows = list(group.members.values_list('pubkey', 'alias_n'))
        members = [p for p, _ in rows]
        if sender_pub not in members:
            return None
        alias = next((n for p, n in rows if p == sender_pub), 0)
        return (members, group.members_visible, group.admin_pubkey, alias,
                group.name, group.members_can_message)

    @database_sync_to_async
    def _store_group_pending(self, member_pub, group_id, message_id, payload, reveal):
        PendingMessage.objects.get_or_create(
            message_id=f'{message_id}:{member_pub[:16]}',
            defaults={
                'sender_pubkey': group_id,
                'receiver_pubkey': member_pub,
                'encrypted_content': json.dumps({
                    'groupId': group_id,
                    'groupName': payload['groupName'],
                    'messageId': message_id,
                    'ct': payload['encryptedContent'],
                    'senderPubkey': payload['senderPubkey'] if reveal else '',
                    'senderLabel': payload['senderLabel'],
                }),
                'timestamp': payload['timestamp'],
                'message_type': 'group_dm',
            },
        )

    # ── DB helpers ────────────────────────────────────────────────────────────

    @database_sync_to_async
    def _save_message(self, message_id, sender_pub, receiver_pub,
                      encrypted_content, message_type, timestamp, sender_name, duration=0):
        _, created = Message.objects.get_or_create(
            message_id=message_id,
            defaults={
                'sender_pubkey':     sender_pub,
                'receiver_pubkey':   receiver_pub,
                'encrypted_content': encrypted_content,
                'message_type':      message_type,
                'timestamp':         timestamp,
                'sender_name':       sender_name,
                'duration':          duration,
                'status':            Message.STATUS_SENT,
            },
        )
        return created

    @database_sync_to_async
    def _update_message_status(self, message_id, receiver_pub, new_status):
        try:
            msg = Message.objects.get(message_id=message_id, receiver_pubkey=receiver_pub)
            if new_status == 'delivered' and msg.status == Message.STATUS_SENT:
                msg.status       = Message.STATUS_DELIVERED
                msg.delivered_at = timezone.now()
                msg.save(update_fields=['status', 'delivered_at'])
            elif new_status == 'read' and msg.status != Message.STATUS_READ:
                msg.status  = Message.STATUS_READ
                msg.read_at = timezone.now()
                msg.save(update_fields=['status', 'read_at'])
        except Message.DoesNotExist:
            pass

    @database_sync_to_async
    def _push_notify_call(self, receiver_pub, caller_name):
        try:
            identity = BitChatIdentity.objects.get(pubkey=receiver_pub)
            if identity.push_token_fcm:
                send_push(
                    token=identity.push_token_fcm,
                    title='Incoming Call',
                    body=f'{caller_name} is calling you',
                    data={
                        'type': 'call',
                        'senderPubkey': self.pubkey,
                        'senderName': caller_name,
                    },
                    # Data-only: the app's background handler shows the
                    # full-screen CallKit ringing UI instead of a banner.
                    data_only=True,
                )
        except Exception:
            pass

    @database_sync_to_async
    def _push_notify(self, receiver_pub, sender_name):
        try:
            identity = BitChatIdentity.objects.get(pubkey=receiver_pub)
            if identity.push_token_fcm:
                send_push(
                    token=identity.push_token_fcm,
                    title='New Message',
                    body=f'{sender_name} sent you a message',
                    data={'type': 'message', 'senderPubkey': self.pubkey},
                )
        except Exception:
            pass

    @database_sync_to_async
    def _store_call_offer(self, call_id, receiver_pub, payload):
        PendingCallOffer.objects.update_or_create(
            call_id=call_id,
            defaults={
                'caller_pubkey':  self.pubkey,
                'receiver_pubkey': receiver_pub,
                'payload':        json.dumps(payload),
                'expires_at':     timezone.now() + timedelta(seconds=60),
            },
        )

    @database_sync_to_async
    def _delete_call_offer(self, call_id):
        PendingCallOffer.objects.filter(call_id=call_id).delete()

    async def _replay_pending_call_offers(self):
        offers = await self._fetch_pending_offers()
        for offer in offers:
            try:
                payload = json.loads(offer['payload'])
                await self.send(text_data=json.dumps(payload))
            except Exception:
                pass
        if offers:
            await self._delete_delivered_offers(self.pubkey)

    @database_sync_to_async
    def _fetch_pending_offers(self):
        now = timezone.now()
        # Delete stale offers first, then return live ones
        PendingCallOffer.objects.filter(expires_at__lt=now).delete()
        return list(
            PendingCallOffer.objects
            .filter(receiver_pubkey=self.pubkey, expires_at__gte=now)
            .values('payload')
        )

    @database_sync_to_async
    def _delete_delivered_offers(self, receiver_pub):
        PendingCallOffer.objects.filter(receiver_pubkey=receiver_pub).delete()

    # ── Helpers ───────────────────────────────────────────────────────────────

    @staticmethod
    def _parse_token(query_string: str) -> str | None:
        for part in query_string.split('&'):
            if part.startswith('token='):
                return part[len('token='):]
        return None

    @database_sync_to_async
    def _validate_token(self, token_str: str) -> int:
        token = AccessToken(token_str)
        return token['user_id']

    @staticmethod
    async def _get_user(user_id: int):
        try:
            get_user = database_sync_to_async(User.objects.get)
            return await get_user(pk=user_id)
        except User.DoesNotExist:
            return None
