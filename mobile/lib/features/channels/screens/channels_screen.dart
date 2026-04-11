import 'dart:async';
import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/channels/models/channel.dart';
import 'package:bitchat_messenger/features/channels/services/channel_service.dart';
import 'package:bitchat_messenger/features/channels/screens/channel_chat_screen.dart';

class ChannelsScreen extends StatefulWidget {
  final ChannelService channelService;

  const ChannelsScreen({super.key, required this.channelService});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  List<Channel> _channels = [];
  StreamSubscription? _channelSub;
  StreamSubscription? _presenceSub;

  @override
  void initState() {
    super.initState();
    _channels = widget.channelService.activeChannels;
    _channelSub = widget.channelService.channelListStream.listen((channels) {
      if (mounted) setState(() => _channels = channels);
    });
    _presenceSub = widget.channelService.presenceStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _channelSub?.cancel();
    _presenceSub?.cancel();
    super.dispose();
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
              // Public / Private toggle
              Row(
                children: [
                  _TypeChip(
                    label: 'Public',
                    icon: Icons.tag,
                    selected: !isPrivate,
                    onTap: () => setInner(() => isPrivate = false),
                  ),
                  const SizedBox(width: 10),
                  _TypeChip(
                    label: 'Private Group',
                    icon: Icons.lock_outline,
                    selected: isPrivate,
                    onTap: () => setInner(() => isPrivate = true),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isPrivate
                    ? 'Invite-only. Add members by Short ID.'
                    : 'Visible to all nearby devices.',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  if (isPrivate) {
                    widget.channelService.createPrivateGroup(name);
                  } else {
                    widget.channelService.createChannel(name);
                  }
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

  void _showJoinByLinkDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Channel'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste invite link',
            prefixIcon: Icon(Icons.link, size: 20),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final link = controller.text.trim();
              if (link.isNotEmpty) {
                final channel = await widget.channelService.joinFromInviteLink(link);
                if (ctx.mounted) Navigator.pop(ctx);
                if (channel != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Joined #${channel.name}')),
                  );
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid invite link')),
                  );
                }
              }
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final defaultChannel = _channels.where((c) => c.isDefault).toList();
    final joinedChannels = _channels.where((c) => !c.isDefault && !c.isPrivate && c.joined).toList();
    final discoveredChannels = _channels.where((c) => !c.isDefault && !c.isPrivate && !c.joined).toList();

    final privateGroups = _channels.where((c) => !c.isDefault && c.isPrivate && c.joined).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link, size: 22),
            tooltip: 'Join by invite link',
            onPressed: _showJoinByLinkDialog,
          ),
        ],
      ),
      body: _channels.isEmpty
          ? const Center(
              child: Text(
                'No channels yet',
                style: TextStyle(color: AppColors.textMuted),
              ),
            )
          : ListView(
              children: [
                // Default "Nearby" channel
                for (final channel in defaultChannel)
                  _ChannelTile(
                    channel: channel,
                    memberCount: widget.channelService.getChannelMemberCount(channel.id),
                    onTap: () => _openChannel(channel),
                  ),

                // Private groups (invite-only, only shown to members)
                if (privateGroups.isNotEmpty) ...[
                  const _SectionHeader(title: 'PRIVATE GROUPS'),
                  for (final channel in privateGroups)
                    _ChannelTile(
                      channel: channel,
                      memberCount: widget.channelService.getChannelMemberCount(channel.id),
                      onTap: () => _openChannel(channel),
                    ),
                ],

                // Joined public channels
                if (joinedChannels.isNotEmpty) ...[
                  const _SectionHeader(title: 'JOINED CHANNELS'),
                  for (final channel in joinedChannels)
                    _ChannelTile(
                      channel: channel,
                      memberCount: widget.channelService.getChannelMemberCount(channel.id),
                      onTap: () => _openChannel(channel),
                      trailing: _JoinLeaveButton(
                        joined: true,
                        onPressed: () => widget.channelService.leaveChannel(channel.id),
                      ),
                    ),
                ],

                // Discovered (not joined) public channels
                if (discoveredChannels.isNotEmpty) ...[
                  const _SectionHeader(title: 'DISCOVERED NEARBY'),
                  for (final channel in discoveredChannels)
                    _ChannelTile(
                      channel: channel,
                      memberCount: widget.channelService.getChannelMemberCount(channel.id),
                      onTap: () => _openChannel(channel),
                      trailing: _JoinLeaveButton(
                        joined: false,
                        onPressed: () => widget.channelService.joinChannel(channel.id),
                      ),
                    ),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateChannelDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _JoinLeaveButton extends StatelessWidget {
  final bool joined;
  final VoidCallback onPressed;

  const _JoinLeaveButton({required this.joined, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: joined ? AppColors.error.withAlpha(20) : AppColors.mint.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          joined ? 'Leave' : 'Join',
          style: TextStyle(
            color: joined ? AppColors.error : AppColors.mint,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final int memberCount;
  final VoidCallback onTap;
  final Widget? trailing;

  const _ChannelTile({
    required this.channel,
    required this.memberCount,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDefault = channel.isDefault;
    final isPrivate = channel.isPrivate;
    final color = isDefault ? AppColors.mint : isPrivate ? AppColors.amber : AppColors.blue;
    final icon = isDefault ? Icons.cell_tower : isPrivate ? Icons.lock_outline : Icons.tag;
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        channel.name,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              isDefault
                  ? 'Public broadcast to nearby devices'
                  : isPrivate
                      ? 'Private group — invite only'
                      : 'Created by ${channel.creatorName.isNotEmpty ? channel.creatorName : 'Unknown'}',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (memberCount > 0) ...[
            const SizedBox(width: 8),
            Icon(Icons.people, size: 12, color: AppColors.mint.withAlpha(180)),
            const SizedBox(width: 3),
            Text(
              '$memberCount',
              style: TextStyle(
                color: AppColors.mint.withAlpha(180),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
      trailing: trailing ??
          const Icon(
            Icons.chevron_right,
            color: AppColors.textMuted,
            size: 20,
          ),
      onTap: onTap,
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.mint : AppColors.textMuted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.mint.withAlpha(15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.mint.withAlpha(80) : AppColors.divider.withAlpha(80),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}
