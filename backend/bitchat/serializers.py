from rest_framework import serializers
from .models import BitChatIdentity


class ChallengeResponseSerializer(serializers.Serializer):
    challenge = serializers.CharField()


class AuthRequestSerializer(serializers.Serializer):
    """Signed Nostr event (kind 27235) proving private key possession."""
    id = serializers.CharField(min_length=64, max_length=64)
    pubkey = serializers.CharField(min_length=64, max_length=64)
    created_at = serializers.IntegerField()
    kind = serializers.IntegerField()
    tags = serializers.ListField()
    content = serializers.CharField(allow_blank=True)
    sig = serializers.CharField(min_length=128, max_length=128)


class RegisterRequestSerializer(serializers.Serializer):
    short_id = serializers.CharField(min_length=8, max_length=8)
    display_name = serializers.CharField(max_length=100, allow_blank=True, default='')

    def validate_short_id(self, value):
        if not value.isdigit():
            raise serializers.ValidationError('short_id must be 8 digits.')
        return value


class LookupResponseSerializer(serializers.Serializer):
    pubkey = serializers.CharField()
    short_id = serializers.CharField()
    display_name = serializers.CharField()
    profile_picture_url = serializers.CharField(allow_null=True)


class BackupRequestSerializer(serializers.Serializer):
    encrypted_backup = serializers.CharField()


class RestoreRequestSerializer(serializers.Serializer):
    short_id = serializers.CharField(min_length=8, max_length=8)


class PushTokenRequestSerializer(serializers.Serializer):
    token = serializers.CharField()
    platform = serializers.ChoiceField(choices=['fcm', 'apns'])


class ProfileUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = BitChatIdentity
        fields = ['display_name', 'profile_picture_url']


class RelayMessageSerializer(serializers.Serializer):
    message_id = serializers.CharField(max_length=128)
    sender_pubkey = serializers.CharField(max_length=128)
    receiver_pubkey = serializers.CharField(max_length=128)
    encrypted_content = serializers.CharField()
    timestamp = serializers.IntegerField()
    message_type = serializers.CharField(max_length=32, default='dm', required=False)
    sender_name = serializers.CharField(max_length=100, allow_blank=True, required=False, default='Someone')


class SendMessageSerializer(serializers.Serializer):
    message_id        = serializers.CharField(max_length=128)
    receiver_pubkey   = serializers.CharField(max_length=128)
    encrypted_content = serializers.CharField()
    message_type      = serializers.CharField(max_length=32, default='dm', required=False)
    timestamp         = serializers.IntegerField()
    sender_name       = serializers.CharField(max_length=100, allow_blank=True, required=False, default='')
    duration          = serializers.IntegerField(default=0, required=False)  # seconds for voice notes


class ReceiptSerializer(serializers.Serializer):
    message_id = serializers.CharField(max_length=128)
    status     = serializers.ChoiceField(choices=['delivered', 'read'])
