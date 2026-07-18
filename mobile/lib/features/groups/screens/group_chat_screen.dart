import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/widgets/voice_player.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
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
  final _recorder = AudioRecorder();
  Map<String, dynamic>? _group;
  List<Message> _messages = [];
  StreamSubscription? _sub;
  bool _isRecording = false;
  int _recordSecs = 0;
  Timer? _recordTimer;
  bool _sendingMedia = false;
  List<Map<String, dynamic>>? _serverMembers;

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
    _syncFromServer();
    _sub = widget.groupService.groupUpdates.listen((gid) {
      if (gid == widget.groupId) _load();
    });
  }

  /// Pull fresh group metadata (member count, name, toggles) — joiners
  /// otherwise only know what the invite carried (memberCount 0).
  Future<void> _syncFromServer() async {
    final info = await ServerService().getGroupInfo(widget.groupId);
    if (info == null) return;
    await widget.dbService.updateGroupInfo(
      widget.groupId,
      name: info['name'] as String?,
      memberCount: (info['member_count'] as num?)?.toInt(),
      membersVisible: info['members_visible'] as bool?,
      membersCanMessage: info['members_can_message'] as bool?,
    );
    _serverMembers = (info['members'] as List?)
        ?.map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    if (mounted) _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recordTimer?.cancel();
    _recorder.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickAndSendImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    debugPrint('[group-media] picker returned: ${picked?.path}');
    if (picked == null || !mounted) return;
    setState(() => _sendingMedia = true);
    final ok = await widget.groupService
        .sendGroupImage(widget.groupId, File(picked.path));
    if (!mounted) return;
    setState(() => _sendingMedia = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Couldn\'t send the photo — check your connection')));
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/grec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path);
    _recordTimer?.cancel();
    setState(() {
      _isRecording = true;
      _recordSecs = 0;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSecs++);
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    final secs = _recordSecs;
    if (mounted) setState(() => _isRecording = false);
    if (!send || path == null || secs < 1) return;
    setState(() => _sendingMedia = true);
    final ok = await widget.groupService
        .sendGroupVoice(widget.groupId, File(path), secs);
    if (!mounted) return;
    setState(() => _sendingMedia = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Couldn\'t send the voice note — check your connection')));
    }
  }

  Future<void> _load() async {
    final group = await widget.dbService.getGroup(widget.groupId);
    final msgs = await widget.dbService.getGroupMessages(widget.groupId);
    // Being in the room means you've seen it — clears the unread badge.
    await widget.dbService.markGroupMessagesRead(widget.groupId, widget.myPubkey);
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

  Future<void> _showGroupInfo() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final g = _group;
    if (g == null) return;
    final blind = (g['membersVisible'] as int? ?? 1) == 0;
    final announcement = (g['membersCanMessage'] as int? ?? 1) == 0;
    final isAdmin = (g['isAdmin'] as int? ?? 0) == 1;
    final count = g['memberCount'] as int? ?? 0;
    final members = _serverMembers;
    final contacts = await widget.dbService.getAllContacts();
    final nameFor = {for (final c in contacts) c.pubkey: c.name};
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 22, 24, 22 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primary,
                child: const Icon(Icons.groups, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(g['name'] as String? ?? 'Group',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      Text('$count ${count == 1 ? 'member' : 'members'}',
                          style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.darkTextMuted
                                  : AppColors.textMuted)),
                    ]),
              ),
            ]),
            const SizedBox(height: 14),
            if (blind)
              _infoTag(
                  '🕶️',
                  isAdmin
                      ? 'Blind group — only you see the members'
                      : 'Blind group — members appear as “Member N”'),
            if (announcement)
              _infoTag('📣',
                  isAdmin
                      ? 'Announcement group — only you can send'
                      : 'Announcement group — only the admin can send'),
            if (blind || announcement) const SizedBox(height: 8),
            if (members != null && members.isNotEmpty) ...[
              Text('MEMBERS',
                  style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w800,
                      color: isDark
                          ? AppColors.darkTextMuted
                          : AppColors.textMuted)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in members)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 15,
                            backgroundColor: _colorFor(
                                m['pubkey'] as String? ?? ''),
                            child: Text(
                              ((m['alias_n'] as num?)?.toInt() ?? 0) == 0
                                  ? '👑'
                                  : '${m['alias_n']}',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              (m['pubkey'] as String?) == widget.myPubkey
                                  ? 'You'
                                  : (nameFor[m['pubkey']] ??
                                      '#${Contact.shortIdFor(m['pubkey'] as String? ?? '')}'),
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (((m['alias_n'] as num?)?.toInt() ?? -1) == 0)
                            Text('admin',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: isDark
                                        ? AppColors.darkTextMuted
                                        : AppColors.textMuted)),
                        ]),
                      ),
                  ],
                ),
              ),
            ] else if (blind && !isAdmin)
              _infoTag('🔒', 'The member list is hidden in blind groups'),
          ],
        ),
      ),
    );
  }

  Widget _infoTag(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.coral.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$emoji  $text',
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.coral)),
      ),
    );
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
        title: InkWell(
          onTap: _showGroupInfo,
          child: Row(
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
                          count > 0
                              ? '$count members · tap for info'
                              : (blind ? 'Blind group' : 'Group'),
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
                child: _isRecording
                    ? Row(children: [
                        const SizedBox(width: 6),
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                              color: AppColors.coral, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Recording  ${_recordSecs ~/ 60}:${(_recordSecs % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: AppColors.coral),
                          onPressed: () => _stopRecording(send: false),
                        ),
                        GestureDetector(
                          onTap: () => _stopRecording(send: true),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle),
                            child: const Icon(Icons.send_rounded,
                                color: Colors.white, size: 22),
                          ),
                        ),
                      ])
                    : Row(
                        children: [
                          IconButton(
                            onPressed: _sendingMedia ? null : _pickAndSendImage,
                            tooltip: 'Send a photo',
                            icon: _sendingMedia
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Icon(Icons.add_photo_alternate_outlined,
                                    color: isDark
                                        ? AppColors.darkTextMuted
                                        : AppColors.textMuted),
                          ),
                          Expanded(
                            child: Container(
                              constraints:
                                  const BoxConstraints(minHeight: 46),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? AppColors.darkInputBg
                                    : AppColors.inputBg,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: isDark
                                      ? AppColors.darkDivider
                                      : AppColors.divider,
                                  width: 1,
                                ),
                              ),
                              child: TextField(
                                controller: _textController,
                                minLines: 1,
                                maxLines: 5,
                                decoration: const InputDecoration(
                                  hintText: 'Message',
                                  border: InputBorder.none,
                                  // Theme sets filled:true with its own 16px
                                  // radius, which paints a rectangle inside
                                  // the pill container. Opt out.
                                  filled: false,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 11),
                                ),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _startRecording,
                            tooltip: 'Record a voice note',
                            icon: Icon(Icons.mic_none,
                                color: isDark
                                    ? AppColors.darkTextMuted
                                    : AppColors.textMuted),
                          ),
                          GestureDetector(
                            onTap: _send,
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                gradient: AppDepth.cobalt,
                                shape: BoxShape.circle,
                                boxShadow: AppDepth.lift(AppColors.primary),
                              ),
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
              // Match the DM bubble language: gradient + coloured lift out,
              // airy outline in.
              color: isMe ? null : (isDark ? AppColors.darkCard : Colors.white),
              gradient: isMe
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: isDark
                          ? const [Color(0xFF4A5CE0), Color(0xFF3444C4)]
                          : const [Color(0xFF4B63FF), AppColors.primary],
                    )
                  : null,
              boxShadow: isMe
                  ? AppDepth.soft(AppColors.primary,
                      opacity: isDark ? 0.30 : 0.22)
                  : null,
              border: isMe
                  ? null
                  : Border.all(
                      color: isDark
                          ? const Color(0xFF3A4386)
                          : const Color(0xFFC9D2F5),
                      width: 1.5),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(isMe ? 22 : 6),
                topRight: Radius.circular(isMe ? 6 : 22),
                bottomLeft: const Radius.circular(22),
                bottomRight: const Radius.circular(22),
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
                if (m.type == 'image')
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: m.content,
                      width: 210,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 210,
                        height: 140,
                        color: isDark ? AppColors.darkInputBg : AppColors.inputBg,
                        child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 210,
                        height: 100,
                        alignment: Alignment.center,
                        color: isDark ? AppColors.darkInputBg : AppColors.inputBg,
                        child: const Text('📷 Photo unavailable',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  )
                else if (m.type == 'voice_note')
                  VoicePlayer(
                    source: m.content,
                    secsLabel: m.replySnippet ?? '0',
                    light: isMe,
                    timeLabel: time,
                  )
                else
                  Text(m.content,
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: isMe
                              ? Colors.white
                              : (isDark
                                  ? AppColors.darkTextPrimary
                                  : AppColors.textPrimary))),
                if (m.type != 'voice_note') ...[
                  const SizedBox(height: 2),
                  Text(time,
                      style: TextStyle(
                          fontSize: 10,
                          color: isMe
                              ? Colors.white.withAlpha(165)
                              : AppColors.textMuted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
