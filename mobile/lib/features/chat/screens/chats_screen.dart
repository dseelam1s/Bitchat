import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
import 'package:bitchat_messenger/features/chat/screens/chat_screen.dart';
import 'package:bitchat_messenger/features/contacts/screens/contacts_screen.dart';
import 'package:bitchat_messenger/features/profile/screens/profile_screen.dart';
import 'package:bitchat_messenger/features/groups/services/group_service.dart';
import 'package:bitchat_messenger/features/groups/screens/create_group_screen.dart';
import 'package:bitchat_messenger/features/groups/screens/group_chat_screen.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/core/widgets/peer_avatar.dart';

// Distinct avatar background colors derived from pubkey hash.
// Beacon family — keep in sync with the palette in contacts_screen.dart.
const _kAvatarPalette = [
  Color(0xFF3D5AFE),
  Color(0xFF00A8B5),
  Color(0xFFFF5C39),
  Color(0xFF7C4DFF),
  Color(0xFF0091EA),
  Color(0xFFFF8F00),
  Color(0xFF2E9E5B),
  Color(0xFFD81B60),
  Color(0xFF5C74FF),
  Color(0xFF00B8D4),
];

Color _avatarColor(String pubkey) {
  // Same hash as contacts_screen so a person keeps one color everywhere.
  if (pubkey.isEmpty) return _kAvatarPalette[0];
  int hash = 0;
  for (final c in pubkey.codeUnits) {
    hash = (hash * 31 + c) & 0x7FFFFFFF;
  }
  return _kAvatarPalette[hash % _kAvatarPalette.length];
}

class _DmItem {
  final Contact contact;
  final Message? lastMessage; // null: saved contact with no conversation yet
  final int unread;
  final bool isNearby;
  _DmItem({required this.contact, required this.lastMessage, required this.unread, required this.isNearby});
  int get sortTimestamp => lastMessage?.timestamp ?? 0;
}

class ChatsScreen extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;
  final GroupService? groupService;

  const ChatsScreen({
    super.key,
    required this.dbService,
    required this.messageService,
    this.callService,
    this.groupService,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Contact> _contacts = [];
  Map<String, Message> _lastMessages = {};
  Map<String, int> _unreadCounts = {};
  StreamSubscription? _nearbySub;
  StreamSubscription? _messageSub;
  Timer? _reloadDebounce;
  String? _myPicPath;
  List<Map<String, dynamic>> _groups = [];
  StreamSubscription? _groupSub;
  Map<String, Map<String, dynamic>> _statusByPubkey = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadMyPicture();
    _loadGroups();
    _groupSub = widget.groupService?.groupUpdates.listen((_) {
      if (mounted) _loadGroups();
    });
    _batchSyncProfiles();
    _nearbySub = widget.messageService.nearbyChangedStream.listen((_) {
      if (mounted) setState(() {});
    });
    _messageSub = widget.messageService.messageStream.listen((_) {
      if (!mounted) return;
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _loadAll();
      });
    });
  }

  Future<void> _loadMyPicture() async {
    final pubkey = widget.messageService.publicKey;
    if (pubkey == null) return;
    final path = await ProfilePictureCacheService().localPath(pubkey);
    if (path != null && mounted) setState(() => _myPicPath = path);
  }

  Future<void> _loadGroups() async {
    final groups = await widget.dbService.getGroups();
    if (mounted) setState(() => _groups = groups);
  }

  void _openGroup(String groupId) {
    if (widget.groupService == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(
          groupId: groupId,
          dbService: widget.dbService,
          groupService: widget.groupService!,
          myPubkey: widget.messageService.publicKey ?? '',
        ),
      ),
    ).then((_) => _loadGroups());
  }

  void _newGroup() async {
    if (widget.groupService == null) return;
    final gid = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => CreateGroupScreen(
          dbService: widget.dbService,
          groupService: widget.groupService!,
        ),
      ),
    );
    await _loadGroups();
    if (gid != null) _openGroup(gid);
  }

  void _batchSyncProfiles() {
    () async {
      await Future.delayed(const Duration(seconds: 2));
      final contacts = await widget.dbService.getContacts();
      final pubkeys = contacts.where((c) => !c.isPending).map((c) => c.pubkey).toList();
      if (pubkeys.isEmpty) return;
      await ProfileSyncService().syncAll(pubkeys, widget.dbService, onContactUpdated: (_) {
        if (mounted) _loadAll();
      });
    }();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _nearbySub?.cancel();
    _messageSub?.cancel();
    _groupSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final contacts = await widget.dbService.getContacts();
    final lastMessages = await widget.messageService.getLastMessages();
    final unreadCounts = await widget.messageService.getUnreadCounts();
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _lastMessages = lastMessages;
      _unreadCounts = unreadCounts;
    });
    _loadStatuses(contacts);
  }

  Future<void> _loadStatuses(List<Contact> contacts) async {
    final myPub = widget.messageService.publicKey;
    final pubkeys = [
      if (myPub != null) myPub,
      ...contacts.where((c) => !c.isPending).map((c) => c.pubkey),
    ];
    if (pubkeys.isEmpty) return;
    final rows = await ServerService().fetchStatuses(pubkeys);
    if (!mounted) return;
    setState(() {
      _statusByPubkey = {for (final r in rows) r['pubkey'] as String: r};
    });
  }

  void _openDm(Contact contact, {String? resolvedName}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactPubkey: contact.pubkey,
          contactName: resolvedName ?? contact.name,
          contactProfilePictureUrl: contact.profilePictureUrl,
          contactProfilePictureLocalPath: contact.profilePictureLocalPath,
          messageService: widget.messageService,
          callService: widget.callService,
        ),
      ),
    ).then((_) => _loadAll());
  }

  void _openNearbyUser(String pubkey, {String? suggestedName}) {
    final existing = _contacts.firstWhere(
      (c) => c.pubkey == pubkey,
      orElse: () => Contact(pubkey: pubkey),
    );
    if (_contacts.any((c) => c.pubkey == pubkey) && !existing.isPending) {
      _openDm(existing);
      return;
    }
    final cleanName = suggestedName?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
    final displayName = (cleanName != null && cleanName.isNotEmpty)
        ? cleanName
        : '#${Contact.shortIdFor(pubkey)}';
    _openDm(Contact(pubkey: pubkey, name: displayName));
  }

  List<_DmItem> _buildList() {
    final nearby = widget.messageService.nearbyUsers;
    final items = <_DmItem>[];
    final contactPubkeys = {for (final c in _contacts) c.pubkey};
    for (final contact in _contacts) {
      // Contacts without a conversation are included too — a saved person is
      // just a chat that hasn't started yet (they sort below real chats).
      items.add(_DmItem(
        contact: contact,
        lastMessage: _lastMessages[contact.pubkey],
        unread: _unreadCounts[contact.pubkey] ?? 0,
        isNearby: nearby.contains(contact.pubkey),
      ));
    }
    for (final pubkey in _lastMessages.keys) {
      if (!contactPubkeys.contains(pubkey)) {
        final lastMsg = _lastMessages[pubkey]!;
        final bleRaw = widget.messageService.nearbyDeviceNames[pubkey];
        final bleName = bleRaw?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
        final senderName = lastMsg.senderPubkey == pubkey ? lastMsg.senderName : null;
        final name = (bleName?.isNotEmpty == true) ? bleName : (senderName?.isNotEmpty == true) ? senderName : null;
        items.add(_DmItem(
          contact: Contact(pubkey: pubkey, name: name),
          lastMessage: lastMsg,
          unread: _unreadCounts[pubkey] ?? 0,
          isNearby: nearby.contains(pubkey),
        ));
      }
    }
    items.sort((a, b) => b.sortTimestamp.compareTo(a.sortTimestamp));
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final nearby = widget.messageService.nearbyUsers;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: GestureDetector(
            onTap: _openProfile,
            child: PeerAvatar(
              name: widget.messageService.username ?? '•',
              localPath: _myPicPath,
              picUrl: widget.messageService.profilePictureUrl,
              size: 34,
              bgColor: AppColors.primary,
            ),
          ),
        ),
        title: const Text(
          'Chats',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined, size: 23),
            tooltip: 'New group',
            onPressed: _newGroup,
          ),
          IconButton(
            icon: const Icon(Icons.call_outlined, size: 23),
            tooltip: 'Calls',
            onPressed: _openCalls,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _buildTodayStrip(isDark),
          if (nearby.isNotEmpty) _buildNearbyStrip(nearby, isDark),
          if (_groups.isNotEmpty) _buildGroupsStrip(isDark),
          Expanded(
            child: items.isEmpty && _groups.isEmpty
                ? _buildEmpty()
                : _buildList2(items, isDark),
          ),
        ],
      ),
    );
  }

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileScreen(messageService: widget.messageService),
      ),
    ).then((_) => _loadAll());
  }

  void _openCalls() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ContactsScreen(
          dbService: widget.dbService,
          messageService: widget.messageService,
          callService: widget.callService,
        ),
      ),
    ).then((_) => _loadAll());
  }

  // ── Today strip (status-lite) ─────────────────────────────────────────────

  Widget _buildTodayStrip(bool isDark) {
    final myPub = widget.messageService.publicKey ?? '';
    final myStatus = _statusByPubkey[myPub];
    final withStatus = _contacts
        .where((c) => c.pubkey != myPub && _statusByPubkey.containsKey(c.pubkey))
        .toList();

    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _statusChip(
            name: 'Your status',
            avatar: PeerAvatar(
              name: widget.messageService.username ?? '•',
              localPath: _myPicPath,
              picUrl: widget.messageService.profilePictureUrl,
              size: 52,
              bgColor: AppColors.primary,
            ),
            emoji: myStatus?['emoji'] as String? ?? '',
            isAdd: myStatus == null,
            onTap: _showSetStatusSheet,
            isDark: isDark,
          ),
          for (final c in withStatus)
            _statusChip(
              name: (c.name ?? '#${c.shortId}').split(' ').first,
              avatar: PeerAvatar(
                name: c.name ?? '#${c.shortId}',
                localPath: c.profilePictureLocalPath,
                picUrl: c.profilePictureUrl,
                size: 52,
                bgColor: _avatarColor(c.pubkey),
              ),
              emoji: _statusByPubkey[c.pubkey]?['emoji'] as String? ?? '',
              isAdd: false,
              onTap: () => _showContactStatusSheet(c),
              isDark: isDark,
            ),
        ],
      ),
    );
  }

  Widget _statusChip({
    required String name,
    required Widget avatar,
    required String emoji,
    required bool isAdd,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            SizedBox(
              width: 58,
              height: 58,
              child: Stack(
                children: [
                  Positioned(top: 0, left: 0, child: avatar),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isAdd
                            ? AppColors.primary
                            : (isDark ? AppColors.darkSurface : Colors.white),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color:
                                isDark ? AppColors.darkSurface : Colors.white,
                            width: 1.5),
                      ),
                      child: isAdd
                          ? const Icon(Icons.add, size: 14, color: Colors.white)
                          : Text(emoji.isEmpty ? '💬' : emoji,
                              style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: isDark
                        ? AppColors.darkTextMuted
                        : AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  void _showSetStatusSheet() {
    final myPub = widget.messageService.publicKey ?? '';
    final existing = _statusByPubkey[myPub];
    final textController =
        TextEditingController(text: existing?['text'] as String? ?? '');
    String selectedEmoji = existing?['emoji'] as String? ?? '';
    const moods = ['😊', '🔥', '😴', '☕', '🎧', '💼', '🎉', '😌'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              // viewPadding keeps Clear/Share above the system nav bar
              bottom: MediaQuery.of(ctx).viewInsets.bottom +
                  MediaQuery.of(ctx).viewPadding.bottom +
                  20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Today's status",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Visible to your contacts for 24 hours',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in moods)
                    GestureDetector(
                      onTap: () => setLocal(
                          () => selectedEmoji = selectedEmoji == m ? '' : m),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: selectedEmoji == m
                              ? AppColors.primary.withAlpha(40)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: selectedEmoji == m
                              ? Border.all(color: AppColors.primary)
                              : Border.all(color: Colors.transparent),
                        ),
                        child: Text(m, style: const TextStyle(fontSize: 22)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLength: 140,
                decoration: const InputDecoration(
                  hintText: "What's up today?",
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (existing != null)
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await ServerService().setStatus(emoji: '', text: '');
                        _loadStatuses(_contacts);
                      },
                      child: const Text('Clear',
                          style: TextStyle(color: AppColors.coral)),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      final text = textController.text.trim();
                      if (selectedEmoji.isEmpty && text.isEmpty) return;
                      Navigator.pop(ctx);
                      final ok = await ServerService()
                          .setStatus(emoji: selectedEmoji, text: text);
                      if (!ok && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content:
                                Text('Could not share status — try again')));
                      }
                      _loadStatuses(_contacts);
                    },
                    child: const Text('Share'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showContactStatusSheet(Contact c) {
    final s = _statusByPubkey[c.pubkey];
    if (s == null) return;
    final updatedAt = s['updated_at'] as int? ?? 0;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000));
    final ago = age.inHours > 0 ? '${age.inHours}h ago' : '${age.inMinutes}m ago';

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PeerAvatar(
              name: c.name ?? '#${c.shortId}',
              localPath: c.profilePictureLocalPath,
              picUrl: c.profilePictureUrl,
              size: 56,
              bgColor: _avatarColor(c.pubkey),
            ),
            const SizedBox(height: 10),
            Text(c.name ?? '#${c.shortId}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(ago,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            if ((s['emoji'] as String? ?? '').isNotEmpty)
              Text(s['emoji'] as String, style: const TextStyle(fontSize: 40)),
            if ((s['text'] as String? ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(s['text'] as String,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, height: 1.4)),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _openDm(c);
              },
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Reply in chat'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsStrip(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in _groups)
          InkWell(
            onTap: () => _openGroup(g['groupId'] as String),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                        color: AppColors.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.groups, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              g['name'] as String? ?? 'Group',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            if ((g['membersVisible'] as int? ?? 1) == 0) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.visibility_off,
                                  size: 13, color: AppColors.coral),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          (g['isAdmin'] as int? ?? 0) == 1
                              ? 'You\'re the admin · ${g['memberCount'] ?? 0} members'
                              : 'Group',
                          style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? AppColors.darkTextMuted
                                  : AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const Divider(height: 1, indent: 82),
      ],
    );
  }

  Widget _buildNearbyStrip(Set<String> nearby, bool isDark) {
    final names = widget.messageService.nearbyDeviceNames;
    final entries = nearby.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Text(
            '● IN RANGE NOW',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: AppColors.coral,
            ),
          ),
        ),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            itemCount: entries.length,
            separatorBuilder: (_, i) => const SizedBox(width: 14),
            itemBuilder: (_, i) {
              final pubkey = entries[i];
              final contactMatch =
                  _contacts.where((c) => c.pubkey == pubkey).toList();
              final raw = names[pubkey];
              final cleaned = raw?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
              final name = contactMatch.isNotEmpty &&
                      contactMatch.first.name?.isNotEmpty == true
                  ? contactMatch.first.name!
                  : (cleaned?.isNotEmpty == true
                      ? cleaned!
                      : '#${Contact.shortIdFor(pubkey)}');
              final contactPic = contactMatch.isNotEmpty ? contactMatch.first : null;
              return GestureDetector(
                onTap: () => _openNearbyUser(pubkey, suggestedName: name),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PeerAvatar(
                      name: name,
                      localPath: contactPic?.profilePictureLocalPath,
                      picUrl: contactPic?.profilePictureUrl,
                      size: 48,
                      bgColor: _avatarColor(pubkey),
                      border: Border.all(color: AppColors.coral, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.coral.withAlpha(70),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name.length > 9 ? '${name.substring(0, 8)}…' : name,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildList2(List<_DmItem> items, bool isDark) {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 100),
      itemCount: items.length,
      separatorBuilder: (_, i) => Divider(
        height: 1,
        indent: 82, // aligns with text start, after avatar + gap
        endIndent: 0,
        color: isDark ? AppColors.darkDivider : AppColors.divider,
      ),
      itemBuilder: (_, i) => _buildRow(items[i], isDark),
    );
  }

  Widget _buildRow(_DmItem item, bool isDark) {
    final contact = item.contact;
    final lastMsg = item.lastMessage;
    // Only trust senderName from INCOMING messages — on outgoing ones it's
    // OUR name (bug: chats titled with your own name after you sent last).
    // Priority stays: contact-saved name > peer's self-set name > #shortId.
    final senderName = (lastMsg != null && lastMsg.senderPubkey == contact.pubkey)
        ? lastMsg.senderName
        : null;
    final label = contact.name?.isNotEmpty == true
        ? contact.name!
        : (senderName != null && senderName.isNotEmpty)
            ? senderName
            : '#${contact.shortId}';
    final hasUnread = item.unread > 0;
    final myPubkey = widget.messageService.publicKey;
    final isMe = lastMsg != null && lastMsg.senderPubkey == myPubkey;

    final String preview;
    if (lastMsg == null) {
      preview = contact.isPending
          ? 'Waiting to be found…'
          : item.isNearby
              ? '● nearby — say hi over bluetooth'
              : 'No messages yet — say hi';
    } else {
      preview = isMe ? 'You: ${_previewText(lastMsg)}' : _previewText(lastMsg);
    }

    return InkWell(
      onTap: () => _openDm(contact, resolvedName: label),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // ── Avatar ──────────────────────────────────────────────────────
            _Avatar(
              name: label,
              pubkey: contact.pubkey,
              localPath: contact.profilePictureLocalPath,
              picUrl: contact.profilePictureUrl,
              isOnline: item.isNearby,
              size: 52,
              bgColor: _avatarColor(contact.pubkey),
            ),

            const SizedBox(width: 12),

            // ── Content ──────────────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + timestamp row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
                            color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        lastMsg == null ? '' : _formatTime(lastMsg.timestamp),
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread
                              ? AppColors.online
                              : (isDark ? AppColors.darkTextMuted : AppColors.textMuted),
                          fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 3),

                  // Preview + unread badge row
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          style: TextStyle(
                            fontSize: 14,
                            color: lastMsg == null && item.isNearby
                                ? AppColors.coral
                                : hasUnread
                                    ? (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
                                    : (isDark ? AppColors.darkTextMuted : AppColors.textMuted),
                            fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: item.unread),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final pubkey = widget.messageService.publicKey ?? '';
    final shortId = pubkey.isNotEmpty ? Contact.shortIdFor(pubkey) : '';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withAlpha(10),
              ),
              child: Icon(Icons.chat_bubble_outline_rounded, size: 36, color: AppColors.primary.withAlpha(120)),
            ),
            const SizedBox(height: 20),
            const Text(
              'No messages yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Open the Radar to see who\'s around you, or share your ID so friends can find you.',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted, height: 1.5),
              textAlign: TextAlign.center,
            ),
            if (shortId.isNotEmpty) ...[
              const SizedBox(height: 24),
              _ShortIdChip(shortId: shortId),
            ],
          ],
        ),
      ),
    );
  }

  String _previewText(Message msg) {
    switch (msg.type) {
      case 'image': return '📷  Photo';
      case 'voice_note': return '🎤  Voice message';
      default: return msg.content;
    }
  }

  String _formatTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(msgDay).inDays;
    if (diff == 0) {
      final h = dt.hour;
      final m = dt.minute.toString().padLeft(2, '0');
      final period = h < 12 ? 'AM' : 'PM';
      final hour = (h % 12 == 0 ? 12 : h % 12).toString();
      return '$hour:$m $period';
    }
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][dt.weekday - 1];
    return '${dt.day}/${dt.month}/${dt.year % 100}';
  }
}

// ── Circular Avatar ───────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String name;
  final String pubkey;
  final String? localPath;
  final String? picUrl;
  final bool isOnline;
  final double size;
  final Color bgColor;

  const _Avatar({
    required this.name,
    required this.pubkey,
    this.localPath,
    this.picUrl,
    required this.isOnline,
    required this.size,
    required this.bgColor,
  });

  String get _initial {
    final n = name.trim();
    if (n.isEmpty || n == '?') return '?';
    // Skip '#' prefix
    final clean = n.startsWith('#') ? n.substring(1) : n;
    return clean.isNotEmpty ? clean[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final dotSize = size * 0.26;
    final borderWidth = 2.0;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;

    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bgColor),
          clipBehavior: Clip.antiAlias,
          child: localPath != null
              ? Image.file(File(localPath!), fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _initials())
              : picUrl != null && picUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: picUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _initials(),
                    )
                  : _initials(),
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.online,
                border: Border.all(color: scaffoldBg, width: borderWidth),
              ),
            ),
          ),
      ],
    );
  }

  Widget _initials() => Center(
    child: Text(
      _initial,
      style: TextStyle(
        fontSize: size * 0.4,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
  );
}

// ── Unread badge ──────────────────────────────────────────────────────────────

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const BoxDecoration(
        color: AppColors.online,
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    );
  }
}

// ── Short ID chip (empty state) ───────────────────────────────────────────────

class _ShortIdChip extends StatefulWidget {
  final String shortId;
  const _ShortIdChip({required this.shortId});

  @override
  State<_ShortIdChip> createState() => _ShortIdChipState();
}

class _ShortIdChipState extends State<_ShortIdChip> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: '#${widget.shortId}'));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _copied ? AppColors.primary.withAlpha(20) : AppColors.primary.withAlpha(8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(_copied ? 80 : 30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '#${widget.shortId}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 1),
            ),
            const SizedBox(width: 8),
            Icon(_copied ? Icons.check : Icons.copy_outlined, size: 14, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}
