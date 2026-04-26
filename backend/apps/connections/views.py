from django.db import models
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from bitchat.models import BitChatIdentity, ConnectionRequest
from apps.common import identity_or_404, picture_url


def _profile_data(pubkey):
    """Return minimal profile dict for a pubkey, or fallback if not registered."""
    try:
        i = BitChatIdentity.objects.get(pubkey=pubkey)
        return {
            'pubkey':              i.pubkey,
            'short_id':           i.short_id,
            'display_name':       i.display_name,
            'bio':                i.bio,
            'profile_picture_url': picture_url(i),
        }
    except BitChatIdentity.DoesNotExist:
        return {'pubkey': pubkey}


# ── Send connection request ───────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def connection_request_send(request):
    """Send a connection request to another user.
    POST /connections/request/   body: { "to_pubkey": "..." }
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    to_pubkey = request.data.get('to_pubkey', '').strip()
    if not to_pubkey:
        return Response({'detail': 'to_pubkey is required.'}, status=status.HTTP_400_BAD_REQUEST)

    if to_pubkey == identity.pubkey:
        return Response({'detail': 'Cannot connect to yourself.'}, status=status.HTTP_400_BAD_REQUEST)

    # Check target user exists and is public
    if not BitChatIdentity.objects.filter(pubkey=to_pubkey, is_public=True).exists():
        return Response({'detail': 'User not found.'}, status=status.HTTP_404_NOT_FOUND)

    # Check if already connected (accepted in either direction)
    already_connected = ConnectionRequest.objects.filter(
        status=ConnectionRequest.STATUS_ACCEPTED,
    ).filter(
        models.Q(from_pubkey=identity.pubkey, to_pubkey=to_pubkey) |
        models.Q(from_pubkey=to_pubkey, to_pubkey=identity.pubkey)
    ).exists()
    if already_connected:
        return Response({'detail': 'Already connected.'}, status=status.HTTP_400_BAD_REQUEST)

    req, created = ConnectionRequest.objects.get_or_create(
        from_pubkey=identity.pubkey,
        to_pubkey=to_pubkey,
        defaults={'status': ConnectionRequest.STATUS_PENDING},
    )

    if not created:
        if req.status == ConnectionRequest.STATUS_PENDING:
            return Response({'detail': 'Request already sent.'}, status=status.HTTP_400_BAD_REQUEST)
        # Declined before — allow re-request by resetting to pending
        req.status = ConnectionRequest.STATUS_PENDING
        req.save(update_fields=['status', 'updated_at'])

    return Response({'id': req.id, 'status': req.status}, status=status.HTTP_201_CREATED)


# ── Accept connection request ─────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def connection_request_accept(request, pk):
    """Accept an incoming connection request.
    POST /connections/<id>/accept/
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    try:
        req = ConnectionRequest.objects.get(pk=pk, to_pubkey=identity.pubkey, status=ConnectionRequest.STATUS_PENDING)
    except ConnectionRequest.DoesNotExist:
        return Response({'detail': 'Request not found.'}, status=status.HTTP_404_NOT_FOUND)

    req.status = ConnectionRequest.STATUS_ACCEPTED
    req.save(update_fields=['status', 'updated_at'])

    return Response({'id': req.id, 'status': req.status})


# ── Decline connection request ────────────────────────────────────────────────

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def connection_request_decline(request, pk):
    """Decline an incoming connection request (sender is not notified).
    POST /connections/<id>/decline/
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    try:
        req = ConnectionRequest.objects.get(pk=pk, to_pubkey=identity.pubkey, status=ConnectionRequest.STATUS_PENDING)
    except ConnectionRequest.DoesNotExist:
        return Response({'detail': 'Request not found.'}, status=status.HTTP_404_NOT_FOUND)

    req.status = ConnectionRequest.STATUS_DECLINED
    req.save(update_fields=['status', 'updated_at'])

    return Response({'id': req.id, 'status': req.status})


# ── List pending incoming requests ────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def connection_requests_pending(request):
    """List incoming pending connection requests.
    GET /connections/pending/
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    reqs = ConnectionRequest.objects.filter(
        to_pubkey=identity.pubkey,
        status=ConnectionRequest.STATUS_PENDING,
    ).order_by('-created_at')

    return Response([{
        'id':         r.id,
        'from':       _profile_data(r.from_pubkey),
        'created_at': r.created_at,
    } for r in reqs])


# ── List accepted connections ─────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def connections_list(request):
    """List all accepted connections for the current user.
    GET /connections/
    Returns profiles of connected users, ordered by display_name.
    """
    identity, err = identity_or_404(request.user.username)
    if err:
        return err

    reqs = ConnectionRequest.objects.filter(
        status=ConnectionRequest.STATUS_ACCEPTED,
    ).filter(
        models.Q(from_pubkey=identity.pubkey) | models.Q(to_pubkey=identity.pubkey)
    )

    # Collect the OTHER person's pubkey from each accepted request
    other_pubkeys = [
        r.to_pubkey if r.from_pubkey == identity.pubkey else r.from_pubkey
        for r in reqs
    ]

    profiles = {
        i.pubkey: i
        for i in BitChatIdentity.objects.filter(pubkey__in=other_pubkeys)
    }

    result = []
    for pubkey in other_pubkeys:
        if pubkey in profiles:
            i = profiles[pubkey]
            result.append({
                'pubkey':              i.pubkey,
                'short_id':           i.short_id,
                'display_name':       i.display_name,
                'bio':                i.bio,
                'profile_picture_url': picture_url(i),
            })
        else:
            result.append({'pubkey': pubkey})

    result.sort(key=lambda x: x.get('display_name') or '')
    return Response(result)
