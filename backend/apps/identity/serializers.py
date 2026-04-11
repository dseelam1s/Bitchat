from rest_framework import serializers
from bitchat.models import BitChatIdentity


class AuthRequestSerializer(serializers.Serializer):
    """Signed Nostr event (kind 27235) proving private key possession."""
    id         = serializers.CharField(min_length=64, max_length=64)
    pubkey     = serializers.CharField(min_length=64, max_length=64)
    created_at = serializers.IntegerField()
    kind       = serializers.IntegerField()
    tags       = serializers.ListField()
    content    = serializers.CharField(allow_blank=True)
    sig        = serializers.CharField(min_length=128, max_length=128)


class RegisterRequestSerializer(serializers.Serializer):
    short_id     = serializers.CharField(min_length=8, max_length=8)
    display_name = serializers.CharField(max_length=100, allow_blank=True, default='')

    def validate_short_id(self, value):
        if not value.isdigit():
            raise serializers.ValidationError('short_id must be 8 digits.')
        return value


class RestoreRequestSerializer(serializers.Serializer):
    short_id = serializers.CharField(min_length=8, max_length=8)


class BackupRequestSerializer(serializers.Serializer):
    encrypted_backup = serializers.CharField()
