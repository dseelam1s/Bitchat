import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/channel.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../services/call/call_service.dart';
import '../../services/channel/channel_service.dart';
import '../../services/database_service.dart';
import '../../services/message/message_service.dart';
import '../../services/profile_sync_service.dart';
import '../channels/channel_chat_screen.dart';
import '../chat/chat_screen.dart';

// ── Unified list item ─────────────────────────────────────────────────────────

abstract class _ChatItem {
  int get sortTimestamp;
}

class _DmItem implements _ChatItem {
  final Contact contact;
  final Message lastMessage;
  final int unread;
  final bool isNearby;
  _DmItem({required this.contact, required this.lastMessage, required this.unread, required this.isNearby});
  @override
  int get sortTimestamp => lastMessage.timestamp;
}

class _ChannelItem implements _ChatItem {
  final Channel channel;
  final String? lastText;
  final int lastTs;
  final int unread;
  _ChannelItem({required this.channel, required this.lastText, required this.lastTs, required this.unread});
  @override
  int get sortTimestamp => lastTs;
}

// ── ChatsScreen ───────────────────────────────────────────────────────────────

class ChatsScreen extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final ChannelService channelService;
  final CallService? callService;

  const ChatsScreen({
    super.key,
    required this.dbService,
    required this.messageService,
    required this.channelService,
    this.callService,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Contact> _contacts = [];
  Map<String, Message> _lastMessages = {};
  Map<String, int> _unreadCounts = {};
  List<Channel> _channels = [];
  StreamSubscription? _nearbySub;
  StreamSubscription? _messageSub;
  StreamSubscription? _channelSub;
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
    _channelSub = widget.channelService.channelListStream.listen((channels) {
      if (mounted) setState(() => _channels = channels);
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
    _channelSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final contacts = await widget.dbService.getContacts();
    final lastMessages = await widget.messageService.getLastMessages();
    final unreadCounts = await widget.messageService.getUnreadCounts();
    final channels = widget.channelService.activeChannels;
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _lastMessages = lastMessages;
      _unreadCounts = unreadCounts;
      _channels = channels;
    });
  }

  void _openDm(Contact contact) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactPubkey: contact.pubkey,
          contactName: contact.name,
          contactProfilePictureUrl: contact.profilePictureUrl,
          contactProfilePictureLocalPath: contact.profilePictureLocalPath,
          messageService: widget.messageService,
          callService: widget.callService,
        ),
      ),
    ).then((_) => _loadAll());
  }

  void _openChannel(Channel channel) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelChatScreen(
          channel: channel,
          channelService: widget.channelService,
        ),
      ),
    );
  }

  void _openNearbyUser(String pubkey, {String? suggestedName}) async {
    final contact = _contacts.firstWhere(
      (c) => c.pubkey == pubkey,
      orElse: () => Contact(pubkey: pubkey),
    );
    if (_contacts.any((c) => c.pubkey == pubkey) && !contact.isPending) {
      _openDm(contact);
      return;
    }
    // Unknown nearby user — ask for name then add
    final cleanName = suggestedName?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
    final nameController = TextEditingController(text: cleanName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Nearby User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surface, borderRadius: BorderRadius.circular(8)),
              child: Text(
                '#${Contact.shortIdFor(pubkey)}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.mint, letterSpacing: 2),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'Give them a name'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, nameController.text.trim()), child: const Text('Add & Chat')),
        ],
      ),
    );
    if (name == null) return;
    final displayName = name.isNotEmpty ? name : null;
    await widget.dbService.insertContact(Contact(pubkey: pubkey, name: displayName));
    await _loadAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(displayName != null ? '$displayName added to contacts' : 'Contact added'),
      duration: const Duration(seconds: 2),
    ));
    _openDm(Contact(pubkey: pubkey, name: displayName));
  }

  void _showCreateChannelDialog() {
    final controller = TextEditingController();
    bool isPrivate = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Create Channel'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Channel name'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _typeChip('Public', Icons.tag, !isPrivate, () => setInner(() => isPrivate = false)),
                  const SizedBox(width: 10),
                  _typeChip('Private', Icons.lock_outline, isPrivate, () => setInner(() => isPrivate = true)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isPrivate ? 'Invite-only. Add members by Short ID.' : 'Visible to all nearby devices.',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  if (isPrivate) widget.channelService.createPrivateGroup(name);
                  else widget.channelService.createChannel(name);
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(String label, IconData icon, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.mint.withAlpha(20) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? AppColors.mint : AppColors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? AppColors.mint : AppColors.textMuted),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: selected ? AppColors.mint : AppColors.textMuted, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  List<_ChatItem> _buildUnifiedList() {
    final nearby = widget.messageService.nearbyUsers;
    final items = <_ChatItem>[];

    // DM conversations
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
    // Unknown senders (not in contacts)
    for (final pubkey in _lastMessages.keys) {
      if (!contactPubkeys.contains(pubkey)) {
        final lastMsg = _lastMessages[pubkey]!;
        items.add(_DmItem(
          contact: Contact(pubkey: pubkey),
          lastMessage: lastMsg,
          unread: _unreadCounts[pubkey] ?? 0,
          isNearby: nearby.contains(pubkey),
        ));
      }
    }

    // Channel conversations (exclude default nearby channel — it's in the stories bar)
    for (final channel in _channels) {
      if (channel.isDefault) continue;
      items.add(_ChannelItem(
        channel: channel,
        lastText: null,
        lastTs: channel.lastActivityAt,
        unread: 0,
      ));
    }

    items.sort((a, b) => b.sortTimestamp.compareTo(a.sortTimestamp));
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final nearby = widget.messageService.nearbyUsers.toList();
    final names = widget.messageService.nearbyDeviceNames;
    final contactMap = {for (final c in _contacts) c.pubkey: c};
    final defaultChannel = _channels.firstWhere((c) => c.isDefault, orElse: () => Channel(id: 'nearby', name: 'Nearby', creatorPubkey: '', createdAt: 0, lastActivityAt: 0, isDefault: true));
    final items = _buildUnifiedList();
    final mode = widget.messageService.mode;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.hub, size: 20, color: AppColors.mint.withAlpha(180)),
            const SizedBox(width: 10),
            const Text('Chats'),
          ],
        ),
        actions: [
          // Mesh node count + connection mode chip
          Tooltip(
            message: nearby.isEmpty
                ? 'No mesh nodes in range'
                : '${nearby.length} mesh node${nearby.length == 1 ? '' : 's'} in range',
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _modeColor(mode).withAlpha(12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _modeColor(mode).withAlpha(40)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_modeIcon(mode), size: 14, color: _modeColor(mode)),
                  if (nearby.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    Text(
                      '${nearby.length}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _modeColor(mode),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Stories bar — nearby broadcast first, then nearby devices
          _buildStoriesBar(nearby, names, contactMap, defaultChannel),

          // Unified list
          Expanded(
            child: items.isEmpty
                ? _buildEmpty()
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 100),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final item = items[i];
                      if (item is _DmItem) return _buildDmTile(item);
                      if (item is _ChannelItem) return _buildChannelTile(item);
                      return const SizedBox.shrink();
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'chats_fab',
        onPressed: _showCreateChannelDialog,
        backgroundColor: AppColors.mint,
        foregroundColor: Colors.black,
        tooltip: 'Create channel',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildStoriesBar(List<String> nearby, Map<String, String> names, Map<String, Contact> contactMap, Channel defaultChannel) {
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
          // Nearby broadcast — always first
          _buildStoryBubble(
            label: 'Nearby',
            icon: Icons.cell_tower,
            color: AppColors.mint,
            onTap: () => _openChannel(defaultChannel),
          ),
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
    final label = contact.name?.isNotEmpty == true ? contact.name! : '#${contact.shortId}';
    final hasUnread = item.unread > 0;
    final myPubkey = widget.messageService.publicKey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openDm(contact),
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

  Widget _buildChannelTile(_ChannelItem item) {
    final channel = item.channel;
    final color = channel.isPrivate ? AppColors.amber : AppColors.blue;
    final icon = channel.isPrivate ? Icons.lock_outline : Icons.tag;
    final hasUnread = item.unread > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openChannel(channel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Stack(
                  children: [
                    Container(
                      width: 42, height: 42,
                      decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 18, color: color),
                    ),
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
                          Expanded(child: Text(channel.name, style: TextStyle(fontSize: 14, fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500), overflow: TextOverflow.ellipsis)),
                          if (item.lastTs > 0)
                            Text(_formatTime(item.lastTs), style: TextStyle(fontSize: 10, color: hasUnread ? AppColors.mint : AppColors.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        channel.isPrivate ? 'Private group' : 'Public channel',
                        style: TextStyle(fontSize: 12, color: AppColors.textMuted.withAlpha(150)),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 40, color: AppColors.textMuted.withAlpha(80)),
          const SizedBox(height: 16),
          const Text('No chats yet', style: TextStyle(fontSize: 15, color: null)),
          const SizedBox(height: 6),
          Text(
            'Tap a nearby device in the bar above, or create a channel',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted.withAlpha(150)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  IconData _modeIcon(String mode) {
    if (mode == AppConstants.modeOnline) return Icons.cloud_outlined;
    if (mode == AppConstants.modeOffline) return Icons.sensors;
    return Icons.auto_awesome;
  }

  Color _modeColor(String mode) {
    if (mode == AppConstants.modeOnline) return AppColors.mint;
    if (mode == AppConstants.modeOffline) return AppColors.amber;
    return AppColors.blue;
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
