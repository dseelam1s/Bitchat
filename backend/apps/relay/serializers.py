from rest_framework import serializers


class RelayMessageSerializer(serializers.Serializer):
    message_id        = serializers.CharField(max_length=128)
    sender_pubkey     = serializers.CharField(max_length=128)
    receiver_pubkey   = serializers.CharField(max_length=128)
    encrypted_content = serializers.CharField()
    timestamp         = serializers.IntegerField()
    message_type      = serializers.CharField(max_length=32, default='dm', required=False)
    sender_name       = serializers.CharField(max_length=100, allow_blank=True, required=False, default='Someone')
