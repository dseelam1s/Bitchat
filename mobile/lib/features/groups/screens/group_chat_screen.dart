import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/groups/services/group_service.dart';

/// Group conversation. In blind groups, incoming messages carry a
/// 'Member N' senderLabel from the server, so members never see each
/// other's identities — only the admin does.
class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final DatabaseService dbService;
  final GroupService groupService;
  final String myPubkey;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.dbService,
    required this.groupService,
    required this.myPubkey,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  Map<String, dynamic>? _group;
  List<Message> _messages = [];
  StreamSubscription? _sub;

  // Stable colour per senderLabel so 'Member 3' keeps one colour.
  static const _palette = [
    Color(0xFF3D5AFE), Color(0xFF00A8B5), Color(0xFF7C4DFF),
    Color(0xFF0091EA), Color(0xFF2E9E5B), Color(0xFFD81B60),
    Color(0xFF5C74FF), Color(0xFF00B8D4), Color(0xFFFF8F00),
  ];

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.groupService.groupUpdates.listen((gid) {
      if (gid == widget.groupId) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final group = await widget.dbService.getGroup(widget.groupId);
    final msgs = await widget.dbService.getGroupMessages(widget.groupId);
    if (!mounted) return;
    setState(() {
      _group = group;
      _messages = msgs;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    widget.groupService.sendGroupMessage(widget.groupId, text);
  }

  Color _colorFor(String label) {
    var h = 0;
    for (final u in label.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return _palette[h % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = _group?['name'] as String? ?? 'Group';
    final count = _group?['memberCount'] as int? ?? 0;
    final blind = (_group?['membersVisible'] as int? ?? 1) == 0;
    final isAdmin = (_group?['isAdmin'] as int? ?? 0) == 1;
    final announcementOnly =
        (_group?['membersCanMessage'] as int? ?? 1) == 0 && !isAdmin;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.primary,
              child: const Icon(Icons.groups, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Row(
                    children: [
                      if (blind)
                        const Padding(
                          padding: EdgeInsets.only(right: 5),
                          child: Icon(Icons.visibility_off,
                              size: 12, color: AppColors.coral),
                        ),
                      Text(
                        count > 0 ? '$count members' : (blind ? 'Blind group' : 'Group'),
                        style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppColors.darkTextMuted
                                : AppColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (blind)
            Container(
              width: double.infinity,
              color: AppColors.coral.withAlpha(20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                isAdmin
                    ? '🕶️ Blind group — members can\'t see each other, only you can'
                    : '🕶️ Blind group — members appear as “Member N”',
                style: const TextStyle(fontSize: 11.5, color: AppColors.coral),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text('No messages yet',
                        style: TextStyle(color: AppColors.textMuted)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _bubble(_messages[i], isDark),
                  ),
          ),
          if (announcementOnly)
            // Announcement group: members read but can't reply.
            Container(
              width: double.infinity,
              color: isDark ? AppColors.darkSurface : Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: SafeArea(
                top: false,
                child: Text(
                  '📣 Only the admin can send messages in this group',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Container(
              color: isDark ? AppColors.darkSurface : Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.darkInputBg : AppColors.inputBg,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          controller: _textController,
                          minLines: 1,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _send,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.send_rounded,
                            color: Colors.white, size: 22),
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

  Widget _bubble(Message m, bool isDark) {
    final isMe = m.senderPubkey == widget.myPubkey;
    final label = isMe ? 'You' : (m.senderLabel ?? 'Member');
    final labelColor = _colorFor(label);
    final dt = DateTime.fromMillisecondsSinceEpoch(m.timestamp * 1000);
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: EdgeInsets.only(
          bottom: 8, left: isMe ? 60 : 0, right: isMe ? 0 : 60),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: isMe
                  ? AppColors.primary
                  : (isDark ? AppColors.darkCard : Colors.white),
              border: isMe
                  ? null
                  : Border.all(
                      color: isDark
                          ? const Color(0xFF3A4386)
                          : const Color(0xFFC9D2F5),
                      width: 1.5),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(isMe ? 18 : 4),
                topRight: Radius.circular(isMe ? 4 : 18),
                bottomLeft: const Radius.circular(18),
                bottomRight: const Radius.circular(18),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isMe)
                  Text(label,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: labelColor)),
                if (!isMe) const SizedBox(height: 2),
                Text(m.content,
                    style: TextStyle(
                        fontSize: 15,
                        height: 1.35,
                        color: isMe
                            ? Colors.white
                            : (isDark
                                ? AppColors.darkTextPrimary
                                : AppColors.textPrimary))),
                const SizedBox(height: 2),
                Text(time,
                    style: TextStyle(
                        fontSize: 10,
                        color: isMe
                            ? Colors.white.withAlpha(165)
                            : AppColors.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
