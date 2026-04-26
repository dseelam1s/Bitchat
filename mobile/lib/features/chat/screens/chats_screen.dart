import 'dart:async';
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
      // Debounce: coalesce rapid message bursts into a single reload
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _loadAll();
      });
    });
  }

  void _batchSyncProfiles() {
    () async {
      // Wait for contacts to be loaded before syncing
      await Future.delayed(const Duration(seconds: 2));
      final contacts = await widget.dbService.getContacts();
      final pubkeys = contacts
          .where((c) => !c.isPending)
          .map((c) => c.pubkey)
          .toList();
      if (pubkeys.isEmpty) return;
      await ProfileSyncService().syncAll(
        pubkeys,
        widget.dbService,
        onContactUpdated: (_) {
          if (mounted) _loadAll();
        },
      );
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
    // If already a contact, open normally
    final existing = _contacts.firstWhere(
      (c) => c.pubkey == pubkey,
      orElse: () => Contact(pubkey: pubkey),
    );
    if (_contacts.any((c) => c.pubkey == pubkey) && !existing.isPending) {
      _openDm(existing);
      return;
    }
    // Not a contact — open chat directly using name or short ID as label.
    // User is NOT added to contacts; they can do that explicitly from within the chat.
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
        // Resolve best available name for non-saved contacts:
        // 1. BLE device name (if nearby), 2. senderName from a received message
        final bleRaw = widget.messageService.nearbyDeviceNames[pubkey];
        final bleName = bleRaw?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
        final senderName = lastMsg.senderPubkey == pubkey ? lastMsg.senderName : null;
        final name = (bleName?.isNotEmpty == true)
            ? bleName
            : (senderName?.isNotEmpty == true)
                ? senderName
                : null;
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
    final nearby = widget.messageService.nearbyUsers.toList();
    final names = widget.messageService.nearbyDeviceNames;
    final contactMap = {for (final c in _contacts) c.pubkey: c};

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.hub, size: 20, color: AppColors.mint.withAlpha(180)),
            const SizedBox(width: 10),
            const Text('Chats'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (nearby.isNotEmpty)
            _buildStoriesBar(nearby, names, contactMap),
          Expanded(
            child: items.isEmpty
                ? _buildEmpty()
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 100),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _buildDmTile(items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoriesBar(List<String> nearby, Map<String, String> names, Map<String, Contact> contactMap) {
    final overflow = nearby.length > 7 ? nearby.length - 6 : 0;
    final visible = nearby.take(overflow > 0 ? 6 : nearby.length).toList();

    return Container(
      height: 86,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider.withAlpha(60))),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        children: [
          // Nearby devices
          ...visible.map((pubkey) {
            final contact = contactMap[pubkey];
            final bleRaw = names[pubkey] ?? '';
            final bleUsername = bleRaw.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
            final label = contact?.name?.isNotEmpty == true
                ? contact!.name!
                : bleUsername.isNotEmpty
                    ? bleUsername
                    : '#${Contact.shortIdFor(pubkey)}';
            return _buildStoryBubble(
              label: label,
              profileUrl: contact?.profilePictureUrl,
              color: AppColors.blue,
              onTap: () => _openNearbyUser(pubkey, suggestedName: names[pubkey]),
            );
          }),
          if (overflow > 0)
            _buildStoryBubble(
              label: '+$overflow',
              color: AppColors.blue,
              isOverflow: true,
              onTap: () {},
            ),
        ],
      ),
    );
  }

  Widget _buildStoryBubble({
    required String label,
    required VoidCallback onTap,
    required Color color,
    String? profileUrl,
    IconData? icon,
    bool isOverflow = false,
  }) {
    final displayLabel = label.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
    final initial = displayLabel.isNotEmpty ? displayLabel[0].toUpperCase() : '?';

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isOverflow
                    ? null
                    : LinearGradient(
                        colors: [color.withAlpha(220), color.withAlpha(100)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                color: isOverflow ? color.withAlpha(30) : null,
              ),
              padding: const EdgeInsets.all(2),
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).scaffoldBackgroundColor),
                padding: const EdgeInsets.all(1.5),
                child: ClipOval(
                  child: profileUrl != null
                      ? CachedNetworkImage(imageUrl: profileUrl, fit: BoxFit.cover, errorWidget: (_, __, ___) => _storyInner(initial, icon, color))
                      : _storyInner(initial, icon, color),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 46,
              child: Text(
                displayLabel.length > 7 ? '${displayLabel.substring(0, 7)}…' : displayLabel,
                style: TextStyle(fontSize: 9, color: null, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _storyInner(String initial, IconData? icon, Color color) {
    return Container(
      color: color.withAlpha(18),
      child: Center(
        child: icon != null
            ? Icon(icon, size: 16, color: color)
            : Text(initial, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
      ),
    );
  }

  Widget _buildDmTile(_DmItem item) {
    final contact = item.contact;
    final senderName = item.lastMessage.senderName;
    final label = contact.name?.isNotEmpty == true
        ? contact.name!
        : (senderName != null && senderName.isNotEmpty)
            ? senderName
            : '#${contact.shortId}';
    final hasUnread = item.unread > 0;
    final myPubkey = widget.messageService.publicKey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openDm(contact, resolvedName: label),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Stack(
                  children: [
                    _avatar(_safeInitial(label), item.isNearby ? AppColors.mint.withAlpha(18) : Theme.of(context).cardColor, item.isNearby ? AppColors.mint : Theme.of(context).colorScheme.onSurface.withAlpha(160)),
                    if (hasUnread)
                      Positioned(
                        right: -1, top: -1,
                        child: Container(
                          width: 18, height: 18,
                          decoration: BoxDecoration(color: AppColors.mint, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).cardColor, width: 2)),
                          child: Center(child: Text(item.unread > 9 ? '9+' : '${item.unread}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white))),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(label, style: TextStyle(fontSize: 14, fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500), overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(item.lastMessage.timestamp),
                            style: TextStyle(fontSize: 10, color: hasUnread ? AppColors.mint : AppColors.textMuted, fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            item.lastMessage.transport == 'bitchat' ? Icons.sensors : Icons.cloud_outlined,
                            size: 10,
                            color: AppColors.textMuted.withAlpha(120),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.lastMessage.senderPubkey == myPubkey
                                  ? 'You: ${_previewText(item.lastMessage)}'
                                  : _previewText(item.lastMessage),
                              style: TextStyle(fontSize: 12, color: hasUnread ? Theme.of(context).colorScheme.onSurface.withAlpha(180) : AppColors.textMuted, fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted.withAlpha(100)),
              ],
            ),
          ),
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
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withAlpha(15),
                border: Border.all(color: AppColors.primary.withAlpha(40), width: 1.5),
              ),
              child: Icon(Icons.chat_bubble_outline, size: 32, color: AppColors.primary.withAlpha(160)),
            ),
            const SizedBox(height: 20),
            const Text(
              'No chats yet',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Share your ID with friends so they can message you.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted, height: 1.5),
              textAlign: TextAlign.center,
            ),
            if (shortId.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ShortIdChip(shortId: shortId),
            ],
          ],
        ),
      ),
    );
  }

  String _safeInitial(String text) => text.isNotEmpty ? text[0] : '?';

  Widget _avatar(String char, Color bg, Color fg) {
    return Container(
      width: 42, height: 42,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Center(child: Text(char.toUpperCase(), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: fg))),
    );
  }

  String _previewText(Message msg) {
    switch (msg.type) {
      case 'image': return '📷 Photo';
      case 'voice_note': return '🎤 Voice message';
      default: return msg.content;
    }
  }

  String _formatTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(msgDay).inDays;
    if (diff == 0) return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][dt.weekday - 1];
    return '${dt.day}/${dt.month}/${dt.year % 100}';
  }
}

// ── Short ID copy chip (used in empty state) ──────────────────────────────────

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
          color: _copied
              ? AppColors.primary.withAlpha(20)
              : AppColors.primary.withAlpha(10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.primary.withAlpha(_copied ? 80 : 40),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '#${widget.shortId}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: AppColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}
