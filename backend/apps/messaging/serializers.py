from rest_framework import serializers


class SendMessageSerializer(serializers.Serializer):
    message_id        = serializers.CharField(max_length=128)
    receiver_pubkey   = serializers.CharField(max_length=128)
    encrypted_content = serializers.CharField()
    message_type      = serializers.CharField(max_length=32, default='dm', required=False)
    timestamp         = serializers.IntegerField()
    sender_name       = serializers.CharField(max_length=100, allow_blank=True, required=False, default='')
    duration          = serializers.IntegerField(default=0, required=False)


class ReceiptSerializer(serializers.Serializer):
    message_id = serializers.CharField(max_length=128)
    status     = serializers.ChoiceField(choices=['delivered', 'read'])
