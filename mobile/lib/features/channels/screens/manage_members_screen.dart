import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/channels/models/channel.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/channels/services/channel_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

class ManageMembersScreen extends StatefulWidget {
  final Channel channel;
  final ChannelService channelService;

  const ManageMembersScreen({
    super.key,
    required this.channel,
    required this.channelService,
  });

  @override
  State<ManageMembersScreen> createState() => _ManageMembersScreenState();
}

class _ManageMembersScreenState extends State<ManageMembersScreen> {
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final members = await widget.channelService.getGroupMembersFromDb(widget.channel.id);
    if (!mounted) return;
    setState(() {
      _members = members;
      _loading = false;
    });
  }

  void _showAddMemberDialog() {
    final shortIdController = TextEditingController();
    String? foundPubkey;
    String? foundName;
    bool isLooking = false;
    String? lookupError;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Add Member'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: shortIdController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: '#729134',
                        prefixText: '#',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  isLooking
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          style: TextButton.styleFrom(foregroundColor: AppColors.mint),
                          onPressed: () async {
                            final raw = shortIdController.text.trim().replaceAll('#', '');
                            if (raw.isEmpty) return;
                            setInner(() { isLooking = true; lookupError = null; });
                            try {
                              final result = await ServerService().lookupByShortId(raw);
                              if (!ctx.mounted) return;
                              if (result != null) {
                                foundPubkey = result['pubkey'] as String?;
                                foundName = (result['display_name'] as String? ?? '').trim();
                                setInner(() => isLooking = false);
                              } else {
                                setInner(() {
                                  isLooking = false;
                                  lookupError = 'User #$raw not found on server';
                                });
                              }
                            } catch (_) {
                              if (!ctx.mounted) return;
                              setInner(() {
                                isLooking = false;
                                lookupError = 'Lookup failed';
                              });
                            }
                          },
                          child: const Text('Look Up'),
                        ),
                ],
              ),
              if (lookupError != null) ...[
                const SizedBox(height: 6),
                Text(lookupError!, style: const TextStyle(fontSize: 11, color: AppColors.error)),
              ],
              if (foundPubkey != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.mint.withAlpha(15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.mint.withAlpha(60)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (foundName?.isNotEmpty == true)
                        Text(foundName!,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                        '#${Contact.shortIdFor(foundPubkey!)}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.mint, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: foundPubkey != null
                  ? () async {
                      final pubkey = foundPubkey!;
                      final name = foundName ?? '';
                      final shortId = Contact.shortIdFor(pubkey);
                      await widget.channelService.addGroupMember(
                          widget.channel.id, pubkey, name, shortId);
                      if (ctx.mounted) Navigator.pop(ctx);
                      _loadMembers();
                    }
                  : null,
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final pubkey = member['pubkey'] as String;
    final name = (member['displayName'] as String?)?.isNotEmpty == true
        ? member['displayName'] as String
        : '#${member['shortId'] ?? Contact.shortIdFor(pubkey)}';

    // Cannot remove self (admin)
    if (pubkey == widget.channelService.myPubkey) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text('Remove $name from this group?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.channelService.removeGroupMember(widget.channel.id, pubkey);
    _loadMembers();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.channel.name} — Members'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1, size: 22),
            tooltip: 'Add member',
            onPressed: _showAddMemberDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _members.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.group_outlined,
                          size: 40, color: AppColors.textMuted.withAlpha(80)),
                      const SizedBox(height: 16),
                      const Text('No members yet',
                          style: TextStyle(fontSize: 15)),
                      const SizedBox(height: 6),
                      Text('Tap + to add members by Short ID',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textMuted.withAlpha(150))),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _members.length,
                  itemBuilder: (_, i) {
                    final member = _members[i];
                    final pubkey = member['pubkey'] as String;
                    final name = (member['displayName'] as String?)?.isNotEmpty == true
                        ? member['displayName'] as String
                        : null;
                    final shortId = member['shortId'] as String? ?? Contact.shortIdFor(pubkey);
                    final isAdmin = pubkey == widget.channel.adminPubkey;
                    final isMe = pubkey == widget.channelService.myPubkey;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                      child: Material(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              // Avatar
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: isAdmin
                                      ? AppColors.amber.withAlpha(18)
                                      : AppColors.mint.withAlpha(10),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isAdmin
                                        ? AppColors.amber.withAlpha(60)
                                        : AppColors.divider.withAlpha(60),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    ((name?.isNotEmpty == true ? name! : shortId)[0])
                                        .toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: isAdmin ? AppColors.amber : null,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (name != null)
                                          Text(name,
                                              style: const TextStyle(
                                                  fontSize: 14, fontWeight: FontWeight.w500)),
                                        if (isAdmin) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppColors.amber.withAlpha(15),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: const Text('Admin',
                                                style: TextStyle(
                                                    fontSize: 9,
                                                    color: AppColors.amber,
                                                    fontWeight: FontWeight.w700)),
                                          ),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      '#$shortId',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.mint,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                              // Remove button (not for self)
                              if (!isMe)
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline,
                                      size: 20, color: AppColors.error),
                                  tooltip: 'Remove',
                                  onPressed: () => _removeMember(member),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMemberDialog,
        child: const Icon(Icons.person_add_alt_1, size: 22),
      ),
    );
  }
}
