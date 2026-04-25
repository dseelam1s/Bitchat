import 'dart:async';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
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
      if (message.senderPubkey == widget.contactPubkey ||
          message.receiverPubkey == widget.contactPubkey) {
        _loadMessages();
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
                  final err = await cs.startCall(widget.contactPubkey, remoteName: widget.contactName);
                  if (!mounted) return;
                  if (err != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err))); return; }
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
                  final err = await cs.startCall(
                    widget.contactPubkey,
                    remoteName: widget.contactName,
                    isVideo: true,
                  );
                  if (!mounted) return;
                  if (err != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err))); return; }
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
    final hasBle = widget.messageService.hasNearbyDevices;

    if (!hasInternet && !hasBle) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No connection available — connect to internet or be near another BitChat user'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final picker = ImagePicker();
    // Use heavier compression for BLE: 640px / quality 30 keeps raw bytes under 80 KB.
    // Online path can afford higher quality since only a URL travels over the wire.
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: hasInternet ? 70 : 30,
      maxWidth: hasInternet ? 1280 : 640,
      maxHeight: hasInternet ? 1280 : 640,
    );
    if (picked == null) return;

    final file = File(picked.path);

    // For the BLE path: reject if still too large after picker compression.
    // Anything >150 KB raw would generate >1100 BLE chunks and become unreliable.
    if (!hasInternet) {
      final sizeBytes = await file.length();
      if (sizeBytes > 150 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image too large for offline sending — connect to internet to send this photo'),
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }
    }

    final result = await widget.messageService.sendImageMessage(file, widget.contactPubkey);
    if (result == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image send failed — check your connection'),
          duration: Duration(seconds: 3),
        ),
      );
    }
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


  @override
  void dispose() {
    _messageSub?.cancel();
    _typingSub?.cancel();
    _typingDismissTimer?.cancel();
    _myTypingThrottle?.cancel();
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
                      // Image/voice messages stored with a local path can't be auto-retried —
                      // the file bytes are not in the DB. Hide the retry hint for these.
                      final canRetry = isMe &&
                          !(msg.type == 'image' && msg.content.startsWith('local:')) &&
                          !(msg.type == 'voice_note' && msg.content.startsWith('local:'));
                      final retryCallback = canRetry
                          ? () => widget.messageService.retryPendingMessages()
                          : null;
                      return _Bubble(
                        message: msg,
                        isMe: isMe,
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
              child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Image attachment — available online (Cloudinary) or via BLE (chunked)
                            if (widget.messageService.hasInternet || widget.messageService.hasNearbyDevices)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: SizedBox(
                                  width: 42, height: 42,
                                  child: Material(
                                    color: Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: _sendImageMessage,
                                      child: Icon(Icons.image_outlined, size: 22,
                                          color: Theme.of(context).colorScheme.onSurface.withAlpha(120)),
                                    ),
                                  ),
                                ),
                              ),
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
  final VoidCallback? onRetry;

  const _Bubble({
    required this.message,
    required this.isMe,
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

    final isImage = message.type == 'image';
    final timeRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_time(message.timestamp), style: TextStyle(fontSize: 10, color: metaColor)),
      ],
    );

    final bubble = Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: isImage
          ? const EdgeInsets.fromLTRB(6, 6, 6, 6)
          : const EdgeInsets.fromLTRB(13, 9, 13, 7),
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
      child: isImage
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildImageContent(context),
                const SizedBox(height: 4),
                timeRow,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(message.content, style: TextStyle(color: textColor, fontSize: 14, height: 1.35)),
                const SizedBox(height: 3),
                timeRow,
              ],
            ),
    );

    final isFailed = isMe && message.status == 'failed';

    return GestureDetector(
      onLongPress: () => _showMessageMenu(context),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            bubble,
            if (isFailed && onRetry != null)
              GestureDetector(
                onTap: onRetry,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 11, color: AppColors.error.withAlpha(180)),
                      const SizedBox(width: 3),
                      Text(
                        'Not delivered · Tap to retry',
                        style: TextStyle(fontSize: 10, color: AppColors.error.withAlpha(180)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageContent(BuildContext context) {
    final content = message.content;
    const size = 200.0;
    const radius = BorderRadius.all(Radius.circular(10));

    if (content.startsWith('local:')) {
      final path = content.substring(6);
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(path),
          width: size, height: size, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox(
            width: size, height: size,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      );
    }
    if (content.startsWith('http')) {
      return ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: content,
          width: size, height: size, fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox(
            width: size, height: size,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mint)),
          ),
          errorWidget: (_, __, ___) => const SizedBox(
            width: size, height: size,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      );
    }
    return const SizedBox(
      width: size, height: size,
      child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mint)),
    );
  }

  void _showMessageMenu(BuildContext context) {
    final hasText = message.content.isNotEmpty;
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

  String _time(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

