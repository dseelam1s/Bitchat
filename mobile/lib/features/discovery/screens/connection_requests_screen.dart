import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/discovery/screens/user_profile_screen.dart';

class ConnectionRequestsScreen extends StatefulWidget {
  final MessageService messageService;

  const ConnectionRequestsScreen({super.key, required this.messageService});

  @override
  State<ConnectionRequestsScreen> createState() => _ConnectionRequestsScreenState();
}

class _ConnectionRequestsScreenState extends State<ConnectionRequestsScreen> {
  List<Map<String, dynamic>>? _requests;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await ServerService().getPendingConnectionRequests();
    if (mounted) setState(() { _requests = result ?? []; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connection Requests')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _requests == null || _requests!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_outline, size: 48, color: AppColors.textMuted.withAlpha(100)),
                      const SizedBox(height: 12),
                      const Text('No pending requests', style: TextStyle(color: AppColors.textMuted)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _requests!.length,
                    separatorBuilder: (_, __) => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(height: 1, color: AppColors.divider),
                    ),
                    itemBuilder: (ctx, i) => _RequestTile(
                      request: _requests![i],
                      messageService: widget.messageService,
                      onResolved: _load,
                    ),
                  ),
                ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  final Map<String, dynamic> request;
  final MessageService messageService;
  final VoidCallback onResolved;

  const _RequestTile({required this.request, required this.messageService, required this.onResolved});

  @override
  Widget build(BuildContext context) {
    final profile = request['from'] as Map<String, dynamic>? ?? {};
    final pubkey = profile['pubkey'] as String? ?? '';
    final name = profile['display_name'] as String? ?? '';
    final bio = profile['bio'] as String? ?? '';
    final picUrl = profile['profile_picture_url'] as String?;
    final requestId = request['id'] as int? ?? 0;
    final shortId = Contact.shortIdFor(pubkey);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.inputBg,
          border: Border.all(color: AppColors.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: picUrl != null && picUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: picUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const Icon(Icons.person_outline, color: AppColors.textMuted),
              )
            : const Icon(Icons.person_outline, color: AppColors.textMuted),
      ),
      title: Text(
        name.isNotEmpty ? '@$name' : '#$shortId',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: bio.isNotEmpty
          ? Text(bio, style: const TextStyle(fontSize: 12, color: AppColors.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis)
          : Text('#$shortId', style: const TextStyle(fontSize: 12, color: AppColors.mint, letterSpacing: 1.2)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            label: 'Decline',
            color: AppColors.error,
            onTap: () async {
              await ServerService().declineConnectionRequest(requestId);
              onResolved();
            },
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Accept',
            color: AppColors.mint,
            textColor: Colors.black,
            onTap: () async {
              await ServerService().acceptConnectionRequest(requestId);
              onResolved();
            },
          ),
        ],
      ),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => UserProfileScreen(
            profile: profile,
            messageService: messageService,
            incomingRequestId: requestId,
          ),
        ));
        onResolved();
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color? textColor;
  final VoidCallback onTap;

  const _ActionButton({required this.label, required this.color, this.textColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: textColor != null ? color : color.withAlpha(20),
          borderRadius: BorderRadius.circular(8),
          border: textColor != null ? null : Border.all(color: color.withAlpha(80)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: textColor ?? color,
          ),
        ),
      ),
    );
  }
}
