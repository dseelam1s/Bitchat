import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/discovery/screens/user_profile_screen.dart';
import 'package:bitchat_messenger/features/discovery/screens/connection_requests_screen.dart';

class DiscoveryScreen extends StatefulWidget {
  final MessageService messageService;

  const DiscoveryScreen({super.key, required this.messageService});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  int _pendingCount = 0;
  Timer? _pendingTimer;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadPendingCount();
    // Refresh pending count every 30s while this screen is visible
    _pendingTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadPendingCount());
  }

  Future<void> _loadPendingCount() async {
    final list = await ServerService().getPendingConnectionRequests();
    if (mounted) setState(() => _pendingCount = list?.length ?? 0);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _pendingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: [
          IconButton(
            tooltip: 'Connection requests',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(
                builder: (_) => ConnectionRequestsScreen(messageService: widget.messageService),
              ));
              _loadPendingCount();
            },
            icon: Badge(
              isLabelVisible: _pendingCount > 0,
              label: Text('$_pendingCount', style: const TextStyle(fontSize: 9)),
              backgroundColor: AppColors.primary,
              textColor: Colors.white,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.bluetooth_searching_outlined, size: 20), text: 'Nearby'),
            Tab(icon: Icon(Icons.search_outlined, size: 20), text: 'Search'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _NearbyTab(messageService: widget.messageService),
          _SearchTab(messageService: widget.messageService),
        ],
      ),
    );
  }
}

// ── Nearby Tab ────────────────────────────────────────────────────────────────

class _NearbyTab extends StatefulWidget {
  final MessageService messageService;
  const _NearbyTab({required this.messageService});

  @override
  State<_NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<_NearbyTab> {
  StreamSubscription? _nearbySub;
  Set<String> _nearbyPubkeys = {};
  final Map<String, Map<String, dynamic>> _profiles = {};

  @override
  void initState() {
    super.initState();
    _nearbyPubkeys = Set.of(widget.messageService.nearbyUsers);
    _nearbySub = widget.messageService.nearbyChangedStream.listen((pubkeys) {
      if (!mounted) return;
      setState(() => _nearbyPubkeys = pubkeys);
      for (final pk in pubkeys) {
        if (!_profiles.containsKey(pk)) _fetchProfile(pk);
      }
    });
    // Fetch profiles for any already-nearby users
    for (final pk in _nearbyPubkeys) {
      _fetchProfile(pk);
    }
  }

  Future<void> _fetchProfile(String pubkey) async {
    final result = await ServerService().getProfile(pubkey);
    if (result != null && mounted) {
      setState(() => _profiles[pubkey] = result);
    }
  }

  @override
  void dispose() {
    _nearbySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myPubkey = widget.messageService.publicKey;
    final peers = _nearbyPubkeys.where((pk) => pk != myPubkey).toList();

    if (peers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_disabled_outlined, size: 56, color: AppColors.textMuted.withAlpha(80)),
              const SizedBox(height: 16),
              const Text(
                'No one nearby',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'People around you with BitChat and Bluetooth on will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.textMuted.withAlpha(180), height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: peers.length,
      separatorBuilder: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Divider(height: 1, color: AppColors.divider),
      ),
      itemBuilder: (ctx, i) {
        final pk = peers[i];
        final profile = _profiles[pk];
        return _ProfileTile(
          pubkey: pk,
          profile: profile,
          messageService: widget.messageService,
          badge: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.online.withAlpha(20),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.online.withAlpha(80)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.online)),
                const SizedBox(width: 4),
                const Text('Nearby', style: TextStyle(fontSize: 10, color: AppColors.online, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Search Tab ────────────────────────────────────────────────────────────────

class _SearchTab extends StatefulWidget {
  final MessageService messageService;
  const _SearchTab({required this.messageService});

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>>? _results;
  bool _loading = false;
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() { _results = null; _loading = false; });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await ServerService().searchProfiles(q.trim());
      if (!mounted) return;
      final myPubkey = widget.messageService.publicKey;
      setState(() {
        _results = results?.where((r) => r['pubkey'] != myPubkey).toList();
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Search bar ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            onChanged: _onQueryChanged,
            autofocus: false,
            decoration: InputDecoration(
              hintText: 'Search by username or #shortId',
              prefixIcon: const Icon(Icons.search_outlined, size: 20),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.inputBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),

        // ── Results ───────────────────────────────────────────────────────
        Expanded(
          child: _buildResults(),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_results == null) {
      return Center(
        child: Text(
          'Type at least 2 characters to search',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted.withAlpha(180)),
        ),
      );
    }

    if (_results!.isEmpty) {
      return Center(
        child: Text(
          'No users found',
          style: TextStyle(fontSize: 14, color: AppColors.textMuted.withAlpha(180)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _results!.length,
      separatorBuilder: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Divider(height: 1, color: AppColors.divider),
      ),
      itemBuilder: (ctx, i) => _ProfileTile(
        pubkey: _results![i]['pubkey'] as String? ?? '',
        profile: _results![i],
        messageService: widget.messageService,
      ),
    );
  }
}

// ── Shared profile tile ───────────────────────────────────────────────────────

class _ProfileTile extends StatelessWidget {
  final String pubkey;
  final Map<String, dynamic>? profile;
  final MessageService messageService;
  final Widget? badge;

  const _ProfileTile({
    required this.pubkey,
    required this.profile,
    required this.messageService,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final name = profile?['display_name'] as String? ?? '';
    final bio = profile?['bio'] as String? ?? '';
    final picUrl = profile?['profile_picture_url'] as String?;
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
        child: profile == null
            ? const CircularProgressIndicator(strokeWidth: 2)
            : picUrl != null && picUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: picUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const Icon(Icons.person_outline, color: AppColors.textMuted),
                  )
                : const Icon(Icons.person_outline, color: AppColors.textMuted),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              name.isNotEmpty ? '@$name' : '#$shortId',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (badge != null) ...[const SizedBox(width: 8), badge!],
        ],
      ),
      subtitle: profile == null
          ? Text('#$shortId', style: const TextStyle(fontSize: 12, color: AppColors.mint, letterSpacing: 1.2))
          : bio.isNotEmpty
              ? Text(bio, style: const TextStyle(fontSize: 12, color: AppColors.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis)
              : name.isNotEmpty
                  ? Text('#$shortId', style: const TextStyle(fontSize: 12, color: AppColors.mint, letterSpacing: 1.2))
                  : null,
      trailing: const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
      onTap: profile == null
          ? null
          : () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  profile: profile!,
                  messageService: messageService,
                ),
              )),
    );
  }
}
