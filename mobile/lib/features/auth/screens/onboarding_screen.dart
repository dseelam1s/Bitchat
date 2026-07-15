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
  bool _introDone = false;
  bool _showRestore = false;
  bool _showNamePrompt = false;

  void _onKeysGenerated() {
    setState(() => _showNamePrompt = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: child,
          ),
          child: _showRestore
              ? _RestoreView(
                  key: const ValueKey('restore'),
                  keyManager: widget.keyManager,
                  onComplete: widget.onComplete,
                  onBack: () => setState(() => _showRestore = false),
                )
              : _showNamePrompt
                  ? _NamePromptView(
                      key: const ValueKey('name'),
                      keyManager: widget.keyManager,
                      onComplete: widget.onComplete,
                    )
                  : !_introDone
                      ? _IntroSlides(
                          key: const ValueKey('intro'),
                          onDone: () => setState(() => _introDone = true),
                        )
                      : _WelcomeView(
                          key: const ValueKey('welcome'),
                          keyManager: widget.keyManager,
                          onKeysGenerated: _onKeysGenerated,
                          onRestoreTapped: () => setState(() => _showRestore = true),
                        ),
        ),
      ),
    );
  }
}

// ── Intro slides ──────────────────────────────────────────────────────────────

class _Slide {
  final IconData icon;
  final String title;
  final String subtitle;

  const _Slide({required this.icon, required this.title, required this.subtitle});
}

const _slides = [
  _Slide(
    icon: Icons.sensors,
    title: 'Chat nearby\nwithout internet',
    subtitle:
        'Connect with people around you using Bluetooth.\nNo data plan, no Wi-Fi — it just works.',
  ),
  _Slide(
    icon: Icons.lock_outline,
    title: 'Private\nby design',
    subtitle:
        'Your messages are end-to-end encrypted.\nWe cannot read them — and neither can anyone else.',
  ),
  _Slide(
    icon: Icons.public,
    title: 'Works\neverywhere',
    subtitle:
        'Online or offline, in a city or a remote area —\nyour messages find a way through.',
  ),
];

class _IntroSlides extends StatefulWidget {
  final VoidCallback onDone;

  const _IntroSlides({super.key, required this.onDone});

  @override
  State<_IntroSlides> createState() => _IntroSlidesState();
}

class _IntroSlidesState extends State<_IntroSlides> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _slides.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _slides.length - 1;

    return Column(
      children: [
        // Skip link
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onDone,
            child: Text(
              'Skip',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textMuted.withAlpha(180),
              ),
            ),
          ),
        ),

        // Slides
        Expanded(
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            itemCount: _slides.length,
            itemBuilder: (_, i) => _SlidePage(slide: _slides[i]),
          ),
        ),

        // Dot indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_slides.length, (i) {
            final active = i == _page;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: active ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: active
                    ? AppColors.primary
                    : AppColors.primary.withAlpha(50),
              ),
            );
          }),
        ),
        const SizedBox(height: 32),

        // Next / Get Started button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _next,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                isLast ? 'Get Started' : 'Next',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

class _SlidePage extends StatelessWidget {
  final _Slide slide;

  const _SlidePage({required this.slide});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon container
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withAlpha(18),
              border:
                  Border.all(color: AppColors.primary.withAlpha(50), width: 1.5),
            ),
            child: Icon(slide.icon, size: 44, color: AppColors.primary),
          ),
          const SizedBox(height: 40),

          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),

          Text(
            slide.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Welcome view ─────────────────────────────────────────────────────────────

class _WelcomeView extends StatefulWidget {
  final KeyManager keyManager;
  final VoidCallback onKeysGenerated;
  final VoidCallback onRestoreTapped;

  const _WelcomeView({
    super.key,
    required this.keyManager,
    required this.onKeysGenerated,
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
    widget.onKeysGenerated();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
              border: Border.all(color: AppColors.primary.withAlpha(60), width: 1.5),
              color: AppColors.primary.withAlpha(12),
            ),
            child: const Icon(Icons.hub, size: 40, color: AppColors.primary),
          ),
          const SizedBox(height: 28),

          const Text(
            'Reach',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'No phone number. No email.\nJust you.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
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
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Create New Identity',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Fresh start · get a new short ID',
            style: TextStyle(
                fontSize: 11, color: AppColors.textMuted.withAlpha(120)),
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
            'Used Reach before? Restore with short ID + password',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, color: AppColors.textMuted.withAlpha(120)),
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
    super.key,
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

    setState(() {
      _loading = true;
      _error = null;
    });

    final blob = await ServerService().restoreEncryptedKey(shortId);
    if (blob == null) {
      setState(() {
        _loading = false;
        _error = 'No backup found for #$shortId. Check your short ID.';
      });
      return;
    }

    final privateKey = await BackupService().decrypt(blob, password);
    if (privateKey == null) {
      setState(() {
        _loading = false;
        _error = 'Wrong password. Try again.';
      });
      return;
    }

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

    await widget.keyManager.loadKeys(privateKey, publicKey);
    await widget.onComplete(widget.keyManager);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          GestureDetector(
            onTap: _loading ? null : widget.onBack,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_ios,
                    size: 14, color: AppColors.textMuted.withAlpha(180)),
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
                color: AppColors.textSecondary,
                height: 1.5),
          ),

          const SizedBox(height: 32),

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
                style: const TextStyle(fontSize: 12, color: AppColors.error)),
          ],

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _restore,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Restore',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),

          const Spacer(flex: 2),

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

// ── Name prompt view ──────────────────────────────────────────────────────────

class _NamePromptView extends StatefulWidget {
  final KeyManager keyManager;
  final Future<void> Function(KeyManager) onComplete;

  const _NamePromptView({
    super.key,
    required this.keyManager,
    required this.onComplete,
  });

  @override
  State<_NamePromptView> createState() => _NamePromptViewState();
}

class _NamePromptViewState extends State<_NamePromptView> {
  final _nameController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a name to continue.');
      return;
    }
    if (name.length < 2) {
      setState(() => _error = 'Name must be at least 2 characters.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    await widget.keyManager.setUsername(name);
    await widget.onComplete(widget.keyManager);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),

          const Text(
            'What should people\ncall you?',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'This is how you appear to others. You can change it later in your profile.',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 36),

          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            maxLength: 32,
            onSubmitted: (_) => _loading ? null : _continue(),
            decoration: const InputDecoration(
              labelText: 'Your name',
              hintText: 'e.g. Alex',
              counterText: '',
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(fontSize: 12, color: AppColors.error)),
          ],

          const Spacer(flex: 2),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _continue,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Continue',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }
}

extension on String {
  bool isDigit() => RegExp(r'^\d+$').hasMatch(this);
}
