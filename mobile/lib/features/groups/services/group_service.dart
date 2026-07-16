import 'dart:async';
import 'dart:convert';

import 'package:nostr_tools/nostr_tools.dart' show KeyApi;
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/core/signaling_service.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';

/// Groups with blind-mode support.
///
/// Each group has its own keypair. The admin creates it, registers members
/// on the server, and hands each member the group PRIVATE key over an
/// existing end-to-end DM (encrypted to that member). Group messages are
/// encrypted with the group key — the server relays ciphertext and, in blind
/// groups, rewrites the sender label to 'Member N' so members never learn
/// each other's identities.
class GroupService {
  final DatabaseService _db;
  final KeyManager _keyManager;
  final _keyApi = KeyApi();
  final _nip44 = Nip44();
  SignalingService? _signaling;

  final _controller = StreamController<String>.broadcast();

  /// Emits a groupId whenever that group has new content (for UI refresh).
  Stream<String> get groupUpdates => _controller.stream;

  GroupService({required DatabaseService db, required KeyManager keyManager})
      : _db = db,
        _keyManager = keyManager;

  void setSignaling(SignalingService s) => _signaling = s;

  /// Admin: create a group, register on server, distribute the group key to
  /// each member via E2E DM. [members] = list of their pubkeys.
  Future<String?> createGroup({
    required String name,
    required bool membersVisible,
    required List<String> members,
  }) async {
    final myPriv = _keyManager.privateKey;
    final myPub = _keyManager.publicKey;
    if (myPriv == null || myPub == null) return null;

    final groupPriv = _keyApi.generatePrivateKey();
    final groupPub = _keyApi.getPublicKey(groupPriv);
    final groupId = 'g_${groupPub.substring(0, 32)}';

    final result = await ServerService().createGroup(
      groupId: groupId,
      name: name,
      membersVisible: membersVisible,
      memberPubkeys: members,
    );
    if (result == null) return null;

    await _db.upsertGroup({
      'groupId': groupId,
      'name': name,
      'groupPrivkey': groupPriv,
      'groupPubkey': groupPub,
      'adminPubkey': myPub,
      'membersVisible': membersVisible ? 1 : 0,
      'isAdmin': 1,
      'memberCount': members.length + 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });

    // Hand each member the group key over their E2E DM.
    for (final memberPub in members) {
      final invite = jsonEncode({
        '__type': 'group_invite',
        'groupId': groupId,
        'name': name,
        'groupPrivkey': groupPriv,
        'groupPubkey': groupPub,
        'adminPubkey': myPub,
        'membersVisible': membersVisible,
      });
      try {
        final ct = await _nip44.encrypt(myPriv, memberPub, invite);
        _sendDm(memberPub, ct);
      } catch (_) {}
    }
    return groupId;
  }

  /// Member: received a group invite over DM — store the group locally.
  Future<void> handleInvite(Map<String, dynamic> invite) async {
    final groupId = invite['groupId'] as String?;
    if (groupId == null) return;
    if (await _db.getGroup(groupId) != null) return; // already joined
    await _db.upsertGroup({
      'groupId': groupId,
      'name': invite['name'] as String? ?? 'Group',
      'groupPrivkey': invite['groupPrivkey'] as String?,
      'groupPubkey': invite['groupPubkey'] as String?,
      'adminPubkey': invite['adminPubkey'] as String? ?? '',
      'membersVisible': (invite['membersVisible'] == true) ? 1 : 0,
      'isAdmin': 0,
      'memberCount': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    _controller.add(groupId);
  }

  /// Send a text message to a group (encrypted with the group key).
  Future<void> sendGroupMessage(String groupId, String body) async {
    final group = await _db.getGroup(groupId);
    final myPub = _keyManager.publicKey;
    if (group == null || myPub == null) return;
    final groupPriv = group['groupPrivkey'] as String?;
    final groupPub = group['groupPubkey'] as String?;
    if (groupPriv == null || groupPub == null) return;

    final messageId = _keyManager.generateMessageId();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Store locally as mine.
    await _db.insertMessage(Message(
      id: messageId,
      senderPubkey: myPub,
      receiverPubkey: groupId,
      content: body,
      type: 'text',
      timestamp: ts,
      status: 'sent',
      senderName: _keyManager.username,
      senderLabel: 'You',
      groupId: groupId,
    ));
    _controller.add(groupId);

    // Encrypt body with the GROUP key (self-encrypt: priv+own pub).
    final ct = await _nip44.encrypt(groupPriv, groupPub, body);
    _signaling?.send({
      'type': 'group_dm',
      'groupId': groupId,
      'messageId': messageId,
      'encryptedContent': ct,
      'timestamp': ts,
      'senderName': _keyManager.username ?? '',
    });
  }

  /// Incoming group message from the WS (or pending-fetch). The wrapper is
  /// plaintext (label only); the body is group-key encrypted.
  Future<void> handleIncomingGroupMessage(Map<String, dynamic> payload) async {
    final groupId = payload['groupId'] as String?;
    final messageId = payload['messageId'] as String?;
    final ct = payload['encryptedContent'] as String? ?? payload['ct'] as String?;
    if (groupId == null || messageId == null || ct == null) return;

    final group = await _db.getGroup(groupId);
    if (group == null) return; // not a member locally
    if (await _db.hasSeenMessage(messageId)) return;

    final groupPriv = group['groupPrivkey'] as String?;
    final groupPub = group['groupPubkey'] as String?;
    if (groupPriv == null || groupPub == null) return;

    String body;
    try {
      body = await _nip44.decrypt(groupPriv, groupPub, ct);
    } catch (_) {
      return;
    }

    final senderPubkey = payload['senderPubkey'] as String? ?? '';
    final senderLabel = payload['senderLabel'] as String? ?? 'Member';

    await _db.insertMessage(Message(
      id: messageId,
      senderPubkey: senderPubkey.isEmpty ? groupId : senderPubkey,
      receiverPubkey: groupId,
      content: body,
      type: 'text',
      timestamp: payload['timestamp'] as int? ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'delivered',
      senderLabel: senderLabel,
      groupId: groupId,
    ));
    _controller.add(groupId);
  }

  void _sendDm(String recipientPubkey, String encryptedContent) {
    _signaling?.send({
      'type': 'dm',
      'recipientPubkey': recipientPubkey,
      'messageId': _keyManager.generateMessageId(),
      'encryptedContent': encryptedContent,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'senderName': _keyManager.username ?? '',
    });
  }

  void dispose() => _controller.close();
}
