import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/core/image_download_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
import 'package:bitchat_messenger/core/voice_note_service.dart';
import 'package:bitchat_messenger/features/calls/screens/in_call_screen.dart';

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

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  StreamSubscription? _messageSub;

  // Pagination
  static const _pageSize = 50;
  int _offset = 0;
  bool _isLoadingInitial = true;
  bool _isLoadingMore = false;
  bool _isRefreshing = false; // prevents concurrent stream-triggered reloads
  bool _pendingRefresh = false; // a stream event arrived while refreshing
  bool _hasMore = true;

  // Mutable local copies so profile sync can update the header without rebuild
  String? _displayName;
  String? _localPicPath;

  // Typing indicator state
  bool _contactIsTyping = false;
  Timer? _typingDismissTimer;
  Timer? _myTypingThrottle;
  DateTime? _lastTypingSent;
  StreamSubscription? _typingSub;

  // Reactions: messageId → emoji → set of senderPubkeys
  final Map<String, Map<String, Set<String>>> _reactions = {};
  StreamSubscription? _reactionSub;

  // Voice note recording state
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  @override
  void initState() {
    super.initState();
    _displayName = widget.contactName;
    _localPicPath = widget.contactProfilePictureLocalPath;
    _syncContactProfile();
    _loadMessages(initial: true);
    widget.messageService.markAsRead(widget.contactPubkey);

    // Load older messages when user scrolls to the top
    _scrollController.addListener(() {
      if (_scrollController.position.pixels <= 80 &&
          !_isLoadingMore &&
          _hasMore) {
        _loadMoreMessages();
      }
    });

    _messageSub = widget.messageService.messageStream.listen((message) {
      if (message.type == 'status_update' ||
          message.senderPubkey == widget.contactPubkey ||
          message.receiverPubkey == widget.contactPubkey) {
        _loadMessages();  // refreshes latest page, preserves pagination
        widget.messageService.markAsRead(widget.contactPubkey);
      }
    });

    // Show "typing..." in appbar when contact sends a typing indicator
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

    // Refresh reactions when a new one arrives
    _reactionSub = widget.messageService.reactionsStream.listen((messageId) {
      if (mounted) {
        setState(() {
          _reactions[messageId] = widget.messageService.reactionsFor(messageId);
        });
      }
    });

    // Send my typing indicators (throttled: at most once every 2 seconds)
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

  Future<void> _loadMessages({bool initial = false}) async {
    if (initial) {
      // Fresh load: reset pagination and show loader
      _offset = 0;
      _hasMore = true;
      _isRefreshing = false;
      _pendingRefresh = false;
      if (mounted) setState(() => _isLoadingInitial = true);
    } else {
      // Stream-triggered refresh — skip if already refreshing or loading more
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

    for (final msg in messages) {
      final r = widget.messageService.reactionsFor(msg.id);
      if (r.isNotEmpty) _reactions[msg.id] = r;
    }

    final atBottom = _scrollController.hasClients &&
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 80;

    setState(() {
      _messages = messages;
      _offset = messages.length;
      _hasMore = messages.length == _pageSize;
      _isLoadingInitial = false;
      _isRefreshing = false;
    });

    if (initial || atBottom) _scrollToBottom();

    // If a stream event arrived while we were refreshing, do one final refresh
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

    for (final msg in older) {
      final r = widget.messageService.reactionsFor(msg.id);
      if (r.isNotEmpty) _reactions[msg.id] = r;
    }

    // Preserve scroll position when prepending older messages
    final prevCount = _messages.length;
    setState(() {
      _messages = [...older, ..._messages];
      _offset += older.length;
      _hasMore = older.length == _pageSize;
      _isLoadingMore = false;
    });

    // A stream event arrived while loading more — refresh now
    if (_pendingRefresh) {
      _pendingRefresh = false;
      _loadMessages();
    }

    // Jump scroll to keep user at the same visual position
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final addedCount = _messages.length - prevCount;
      if (addedCount > 0) {
        // Each item is ~60px average — snap position forward
        final approxOffset = _scrollController.position.pixels + addedCount * 60.0;
        _scrollController.jumpTo(approxOffset.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ));
      }
    });
  }

  Future<void> _sendReaction(Message message, String emoji) async {
    await widget.messageService.sendReaction(
      message.id,
      widget.contactPubkey,
      emoji,
    );
  }

  void _showCallPicker(BuildContext ctx) {
    final cs = widget.callService!;
    if (cs.hasActiveCall) return;

    showModalBottomSheet(
      context: ctx,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.call, color: AppColors.mint),
                title: const Text('Voice call'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await cs.startCall(widget.contactPubkey, remoteName: widget.contactName);
                  if (!mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: AppColors.mint),
                title: const Text('Video call'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await cs.startCall(
                    widget.contactPubkey,
                    remoteName: widget.contactName,
                    isVideo: true,
                  );
                  if (!mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showImageSourcePicker() async {
    final canSend = widget.messageService.canSendImage || widget.messageService.hasInternet;
    if (!canSend) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No connection available. Make sure you have internet or Bluetooth is on.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;
    await _pickAndSendImage(source);
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    final path = await widget.messageService.imageSharingService
        .pickImage(fromCamera: source == ImageSource.camera);
    if (path == null || !mounted) return;

    final sent = await widget.messageService.sendImage(
      widget.contactPubkey,
      path,
    );

    if (sent == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not send image — peer not reachable or image too large (max 1 MB).'),
          duration: Duration(seconds: 4),
        ),
      );
    }
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

  Widget _buildRecordingBar(ColorScheme cs) {
    final minutes = _recordingSeconds ~/ 60;
    final secs = _recordingSeconds % 60;
    final timeStr = '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    return Row(
      children: [
        // Cancel
        GestureDetector(
          onTap: _cancelRecording,
          child: const Icon(Icons.delete_outline, color: AppColors.textMuted, size: 24),
        ),
        const SizedBox(width: 12),
        // Pulse indicator
        const _RecordingPulse(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Recording $timeStr / 1:00',
            style: const TextStyle(fontSize: 13, color: AppColors.mint, fontWeight: FontWeight.w500),
          ),
        ),
        // Send
        GestureDetector(
          onTap: _stopAndSendRecording,
          child: Container(
            width: 42, height: 42,
            decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.send, size: 18, color: cs.onPrimary),
          ),
        ),
      ],
    );
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    bool anySent = false;
    try {
      final messageId =
          await widget.messageService.sendMessage(widget.contactPubkey, text);
      if (messageId != null) {
        final msgs = await widget.messageService
            .getChatMessages(widget.contactPubkey, limit: 10);
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


  Future<void> _startRecording() async {
    final vns = widget.messageService.voiceNoteService;
    vns.onMaxDurationReached = _stopAndSendRecording;
    final started = await vns.startRecording();
    if (!started) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }
    setState(() { _isRecording = true; _recordingSeconds = 0; });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    setState(() => _isRecording = false);

    final vns = widget.messageService.voiceNoteService;
    final result = await vns.stopRecording();
    if (result == null) return;

    if (!widget.messageService.canSendVoiceNote) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No nearby device connected. Make sure Bluetooth is on and the other device has the app open.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      await widget.messageService.voiceNoteService.deleteFile(result.path.split('/').last.replaceAll('.m4a', ''));
      return;
    }

    final sent = await widget.messageService.sendVoiceNote(
      widget.contactPubkey,
      result.path,
      result.duration,
    );

    if (sent == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not send voice note — peer not reachable'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _cancelRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    setState(() => _isRecording = false);
    await widget.messageService.voiceNoteService.cancelRecording();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _typingSub?.cancel();
    _reactionSub?.cancel();
    _typingDismissTimer?.cancel();
    _myTypingThrottle?.cancel();
    _recordingTimer?.cancel();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
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
    final isNearby =
        widget.messageService.nearbyUsers.contains(widget.contactPubkey);

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 32,
        title: Row(
          children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: isNearby ? AppColors.mint.withAlpha(18) : theme.cardColor,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: _localPicPath != null
                  ? Image.file(
                      File(_localPicPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Center(
                        child: Text(
                          displayName[0].toUpperCase(),
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                              color: isNearby ? AppColors.mint : cs.onSurface.withAlpha(150)),
                        ),
                      ),
                    )
                  : widget.contactProfilePictureUrl != null
                  ? CachedNetworkImage(
                      imageUrl: widget.contactProfilePictureUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Center(
                        child: Text(
                          displayName[0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isNearby ? AppColors.mint : cs.onSurface.withAlpha(150),
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        displayName[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isNearby ? AppColors.mint : cs.onSurface.withAlpha(150),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 5, height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _contactIsTyping
                              ? AppColors.mint
                              : (isNearby ? AppColors.online : AppColors.offline),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _contactIsTyping
                            ? 'typing...'
                            : (isNearby
                                ? 'Connected nearby'
                                : (widget.messageService.hasInternet
                                    ? 'Connected'
                                    : 'Will deliver when reachable')),
                        style: TextStyle(
                          fontSize: 10,
                          color: _contactIsTyping
                              ? AppColors.teal
                              : (isNearby ? AppColors.online : AppColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Call button — only shown when internet is available
          if (widget.callService != null && widget.messageService.hasInternet)
            GestureDetector(
              onTap: () => _showCallPicker(context),
              child: Container(
                width: 34, height: 34,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: AppColors.mint.withAlpha(15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.mint.withAlpha(50)),
                ),
                child: const Icon(Icons.call_outlined, size: 17, color: AppColors.mint),
              ),
            ),
          // More options menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) async {
              if (value == 'delete') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete conversation'),
                    content: const Text('All messages with this contact will be deleted. This cannot be undone.'),
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
            child: _isLoadingInitial
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mint))
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline,
                                size: 48, color: AppColors.textMuted.withAlpha(80)),
                            const SizedBox(height: 12),
                            Text(
                              'No messages yet',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textMuted.withAlpha(140),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Say hi to get the conversation started',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted.withAlpha(100),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        // +1 for the "load more" header slot
                        itemCount: _messages.length + 1,
                        itemBuilder: (context, index) {
                          // Top slot: loading spinner or spacer
                          if (index == 0) {
                            return _isLoadingMore
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20, height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.mint,
                                        ),
                                      ),
                                    ),
                                  )
                                : _hasMore
                                    ? const SizedBox(height: 4)
                                    : Padding(
                                        padding: const EdgeInsets.only(bottom: 8),
                                        child: Center(
                                          child: Text(
                                            'Beginning of conversation',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: AppColors.textMuted.withAlpha(100),
                                            ),
                                          ),
                                        ),
                                      );
                          }
                          final msg = _messages[index - 1];
                      if (msg.type == 'delivery_receipt' ||
                          msg.type == 'read_receipt' ||
                          msg.type == 'status_update') {
                        return const SizedBox.shrink();
                      }
                      final isMe = msg.senderPubkey == widget.messageService.publicKey;
                      final msgReactions = _reactions[msg.id] ?? {};
                      if (msg.type == 'voice_note') {
                        return _VoiceBubble(
                          message: msg,
                          isMe: isMe,
                          reactions: msgReactions,
                          onReact: (emoji) => _sendReaction(msg, emoji),
                          voiceNoteService: widget.messageService.voiceNoteService,
                          messageService: widget.messageService,
                        );
                      }
                      final retryCallback = isMe
                          ? () => widget.messageService.retryPendingMessages()
                          : null;
                      if (msg.type == 'image') {
                        return _ImageBubble(
                          message: msg,
                          isMe: isMe,
                          reactions: msgReactions,
                          onReact: (emoji) => _sendReaction(msg, emoji),
                          messageService: widget.messageService,
                          onRetry: retryCallback,
                        );
                      }
                      return _Bubble(
                        message: msg,
                        isMe: isMe,
                        reactions: msgReactions,
                        onReact: (emoji) => _sendReaction(msg, emoji),
                        onRetry: retryCallback,
                      );
                    },
                  ),
          ),
          // Input
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(top: BorderSide(color: theme.dividerColor, width: 0.5)),
            ),
            child: SafeArea(
              top: false,
              child: _isRecording
                  ? _buildRecordingBar(cs)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.inputDecorationTheme.fillColor ?? cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(color: theme.dividerColor),
                                ),
                                child: TextField(
                                  controller: _textController,
                                  maxLines: 4,
                                  minLines: 1,
                                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                                  decoration: InputDecoration(
                                    hintText: 'Message...',
                                    hintStyle: TextStyle(color: cs.onSurface.withAlpha(90)),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    filled: false,
                                  ),
                                  onSubmitted: (_) => _sendMessage(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Image button
                            GestureDetector(
                              onTap: _showImageSourcePicker,
                              child: SizedBox(
                                width: 42, height: 42,
                                child: Material(
                                  color: AppColors.mint.withAlpha(15),
                                  borderRadius: BorderRadius.circular(12),
                                  child: const Icon(Icons.image_outlined, size: 20, color: AppColors.mint),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Mic button — hold to record
                            GestureDetector(
                              onLongPressStart: (_) => _startRecording(),
                              onLongPressEnd: (_) => _stopAndSendRecording(),
                              child: SizedBox(
                                width: 42, height: 42,
                                child: Material(
                                  color: AppColors.mint.withAlpha(15),
                                  borderRadius: BorderRadius.circular(12),
                                  child: const Icon(Icons.mic_none, size: 20, color: AppColors.mint),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 42, height: 42,
                              child: Material(
                                color: AppColors.mint,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _sendMessage,
                                  child: Icon(Icons.arrow_upward, size: 20, color: cs.onPrimary),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _DeliveryStatus(
                          hasInternet: widget.messageService.hasInternet,
                          isNearby: widget.messageService.nearbyUsers.contains(widget.contactPubkey),
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

// ── Delivery status indicator ────────────────────────────────────────────────

// ── Shared message status tick widget ───────────────────────────────────────
// Single source of truth for pending/sent/delivered/read icons.
// Used by _Bubble, _ImageBubble, _VoiceBubble.

class _StatusTick extends StatelessWidget {
  final String status;
  final bool isDark;
  final VoidCallback? onRetry;

  const _StatusTick({required this.status, required this.isDark, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isRead = status == 'read';
    final IconData icon;
    final Color color;

    if (isRead) {
      icon = Icons.visibility;
      color = AppColors.amber;
    } else if (status == 'delivered') {
      icon = Icons.done_all;
      color = isDark ? AppColors.mint : Colors.white.withAlpha(220);
    } else if (status == 'sent') {
      icon = Icons.done;
      color = isDark ? Colors.white.withAlpha(120) : Colors.white.withAlpha(180);
    } else {
      // pending — tappable retry
      icon = Icons.access_time;
      color = isDark ? Colors.white.withAlpha(80) : Colors.white.withAlpha(140);
    }

    final iconWidget = Icon(icon, size: 12, color: color);

    if (status == 'pending' && onRetry != null) {
      return GestureDetector(
        onTap: onRetry,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: iconWidget,
        ),
      );
    }
    return iconWidget;
  }
}

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
      color = AppColors.teal;
      icon  = Icons.wifi_tethering;
    } else if (isNearby) {
      label = 'Sending nearby';
      color = AppColors.amber;
      icon  = Icons.wifi_tethering;
    } else if (hasInternet) {
      label = 'Sending via internet';
      color = AppColors.teal;
      icon  = Icons.signal_wifi_4_bar;
    } else {
      label = 'Will send when connection is available';
      color = AppColors.textMuted;
      icon  = Icons.wifi_off_outlined;
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final Map<String, Set<String>> reactions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onRetry;

  const _Bubble({
    required this.message,
    required this.isMe,
    this.reactions = const {},
    this.onReact,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    // Sent bubble: solid mint in light mode, faint tint in dark mode
    final sentBgColor = isDark ? AppColors.mint.withAlpha(20) : AppColors.mint;
    final sentBorderColor = isDark ? AppColors.mint.withAlpha(35) : AppColors.mintDark;
    final sentTextColor = isDark ? cs.onSurface : Colors.white;
    final sentMetaColor = isDark
        ? cs.onSurface.withAlpha(80)
        : Colors.white.withAlpha(180);

    // Received bubble: card color
    final recvBgColor = theme.cardColor;
    final recvBorderColor = theme.dividerColor.withAlpha(60);
    final recvTextColor = cs.onSurface;
    final recvMetaColor = cs.onSurface.withAlpha(80);

    final bubbleBg = isMe ? sentBgColor : recvBgColor;
    final bubbleBorder = isMe ? sentBorderColor : recvBorderColor;
    final textColor = isMe ? sentTextColor : recvTextColor;
    final metaColor = isMe ? sentMetaColor : recvMetaColor;

    final bubble = Container(
      margin: EdgeInsets.only(bottom: reactions.isEmpty ? 5 : 2),
      padding: const EdgeInsets.fromLTRB(13, 9, 13, 7),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
          bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
        ),
        border: Border.all(color: bubbleBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            message.content,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                message.transport == 'bitchat' ? Icons.sensors : Icons.cloud_outlined,
                size: 10,
                color: metaColor,
              ),
              const SizedBox(width: 4),
              Text(
                _time(message.timestamp),
                style: TextStyle(fontSize: 10, color: metaColor),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                _StatusTick(status: message.status, isDark: isDark, onRetry: onRetry),
              ],
            ],
          ),
        ],
      ),
    );

    return GestureDetector(
      onLongPress: () => _showMessageMenu(context),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            bubble,
            if (reactions.isNotEmpty) _buildReactions(context),
          ],
        ),
      ),
    );
  }

  void _showMessageMenu(BuildContext context) {
    final hasText = message.content.isNotEmpty &&
        message.type != 'image' &&
        message.type != 'voice_note';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Emoji reactions row
            if (onReact != null)
              SizedBox(
                height: 72,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ['👍', '❤️', '😂', '😮', '😢', '🔥'].map((emoji) {
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onReact!(emoji);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(emoji, style: const TextStyle(fontSize: 28)),
                      ),
                    );
                  }).toList(),
                ),
              ),
            if (onReact != null) const Divider(height: 1),
            // Copy text
            if (hasText)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: message.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildReactions(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 4,
        children: reactions.entries.map((e) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Text(
              '${e.key} ${e.value.length}',
              style: const TextStyle(fontSize: 12),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _time(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── Recording pulse indicator ─────────────────────────────────────────────────

class _RecordingPulse extends StatefulWidget {
  const _RecordingPulse();
  @override
  State<_RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<_RecordingPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 10, height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red.withAlpha((180 + _ctrl.value * 75).toInt()),
        ),
      ),
    );
  }
}

// ── Image bubble ─────────────────────────────────────────────────────────────

class _ImageBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final Map<String, Set<String>> reactions;
  final void Function(String emoji)? onReact;
  final MessageService messageService;
  final VoidCallback? onRetry;

  const _ImageBubble({
    required this.message,
    required this.isMe,
    required this.messageService,
    this.reactions = const {},
    this.onReact,
    this.onRetry,
  });

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  // Non-null once the image is saved locally (or if it was always a local path)
  String? _localPath;
  // Tracks background download state; null means no download needed
  DownloadState? _downloadState;
  StreamSubscription<ImageDownloadEvent>? _downloadSub;

  bool get _isUrl =>
      widget.message.content.startsWith('http://') ||
      widget.message.content.startsWith('https://');

  @override
  void initState() {
    super.initState();
    if (!_isUrl) {
      // BLE image or previously downloaded — content is already a local path
      _localPath = widget.message.content;
    } else {
      // Content is a URL — check if this session already downloaded it
      final existing = ImageDownloadService().localPathFor(widget.message.id);
      if (existing != null) {
        _localPath = existing;
        _downloadState = DownloadState.done;
      } else {
        _downloadState =
            ImageDownloadService().stateFor(widget.message.id) ??
                DownloadState.downloading;

        // Listen for download progress / completion / failure
        _downloadSub = ImageDownloadService()
            .events
            .where((e) => e.messageId == widget.message.id)
            .listen((event) {
          if (!mounted) return;
          setState(() {
            _downloadState = event.state;
            if (event.localPath != null) _localPath = event.localPath;
          });
        });

        // Start download (no-op if already in-flight or done)
        ImageDownloadService().download(
          widget.message.id,
          widget.message.content,
          widget.messageService.dbService,
          widget.messageService.imageSharingService,
        );
      }
    }
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  void _retry() {
    ImageDownloadService().resetForRetry(widget.message.id);
    setState(() => _downloadState = DownloadState.downloading);
    ImageDownloadService().download(
      widget.message.id,
      widget.message.content,
      widget.messageService.dbService,
      widget.messageService.imageSharingService,
    );
  }

  void _viewFullScreen() {
    final content = _localPath ?? widget.message.content;
    final isUrl =
        content.startsWith('http://') || content.startsWith('https://');
    if (!isUrl && !File(content).existsSync()) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar:
              AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: Center(
            child: InteractiveViewer(
              child: isUrl
                  ? CachedNetworkImage(imageUrl: content, fit: BoxFit.contain)
                  : Image.file(File(content), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final bubbleBg = widget.isMe
        ? (isDark ? AppColors.mint.withAlpha(20) : AppColors.mint)
        : theme.cardColor;
    final bubbleBorder = widget.isMe
        ? (isDark ? AppColors.mint.withAlpha(35) : AppColors.mintDark)
        : theme.dividerColor.withAlpha(60);
    final metaColor = widget.isMe
        ? (isDark ? cs.onSurface.withAlpha(80) : Colors.white.withAlpha(180))
        : cs.onSurface.withAlpha(80);

    Widget imageWidget;
    if (_localPath != null) {
      // ── Downloaded / local file ───────────────────────────────────────────
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(_localPath!),
          width: 220, height: 220,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        ),
      );
    } else if (_downloadState == DownloadState.failed) {
      // ── Failed — show retry ───────────────────────────────────────────────
      imageWidget = GestureDetector(
        onTap: _retry,
        child: Container(
          width: 220, height: 160,
          decoration: BoxDecoration(
            color: Colors.grey.withAlpha(40),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.refresh_rounded, size: 36, color: cs.onSurface.withAlpha(120)),
              const SizedBox(height: 8),
              Text(
                'Tap to retry',
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(120)),
              ),
            ],
          ),
        ),
      );
    } else {
      // ── Downloading — show network image with loading indicator ───────────
      // CachedNetworkImage shows instantly from in-memory cache if the sender
      // just uploaded it; background download persists it to local storage.
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CachedNetworkImage(
              imageUrl: widget.message.content,
              width: 220, height: 220,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 220, height: 160,
                color: Colors.grey.withAlpha(40),
              ),
              errorWidget: (_, __, ___) => _buildPlaceholder(),
            ),
            // Subtle download progress indicator over the image
            Positioned(
              bottom: 8, right: 8,
              child: Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(100),
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bubble = GestureDetector(
      onTap: _viewFullScreen,
      onLongPress: () => _showReactionPicker(context),
      child: Container(
        margin: EdgeInsets.only(bottom: widget.reactions.isEmpty ? 5 : 2),
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: bubbleBg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: widget.isMe
                ? const Radius.circular(16)
                : const Radius.circular(4),
            bottomRight: widget.isMe
                ? const Radius.circular(4)
                : const Radius.circular(16),
          ),
          border: Border.all(color: bubbleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            imageWidget,
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.message.transport == 'bitchat' ? Icons.sensors : Icons.cloud_outlined,
                  size: 10,
                  color: metaColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _time(widget.message.timestamp),
                  style: TextStyle(fontSize: 10, color: metaColor),
                ),
                if (widget.isMe) ...[
                  const SizedBox(width: 4),
                  _StatusTick(
                    status: widget.message.status,
                    isDark: isDark,
                    onRetry: widget.onRetry,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: widget.isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          if (widget.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                spacing: 4,
                children: widget.reactions.entries.map((e) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: Text('${e.key} ${e.value.length}',
                        style: const TextStyle(fontSize: 12)),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 220, height: 160,
      decoration: BoxDecoration(
        color: Colors.grey.withAlpha(40),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.image_outlined, size: 40, color: AppColors.textMuted),
    );
  }

  void _showReactionPicker(BuildContext context) {
    if (widget.onReact == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: 80,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['👍', '❤️', '😂', '😮', '😢', '🔥'].map((emoji) {
            return GestureDetector(
              onTap: () {
                Navigator.pop(context);
                widget.onReact!(emoji);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(emoji, style: const TextStyle(fontSize: 30)),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  String _time(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── Voice note bubble ─────────────────────────────────────────────────────────

class _VoiceBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final Map<String, Set<String>> reactions;
  final void Function(String emoji)? onReact;
  final VoiceNoteService? voiceNoteService;
  final MessageService? messageService;

  const _VoiceBubble({
    required this.message,
    required this.isMe,
    this.reactions = const {},
    this.onReact,
    this.voiceNoteService,
    this.messageService,
  });

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _downloading = false;
  bool _downloadFailed = false;
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player?.stop();
    _player?.dispose();
    super.dispose();
  }

  Future<String?> _resolveLocalPath() async {
    final content = widget.message.content;
    if (!content.startsWith('http')) return content; // already a local path

    // URL — check if already downloaded
    final vns = widget.voiceNoteService;
    if (vns == null) return null;
    final existing = await vns.localPath(widget.message.id);
    if (existing != null) return existing;

    // Download now
    if (mounted) setState(() { _downloading = true; _downloadFailed = false; });
    final localPath = await vns.downloadFromUrl(widget.message.id, content);
    if (!mounted) return null;
    if (localPath == null) {
      setState(() { _downloading = false; _downloadFailed = true; });
      return null;
    }
    // Persist local path so we don't download again
    widget.messageService?.updateMessageContent(widget.message.id, localPath);
    setState(() => _downloading = false);
    return localPath;
  }

  Future<void> _initPlayer() async {
    if (_player != null) return;
    final path = await _resolveLocalPath();
    if (!mounted) return; // widget disposed during download
    if (path == null || path.isEmpty) return;

    final player = AudioPlayer();
    try {
      await player.setFilePath(path);
    } catch (_) {
      player.dispose();
      return;
    }

    if (!mounted) {
      // Disposed while setting file path — clean up immediately
      player.dispose();
      return;
    }

    _posSub = player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });

    _stateSub = player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero);
        if (mounted) setState(() { _playing = false; _position = Duration.zero; });
      }
    });

    _player = player;
  }

  Future<void> _toggle() async {
    if (_downloadFailed) {
      // Reset so _resolveLocalPath retries the download
      setState(() { _downloadFailed = false; });
    }
    await _initPlayer();
    final player = _player;
    if (player == null) return;

    // Update icon immediately on tap — don't wait for the stream.
    if (_playing) {
      setState(() => _playing = false);
      await player.pause();
    } else {
      setState(() => _playing = true);
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final isMe = widget.isMe;

    final bubbleBg = isMe
        ? (isDark ? AppColors.mint.withAlpha(20) : AppColors.mint)
        : theme.cardColor;
    final bubbleBorder = isMe
        ? (isDark ? AppColors.mint.withAlpha(35) : AppColors.mintDark)
        : theme.dividerColor.withAlpha(60);
    final fgColor = isMe ? (isDark ? cs.onSurface : Colors.white) : cs.onSurface;
    final metaColor = isMe
        ? (isDark ? cs.onSurface.withAlpha(80) : Colors.white.withAlpha(180))
        : cs.onSurface.withAlpha(80);

    final totalSecs = widget.message.duration;
    final posSecs = _position.inSeconds;
    final progress = totalSecs > 0 ? (posSecs / totalSecs).clamp(0.0, 1.0) : 0.0;
    final remaining = totalSecs - posSecs;
    final timeLabel = _fmt(remaining > 0 ? remaining : totalSecs);

    final voiceBubble = Container(
      margin: EdgeInsets.only(bottom: widget.reactions.isEmpty ? 5 : 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 7),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
          bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
        ),
        border: Border.all(color: bubbleBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _downloading ? null : _toggle,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: fgColor.withAlpha(20),
                    ),
                    child: _downloading
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: fgColor,
                            ),
                          )
                        : _downloadFailed
                            ? Icon(Icons.refresh, size: 20, color: Colors.redAccent)
                            : Icon(
                                _playing ? Icons.pause : Icons.play_arrow,
                                size: 20,
                                color: fgColor,
                              ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: fgColor.withAlpha(30),
                          valueColor: AlwaysStoppedAnimation<Color>(fgColor.withAlpha(180)),
                          minHeight: 3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        timeLabel,
                        style: TextStyle(fontSize: 10, color: metaColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.message.transport == 'bitchat' ? Icons.sensors : Icons.cloud_outlined,
                  size: 10,
                  color: metaColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _time(widget.message.timestamp),
                  style: TextStyle(fontSize: 10, color: metaColor),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _StatusTick(
                    status: widget.message.status,
                    isDark: isDark,
                    onRetry: widget.messageService != null
                        ? () => widget.messageService!.retryPendingMessages()
                        : null,
                  ),
                ],
              ],
            ),
          ],
        ),
    );

    return GestureDetector(
      onLongPress: () {
        if (widget.onReact == null) return;
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: theme.cardColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => SizedBox(
            height: 80,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ['👍', '❤️', '😂', '😮', '😢', '🔥'].map((emoji) {
                return GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onReact!(emoji);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(emoji, style: const TextStyle(fontSize: 30)),
                  ),
                );
              }).toList(),
            ),
          ),
        );
      },
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            voiceBubble,
            if (widget.reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 4,
                  children: widget.reactions.entries.map((e) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: Text(
                        '${e.key} ${e.value.length}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _fmt(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _time(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
