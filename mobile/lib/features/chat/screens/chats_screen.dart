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
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
import 'package:bitchat_messenger/features/chat/screens/chat_screen.dart';

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
  final hash = pubkey.codeUnits.fold(0, (a, b) => a ^ b);
  return _kAvatarPalette[hash.abs() % _kAvatarPalette.length];
}

class _DmItem {
  final Contact contact;
  final Message lastMessage;
  final int unread;
  final bool isNearby;
  _DmItem({required this.contact, required this.lastMessage, required this.unread, required this.isNearby});
  int get sortTimestamp => lastMessage.timestamp;
}

class ChatsScreen extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;

  const ChatsScreen({
    super.key,
    required this.dbService,
    required this.messageService,
    this.callService,
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

  @override
  void initState() {
    super.initState();
    _loadAll();
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
      final lastMsg = _lastMessages[contact.pubkey];
      if (lastMsg == null) continue;
      items.add(_DmItem(
        contact: contact,
        lastMessage: lastMsg,
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

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Chats',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 22),
            tooltip: 'New message',
            onPressed: () {},
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: items.isEmpty ? _buildEmpty() : _buildList2(items, isDark),
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
    final senderName = item.lastMessage.senderName;
    final label = contact.name?.isNotEmpty == true
        ? contact.name!
        : (senderName != null && senderName.isNotEmpty)
            ? senderName
            : '#${contact.shortId}';
    final hasUnread = item.unread > 0;
    final myPubkey = widget.messageService.publicKey;
    final isMe = item.lastMessage.senderPubkey == myPubkey;

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
                        _formatTime(item.lastMessage.timestamp),
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
                          isMe
                              ? 'You: ${_previewText(item.lastMessage)}'
                              : _previewText(item.lastMessage),
                          style: TextStyle(
                            fontSize: 14,
                            color: hasUnread
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
              'Start a conversation from your contacts or share your ID with friends.',
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
