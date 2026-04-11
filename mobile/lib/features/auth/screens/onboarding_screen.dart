import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/profile/services/backup_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

class OnboardingScreen extends StatefulWidget {
  final KeyManager keyManager;
  final Future<void> Function(KeyManager) onComplete;

  const OnboardingScreen({
    super.key,
    required this.keyManager,
    required this.onComplete,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _showRestore = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _showRestore
              ? _RestoreView(
                  keyManager: widget.keyManager,
                  onComplete: widget.onComplete,
                  onBack: () => setState(() => _showRestore = false),
                )
              : _WelcomeView(
                  keyManager: widget.keyManager,
                  onComplete: widget.onComplete,
                  onRestoreTapped: () => setState(() => _showRestore = true),
                ),
        ),
      ),
    );
  }
}

// ── Welcome view ─────────────────────────────────────────────────────────────

class _WelcomeView extends StatefulWidget {
  final KeyManager keyManager;
  final Future<void> Function(KeyManager) onComplete;
  final VoidCallback onRestoreTapped;

  const _WelcomeView({
    required this.keyManager,
    required this.onComplete,
    required this.onRestoreTapped,
  });

  @override
  State<_WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<_WelcomeView> {
  bool _loading = false;

  Future<void> _startFresh() async {
    setState(() => _loading = true);
    await widget.keyManager.generateKeyPair();
    await widget.onComplete(widget.keyManager);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('welcome'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 2),

          // Icon
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.mint.withAlpha(60), width: 1.5),
              color: AppColors.mint.withAlpha(10),
            ),
            child: const Icon(Icons.hub, size: 40, color: AppColors.mint),
          ),
          const SizedBox(height: 28),

          // Title
          const Text(
            'BitChat',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Decentralized messaging.\nNo phone number. No email.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textMuted.withAlpha(180),
              height: 1.5,
            ),
          ),

          const Spacer(flex: 2),

          // Start Fresh
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _startFresh,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.mint,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Start Fresh',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'New identity · new short ID',
            style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(120)),
          ),

          const SizedBox(height: 20),

          // Restore
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _loading ? null : widget.onRestoreTapped,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.divider.withAlpha(150)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('Restore Backup',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Had BitChat before? Restore with short ID + password',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(120)),
          ),

          const Spacer(flex: 1),
        ],
      ),
    );
  }
}

// ── Restore view ─────────────────────────────────────────────────────────────

class _RestoreView extends StatefulWidget {
  final KeyManager keyManager;
  final Future<void> Function(KeyManager) onComplete;
  final VoidCallback onBack;

  const _RestoreView({
    required this.keyManager,
    required this.onComplete,
    required this.onBack,
  });

  @override
  State<_RestoreView> createState() => _RestoreViewState();
}

class _RestoreViewState extends State<_RestoreView> {
  final _shortIdController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _shortIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final shortId = _shortIdController.text.trim().replaceAll('#', '');
    final password = _passwordController.text;

    if (shortId.length != 8 || !shortId.isDigit()) {
      setState(() => _error = 'Enter a valid 8-digit short ID.');
      return;
    }
    if (password.length < 4) {
      setState(() => _error = 'Password must be at least 4 characters.');
      return;
    }

    setState(() { _loading = true; _error = null; });

    // 1. Fetch encrypted blob from server
    final blob = await ServerService().restoreEncryptedKey(shortId);
    if (blob == null) {
      setState(() {
        _loading = false;
        _error = 'No backup found for #$shortId. Check your short ID.';
      });
      return;
    }

    // 2. Decrypt on-device with backup password
    final privateKey = await BackupService().decrypt(blob, password);
    if (privateKey == null) {
      setState(() {
        _loading = false;
        _error = 'Wrong password. Try again.';
      });
      return;
    }

    // 3. Verify: derive public key → check short ID matches
    final keyApi = widget.keyManager.keyApi;
    if (!keyApi.isValidPrivateKey(privateKey)) {
      setState(() {
        _loading = false;
        _error = 'Restored key is invalid. Try again.';
      });
      return;
    }
    final publicKey = keyApi.getPublicKey(privateKey);
    final derivedShortId = Contact.shortIdFor(publicKey);

    if (derivedShortId != shortId) {
      setState(() {
        _loading = false;
        _error = 'Short ID does not match the restored key. Wrong password?';
      });
      return;
    }

    // 4. Save restored key and continue
    await widget.keyManager.loadKeys(privateKey, publicKey);
    await widget.onComplete(widget.keyManager);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('restore'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          // Back
          GestureDetector(
            onTap: _loading ? null : widget.onBack,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_ios, size: 14,
                    color: AppColors.textMuted.withAlpha(180)),
                const SizedBox(width: 4),
                Text('Back',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted.withAlpha(180))),
              ],
            ),
          ),

          const Spacer(flex: 1),

          const Text(
            'Restore Backup',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your short ID and backup password to restore your identity.',
            style: TextStyle(
                fontSize: 13,
                color: AppColors.textMuted.withAlpha(180),
                height: 1.5),
          ),

          const SizedBox(height: 32),

          // Short ID
          TextField(
            controller: _shortIdController,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: const InputDecoration(
              labelText: 'Short ID',
              hintText: '72913456',
              prefixText: '#',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),

          // Password
          TextField(
            controller: _passwordController,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Backup password',
              suffixIcon: IconButton(
                icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.error)),
          ],

          const SizedBox(height: 28),

          // Restore button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _restore,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.mint,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black))
                  : const Text('Restore',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),

          const Spacer(flex: 2),

          // Start fresh fallback
          Center(
            child: GestureDetector(
              onTap: _loading ? null : widget.onBack,
              child: Text(
                "Don't have a backup? Start Fresh instead",
                style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted.withAlpha(150),
                    decoration: TextDecoration.underline),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

extension on String {
  bool isDigit() => RegExp(r'^\d+$').hasMatch(this);
}
