import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';

enum _ConnState { none, pending, connected, incoming }

class UserProfileScreen extends StatefulWidget {
  final Map<String, dynamic> profile;
  final MessageService messageService;

  // If we already know there's a pending incoming request (id needed to accept/decline)
  final int? incomingRequestId;

  const UserProfileScreen({
    super.key,
    required this.profile,
    required this.messageService,
    this.incomingRequestId,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  _ConnState _connState = _ConnState.none;
  bool _busy = false;
  String? _localPicPath;

  String get _pubkey => widget.profile['pubkey'] as String? ?? '';
  String get _displayName => widget.profile['display_name'] as String? ?? '';
  String get _bio => widget.profile['bio'] as String? ?? '';
  String? get _pictureUrl => widget.profile['profile_picture_url'] as String?;
  String get _shortId => Contact.shortIdFor(_pubkey);

  @override
  void initState() {
    super.initState();
    if (widget.incomingRequestId != null) {
      _connState = _ConnState.incoming;
    } else {
      _connState = _ConnState.none;
    }
    _cacheLocalPic();
  }

  Future<void> _cacheLocalPic() async {
    final url = _pictureUrl;
    if (url == null || url.isEmpty) return;
    final path = await ProfilePictureCacheService().download(_pubkey, url);
    if (path != null && mounted) setState(() => _localPicPath = path);
  }

  Future<void> _sendRequest() async {
    setState(() => _busy = true);
    final ok = await ServerService().sendConnectionRequest(_pubkey);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _connState = _ConnState.pending;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send request — try again')),
      );
    }
  }

  Future<void> _accept() async {
    final id = widget.incomingRequestId;
    if (id == null) return;
    setState(() => _busy = true);
    final ok = await ServerService().acceptConnectionRequest(id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _connState = _ConnState.connected;
    });
  }

  Future<void> _decline() async {
    final id = widget.incomingRequestId;
    if (id == null) return;
    setState(() => _busy = true);
    final ok = await ServerService().declineConnectionRequest(id);
    if (!mounted) return;
    if (ok) Navigator.pop(context);
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ── Avatar ──────────────────────────────────────────────────────
          Center(
            child: Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.mint.withAlpha(80), width: 2),
                color: AppColors.inputBg,
              ),
              clipBehavior: Clip.antiAlias,
              child: _localPicPath != null
                  ? Image.file(File(_localPicPath!), fit: BoxFit.cover)
                  : _pictureUrl != null && _pictureUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: _pictureUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const Icon(Icons.person_outline, size: 44, color: AppColors.textMuted),
                        )
                      : const Icon(Icons.person_outline, size: 44, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(height: 16),

          // ── Name + shortId ───────────────────────────────────────────────
          Center(
            child: Text(
              _displayName.isNotEmpty ? '@$_displayName' : '#$_shortId',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          if (_displayName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                '#$_shortId',
                style: const TextStyle(fontSize: 13, color: AppColors.mint, fontWeight: FontWeight.w600, letterSpacing: 1.5),
              ),
            ),
          ],
          if (_bio.isNotEmpty) ...[
            const SizedBox(height: 12),
            Center(
              child: Text(
                _bio,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: AppColors.textMuted, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 32),

          // ── Action buttons ───────────────────────────────────────────────
          _buildAction(),
        ],
      ),
    );
  }

  Widget _buildAction() {
    if (_busy) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (_connState) {
      case _ConnState.connected:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline, color: AppColors.online, size: 20),
            const SizedBox(width: 8),
            const Text('Connected', style: TextStyle(fontSize: 15, color: AppColors.online, fontWeight: FontWeight.w600)),
          ],
        );

      case _ConnState.pending:
        return const Center(
          child: Text(
            'Request sent — waiting for them to accept',
            style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
        );

      case _ConnState.incoming:
        return Column(
          children: [
            Text(
              '@${_displayName.isNotEmpty ? _displayName : _shortId} wants to connect with you',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _decline,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.error),
                      foregroundColor: AppColors.error,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _accept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.mint,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Accept', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        );

      case _ConnState.none:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _sendRequest,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.mint,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Connect', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        );
    }
  }
}
