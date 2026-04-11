from rest_framework import serializers
from bitchat.models import BitChatIdentity


class ProfileUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model  = BitChatIdentity
        fields = ['display_name', 'profile_picture_url']
