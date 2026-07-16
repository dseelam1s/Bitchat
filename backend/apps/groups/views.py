from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from bitchat.models import Group, GroupMember


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def group_create(request):
    """Create a group. Body: {group_id, name, members_visible, member_pubkeys: []}
    The creator becomes admin (alias 0); members get alias 1..N.
    Key distribution happens client-side via E2E DMs — the server never
    sees the group key."""
    group_id = (request.data.get('group_id') or '').strip()
    name = (request.data.get('name') or '').strip()
    members_visible = bool(request.data.get('members_visible', True))
    member_pubkeys = request.data.get('member_pubkeys') or []

    if not group_id or not name:
        return Response({'detail': 'group_id and name required.'}, status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(member_pubkeys, list) or len(member_pubkeys) > 256:
        return Response({'detail': 'invalid member list.'}, status=status.HTTP_400_BAD_REQUEST)
    if Group.objects.filter(group_id=group_id).exists():
        return Response({'detail': 'group exists.'}, status=status.HTTP_400_BAD_REQUEST)

    admin_pubkey = request.user.username
    group = Group.objects.create(
        group_id=group_id, name=name,
        admin_pubkey=admin_pubkey, members_visible=members_visible,
    )
    GroupMember.objects.create(group=group, pubkey=admin_pubkey, alias_n=0)
    aliases = {}
    for n, pk in enumerate(dict.fromkeys(member_pubkeys), start=1):
        if pk == admin_pubkey:
            continue
        GroupMember.objects.create(group=group, pubkey=pk, alias_n=n)
        aliases[pk] = n
    return Response({'group_id': group_id, 'aliases': aliases}, status=status.HTTP_201_CREATED)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def group_info(request, group_id):
    """Group metadata. Member list only for the admin of blind groups."""
    try:
        group = Group.objects.get(group_id=group_id)
    except Group.DoesNotExist:
        return Response({'detail': 'not found.'}, status=status.HTTP_404_NOT_FOUND)

    me = request.user.username
    is_member = group.members.filter(pubkey=me).exists()
    if not is_member:
        return Response({'detail': 'not a member.'}, status=status.HTTP_403_FORBIDDEN)

    data = {
        'group_id': group.group_id,
        'name': group.name,
        'members_visible': group.members_visible,
        'is_admin': me == group.admin_pubkey,
        'member_count': group.members.count(),
    }
    if group.members_visible or me == group.admin_pubkey:
        data['members'] = [
            {'pubkey': m.pubkey, 'alias_n': m.alias_n}
            for m in group.members.all()
        ]
    return Response(data)
