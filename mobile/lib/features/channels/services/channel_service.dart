import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';

import 'package:bitchat_messenger/core/bounded_set.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/features/channels/models/channel.dart';
import 'package:bitchat_messenger/features/channels/models/channel_message.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/mesh/services/bitchat_service.dart';
import 'package:bitchat_messenger/core/nostr_service.dart';

class _PresenceEntry {
  final String name;
  int lastSeen; // unix seconds

  _PresenceEntry({required this.name, required this.lastSeen});
}

class ChannelMember {
  final String pubkey;
  final String name;

  const ChannelMember({required this.pubkey, required this.name});
}

class ChannelService {
  final DatabaseService _dbService;
  final BitChatService _bitChatService;
  final NostrService _nostrService;

  final _channelListController = StreamController<List<Channel>>.broadcast();
  final _channelMessageController = StreamController<ChannelMessage>.broadcast();
  final _presenceController = StreamController<void>.broadcast();
  final _seenMessageIds = BoundedSet<String>(3000);
  final _seenAnnouncementIds = BoundedSet<String>(500);
  final _uuid = const Uuid();

  final Map<String, Channel> _activeChannels = {};

  // Per-channel presence: channelId -> { pubkey -> _PresenceEntry }
  final Map<String, Map<String, _PresenceEntry>> _channelPresence = {};

  Timer? _announcementTimer;
  Timer? _cleanupTimer;
  Timer? _presenceCleanupTimer;
  StreamSubscription? _meshMessageSub;
  StreamSubscription? _nearbySub;
  StreamSubscription? _nostrChannelSub;

  String? _myPubkey;
  String? _myUsername;

  ChannelService({
    required DatabaseService dbService,
    required BitChatService bitChatService,
    required NostrService nostrService,
  })  : _dbService = dbService,
        _bitChatService = bitChatService,
        _nostrService = nostrService;

  Stream<List<Channel>> get channelListStream => _channelListController.stream;
  Stream<ChannelMessage> get channelMessageStream => _channelMessageController.stream;
  Stream<void> get presenceStream => _presenceController.stream;
  List<Channel> get activeChannels => _activeChannels.values.toList();
  String? get myPubkey => _myPubkey;

  /// Get members currently present in a specific channel.
  List<ChannelMember> getChannelMembers(String channelId) {
    final presenceMap = _channelPresence[channelId];
    if (presenceMap == null || presenceMap.isEmpty) return [];
    return presenceMap.entries
        .map((e) => ChannelMember(pubkey: e.key, name: e.value.name))
        .toList();
  }

  /// Get count of nearby members for a channel.
  int getChannelMemberCount(String channelId) {
    if (channelId == AppConstants.defaultChannelId) {
      return _bitChatService.nearbyPubkeys.length;
    }
    return _channelPresence[channelId]?.length ?? 0;
  }

  void setUsername(String? username) {
    _myUsername = username;
  }

  Future<void> start(String myPubkey, {String? username}) async {
    _myPubkey = myPubkey;
    _myUsername = username;

    // Load saved channels from DB
    final saved = await _dbService.getChannels();
    for (final map in saved) {
      final channel = Channel.fromMap(map);
      _activeChannels[channel.id] = channel;
    }

    // Ensure default "Nearby" channel exists (always joined)
    if (!_activeChannels.containsKey(AppConstants.defaultChannelId)) {
      final nearby = Channel(
        id: AppConstants.defaultChannelId,
        name: AppConstants.defaultChannelName,
        creatorPubkey: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        lastActivityAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        isDefault: true,
        joined: true,
      );
      _activeChannels[nearby.id] = nearby;
      await _dbService.upsertChannel(nearby.toMap());
    }

    _notifyChannelList();

    // Listen for incoming mesh messages that are channel-related
    _meshMessageSub = _bitChatService.messageStream.listen(_handleMeshMessage);

    // Listen for nearby changes to update "Nearby" channel presence
    _nearbySub = _bitChatService.nearbyChangedStream.listen((_) {
      _syncNearbyPresence();
    });

    _syncNearbyPresence();

    // Periodically announce our channels so others discover them
    _announcementTimer = Timer.periodic(
      Duration(seconds: AppConstants.channelAnnouncementIntervalSeconds),
      (_) => _broadcastAnnouncements(),
    );

    // Periodic cleanup of expired channels and old messages
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      await _dbService.cleanupExpiredChannels(AppConstants.channelExpirySeconds);
      await _dbService.cleanupOldChannelMessages(AppConstants.channelMessageRetentionHours);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _activeChannels.removeWhere((id, ch) =>
          !ch.isDefault &&
          !ch.joined &&
          (now - ch.lastActivityAt) > AppConstants.channelExpirySeconds);
      _notifyChannelList();
    });

    // Periodically prune stale presence entries
    _presenceCleanupTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _pruneStalePresence();
    });

    _broadcastAnnouncements();
  }

  /// Sync the "Nearby" channel presence from BitChatService's nearby devices.
  void _syncNearbyPresence() {
    final nearbyPubkeys = _bitChatService.nearbyPubkeys;
    final deviceNames = _bitChatService.nearbyDeviceNames;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final nearbyPresence = _channelPresence.putIfAbsent(
        AppConstants.defaultChannelId, () => {});

    for (final pubkey in nearbyPubkeys) {
      final name = deviceNames[pubkey] ?? '';
      nearbyPresence[pubkey] = _PresenceEntry(name: name, lastSeen: now);
    }

    nearbyPresence.removeWhere((pubkey, _) => !nearbyPubkeys.contains(pubkey));

    _presenceController.add(null);
    _notifyChannelList();
  }

  // ---- Join / Leave ----

  /// Join a custom channel.
  Future<void> joinChannel(String channelId) async {
    final channel = _activeChannels[channelId];
    if (channel == null || channel.joined) return;

    final updated = channel.copyWith(joined: true);
    _activeChannels[channelId] = updated;
    await _dbService.updateChannelJoined(channelId, true);
    _notifyChannelList();

    // Subscribe on Nostr for this channel
    if (!channel.isDefault) {
      _nostrService.subscribeToChannel(channelId);
    }

    // Announce immediately so others see us
    final joinedIds = _activeChannels.entries
        .where((e) => e.value.joined)
        .map((e) => e.key)
        .toList();
    _broadcastAnnouncement(updated, joinedIds);
  }

  /// Leave a custom channel.
  Future<void> leaveChannel(String channelId) async {
    final channel = _activeChannels[channelId];
    if (channel == null || channel.isDefault) return; // can't leave Nearby

    final updated = channel.copyWith(joined: false);
    _activeChannels[channelId] = updated;
    await _dbService.updateChannelJoined(channelId, false);
    _notifyChannelList();

    // Unsubscribe from Nostr
    _nostrService.unsubscribeFromChannel(channelId);

    // Remove our presence from this channel
    _channelPresence[channelId]?.remove(_myPubkey);
    _presenceController.add(null);
  }

  // ---- Invite links ----

  /// Join a channel via invite link. Returns the channel or null if invalid.
  Future<Channel?> joinFromInviteLink(String link) async {
    final parsed = Channel.parseInviteLink(link);
    if (parsed == null) return null;

    final channelId = parsed['id']!;
    final channelName = parsed['name']!;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // If we already have this channel, just join it
    if (_activeChannels.containsKey(channelId)) {
      await joinChannel(channelId);
      return _activeChannels[channelId];
    }

    // Create the channel entry and join
    final channel = Channel(
      id: channelId,
      name: channelName,
      creatorPubkey: '',
      creatorName: '',
      createdAt: now,
      lastActivityAt: now,
      joined: true,
    );
    _activeChannels[channelId] = channel;
    await _dbService.upsertChannel(channel.toMap());
    _notifyChannelList();

    // Subscribe on Nostr
    _nostrService.subscribeToChannel(channelId);

    return channel;
  }

  /// Create a new custom channel (auto-joined).
  Future<Channel> createChannel(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final channel = Channel(
      id: _uuid.v4(),
      name: name,
      creatorPubkey: _myPubkey ?? '',
      creatorName: _myUsername ?? '',
      createdAt: now,
      lastActivityAt: now,
      joined: true,
    );
    _activeChannels[channel.id] = channel;
    await _dbService.upsertChannel(channel.toMap());
    _notifyChannelList();

    // Subscribe on Nostr
    _nostrService.subscribeToChannel(channel.id);

    // Immediately announce
    final joinedIds = _activeChannels.entries
        .where((e) => e.value.joined)
        .map((e) => e.key)
        .toList();
    _broadcastAnnouncement(channel, joinedIds);
    return channel;
  }

  /// Create a new private group (invite-only). Admin = self.
  Future<Channel> createPrivateGroup(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final channel = Channel(
      id: _uuid.v4(),
      name: name,
      creatorPubkey: _myPubkey ?? '',
      creatorName: _myUsername ?? '',
      createdAt: now,
      lastActivityAt: now,
      joined: true,
      isPrivate: true,
      adminPubkey: _myPubkey ?? '',
    );
    _activeChannels[channel.id] = channel;
    await _dbService.upsertChannel(channel.toMap());

    // Add self as first member
    if (_myPubkey != null) {
      await _dbService.addGroupMember(
        channel.id, _myPubkey!, _myUsername ?? '', Contact.shortIdFor(_myPubkey!));
    }

    _notifyChannelList();

    // Subscribe on Nostr to receive messages for this group
    _nostrService.subscribeToChannel(channel.id);

    // Do NOT broadcast an announcement — private groups are not discoverable
    return channel;
  }

  /// Add a member to a private group. Admin only.
  /// Sends them a Nostr DM invite so their app auto-joins the group.
  Future<void> addGroupMember(
      String channelId, String pubkey, String displayName, String shortId) async {
    final channel = _activeChannels[channelId];
    if (channel == null || !channel.isPrivate) return;
    if (channel.adminPubkey != _myPubkey) return; // only admin can add

    await _dbService.addGroupMember(channelId, pubkey, displayName, shortId);

    // Send invite DM so receiver's app auto-joins
    try {
      await _nostrService.sendGroupInviteDm(
        recipientPubkey: pubkey,
        channelId: channelId,
        channelName: channel.name,
        adminPubkey: _myPubkey!,
      );
    } catch (_) {}
  }

  /// Remove a member from a private group. Admin only.
  /// If the removed member is ourselves, also leave the group locally.
  Future<void> removeGroupMember(String channelId, String pubkey) async {
    final channel = _activeChannels[channelId];
    if (channel == null || !channel.isPrivate) return;
    if (channel.adminPubkey != _myPubkey) return;
    await _dbService.removeGroupMember(channelId, pubkey);

    // Notify the removed member via encrypted DM so their app leaves the group
    if (pubkey != _myPubkey) {
      try {
        await _nostrService.sendGroupRemovalDm(
          recipientPubkey: pubkey,
          channelId: channelId,
        );
      } catch (_) {}
    }

    // If admin removed themselves, unsubscribe and mark as left
    if (pubkey == _myPubkey) {
      _nostrService.unsubscribeFromChannel(channelId);
      final updated = channel.copyWith(joined: false);
      _activeChannels[channelId] = updated;
      await _dbService.updateChannelJoined(channelId, false);
      _notifyChannelList();
    }
  }

  /// Called by the server/admin side to notify a removed member they should leave.
  /// Removes the group locally so the user stops receiving its messages.
  Future<void> leavePrivateGroup(String channelId) async {
    final channel = _activeChannels[channelId];
    if (channel == null || !channel.isPrivate) return;

    _nostrService.unsubscribeFromChannel(channelId);
    final updated = channel.copyWith(joined: false);
    _activeChannels[channelId] = updated;
    await _dbService.updateChannelJoined(channelId, false);
    await _dbService.removeGroupMember(channelId, _myPubkey ?? '');
    _channelPresence.remove(channelId);
    _notifyChannelList();
  }

  /// Load the persisted member list for a private group from the database.
  Future<List<Map<String, dynamic>>> getGroupMembersFromDb(String channelId) async {
    return _dbService.getGroupMembers(channelId);
  }

  /// Called when we receive a group invite DM. Auto-joins the group.
  Future<void> receiveGroupInvite(
      String channelId, String channelName, String adminPubkey) async {
    if (channelId.isEmpty || channelName.isEmpty) return;
    if (_activeChannels.containsKey(channelId)) return; // already in group

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final channel = Channel(
      id: channelId,
      name: channelName,
      creatorPubkey: adminPubkey,
      creatorName: '',
      createdAt: now,
      lastActivityAt: now,
      joined: true,
      isPrivate: true,
      adminPubkey: adminPubkey,
    );
    _activeChannels[channelId] = channel;
    await _dbService.upsertChannel(channel.toMap());

    // Add self to members table
    if (_myPubkey != null) {
      await _dbService.addGroupMember(
        channelId, _myPubkey!, _myUsername ?? '', Contact.shortIdFor(_myPubkey!));
    }

    // Subscribe on Nostr to start receiving messages
    _nostrService.subscribeToChannel(channelId);
    _notifyChannelList();
  }

  /// Send a message to a channel (only if joined or default).
  Future<void> sendMessage(String channelId, String content) async {
    if (_myPubkey == null) return;
    final channel = _activeChannels[channelId];
    if (channel == null) return;
    if (!channel.isDefault && !channel.joined) return; // must join first

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final msg = ChannelMessage(
      id: _uuid.v4(),
      channelId: channelId,
      senderPubkey: _myPubkey!,
      senderName: _myUsername ?? '',
      content: content,
      timestamp: now,
      ttl: AppConstants.channelMessageTTL,
    );

    _seenMessageIds.add(msg.id);

    // Store locally
    await _dbService.insertChannelMessage(msg.toMap());

    _touchChannel(channelId, now);

    // Emit locally
    _channelMessageController.add(msg);

    // Send over mesh for ALL channels including private groups.
    // Private group messages are NOT encrypted at the transport layer, but
    // _handleChannelMessage rejects them on non-member devices (channel not in
    // _activeChannels → silently dropped). This gives functional privacy for the
    // default threat model (legitimate app users). Physical packet sniffing can
    // still observe content — per-member encryption is a planned future improvement.
    final wireMessage = Message.fromMap(msg.toWireMap());
    await _bitChatService.sendMessage(wireMessage);

    // Send via Nostr for custom channels (not Nearby — mesh only)
    if (!channel.isDefault && _nostrService.isConnected) {
      try {
        await _nostrService.sendChannelMessage(
          channelId: channelId,
          content: content,
          senderName: _myUsername ?? '',
          timestamp: now,
        );
      } catch (_) {}
    }
  }

  /// Get message history for a channel.
  Future<List<ChannelMessage>> getMessages(String channelId) async {
    final maps = await _dbService.getChannelMessages(channelId);
    return maps.map((m) => ChannelMessage.fromMap(m)).toList();
  }

  // ---- Mesh message handling ----

  Future<void> _handleMeshMessage(Message message) async {
    if (message.type == AppConstants.typeChannelMessage) {
      await _handleChannelMessage(message);
    } else if (message.type == AppConstants.typeChannelAnnouncement) {
      await _handleChannelAnnouncement(message);
    }
  }

  Future<void> _handleChannelMessage(Message message) async {
    if (_seenMessageIds.contains(message.id)) return;
    _seenMessageIds.add(message.id);

    if (message.senderPubkey == _myPubkey) return;

    final channelMsg = ChannelMessage.fromWireMap(message.toMap());
    if (channelMsg.channelId.isEmpty) return;

    // Only process messages for channels we've joined
    // Unknown channels (channel == null) are always rejected — prevents non-members
    // from storing private group messages that arrive via mesh relay
    final channel = _activeChannels[channelMsg.channelId];
    if (channel == null) return;
    if (!channel.isDefault && !channel.joined) return;

    await _dbService.insertChannelMessage(channelMsg.toMap());
    _channelMessageController.add(channelMsg);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _touchChannel(channelMsg.channelId, now);

    _updatePresence(
      channelMsg.channelId,
      message.senderPubkey,
      channelMsg.senderName,
      now,
    );
  }

  Future<void> _handleChannelAnnouncement(Message message) async {
    if (_seenAnnouncementIds.contains(message.id)) return;
    _seenAnnouncementIds.add(message.id);

    if (message.senderPubkey == _myPubkey) return;

    try {
      final data = jsonDecode(message.content);
      final channelId = data['channelId'] as String? ?? '';
      final channelName = data['channelName'] as String? ?? '';
      if (channelId.isEmpty || channelName.isEmpty) return;

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final isDefault = channelId == AppConstants.defaultChannelId;
      final senderName = data['senderName'] as String? ?? '';

      if (_activeChannels.containsKey(channelId)) {
        _touchChannel(channelId, now);
      } else {
        // Discover new channel (not joined yet)
        final channel = Channel(
          id: channelId,
          name: channelName,
          creatorPubkey: data['creatorPubkey'] as String? ?? '',
          creatorName: data['creatorName'] as String? ?? '',
          createdAt: (data['createdAt'] as int?) ?? now,
          lastActivityAt: now,
          isDefault: isDefault,
          joined: isDefault, // auto-join Nearby, others require explicit join
        );
        _activeChannels[channelId] = channel;
        await _dbService.upsertChannel(channel.toMap());
        _notifyChannelList();
      }

      // Process joinedChannels list for per-channel presence
      final joinedChannels = data['joinedChannels'] as List?;
      if (joinedChannels != null) {
        for (final jc in joinedChannels) {
          final jcId = jc as String? ?? '';
          if (jcId.isNotEmpty) {
            _updatePresence(jcId, message.senderPubkey, senderName, now);
          }
        }
      }

      _updatePresence(channelId, message.senderPubkey, senderName, now);
    } catch (_) {}
  }

  // ---- Nostr channel message handling ----

  Future<void> _handleNostrChannelMessage(Map<String, dynamic> data) async {
    final channelId = data['channelId'] as String? ?? '';
    final senderPubkey = data['senderPubkey'] as String? ?? '';
    final msgId = data['id'] as String? ?? '';

    if (channelId.isEmpty || senderPubkey.isEmpty) return;
    if (senderPubkey == _myPubkey) return;
    if (_seenMessageIds.contains(msgId)) return;
    _seenMessageIds.add(msgId);

    // Only process for joined channels
    final channel = _activeChannels[channelId];
    if (channel == null || !channel.joined) return;

    final msg = ChannelMessage(
      id: msgId,
      channelId: channelId,
      senderPubkey: senderPubkey,
      senderName: data['senderName'] as String? ?? '',
      content: data['content'] as String? ?? '',
      timestamp: (data['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 0, // from Nostr, no mesh relay needed
    );

    await _dbService.insertChannelMessage(msg.toMap());
    _channelMessageController.add(msg);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _touchChannel(channelId, now);
    _updatePresence(channelId, senderPubkey, msg.senderName, now);
  }

  // ---- Presence ----

  void _updatePresence(String channelId, String pubkey, String name, int now) {
    if (channelId == AppConstants.defaultChannelId) return;

    final presenceMap = _channelPresence.putIfAbsent(channelId, () => {});
    presenceMap[pubkey] = _PresenceEntry(name: name, lastSeen: now);
    _presenceController.add(null);
  }

  void _pruneStalePresence() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiryThreshold = AppConstants.channelExpirySeconds;
    bool changed = false;

    for (final channelId in _channelPresence.keys.toList()) {
      if (channelId == AppConstants.defaultChannelId) continue;

      final presenceMap = _channelPresence[channelId]!;
      final before = presenceMap.length;
      presenceMap.removeWhere((_, entry) =>
          (now - entry.lastSeen) > expiryThreshold);
      if (presenceMap.length != before) changed = true;

      if (presenceMap.isEmpty) {
        _channelPresence.remove(channelId);
        changed = true;
      }
    }

    if (changed) _presenceController.add(null);
  }

  // ---- Announcements ----

  void _broadcastAnnouncements() {
    // Private groups are never announced — they must not be discoverable
    final joinedIds = _activeChannels.entries
        .where((e) => e.value.joined && !e.value.isPrivate)
        .map((e) => e.key)
        .toList();

    for (final channel in _activeChannels.values) {
      if (channel.joined && !channel.isPrivate) {
        _broadcastAnnouncement(channel, joinedIds);
      }
    }
  }

  void _broadcastAnnouncement(Channel channel, [List<String>? joinedChannels]) {
    if (_myPubkey == null) return;

    final announcementData = jsonEncode({
      'channelId': channel.id,
      'channelName': channel.name,
      'creatorPubkey': channel.creatorPubkey,
      'creatorName': channel.creatorName,
      'createdAt': channel.createdAt,
      'senderName': _myUsername ?? '',
      'joinedChannels': joinedChannels ?? [channel.id],
    });

    final wireMessage = Message(
      id: _uuid.v4(),
      senderPubkey: _myPubkey!,
      receiverPubkey: 'channel:${channel.id}',
      content: announcementData,
      type: AppConstants.typeChannelAnnouncement,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: AppConstants.channelMessageTTL,
      status: 'sent',
      transport: 'bitchat',
    );

    _bitChatService.sendMessage(wireMessage);
  }

  void _touchChannel(String channelId, int timestamp) {
    final existing = _activeChannels[channelId];
    if (existing != null) {
      _activeChannels[channelId] = existing.copyWith(lastActivityAt: timestamp);
      _dbService.updateChannelActivity(channelId, timestamp);
      _notifyChannelList();
    }
  }

  void _notifyChannelList() {
    _channelListController.add(_activeChannels.values.toList());
  }

  Future<void> stop() async {
    _announcementTimer?.cancel();
    _cleanupTimer?.cancel();
    _presenceCleanupTimer?.cancel();
    _meshMessageSub?.cancel();
    _nearbySub?.cancel();
  }

  Future<void> dispose() async {
    await stop();
    _channelListController.close();
    _channelMessageController.close();
    _presenceController.close();
  }
}
