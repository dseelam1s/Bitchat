from rest_framework import serializers


class PushTokenRequestSerializer(serializers.Serializer):
    token    = serializers.CharField()
    platform = serializers.ChoiceField(choices=['fcm', 'apns'])
