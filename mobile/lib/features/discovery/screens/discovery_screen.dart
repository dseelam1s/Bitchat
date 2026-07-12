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
  Set<String> _liveNearbyPubkeys = {};
  List<Map<String, dynamic>> _bleHistory = [];
  final Map<String, Map<String, dynamic>> _profiles = {};

  @override
  void initState() {
    super.initState();
    _liveNearbyPubkeys = Set.of(widget.messageService.nearbyUsers);
    _loadHistory();
    _nearbySub = widget.messageService.nearbyChangedStream.listen((pubkeys) {
      if (!mounted) return;
      setState(() => _liveNearbyPubkeys = pubkeys);
      _loadHistory();
    });
  }

  Future<void> _loadHistory() async {
    final rows = await widget.messageService.dbService.getBleHistory();
    if (!mounted) return;
    setState(() => _bleHistory = rows);
    for (final row in rows) {
      final pk = row['pubkey'] as String;
      if (!_profiles.containsKey(pk)) _fetchProfile(pk);
    }
  }

  Future<void> _fetchProfile(String pubkey) async {
    final result = await ServerService().getProfile(pubkey);
    if (!mounted) return;
    // Store empty map when server has no profile — distinguishes "loaded, no profile"
    // from null = "still loading". _ProfileTile handles both cases differently.
    setState(() => _profiles[pubkey] = result ?? {});
  }

  @override
  void dispose() {
    _nearbySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myPubkey = widget.messageService.publicKey;
    final peers = _bleHistory
        .where((r) => (r['pubkey'] as String) != myPubkey)
        .toList(); // already sorted lastSeen DESC from DB

    if (peers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_searching_outlined, size: 56, color: AppColors.textMuted.withAlpha(80)),
              const SizedBox(height: 16),
              const Text(
                'No one nearby yet',
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
        final row = peers[i];
        final pk = row['pubkey'] as String;
        final isLive = _liveNearbyPubkeys.contains(pk);
        final profile = _profiles[pk];
        // BLE handshake name — used as fallback when server has no profile
        final bleName = row['displayName'] as String?;
        return _ProfileTile(
          pubkey: pk,
          profile: profile,
          fallbackName: bleName,
          messageService: widget.messageService,
          badge: isLive
              ? Container(
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
                )
              : null,
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
  /// null  = still loading from server
  /// {}    = loaded, no server profile found
  /// {...} = full server profile
  final Map<String, dynamic>? profile;
  final MessageService messageService;
  final Widget? badge;
  final String? fallbackName; // BLE handshake name when server has no profile

  const _ProfileTile({
    required this.pubkey,
    required this.profile,
    required this.messageService,
    this.badge,
    this.fallbackName,
  });

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = profile == null;
    final hasProfile = profile != null && profile!.isNotEmpty;

    final serverName = hasProfile ? (profile!['display_name'] as String? ?? '') : '';
    final bio = hasProfile ? (profile!['bio'] as String? ?? '') : '';
    final picUrl = hasProfile ? (profile!['profile_picture_url'] as String?) : null;
    final shortId = Contact.shortIdFor(pubkey);

    // Resolved display name: server name > BLE handshake name > short ID
    // Strip leading '#' from BLE name since we add it ourselves if needed
    final bleName = fallbackName?.replaceFirst(RegExp(r'^#'), '');
    final displayName = serverName.isNotEmpty
        ? serverName
        : (bleName != null && bleName.isNotEmpty && bleName != shortId)
            ? bleName
            : '';

    final titleText = displayName.isNotEmpty ? displayName : '#$shortId';
    final showShortIdSubtitle = displayName.isNotEmpty;

    return InkWell(
      onTap: isLoading
          ? null
          : () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  profile: hasProfile ? profile! : {'pubkey': pubkey},
                  messageService: messageService,
                ),
              )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 52, height: 52,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.inputBg),
              clipBehavior: Clip.antiAlias,
              child: isLoading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : picUrl != null && picUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: picUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _initialsAvatar(titleText),
                        )
                      : _initialsAvatar(titleText),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleText,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!isLoading) ...[
                    const SizedBox(height: 2),
                    if (bio.isNotEmpty)
                      Text(bio, style: const TextStyle(fontSize: 13, color: AppColors.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis)
                    else if (showShortIdSubtitle)
                      Text('#$shortId', style: const TextStyle(fontSize: 13, color: AppColors.textMuted, letterSpacing: 0.5)),
                  ],
                ],
              ),
            ),
            if (badge != null) ...[const SizedBox(width: 8), badge!],
          ],
        ),
      ),
    );
  }

  Widget _initialsAvatar(String name) {
    final letters = _initials(name.startsWith('#') ? name.substring(1) : name);
    return Center(
      child: Text(
        letters,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textMuted),
      ),
    );
  }
}
