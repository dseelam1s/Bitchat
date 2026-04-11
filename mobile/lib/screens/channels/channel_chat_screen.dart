import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme.dart';
import '../../models/channel.dart';
import '../../models/channel_message.dart';
import '../../services/channel/channel_service.dart';
import 'manage_members_screen.dart';

class ChannelChatScreen extends StatefulWidget {
  final Channel channel;
  final ChannelService channelService;

  const ChannelChatScreen({
    super.key,
    required this.channel,
    required this.channelService,
  });

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  List<ChannelMessage> _messages = [];
  List<ChannelMember> _members = [];
  bool _showMembers = false;
  late Channel _channel;
  StreamSubscription? _messageSub;
  StreamSubscription? _presenceSub;
  StreamSubscription? _channelListSub;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _loadMessages();
    _refreshMembers();

    _messageSub = widget.channelService.channelMessageStream.listen((msg) {
      if (msg.channelId == _channel.id) {
        _loadMessages();
      }
    });

    _presenceSub = widget.channelService.presenceStream.listen((_) {
      _refreshMembers();
    });

    // Listen for join/leave state changes
    _channelListSub = widget.channelService.channelListStream.listen((channels) {
      for (final ch in channels) {
        if (ch.id == _channel.id) {
          if (mounted) setState(() => _channel = ch);
          break;
        }
      }
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _presenceSub?.cancel();
    _channelListSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _refreshMembers() {
    if (!mounted) return;
    setState(() {
      _members = widget.channelService.getChannelMembers(_channel.id);
    });
  }

  Future<void> _loadMessages() async {
    final messages = await widget.channelService.getMessages(_channel.id);
    if (!mounted) return;
    setState(() => _messages = messages);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    widget.channelService.sendMessage(_channel.id, text);
  }

  void _copyInviteLink() {
    Clipboard.setData(ClipboardData(text: _channel.inviteLink));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied!')),
    );
  }

  void _joinChannel() {
    widget.channelService.joinChannel(_channel.id);
  }

  void _leaveChannel() {
    widget.channelService.leaveChannel(_channel.id);
  }

  bool get _canSend => _channel.isDefault || _channel.joined;

  @override
  Widget build(BuildContext context) {
    final memberCount = widget.channelService.getChannelMemberCount(_channel.id);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => setState(() => _showMembers = !_showMembers),
          child: Row(
            children: [
              Icon(
                _channel.isDefault ? Icons.cell_tower : Icons.tag,
                color: AppColors.mint,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _channel.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    if (memberCount > 0)
                      Text(
                        '$memberCount nearby',
                        style: const TextStyle(
                          color: AppColors.mint,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Manage members button — private group admin only
          if (_channel.isPrivate && widget.channelService.myPubkey == _channel.adminPubkey)
            IconButton(
              icon: const Icon(Icons.group_add_outlined, size: 22),
              tooltip: 'Manage members',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ManageMembersScreen(
                    channel: _channel,
                    channelService: widget.channelService,
                  ),
                ),
              ),
            ),
          // Invite link button (only for public custom channels)
          if (!_channel.isDefault && !_channel.isPrivate)
            IconButton(
              icon: const Icon(Icons.share, size: 20),
              tooltip: 'Copy invite link',
              onPressed: _copyInviteLink,
            ),
          // Leave button (only for joined custom channels)
          if (!_channel.isDefault && _channel.joined)
            IconButton(
              icon: const Icon(Icons.exit_to_app, size: 20),
              tooltip: 'Leave channel',
              onPressed: () {
                _leaveChannel();
                Navigator.pop(context);
              },
            ),
          IconButton(
            icon: Icon(
              _showMembers ? Icons.people : Icons.people_outline,
              color: _showMembers ? AppColors.mint : null,
              size: 22,
            ),
            onPressed: () => setState(() => _showMembers = !_showMembers),
          ),
        ],
      ),
      body: Column(
        children: [
          // Members panel (collapsible)
          if (_showMembers)
            _MembersPanel(members: _members, memberCount: memberCount),

          // Join banner for custom channels not yet joined
          if (!_channel.isDefault && !_channel.joined)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: AppColors.blue.withAlpha(15),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Join this channel to send messages',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  GestureDetector(
                    onTap: _joinChannel,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.mint,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Join',
                        style: TextStyle(
                          color: AppColors.bg,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Info banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.mint.withAlpha(10),
            child: Text(
              _channel.isDefault
                  ? 'Public broadcast — visible to all nearby devices'
                  : _channel.isPrivate
                      ? 'Private group — only invited members can participate'
                      : _channel.joined
                          ? 'Public channel — messages sent via mesh & Nostr'
                          : 'Public channel — join to participate',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          // Messages
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'No messages yet.\nSay something!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _ChannelMessageBubble(message: _messages[index]);
                    },
                  ),
          ),

          // Input bar (disabled if not joined for custom channels)
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor, width: 0.5)),
              color: cs.surface,
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      enabled: _canSend,
                      decoration: InputDecoration(
                        hintText: _canSend
                            ? 'Message #${_channel.name}'
                            : 'Join to send messages',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: theme.inputDecorationTheme.fillColor,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: _canSend ? (_) => _sendMessage() : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _canSend ? _sendMessage : null,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _canSend ? AppColors.mint : cs.onSurface.withAlpha(60),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        Icons.send,
                        size: 18,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MembersPanel extends StatelessWidget {
  final List<ChannelMember> members;
  final int memberCount;

  const _MembersPanel({required this.members, required this.memberCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor, width: 0.5)),
      ),
      child: members.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                memberCount > 0
                    ? '$memberCount device${memberCount == 1 ? '' : 's'} nearby'
                    : 'No one nearby yet',
                style: TextStyle(color: cs.onSurface.withAlpha(100), fontSize: 13),
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              shrinkWrap: true,
              itemCount: members.length,
              itemBuilder: (context, index) {
                final member = members[index];
                final displayName = member.name.isNotEmpty
                    ? member.name
                    : member.pubkey.length >= 8
                        ? '${member.pubkey.substring(0, 8)}...'
                        : member.pubkey;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.online,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          displayName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        member.pubkey.length >= 6
                            ? '${member.pubkey.substring(0, 6)}...'
                            : member.pubkey,
                        style: TextStyle(
                          color: cs.onSurface.withAlpha(100),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _ChannelMessageBubble extends StatelessWidget {
  final ChannelMessage message;

  const _ChannelMessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final time = DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final displayName = message.senderName.isNotEmpty
        ? message.senderName
        : message.senderPubkey.length >= 8
            ? '${message.senderPubkey.substring(0, 8)}...'
            : message.senderPubkey;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    color: AppColors.mint,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  timeStr,
                  style: TextStyle(
                    color: cs.onSurface.withAlpha(100),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              message.content,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
