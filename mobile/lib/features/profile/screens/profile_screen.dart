import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:bitchat_messenger/core/demo_data.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/main.dart' show themeNotifier;
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/backup_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';

// ── Profile Screen (Tab: Me) ──────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  final MessageService messageService;
  const ProfileScreen({super.key, required this.messageService});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _usernameController;
  bool _isPublic = true;
  String? _profilePictureUrl;
  String? _localProfilePicturePath;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.messageService.username ?? '');
    _loadProfilePicture();
    _loadProfileSettings();
  }

  Future<void> _loadProfilePicture() async {
    final pubkey = widget.messageService.publicKey;
    if (pubkey == null) return;
    final cached = await ProfilePictureCacheService().localPath(pubkey);
    if (cached != null && mounted) setState(() => _localProfilePicturePath = cached);

    final result = await ServerService().getMyProfile();
    final url = result?['profile_picture_url'] as String?;
    if (url != null && url.isNotEmpty && mounted) {
      setState(() => _profilePictureUrl = url);
      final localPath = await ProfilePictureCacheService().download(pubkey, url);
      if (localPath != null && mounted) setState(() => _localProfilePicturePath = localPath);
    }
  }

  Future<void> _loadProfileSettings() async {
    final result = await ServerService().getMyProfile();
    if (result != null && mounted) {
      setState(() {
        _isPublic = result['is_public'] as bool? ?? true;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  void _saveUsername() {
    final name = _usernameController.text.trim();
    widget.messageService.setUsername(name.isNotEmpty ? name : null);
  }

  /// One visibility switch — sets both server flags (search + nearby)
  /// together. Two separate toggles was a privacy quiz nobody asked for.
  Future<void> _toggleVisibility(bool value) async {
    setState(() => _isPublic = value);
    await ServerService().updateProfile(
      isPublic: value,
      isDiscoverableNearby: value,
    );
  }

  void _showEditNameDialog() {
    final ctrl = TextEditingController(text: _usernameController.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Your name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              _usernameController.text = ctrl.text;
              _saveUsername();
              setState(() {});
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showProfilePictureOptions() async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            if (_profilePictureUrl != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.error),
                title: const Text('Remove photo', style: TextStyle(color: AppColors.error)),
                onTap: () => Navigator.pop(ctx, '_remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (result == '_remove') { await _removeProfilePicture(); return; }
    if (result is! ImageSource) return;
    await _pickAndUpload(result);
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 85);
    if (picked == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        SizedBox(width: 12),
        Text('Uploading photo...'),
      ]),
      duration: Duration(days: 1),
    ));

    try {
      final url = await ServerService().uploadProfilePicture(File(picked.path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await ServerService().updateProfile(profilePictureUrl: url);
      if (!mounted) return;
      setState(() => _profilePictureUrl = url);
      widget.messageService.setProfilePictureUrl(url);
      final pubkey = widget.messageService.publicKey;
      if (pubkey != null) {
        final localPath = await ProfilePictureCacheService().download(pubkey, url);
        if (localPath != null && mounted) setState(() => _localProfilePicturePath = localPath);
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile picture updated')));
    } on ServerUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed — ${e.message}'), duration: const Duration(seconds: 5)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed')));
    }
  }

  Future<void> _removeProfilePicture() async {
    await ServerService().updateProfile(profilePictureUrl: '');
    widget.messageService.setProfilePictureUrl(null);
    final pubkey = widget.messageService.publicKey;
    if (pubkey != null) await ProfilePictureCacheService().delete(pubkey);
    if (mounted) setState(() { _profilePictureUrl = null; _localProfilePicturePath = null; });
  }

  String _initials() {
    final name = _usernameController.text.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.substring(0, min(2, name.length)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final pubkey = widget.messageService.publicKey;
    final shortId = pubkey != null ? Contact.shortIdFor(pubkey) : '——————';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final displayName = _usernameController.text.trim();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Instagram-style sticky header ──────────────────────────────
          SliverAppBar(
            backgroundColor: cs.surface,
            surfaceTintColor: Colors.transparent,
            pinned: true,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            title: Text(
              displayName.isNotEmpty ? displayName : 'Me',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 24),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _SettingsScreen(messageService: widget.messageService),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),

          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── Identity — calm, centered ───────────────────────────────────
                Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: _showProfilePictureOptions,
                          child: Stack(
                            children: [
                              Container(
                                width: 96, height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isDark ? AppColors.darkCard : AppColors.card,
                                  border: Border.all(color: AppColors.primary.withAlpha(60), width: 2),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: _localProfilePicturePath != null
                                    ? Image.file(File(_localProfilePicturePath!), fit: BoxFit.cover)
                                    : _profilePictureUrl != null && _profilePictureUrl!.isNotEmpty
                                        ? CachedNetworkImage(
                                            imageUrl: _profilePictureUrl!,
                                            fit: BoxFit.cover,
                                            errorWidget: (_, __, ___) => _initialsWidget(),
                                          )
                                        : _initialsWidget(),
                              ),
                              Positioned(
                                right: 2, bottom: 2,
                                child: Container(
                                  width: 28, height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.primary,
                                    border: Border.all(color: cs.surface, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        GestureDetector(
                          onTap: _showEditNameDialog,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                displayName.isNotEmpty ? displayName : 'Set your name',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                  color: displayName.isNotEmpty ? cs.onSurface : AppColors.textMuted,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(Icons.edit, size: 15, color: AppColors.textMuted.withAlpha(160)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Short ID chip + share — the key you hand to people
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: '#$shortId'));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('ID copied'), duration: Duration(seconds: 2)),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isDark ? AppColors.darkCard : AppColors.card,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '#$shortId',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 2,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.copy, size: 15, color: AppColors.textMuted),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                SharePlus.instance.share(ShareParams(
                                  text: 'Find me on Reach — my ID is #$shortId',
                                ));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.share_outlined, size: 15, color: Colors.white),
                                    SizedBox(width: 6),
                                    Text('Share',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13.5)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'No phone number — your ID is how people find you.',
                          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),

                // ── Visibility ─────────────────────────────────────────────
                _sectionHeader('Visibility'),
                _settingsCard(
                  isDark: isDark,
                  children: [
                    _switchRow(
                      icon: Icons.radar_outlined,
                      label: 'Visible to others',
                      subtitle: 'People can find you nearby and by search. '
                          'Off: only your contacts can reach you.',
                      value: _isPublic,
                      onChanged: _toggleVisibility,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── More section ───────────────────────────────────────────
                _sectionHeader('More'),
                _settingsCard(
                  isDark: isDark,
                  children: [
                    _navRow(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      isDark: isDark,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _SettingsScreen(messageService: widget.messageService),
                        ),
                      ),
                    ),
                    _cardDivider(),
                    _navRow(
                      icon: Icons.privacy_tip_outlined,
                      label: 'Privacy Policy',
                      isDark: isDark,
                      onTap: () => _showPrivacyPolicy(context),
                    ),
                  ],
                ),

                const SizedBox(height: 32),
                Center(
                  child: Text(
                    'v1.0.0',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(80)),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textMuted,
      ),
    ),
  );

  Widget _settingsCard({required bool isDark, required List<Widget> children}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    ),
  );

  Widget _cardDivider() => const Padding(
    padding: EdgeInsets.only(left: 52),
    child: Divider(height: 1, color: AppColors.divider),
  );

  Widget _switchRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    ValueChanged<bool>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _navRow({
    required IconData icon,
    required String label,
    required bool isDark,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              ),
              Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
            ],
          ),
        ),
      );

  Widget _initialsWidget() => Center(
    child: Text(
      _initials(),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textMuted),
    ),
  );

  void _showPrivacyPolicy(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Privacy Policy'),
        content: const SingleChildScrollView(
          child: Text(
            'Reach is a decentralized, end-to-end encrypted messaging app.\n\n'
            'Data We Collect:\n'
            '• Your keypair is generated on-device and never sent to any server in plaintext.\n'
            '• Messages are encrypted on-device before transmission.\n'
            '• If you enable key backup, your encrypted private key is stored on our server. Only you can decrypt it with your password.\n'
            '• Firebase may collect crash diagnostics if enabled.\n\n'
            'Data We Do Not Collect:\n'
            '• We do not collect your phone number, email, or real name.\n'
            '• We cannot read your messages.\n'
            '• We do not sell or share your data with third parties.\n\n'
            'Permissions:\n'
            '• Bluetooth: Required for offline peer-to-peer messaging.\n'
            '• Location: Required on Android for Bluetooth scanning.\n'
            '• Notifications: For incoming message and call alerts.\n'
            '• Camera/Photos: Only if you set a profile picture.\n\n'
            'By using BitChat you agree to these terms.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }
}

// ── Combined Settings Screen ──────────────────────────────────────────────────

class _SettingsScreen extends StatefulWidget {
  final MessageService messageService;
  const _SettingsScreen({required this.messageService});

  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  bool _backupActive = false;

  @override
  void initState() {
    super.initState();
    BackupService().isBackupActive().then((v) {
      if (mounted) setState(() => _backupActive = v);
    });
  }

  void _showPublicKeyDialog() {
    final pubkey = widget.messageService.publicKey ?? 'Not generated';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Public Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your 64-character identity. Share it so others can message you directly.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.inputBg, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(pubkey, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.6)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pubkey));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Public key copied')));
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  void _showBackupDialog({required bool isUpdate}) {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    bool obscure1 = true;
    bool obscure2 = true;
    String? error;
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(isUpdate ? 'Update Backup Password' : 'Back Up My Key'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUpdate)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text(
                      'Your private key will be encrypted with this password and stored on the server. Only you can decrypt it.',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                TextField(
                  controller: passwordController,
                  obscureText: obscure1,
                  decoration: InputDecoration(
                    labelText: 'Password (min 4 chars)',
                    suffixIcon: IconButton(
                      icon: Icon(obscure1 ? Icons.visibility_off : Icons.visibility, size: 18),
                      onPressed: () => setLocal(() => obscure1 = !obscure1),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmController,
                  obscureText: obscure2,
                  decoration: InputDecoration(
                    labelText: 'Confirm password',
                    suffixIcon: IconButton(
                      icon: Icon(obscure2 ? Icons.visibility_off : Icons.visibility, size: 18),
                      onPressed: () => setLocal(() => obscure2 = !obscure2),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(fontSize: 11, color: AppColors.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: isLoading ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: isLoading ? null : () async {
                final pw = passwordController.text;
                final confirm = confirmController.text;
                if (pw.length < 4) { setLocal(() => error = 'Minimum 4 characters.'); return; }
                if (pw != confirm) { setLocal(() => error = 'Passwords do not match.'); return; }
                setLocal(() { isLoading = true; error = null; });
                final privateKey = widget.messageService.privateKey;
                if (privateKey == null) { setLocal(() { isLoading = false; error = 'No key found.'; }); return; }
                final success = await BackupService().backupToServer(privateKey, pw);
                if (!ctx.mounted) return;
                if (success) {
                  Navigator.pop(ctx);
                  setState(() => _backupActive = true);
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Key backed up successfully.')));
                } else {
                  setLocal(() { isLoading = false; error = 'Server unreachable. Try again later.'; });
                }
              },
              child: isLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(isUpdate ? 'Update' : 'Back Up'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        SizedBox(width: 12),
        Text('Checking server...'),
      ]),
      duration: Duration(seconds: 10),
    ));
    final ok = await ServerService().ping();
    if (!mounted) return;
    final wsConnected = widget.messageService.isSignalingConnected;
    messenger.hideCurrentSnackBar();
    final String msg;
    final Color color;
    if (!ok) {
      msg = 'Server unreachable — check your internet connection';
      color = Colors.red[700]!;
    } else if (!wsConnected) {
      msg = 'Server reachable but real-time connection not ready yet';
      color = Colors.orange[700]!;
    } else {
      msg = 'Server reachable and real-time connection active';
      color = Colors.green[700]!;
    }
    messenger.showSnackBar(SnackBar(content: Text(msg), backgroundColor: color, duration: const Duration(seconds: 4)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 16),

          // ── Account ──────────────────────────────────────────────────────
          _sectionLabel('ACCOUNT'),
          _tile(Icons.key_outlined, 'Public Key', onTap: _showPublicKeyDialog),
          const Divider(height: 1, indent: 20),
          _tile(
            _backupActive ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            'Key Backup',
            trailing: _backupActive
                ? const Icon(Icons.check_circle, size: 16, color: AppColors.online)
                : const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber),
            onTap: () => _showBackupDialog(isUpdate: _backupActive),
          ),

          const SizedBox(height: 24),

          // ── Messaging ─────────────────────────────────────────────────────
          // Relay range (mesh TTL) slider removed — an engineer's knob users
          // can't reason about; the default in AppConstants applies.
          _sectionLabel('MESSAGING'),
          _tile(Icons.network_check_outlined, 'Test Connection', onTap: _testConnection),

          if (kDebugMode) ...[
            const SizedBox(height: 24),
            _sectionLabel('DEVELOPER'),
            _tile(Icons.auto_awesome_outlined, 'Load demo data', onTap: () async {
              final myPubkey = widget.messageService.publicKey ?? '';
              await DemoData.seed(widget.messageService.dbService, myPubkey);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Demo data loaded — reopen Chats')));
              }
            }),
            const Divider(height: 1, indent: 20),
            _tile(Icons.cleaning_services_outlined, 'Clear demo data', onTap: () async {
              await DemoData.clear(widget.messageService.dbService);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Demo data cleared')));
              }
            }),
          ],

          const SizedBox(height: 24),

          // ── Appearance ────────────────────────────────────────────────────
          _sectionLabel('APPEARANCE'),
          ListenableBuilder(
            listenable: themeNotifier,
            builder: (_, __) => Column(
              children: [
                _themeRow(Icons.light_mode_outlined, 'Light', ThemeMode.light),
                const Divider(height: 1, indent: 20),
                _themeRow(Icons.dark_mode_outlined, 'Dark', ThemeMode.dark),
                const Divider(height: 1, indent: 20),
                _themeRow(Icons.brightness_auto_outlined, 'System default', ThemeMode.system),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted.withAlpha(150), letterSpacing: 1.5),
    ),
  );

  Widget _tile(IconData icon, String title, {Widget? trailing, VoidCallback? onTap}) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
    leading: Icon(icon, size: 22, color: AppColors.textMuted),
    title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
    trailing: trailing ?? const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
    onTap: onTap,
  );

  Widget _themeRow(IconData icon, String title, ThemeMode value) {
    final sel = themeNotifier.mode == value;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Icon(icon, size: 22, color: sel ? AppColors.textPrimary : AppColors.textMuted),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: sel ? FontWeight.w600 : FontWeight.w500)),
      trailing: sel ? const Icon(Icons.check, size: 18, color: AppColors.textPrimary) : null,
      onTap: () {
        if (value == ThemeMode.dark) themeNotifier.setDark();
        else if (value == ThemeMode.light) themeNotifier.setLight();
        else themeNotifier.setSystem();
      },
    );
  }
}
