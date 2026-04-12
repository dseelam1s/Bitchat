import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/main.dart' show themeNotifier;
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/backup_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

// ── Profile Screen (Tab 3) ────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  final MessageService messageService;

  const ProfileScreen({super.key, required this.messageService});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _usernameController;
  bool _isEditingUsername = false;
  String? _profilePictureUrl;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(
      text: widget.messageService.username ?? '',
    );
    _loadProfilePicture();
  }

  Future<void> _loadProfilePicture() async {
    final pubkey = widget.messageService.publicKey;
    if (pubkey == null) return;
    final result = await ServerService().getProfile(pubkey);
    final url = result?['profile_picture_url'] as String?;
    if (url != null && url.isNotEmpty && mounted) {
      setState(() => _profilePictureUrl = url);
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
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(name.isNotEmpty ? 'Username updated' : 'Username cleared')),
    );
  }

  Future<void> _showProfilePictureOptions() async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: _optionIcon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: _optionIcon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            if (_profilePictureUrl != null)
              ListTile(
                leading: _optionIcon(Icons.delete_outline, isError: true),
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

  Widget _optionIcon(IconData icon, {bool isError = false}) {
    final color = isError ? AppColors.error : AppColors.mint;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: color.withAlpha(15), borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: color),
    );
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
      duration: Duration(days: 1), // dismissed explicitly below
    ));

    try {
      final url = await ServerService().uploadProfilePicture(File(picked.path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await ServerService().updateProfile(profilePictureUrl: url);
      if (!mounted) return;
      setState(() => _profilePictureUrl = url);
      // Persist locally so it's available offline and in BLE handshakes
      widget.messageService.setProfilePictureUrl(url);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile picture updated')));
    } on ServerUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Upload failed — ${e.message}'),
        duration: const Duration(seconds: 5),
      ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed — unexpected error')));
    }
  }

  Future<void> _removeProfilePicture() async {
    await ServerService().updateProfile(profilePictureUrl: '');
    widget.messageService.setProfilePictureUrl(null);
    if (mounted) setState(() => _profilePictureUrl = null);
  }

  @override
  Widget build(BuildContext context) {
    final pubkey = widget.messageService.publicKey;
    final shortId = pubkey != null ? Contact.shortIdFor(pubkey) : '——————';

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 16,
          bottom: 40,
        ),
        children: [
          // ── Profile header ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                // Avatar
                GestureDetector(
                  onTap: _showProfilePictureOptions,
                  child: Stack(
                    children: [
                      Container(
                        width: 72, height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.mint.withAlpha(80), width: 2),
                          color: AppColors.inputBg,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _profilePictureUrl != null
                            ? CachedNetworkImage(
                                imageUrl: _profilePictureUrl!,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => const Icon(Icons.person_outline, size: 34, color: AppColors.textMuted),
                              )
                            : const Icon(Icons.person_outline, size: 34, color: AppColors.textMuted),
                      ),
                      Positioned(
                        bottom: 0, right: 0,
                        child: Container(
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.mint,
                            border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 1.5),
                          ),
                          child: const Icon(Icons.camera_alt, size: 12, color: Colors.black),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Name + Short ID
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Editable username
                      _isEditingUsername
                          ? Row(
                              children: [
                                Text('@', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.mint)),
                                Expanded(
                                  child: TextField(
                                    controller: _usernameController,
                                    autofocus: true,
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                      isDense: true,
                                      filled: false,
                                    ),
                                    onSubmitted: (_) {
                                      _saveUsername();
                                      setState(() => _isEditingUsername = false);
                                    },
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () { _saveUsername(); setState(() => _isEditingUsername = false); },
                                  child: const Icon(Icons.check_circle, size: 20, color: AppColors.mint),
                                ),
                              ],
                            )
                          : GestureDetector(
                              onTap: () => setState(() => _isEditingUsername = true),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _usernameController.text.isNotEmpty
                                        ? '@${_usernameController.text}'
                                        : 'Tap to set username',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      color: _usernameController.text.isNotEmpty ? null : AppColors.textMuted,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Icons.edit, size: 13, color: AppColors.textMuted.withAlpha(120)),
                                ],
                              ),
                            ),
                      const SizedBox(height: 4),
                      Text(
                        '#$shortId',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.mint, letterSpacing: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(height: 1, color: AppColors.divider),
          ),
          const SizedBox(height: 8),

          // ── Settings rows ───────────────────────────────────────────────
          _settingsRow(
            context,
            icon: Icons.manage_accounts_outlined,
            title: 'Account',
            subtitle: 'Public key, key backup',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => _AccountScreen(messageService: widget.messageService),
            )),
          ),
          _settingsRow(
            context,
            icon: Icons.forum_outlined,
            title: 'Messaging',
            subtitle: 'How your messages are delivered',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => _MessagingScreen(messageService: widget.messageService),
            )),
          ),
          _settingsRow(
            context,
            icon: Icons.hub_outlined,
            title: 'Network',
            subtitle: 'Nostr relays',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => _NetworkScreen(messageService: widget.messageService),
            )),
          ),
          _settingsRow(
            context,
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: 'Theme',
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _AppearanceScreen(),
            )),
          ),
          _settingsRow(
            context,
            icon: Icons.network_check_outlined,
            title: 'Test Server Connection',
            subtitle: 'Check if server is reachable',
            onTap: () async {
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
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(SnackBar(
                content: Text(ok ? 'Server is reachable' : 'Server unreachable — check your internet connection'),
                backgroundColor: ok ? Colors.green[700] : Colors.red[700],
                duration: const Duration(seconds: 3),
              ));
            },
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Divider(height: 1),
          ),
          _settingsRow(
            context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'How your data is handled',
            onTap: () => _showPrivacyPolicy(context),
          ),

          const SizedBox(height: 32),
          Center(
            child: Text('v0.1.0', style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(80))),
          ),
        ],
      ),
    );
  }

  void _showPrivacyPolicy(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Privacy Policy'),
        content: const SingleChildScrollView(
          child: Text(
            'BitChat is a decentralized, end-to-end encrypted messaging app.\n\n'
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
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _settingsRow(BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: AppColors.mint.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AppColors.mint, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      trailing: const Icon(Icons.chevron_right, size: 20, color: AppColors.textMuted),
      onTap: onTap,
    );
  }
}

// ── Account Screen ────────────────────────────────────────────────────────────

class _AccountScreen extends StatefulWidget {
  final MessageService messageService;
  const _AccountScreen({required this.messageService});

  @override
  State<_AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<_AccountScreen> {
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
              child: SelectableText(
                pubkey,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.6),
              ),
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
                if (privateKey == null) {
                  setLocal(() { isLoading = false; error = 'No key found.'; });
                  return;
                }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _tile(
            icon: Icons.key_outlined,
            title: 'Public Key',
            subtitle: 'View your 64-character identity key',
            onTap: _showPublicKeyDialog,
          ),
          _divider(),
          _tile(
            icon: _backupActive ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            iconColor: _backupActive ? AppColors.online : Colors.amber,
            title: 'Key Backup',
            subtitle: _backupActive ? 'Backed up — tap to update password' : 'Not backed up — tap to protect',
            trailing: _backupActive
                ? const Icon(Icons.check_circle, size: 18, color: AppColors.online)
                : const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber),
            onTap: () => _showBackupDialog(isUpdate: _backupActive),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    Color? iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(icon, size: 22, color: iconColor ?? AppColors.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)) : null,
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
      onTap: onTap,
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20),
    child: Divider(height: 1, color: AppColors.divider),
  );
}

// ── Messaging Screen ──────────────────────────────────────────────────────────

class _MessagingScreen extends StatefulWidget {
  final MessageService messageService;
  const _MessagingScreen({required this.messageService});

  @override
  State<_MessagingScreen> createState() => _MessagingScreenState();
}

class _MessagingScreenState extends State<_MessagingScreen> {
  late String _mode;
  late int _ttl;

  @override
  void initState() {
    super.initState();
    _mode = widget.messageService.mode;
    _ttl = widget.messageService.ttl;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Messaging')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _sectionLabel('MESSAGE DELIVERY'),
          _modeRow(
            Icons.wifi_tethering,
            'Smart (recommended)',
            'Uses internet when available, switches to nearby automatically',
            AppConstants.modeAuto,
          ),
          _divider(),
          _modeRow(
            Icons.signal_wifi_4_bar,
            'Internet only',
            'Only sends when you have a data connection',
            AppConstants.modeOnline,
          ),
          _divider(),
          _modeRow(
            Icons.bluetooth,
            'Nearby only',
            'Only connects to people around you, no internet needed',
            AppConstants.modeOffline,
          ),
          const SizedBox(height: 24),
          _sectionLabel('ADVANCED'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.route_outlined, size: 18, color: AppColors.textMuted),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('Relay range', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(color: AppColors.teal.withAlpha(15), borderRadius: BorderRadius.circular(8)),
                      child: Text('$_ttl', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.teal)),
                    ),
                  ],
                ),
                Slider(
                  value: _ttl.toDouble(),
                  min: 1, max: 15, divisions: 14,
                  label: '$_ttl',
                  onChanged: (v) => setState(() {
                    _ttl = v.toInt();
                    widget.messageService.setTTL(_ttl);
                  }),
                ),
                Text(
                  'How far your message travels through nearby devices when no internet is available.',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(150)),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted.withAlpha(150), letterSpacing: 1.5),
    ),
  );

  Widget _modeRow(IconData icon, String title, String sub, String value) {
    final sel = _mode == value;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Icon(icon, size: 22, color: sel ? AppColors.teal : AppColors.textMuted),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: sel ? AppColors.teal : null)),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      trailing: _radio(sel),
      onTap: () => setState(() {
        _mode = value;
        widget.messageService.setMode(value);
      }),
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20),
    child: Divider(height: 1, color: AppColors.divider),
  );

  Widget _radio(bool selected) => Container(
    width: 20, height: 20,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: selected ? AppColors.mint : AppColors.textMuted, width: 1.5),
    ),
    child: selected
        ? Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.mint)))
        : null,
  );
}

// ── Network Screen ────────────────────────────────────────────────────────────

class _NetworkScreen extends StatefulWidget {
  final MessageService messageService;
  const _NetworkScreen({required this.messageService});

  @override
  State<_NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<_NetworkScreen> {
  void _addRelay() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Relay'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Relay URL', hintText: 'wss://relay.example.com'),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.startsWith('wss://') || url.startsWith('ws://')) {
                await widget.messageService.nostrService.addRelay(url);
                setState(() {});
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _removeRelay(String url) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Relay'),
        content: Text('Remove $url?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await widget.messageService.nostrService.removeRelay(url);
              setState(() {});
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Remove', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final relayStatuses = widget.messageService.nostrService.relayStatuses;
    final connected = relayStatuses.values.where((v) => v).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Network'),
        actions: [
          TextButton.icon(
            onPressed: _addRelay,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
            style: TextButton.styleFrom(foregroundColor: AppColors.mint),
          ),
        ],
      ),
      body: relayStatuses.isEmpty
          ? const Center(child: Text('No relays configured', style: TextStyle(color: AppColors.textMuted)))
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    '$connected of ${relayStatuses.length} connected',
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
                ...relayStatuses.entries.map((e) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  leading: Container(
                    width: 10, height: 10,
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: e.value ? AppColors.online : AppColors.error,
                    ),
                  ),
                  title: Text(
                    e.key,
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(e.value ? 'Connected' : 'Disconnected',
                    style: TextStyle(fontSize: 11, color: e.value ? AppColors.online : AppColors.error)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.textMuted),
                    onPressed: () => _removeRelay(e.key),
                  ),
                )),
              ],
            ),
    );
  }
}

// ── Appearance Screen ─────────────────────────────────────────────────────────

class _AppearanceScreen extends StatelessWidget {
  const _AppearanceScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListenableBuilder(
        listenable: themeNotifier,
        builder: (_, __) => ListView(
          children: [
            const SizedBox(height: 8),
            _themeRow(context, Icons.dark_mode_outlined, 'Dark', ThemeMode.dark),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Divider(height: 1, color: AppColors.divider)),
            _themeRow(context, Icons.light_mode_outlined, 'Light', ThemeMode.light),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Divider(height: 1, color: AppColors.divider)),
            _themeRow(context, Icons.brightness_auto_outlined, 'System default', ThemeMode.system),
          ],
        ),
      ),
    );
  }

  Widget _themeRow(BuildContext context, IconData icon, String title, ThemeMode value) {
    final sel = themeNotifier.mode == value;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(icon, size: 22, color: sel ? AppColors.teal : AppColors.textMuted),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: sel ? AppColors.teal : null)),
      trailing: sel
          ? Container(
              width: 20, height: 20,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.mint),
              child: const Icon(Icons.check, size: 13, color: Colors.white),
            )
          : Container(
              width: 20, height: 20,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.textMuted, width: 1.5)),
            ),
      onTap: () {
        if (value == ThemeMode.dark) themeNotifier.setDark();
        else if (value == ThemeMode.light) themeNotifier.setLight();
        else themeNotifier.setSystem();
      },
    );
  }
}
