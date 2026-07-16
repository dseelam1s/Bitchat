import 'dart:async';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
import 'package:bitchat_messenger/features/calls/screens/in_call_screen.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';

const _kAccent = AppColors.primary;
const _kMetaGray = Color(0xFF9AA3C8);

class ChatScreen extends StatefulWidget {
  final String contactPubkey;
  final String? contactName;
  final String? contactProfilePictureUrl;
  final String? contactProfilePictureLocalPath;
  final MessageService messageService;
  final CallService? callService;

  const ChatScreen({
    super.key,
    required this.contactPubkey,
    this.contactName,
    this.contactProfilePictureUrl,
    this.contactProfilePictureLocalPath,
    required this.messageService,
    this.callService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _rangeSub;

  // Presence Field: live range events shown inline in the conversation.
  bool _inRange = false;
  final List<_RangeEvent> _rangeEvents = [];
  late final AnimationController _sendPulse;

  static const _pageSize = 50;
  int _offset = 0;
  bool _isLoadingInitial = true;
  bool _isLoadingMore = false;
  bool _isRefreshing = false;
  bool _pendingRefresh = false;
  bool _hasMore = true;

  String? _displayName;
  String? _localPicPath;

  Message? _replyingTo;

  // Voice notes
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordSecs = 0;
  Timer? _recordTimer;

  bool _contactIsTyping = false;
  Timer? _typingDismissTimer;
  Timer? _myTypingThrottle;
  DateTime? _lastTypingSent;
  StreamSubscription? _typingSub;

  @override
  void initState() {
    super.initState();
    _sendPulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _inRange = widget.messageService.nearbyUsers.contains(widget.contactPubkey);
    _rangeSub = widget.messageService.nearbyChangedStream.listen((set) {
      final now = set.contains(widget.contactPubkey);
      if (now != _inRange && mounted) {
        setState(() {
          _inRange = now;
          _rangeEvents.add(_RangeEvent(
            entered: now,
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ));
        });
      }
    });
    _displayName = widget.contactName;
    _localPicPath = widget.contactProfilePictureLocalPath;
    _syncContactProfile();
    _loadMessages(initial: true);
    widget.messageService.markAsRead(widget.contactPubkey);

    _scrollController.addListener(() {
      if (_scrollController.position.pixels <= 80 && !_isLoadingMore && _hasMore) {
        _loadMoreMessages();
      }
    });

    _messageSub = widget.messageService.messageStream.listen((message) {
      if (message.type == 'status_update') {
        // status_update events carry empty pubkeys, so handle them separately
        // by patching the in-memory list directly (no DB roundtrip needed).
        if (!mounted) return;
        bool found = false;
        setState(() {
          _messages = _messages.map((m) {
            if (m.id == message.id) {
              found = true;
              return m.copyWith(status: message.status);
            }
            return m;
          }).toList();
        });
        // Race condition: status_update arrived before the message was added to
        // _messages (still loading from DB). Fall back to a DB reload — DB is
        // already updated by the time the event fires.
        if (!found) _loadMessages();
        return;
      }
      if (message.senderPubkey == widget.contactPubkey ||
          message.receiverPubkey == widget.contactPubkey) {
        _loadMessages();
        widget.messageService.markAsRead(widget.contactPubkey);
      }
    });

    _typingSub = widget.messageService.typingStream.listen((event) {
      final sender = event['senderPubkey'] as String?;
      if (sender == widget.contactPubkey) {
        _typingDismissTimer?.cancel();
        if (mounted) setState(() => _contactIsTyping = true);
        _typingDismissTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _contactIsTyping = false);
        });
      }
    });

    _textController.addListener(_onTextChanged);
  }

  void _syncContactProfile() {
    () async {
      final updated = await ProfileSyncService().syncContact(
        widget.contactPubkey,
        widget.messageService.dbService,
      );
      if (updated != null && mounted) {
        setState(() {
          if (updated.name?.isNotEmpty == true) _displayName = updated.name;
          if (updated.localPath != null) _localPicPath = updated.localPath;
        });
      }
    }();
  }

  void _onTextChanged() {
    if (_textController.text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSent == null ||
        now.difference(_lastTypingSent!).inMilliseconds > 2000) {
      _lastTypingSent = now;
      widget.messageService.sendTypingIndicator(widget.contactPubkey);
    }
  }

  /// Conversation start: an identity card instead of a bare caption —
  /// who this is, their key, and the present connection context.
  Widget _buildConversationStart(String displayName, bool isDark) {
    final shortId = Contact.shortIdFor(widget.contactPubkey);
    final isNearby =
        widget.messageService.nearbyUsers.contains(widget.contactPubkey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        children: [
          _buildContactAvatar(displayName, 72),
          const SizedBox(height: 10),
          Text(
            displayName,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            '#$shortId',
            style: const TextStyle(
                fontSize: 12, color: _kMetaGray, letterSpacing: 2),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isNearby
                  ? AppColors.coral.withAlpha(22)
                  : (isDark ? AppColors.darkCard : AppColors.card),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isNearby
                  ? '● you\'re near each other right now'
                  : '🔒 end-to-end encrypted',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isNearby
                    ? AppColors.coral
                    : (isDark ? AppColors.darkTextMuted : AppColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Emoji reactions grouped by the message they point at.
  Map<String, List<String>> get _reactionsByTarget {
    final map = <String, List<String>>{};
    for (final m in _messages) {
      if (m.type == 'reaction' && m.replyToId != null) {
        map.putIfAbsent(m.replyToId!, () => []).add(m.content);
      }
    }
    return map;
  }

  /// Messages merged with live range events, chronologically — the
  /// conversation records when you were actually near each other.
  List<Object> get _chatItems {
    if (_rangeEvents.isEmpty) return _messages;
    final items = <Object>[];
    var ei = 0;
    for (final m in _messages) {
      while (ei < _rangeEvents.length &&
          _rangeEvents[ei].timestamp <= m.timestamp) {
        items.add(_rangeEvents[ei++]);
      }
      items.add(m);
    }
    while (ei < _rangeEvents.length) {
      items.add(_rangeEvents[ei++]);
    }
    return items;
  }

  /// Id of the newest visible outgoing message — the only one that shows a
  /// delivery-status word (iMessage style), so the chat stays uncluttered.
  String? get _latestOutgoingMsgId {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == 'delivery_receipt' ||
          m.type == 'read_receipt' ||
          m.type == 'status_update') {
        continue;
      }
      if (m.senderPubkey == widget.messageService.publicKey) return m.id;
    }
    return null;
  }

  Future<void> _loadMessages({bool initial = false}) async {
    if (initial) {
      _offset = 0;
      _hasMore = true;
      _isRefreshing = false;
      _pendingRefresh = false;
      if (mounted) setState(() => _isLoadingInitial = true);
    } else {
      if (_isLoadingMore) { _pendingRefresh = true; return; }
      if (_isRefreshing) { _pendingRefresh = true; return; }
      _isRefreshing = true;
    }

    final messages = await widget.messageService.getChatMessages(
      widget.contactPubkey,
      limit: _pageSize,
      offset: 0,
    );
    if (!mounted) return;

    final atBottom = _scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 80;

    setState(() {
      _messages = messages;
      _offset = messages.length;
      _hasMore = messages.length == _pageSize;
      _isLoadingInitial = false;
      _isRefreshing = false;
    });

    if (initial || atBottom) _scrollToBottom();

    if (_pendingRefresh) {
      _pendingRefresh = false;
      _loadMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    final older = await widget.messageService.getChatMessages(
      widget.contactPubkey,
      limit: _pageSize,
      offset: _offset,
    );
    if (!mounted) return;

    final prevCount = _messages.length;
    setState(() {
      _messages = [...older, ..._messages];
      _offset += older.length;
      _hasMore = older.length == _pageSize;
      _isLoadingMore = false;
    });

    if (_pendingRefresh) {
      _pendingRefresh = false;
      _loadMessages();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final addedCount = _messages.length - prevCount;
      if (addedCount > 0) {
        final approxOffset = _scrollController.position.pixels + addedCount * 60.0;
        _scrollController.jumpTo(
          approxOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
    });
  }

  void _showCallPicker(BuildContext ctx) {
    final cs = widget.callService!;
    if (cs.hasActiveCall) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.call_outlined, color: _kAccent),
                title: const Text('Voice call'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final err = await cs.startCall(widget.contactPubkey, remoteName: widget.contactName);
                  if (!mounted) return;
                  if (err != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    return;
                  }
                  Navigator.push(context, MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, color: _kAccent),
                title: const Text('Video call'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final err = await cs.startCall(
                    widget.contactPubkey,
                    remoteName: widget.contactName,
                    isVideo: true,
                  );
                  if (!mounted) return;
                  if (err != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    return;
                  }
                  Navigator.push(context, MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)));
                },
              ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _sendImageMessage() async {
    final hasInternet = widget.messageService.hasInternet;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: hasInternet ? 70 : 30,
      maxWidth: hasInternet ? 1280 : 640,
      maxHeight: hasInternet ? 1280 : 640,
    );
    if (picked == null) return;
    await widget.messageService.sendImageMessage(File(picked.path), widget.contactPubkey);
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
    await widget.messageService
        .sendVoiceMessage(File(path), secs, widget.contactPubkey);
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    final reply = _replyingTo;
    if (reply != null) setState(() => _replyingTo = null);

    bool anySent = false;
    try {
      final messageId = await widget.messageService.sendMessage(
        widget.contactPubkey,
        text,
        replyToId: reply?.id,
        replySnippet: reply == null
            ? null
            : (reply.type == 'image'
                ? '📷 Photo'
                : reply.content.length > 80
                    ? '${reply.content.substring(0, 80)}…'
                    : reply.content),
      );
      if (messageId != null) {
        final msgs = await widget.messageService.getChatMessages(widget.contactPubkey, limit: 10);
        final msg = msgs.where((m) => m.id == messageId).firstOrNull;
        anySent = msg == null || msg.status != 'pending';
      }
    } catch (_) {}

    if (!anySent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message queued — will send when connection is available'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildContactAvatar(String displayName, double size) {
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    Widget fallback = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    if (_localPicPath != null) {
      return ClipOval(
        child: Image.file(
          File(_localPicPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    if (widget.contactProfilePictureUrl != null) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: widget.contactProfilePictureUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => fallback,
        ),
      );
    }
    return fallback;
  }

  bool _showTimestamp(int msgIndex) {
    if (msgIndex == 0) return true;
    final curr = _messages[msgIndex];
    final prev = _messages[msgIndex - 1];
    return (curr.timestamp - prev.timestamp) > 3600;
  }

  String _formatTimestamp(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final timeStr = '$displayH:$m $period';
    if (msgDay == today) return 'Today $timeStr';
    if (msgDay == yesterday) return 'Yesterday $timeStr';
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return '${days[dt.weekday - 1]} $timeStr';
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _typingSub?.cancel();
    _typingDismissTimer?.cancel();
    _myTypingThrottle?.cancel();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
    _rangeSub?.cancel();
    _sendPulse.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayName = (_displayName?.isNotEmpty == true)
        ? _displayName!
        : widget.contactPubkey.length >= 8
            ? '${widget.contactPubkey.substring(0, 8)}...'
            : widget.contactPubkey.isNotEmpty
                ? widget.contactPubkey
                : '?';

    final isNearby = widget.messageService.nearbyUsers.contains(widget.contactPubkey);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final statusLabel = _contactIsTyping
        ? 'typing…'
        : isNearby
            ? '● IN RANGE · bluetooth'
            : (widget.messageService.hasInternet ? 'Online' : 'Offline');
    final statusOnline = _contactIsTyping || isNearby || widget.messageService.hasInternet;
    final statusColor = _contactIsTyping || isNearby
        ? AppColors.coral
        : statusOnline
            ? AppColors.online
            : AppColors.darkTextMuted;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        leadingWidth: 44,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 18, color: cs.onSurface),
          onPressed: () => Navigator.pop(context),
          padding: const EdgeInsets.only(left: 12),
        ),
        titleSpacing: 0,
        // Presence Field: coral line under the header while they're in range
        bottom: isNearby
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2.5),
                child: Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      AppColors.coral,
                      AppColors.coral.withAlpha(30),
                    ]),
                  ),
                ),
              )
            : null,
        title: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: isNearby
                        ? const Border.fromBorderSide(
                            BorderSide(color: AppColors.coral, width: 2))
                        : null,
                    boxShadow: isNearby
                        ? [
                            BoxShadow(
                              color: AppColors.coral.withAlpha(110),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(isNearby ? 2.0 : 0),
                    child: _buildContactAvatar(displayName, isNearby ? 38 : 42),
                  ),
                ),
                Positioned(
                  bottom: 1,
                  right: 1,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.online,
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.scaffoldBackgroundColor, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            // Flexible + ellipsis: the coral in-range status is wide — without
            // this the title row overflows next to the call buttons.
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Text(
                    statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isNearby && !_contactIsTyping ? 10.5 : 12,
                      color: statusColor,
                      fontWeight:
                          isNearby || _contactIsTyping ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: isNearby && !_contactIsTyping ? 0.5 : 0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (widget.callService != null && widget.messageService.hasInternet)
            IconButton(
              icon: const Icon(Icons.call_outlined, size: 22, color: _kAccent),
              onPressed: () => _showCallPicker(context),
              tooltip: 'Call',
            ),
          if (widget.callService != null && widget.messageService.hasInternet)
            IconButton(
              icon: const Icon(Icons.videocam_outlined, size: 24, color: _kAccent),
              onPressed: () => _showCallPicker(context),
              tooltip: 'Video',
            ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 22, color: cs.onSurface.withAlpha(150)),
            onSelected: (value) async {
              if (value == 'delete') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete conversation'),
                    content: const Text(
                        'All messages with this contact will be deleted. This cannot be undone.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Delete', style: TextStyle(color: AppColors.error)),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  await widget.messageService.deleteConversation(widget.contactPubkey);
                  if (mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: AppColors.error),
                    SizedBox(width: 10),
                    Text('Delete conversation', style: TextStyle(color: AppColors.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // Presence Field: faint beacon rings rise from the bottom —
                // you are the beacon; slightly stronger while they're in range.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _BeaconRingsPainter(
                        isDark: isDark,
                        inRange: isNearby,
                      ),
                    ),
                  ),
                ),
                _isLoadingInitial
                    ? const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _kAccent),
                      )
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildConversationStart(displayName, isDark),
                            // One-tap opener — an empty screen telling you to
                            // type is homework; a wave is an invitation.
                            GestureDetector(
                              onTap: () {
                                widget.messageService.sendMessage(
                                    widget.contactPubkey, '👋');
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 12),
                                decoration: BoxDecoration(
                                  color: _kAccent,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  '👋  Say hi',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        itemCount: _chatItems.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _isLoadingMore
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2, color: _kAccent),
                                      ),
                                    ),
                                  )
                                : _hasMore
                                    ? const SizedBox(height: 4)
                                    : _buildConversationStart(displayName, isDark);
                          }

                          final item = _chatItems[index - 1];
                          if (item is _RangeEvent) {
                            return _RangeDivider(
                              entered: item.entered,
                              name: _displayName ?? displayName,
                              timestamp: item.timestamp,
                            );
                          }
                          final msg = item as Message;
                          if (msg.type == 'delivery_receipt' ||
                              msg.type == 'read_receipt' ||
                              msg.type == 'reaction' ||
                              msg.type == 'status_update') {
                            return const SizedBox.shrink();
                          }

                          final isMe =
                              msg.senderPubkey == widget.messageService.publicKey;
                          final canRetry = isMe &&
                              !(msg.type == 'image' && msg.content.startsWith('local:')) &&
                              !(msg.type == 'voice_note' &&
                                  msg.content.startsWith('local:'));
                          final retryCallback = canRetry
                              ? () => widget.messageService.retryPendingMessages()
                              : null;
                          final hasConn = widget.messageService.hasInternet ||
                              widget.messageService.hasNearbyDevices;

                          final showTs = _showTimestamp(_messages.indexOf(msg));
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            // stretch forces full-width so crossAxisAlignment.end
                            // inside _Bubble aligns against the real screen edge
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showTs)
                                _TimestampSeparator(
                                  label: _formatTimestamp(msg.timestamp),
                                ),
                              _Bubble(
                                message: msg,
                                isMe: isMe,
                                onRetry: retryCallback,
                                hasConnectivity: hasConn,
                                contactName: _displayName ?? displayName,
                                contactLocalPicPath: _localPicPath,
                                contactPicUrl: widget.contactProfilePictureUrl,
                                isLatestOutgoing: msg.id == _latestOutgoingMsgId,
                                reactions:
                                    _reactionsByTarget[msg.id] ?? const [],
                                onReact: (emoji) => widget.messageService
                                    .sendReaction(widget.contactPubkey,
                                        msg.id, emoji),
                                onReply: () =>
                                    setState(() => _replyingTo = msg),
                                onDeleteForMe: () async {
                                  await widget.messageService
                                      .deleteMessageForMe(msg.id);
                                  _loadMessages();
                                },
                                onDeleteForEveryone: () async {
                                  await widget.messageService
                                      .deleteMessageForEveryone(
                                          widget.contactPubkey, msg.id);
                                  _loadMessages();
                                },
                              ),
                            ],
                          );
                        },
                      ),
              ],
            ),
          ),

          // ── Reply preview (composer) ─────────────────────────────────────
          if (_replyingTo != null)
            Container(
              color: isDark ? AppColors.darkSurface : Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Container(width: 3, height: 34, color: AppColors.coral),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyingTo!.senderPubkey ==
                                  widget.messageService.publicKey
                              ? 'You'
                              : (_displayName ?? displayName),
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.coral),
                        ),
                        Text(
                          _replyingTo!.type == 'image'
                              ? '📷 Photo'
                              : _replyingTo!.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: isDark
                                  ? AppColors.darkTextMuted
                                  : AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),

          // ── Input bar ───────────────────────────────────────────────────
          Container(
            color: isDark ? AppColors.darkSurface : Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isRecording)
                    Row(
                      children: [
                        const SizedBox(width: 6),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                              color: AppColors.error, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Recording  ${(_recordSecs ~/ 60).toString().padLeft(1, '0')}:${(_recordSecs % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: AppColors.error, size: 26),
                          onPressed: () => _stopRecording(send: false),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _stopRecording(send: true),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                                color: AppColors.coral, shape: BoxShape.circle),
                            child: const Icon(Icons.send_rounded,
                                color: Colors.white, size: 22),
                          ),
                        ),
                      ],
                    )
                  else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Purple "+" circle — opens image picker
                      GestureDetector(
                        onTap: _sendImageMessage,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                            color: _kAccent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.add, color: Colors.white, size: 22),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Text field pill with emoji icon inside
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44, maxHeight: 120),
                          decoration: BoxDecoration(
                            color: isDark ? AppColors.darkInputBg : AppColors.inputBg,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _textController,
                                  maxLines: 4,
                                  minLines: 1,
                                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                                  decoration: InputDecoration(
                                    hintText: 'Type a message...',
                                    hintStyle: TextStyle(
                                        color: cs.onSurface.withAlpha(90)),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    filled: false,
                                  ),
                                  onSubmitted: (_) => _sendMessage(),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Icon(
                                  Icons.sentiment_satisfied_alt_outlined,
                                  size: 22,
                                  color: cs.onSurface.withAlpha(100),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Mic — hold nothing, tap to record, tap send/cancel
                      IconButton(
                        icon: Icon(Icons.mic_none_rounded,
                            size: 26,
                            color:
                                isDark ? AppColors.darkTextMuted : AppColors.textMuted),
                        onPressed: _startRecording,
                      ),

                      // Send button — coral with a ripple pulse when the
                      // message will travel through the air (no internet,
                      // contact in BLE range); cobalt and still when online.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _textController,
                        builder: (_, val, __) {
                          final hasText = val.text.isNotEmpty;
                          final airPath = !widget.messageService.hasInternet &&
                              widget.messageService.nearbyUsers
                                  .contains(widget.contactPubkey);
                          return GestureDetector(
                            onTap: hasText ? _sendMessage : null,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 150),
                              opacity: hasText ? 1.0 : 0.45,
                              child: SizedBox(
                                width: 52,
                                height: 52,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    if (airPath)
                                      AnimatedBuilder(
                                        animation: _sendPulse,
                                        builder: (_, __) {
                                          final t = _sendPulse.value;
                                          return Container(
                                            width: 40 + 12 * t,
                                            height: 40 + 12 * t,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: AppColors.coral.withAlpha(
                                                    ((1 - t) * 150).round()),
                                                width: 2,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: airPath ? AppColors.coral : _kAccent,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.send_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _DeliveryStatus(
                    hasInternet: widget.messageService.hasInternet,
                    isNearby:
                        widget.messageService.nearbyUsers.contains(widget.contactPubkey),
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


// ── Timestamp separator ──────────────────────────────────────────────────────

class _TimestampSeparator extends StatelessWidget {
  final String label;
  const _TimestampSeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: _kMetaGray),
        ),
      ),
    );
  }
}


// ── Delivery status row ──────────────────────────────────────────────────────

class _DeliveryStatus extends StatelessWidget {
  final bool hasInternet;
  final bool isNearby;

  const _DeliveryStatus({required this.hasInternet, required this.isNearby});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;
    final IconData icon;

    if (isNearby && hasInternet) {
      label = 'Sending via best route';
      color = _kAccent;
      icon = Icons.wifi_tethering;
    } else if (isNearby) {
      label = 'Sending nearby';
      color = AppColors.amber;
      icon = Icons.wifi_tethering;
    } else if (hasInternet) {
      label = 'Sending via internet';
      color = _kAccent;
      icon = Icons.signal_wifi_4_bar;
    } else {
      label = 'Will send when connection is available';
      color = AppColors.darkTextMuted;
      icon = Icons.wifi_off_outlined;
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }
}


// ── Message bubble ───────────────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final VoidCallback? onRetry;
  final bool hasConnectivity;
  final String? contactName;
  final String? contactLocalPicPath;
  final String? contactPicUrl;
  final bool isLatestOutgoing;
  final List<String> reactions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onReply;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;

  const _Bubble({
    required this.message,
    required this.isMe,
    this.onRetry,
    this.hasConnectivity = true,
    this.contactName,
    this.contactLocalPicPath,
    this.contactPicUrl,
    this.isLatestOutgoing = false,
    this.reactions = const [],
    this.onReact,
    this.onReply,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Presence Field bubbles:
    // outgoing — cobalt online, coral when it went through the air (BLE);
    // incoming — airy outline, no filled slab.
    final viaAir = message.transport == 'bitchat';
    final bubbleBg = isMe
        ? (viaAir
            ? AppColors.coral
            : (isDark ? AppColors.primaryDark : AppColors.primary))
        : Colors.transparent;
    final bubbleBorder = isMe
        ? null
        : Border.all(
            color: isDark ? const Color(0xFF3A4386) : const Color(0xFFC9D2F5),
            width: 1.5,
          );
    final textColor = isMe
        ? Colors.white
        : (isDark ? AppColors.darkTextPrimary : AppColors.textPrimary);

    final isImage = message.type == 'image';

    Widget? statusIcon;
    if (isMe) {
      if (message.status == 'failed') {
        // Always show error regardless of transport.
        statusIcon = Icon(Icons.error_outline, size: 12, color: AppColors.error);
      } else if (message.transport == 'server' && isLatestOutgoing) {
        // Status word under the newest outgoing message only (iMessage
        // style) — server messages only; BLE/offline needs no receipt.
        // Read receipts intentionally not surfaced: 'read' shows as
        // 'Delivered'.
        final label = switch (message.status) {
          'pending' => 'Sending…',
          'sent' => 'Sent',
          'delivered' || 'read' => 'Delivered',
          _ => null,
        };
        if (label != null) {
          statusIcon = Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              color: _kMetaGray,
              fontWeight: FontWeight.w500,
            ),
          );
        }
      }
    }

    final timeDt = DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000);
    final timeLabel =
        '${timeDt.hour.toString().padLeft(2, '0')}:${timeDt.minute.toString().padLeft(2, '0')}';
    final timeColor = isMe
        ? Colors.white.withAlpha(165)
        : (isDark ? AppColors.darkTextMuted : AppColors.textMuted);

    final Widget textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Quoted message (reply)
        if (message.replyToId != null && message.replySnippet != null)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isMe
                  ? Colors.white.withAlpha(40)
                  : (isDark ? AppColors.darkCardHover : AppColors.card),
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: BorderSide(
                  color: isMe ? Colors.white : AppColors.coral,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              message.replySnippet!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: isMe
                    ? Colors.white.withAlpha(210)
                    : (isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.textSecondary),
              ),
            ),
          ),
        Text(
          message.content,
          style: TextStyle(color: textColor, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 2),
        Text(timeLabel, style: TextStyle(fontSize: 10, color: timeColor)),
      ],
    );

    final isVoice = message.type == 'voice_note';
    Widget bubbleContent = isImage
        ? _buildImageContent(context)
        : isVoice
            ? _VoicePlayer(
                source: message.content,
                secsLabel: message.replySnippet ?? '',
                light: isMe,
                timeLabel: timeLabel,
              )
            : textBlock;

    // Air badge under content on BLE-sent messages
    if (isMe && viaAir) {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubbleContent,
          const SizedBox(height: 4),
          Text(
            '↯ through the air · no internet',
            style: TextStyle(
              fontSize: 9.5,
              letterSpacing: 0.5,
              color: Colors.white.withAlpha(200),
            ),
          ),
        ],
      );
    }

    // Asymmetric "speaking corner": sharp corner points at the speaker.
    final radius = isMe
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          );

    final bubble = Container(
      padding: isImage
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
          minWidth: 72,
          maxWidth:
              isImage ? 260 : MediaQuery.of(context).size.width * 0.65),
      decoration: BoxDecoration(
        color: bubbleBg,
        border: bubbleBorder,
        borderRadius: radius,
      ),
      child: bubbleContent,
    );

    final showFailedLabel = isMe && message.status == 'failed' && hasConnectivity;

    if (isMe) {
      return GestureDetector(
        onLongPress: () => _showMessageMenu(context),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10, left: 64),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              bubble,
              if (reactions.isNotEmpty) _reactionChips(isDark),
              if (statusIcon != null) ...[
                const SizedBox(height: 2),
                statusIcon!,
              ],
              if (showFailedLabel)
                Text(
                  'Not delivered',
                  style: TextStyle(fontSize: 10, color: AppColors.error),
                ),
            ],
          ),
        ),
      );
    } else {
      return GestureDetector(
        onLongPress: () => _showMessageMenu(context),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10, right: 64),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // No per-message avatar in 1:1 chats — the header already says
              // who you're talking to; repeating it is visual noise.
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    bubble,
                    if (reactions.isNotEmpty) _reactionChips(isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _contactAvatarWidget(double size) {
    final name = contactName ?? '?';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    Widget fallback = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    if (contactLocalPicPath != null) {
      return ClipOval(
        child: Image.file(
          File(contactLocalPicPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    if (contactPicUrl != null) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: contactPicUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => fallback,
        ),
      );
    }
    return fallback;
  }

  Widget _buildImageContent(BuildContext context) {
    final content = message.content;
    // Photos read as photos, not stamps: larger, portrait-friendly,
    // asymmetric speaking-corner like text bubbles, time chip overlaid.
    const w = 250.0;
    const h = 300.0;
    final radius = isMe
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          );

    final timeDt =
        DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000);
    final timeLabel =
        '${timeDt.hour.toString().padLeft(2, '0')}:${timeDt.minute.toString().padLeft(2, '0')}';

    Widget image;
    if (content.startsWith('local:')) {
      image = Image.file(
        File(content.substring(6)),
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(
          width: w,
          height: h,
          child: Center(child: Icon(Icons.broken_image_outlined)),
        ),
      );
    } else if (content.startsWith('http')) {
      image = CachedNetworkImage(
        imageUrl: content,
        width: w,
        height: h,
        fit: BoxFit.cover,
        placeholder: (_, __) => const SizedBox(
          width: w,
          height: h,
          child: Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: _kAccent)),
        ),
        errorWidget: (_, __, ___) => const SizedBox(
          width: w,
          height: h,
          child: Center(child: Icon(Icons.broken_image_outlined)),
        ),
      );
    } else {
      image = const SizedBox(
        width: w,
        height: h,
        child: Center(
            child:
                CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          image,
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(110),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                timeLabel,
                style: const TextStyle(color: Colors.white, fontSize: 10.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reactionChips(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: AppColors.coral.withAlpha(120),
            width: 1,
          ),
        ),
        child: Text(
          reactions.join(' '),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  void _showMessageMenu(BuildContext context) {
    final hasText = message.content.isNotEmpty;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quick reactions
            if (onReact != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in const ['❤️', '😂', '👍', '✨', '👋'])
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          onReact!(e);
                        },
                        child: Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? AppColors.darkCardHover
                                : AppColors.card,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 24)),
                        ),
                      ),
                  ],
                ),
              ),
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(ctx);
                  onReply!();
                },
              ),
            if (hasText)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: message.content));
                },
              ),
            if (onDeleteForMe != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete for me'),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteForMe!();
                },
              ),
            if (isMe && onDeleteForEveryone != null)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined,
                    color: AppColors.error),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: AppColors.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteForEveryone!();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

}


/// A live presence change recorded while the chat was open.
class _RangeEvent {
  final bool entered;
  final int timestamp; // epoch seconds
  _RangeEvent({required this.entered, required this.timestamp});
}

/// Inline divider marking when the contact came into / left Bluetooth range.
class _RangeDivider extends StatelessWidget {
  final bool entered;
  final String name;
  final int timestamp;
  const _RangeDivider({
    required this.entered,
    required this.name,
    required this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final color = entered ? AppColors.coral : AppColors.textMuted;
    final label = entered
        ? '$name came into range · $hh:$mm'
        : 'left range · $hh:$mm';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: 36, height: 1, color: color.withAlpha(110)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
          Container(width: 36, height: 1, color: color.withAlpha(110)),
        ],
      ),
    );
  }
}

/// Faint beacon rings rising from the bottom edge of the conversation —
/// you are the beacon. Slightly stronger while the contact is in range.
class _BeaconRingsPainter extends CustomPainter {
  final bool isDark;
  final bool inRange;
  _BeaconRingsPainter({required this.isDark, required this.inRange});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height + 140);
    final boost = inRange ? 1.6 : 1.0;
    final cobalt = (isDark ? AppColors.primaryDark : AppColors.primary)
        .withAlpha((16 * boost).round());
    final coral = AppColors.coral.withAlpha((20 * boost).round());

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(center, 190, paint..color = coral);
    canvas.drawCircle(center, 260, paint..color = cobalt);
    canvas.drawCircle(center, 330, paint..color = cobalt.withAlpha(10));
  }

  @override
  bool shouldRepaint(_BeaconRingsPainter old) =>
      old.isDark != isDark || old.inRange != inRange;
}

/// Inline voice-note player: play/pause + progress + duration.
class _VoicePlayer extends StatefulWidget {
  final String source; // 'local:<path>' or https URL
  final String secsLabel;
  final bool light; // on cobalt (outgoing) → white controls
  final String timeLabel;
  const _VoicePlayer({
    required this.source,
    required this.secsLabel,
    required this.light,
    required this.timeLabel,
  });

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player = ap.AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    final src = widget.source.startsWith('local:')
        ? ap.DeviceFileSource(widget.source.substring(6))
        : ap.UrlSource(widget.source);
    await _player.play(src);
    setState(() => _playing = true);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.light ? Colors.white : AppColors.primary;
    final track = widget.light
        ? Colors.white.withAlpha(90)
        : AppColors.primary.withAlpha(50);
    final totalSecs = _total.inSeconds > 0
        ? _total.inSeconds
        : int.tryParse(widget.secsLabel) ?? 0;
    final progress =
        totalSecs > 0 ? (_pos.inSeconds / totalSecs).clamp(0.0, 1.0) : 0.0;
    final label = _playing || _pos > Duration.zero
        ? '${(_pos.inSeconds ~/ 60)}:${(_pos.inSeconds % 60).toString().padLeft(2, '0')}'
        : '${(totalSecs ~/ 60)}:${(totalSecs % 60).toString().padLeft(2, '0')}';

    return SizedBox(
      width: 210,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Icon(
              _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              size: 38,
              color: fg,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: track,
                    valueColor: AlwaysStoppedAnimation(fg),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '🎤 $label · ${widget.timeLabel}',
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.light
                        ? Colors.white.withAlpha(180)
                        : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
