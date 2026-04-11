"""Shared helpers used across multiple domain apps."""
from rest_framework.response import Response
from rest_framework import status
from rest_framework_simplejwt.tokens import RefreshToken

from bitchat.models import BitChatIdentity


def picture_url(identity):
    return identity.profile_picture_url or None


def make_tokens(user):
    refresh = RefreshToken.for_user(user)
    return {'access': str(refresh.access_token), 'refresh': str(refresh)}


def identity_or_404(pubkey):
    """Return (identity, None) or (None, 404 Response)."""
    try:
        return BitChatIdentity.objects.get(pubkey=pubkey), None
    except BitChatIdentity.DoesNotExist:
        return None, Response(
            {'detail': 'Register first.'},
            status=status.HTTP_404_NOT_FOUND,
        )
