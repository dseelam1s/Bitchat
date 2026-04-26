from rest_framework import serializers
from bitchat.models import BitChatIdentity


class ProfileUpdateSerializer(serializers.ModelSerializer):
    bio = serializers.CharField(max_length=150, allow_blank=True, required=False)

    class Meta:
        model  = BitChatIdentity
        fields = ['display_name', 'profile_picture_url', 'bio', 'is_public', 'is_discoverable_nearby']
