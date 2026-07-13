import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import 'package:bitchat_messenger/firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/theme_notifier.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/nostr_service.dart';
import 'package:bitchat_messenger/features/mesh/services/bitchat_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/core/signaling_service.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/contacts/services/contact_resolver_service.dart';
import 'package:bitchat_messenger/features/contacts/services/contacts_backup_service.dart';
import 'package:bitchat_messenger/features/mesh/services/foreground_service.dart';
import 'package:bitchat_messenger/features/chat/screens/chat_screen.dart';
import 'package:bitchat_messenger/app/home_screen.dart';
import 'package:bitchat_messenger/features/auth/screens/onboarding_screen.dart';

final themeNotifier = ThemeNotifier();

/// Global navigator key — used to navigate from notification taps
/// without requiring a BuildContext.
final navigatorKey = GlobalKey<NavigatorState>();

// Globals set once services are ready — safe to read from notification handlers
MessageService? _globalMessageService;
DatabaseService? _globalDbService;

/// Navigate to a chat screen from a notification tap.
/// Looks up the contact in the DB and opens ChatScreen.
void _openChatFromPubkey(String senderPubkey) async {
  final messageService = _globalMessageService;
  if (messageService == null) return;

  String? contactName;
  final dbService = _globalDbService;
  if (dbService != null) {
    final contacts = await dbService.getAllContacts();
    final match = contacts.where((c) => c.pubkey == senderPubkey).toList();
    if (match.isNotEmpty) contactName = match.first.name;
  }

  navigatorKey.currentState?.push(MaterialPageRoute(
    builder: (_) => ChatScreen(
      contactPubkey: senderPubkey,
      contactName: contactName,
      messageService: messageService,
    ),
  ));
}

/// Handle a notification tap — routes to chat for messages, ignores for calls.
/// (Call signals are delivered over WebSocket; tapping a call notification when
/// the app is backgrounded/killed cannot replay the WebRTC offer.)
void _handleNotificationTap(RemoteMessage message) {
  final type = message.data['type'] as String?;
  if (type == 'call') return; // call offer comes via WebSocket, not tap
  final senderPubkey = message.data['senderPubkey'] as String?;
  if (senderPubkey != null && senderPubkey.isNotEmpty) {
    _openChatFromPubkey(senderPubkey);
  }
}

// Must be top-level — called by FCM when app is in background/terminated
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // Message pushes carry a notification block and are shown by Android itself.
  // Call pushes are data-only (see backend send_push data_only) so we can show
  // a full-screen ringing UI with Answer/Decline — like any real calling app.
  if (message.data['type'] == 'call') {
    final callerName = (message.data['senderName'] as String?)?.trim();
    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: const Uuid().v4(),
      nameCaller: (callerName == null || callerName.isEmpty) ? 'Someone' : callerName,
      appName: 'BitChat',
      handle: 'BitChat call',
      type: 0,
      duration: 45000, // matches server-side PendingCallOffer expiry window
      android: const AndroidParams(
        isCustomNotification: false,
        isShowLogo: false,
        isShowFullLockedScreen: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#2544FF',
        actionColor: '#34C759',
        textAccept: 'Answer',
        textDecline: 'Decline',
        incomingCallNotificationChannelName: 'Incoming Calls',
      ),
    ));
  }
}

// Used for foreground notifications
final _localNotifications = FlutterLocalNotificationsPlugin();
const _androidChannel = AndroidNotificationChannel(
  'bitchat_messages',
  'BitChat Notifications',
  description: 'Messages and incoming calls',
  importance: Importance.high,
  playSound: true,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize Firebase — required for push notifications.
  // If google-services.json is not yet added, this will throw and be caught.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Register background handler (must be before any other Firebase calls)
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    // Request FCM permission (required on Android 13+ and iOS)
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      sound: true,
      badge: true,
    );

    // Set up local notifications for foreground display
    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (details) {
        // Tap on foreground local notification — payload is "type|senderPubkey"
        final payload = details.payload;
        if (payload != null && payload.isNotEmpty) {
          final parts = payload.split('|');
          final notifType = parts.length > 1 ? parts[0] : null;
          final pubkey = parts.length > 1 ? parts[1] : parts[0];
          if (notifType != 'call' && pubkey.isNotEmpty) {
            _openChatFromPubkey(pubkey);
          }
        }
      },
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    // Foreground FCM: only show call notifications — message notifications
    // are suppressed because the WebSocket already delivers them in real-time.
    // Background/killed FCM is shown automatically by Android without this handler.
    FirebaseMessaging.onMessage.listen((message) {
      final notifType = message.data['type'] as String?;
      if (notifType != 'call') return; // messages arrive via WS; skip duplicate pop-up
      final notification = message.notification;
      if (notification == null) return;
      final senderPubkey = message.data['senderPubkey'] as String?;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _androidChannel.id,
            _androidChannel.name,
            channelDescription: _androidChannel.description,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: '${notifType ?? ''}|${senderPubkey ?? ''}',
      );
    });

    // App in background — user taps notification
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // App was terminated — user taps notification that launched the app
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      // Delay until the app's navigator is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleNotificationTap(initialMessage);
      });
    }
  } catch (_) {
    // Firebase not configured — push notifications disabled, app works normally.
  }
  await themeNotifier.load(); // restore saved theme before first frame
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));
  runApp(const BitChatApp());
}

class BitChatApp extends StatefulWidget {
  const BitChatApp({super.key});

  @override
  State<BitChatApp> createState() => _BitChatAppState();
}

class _BitChatAppState extends State<BitChatApp> {
  @override
  void initState() {
    super.initState();
    themeNotifier.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    themeNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BitChat Messenger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeNotifier.mode,
      navigatorKey: navigatorKey,
      home: const AppInitializer(),
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _isLoading = true;
  bool _needsOnboarding = false;
  String _statusText = 'Initializing...';
  double _progress = 0.0;
  DatabaseService? _dbService;
  MessageService? _messageService;
  CallService? _callService;
  BitChatService? _bitchatService;
  ContactResolverService? _contactResolver;
  KeyManager? _pendingKeyManager;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _messageService?.dispose();
    _callService?.dispose();
    _contactResolver?.dispose();
    ServerService().dispose();
    ForegroundServiceHelper.stop();
    super.dispose();
  }

  // Called by iOS when the app returns to foreground after being suspended
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isLoading) {
      // Re-start BLE discovery — iOS kills scanning when app goes to background
      _bitchatService?.restartBle();
    }
  }

  void _updateStatus(String text, double progress) {
    if (mounted) {
      setState(() {
        _statusText = text;
        _progress = progress;
      });
    }
  }

  Future<void> _requestPermissions() async {
    // Only request permissions that aren't already granted — avoids the
    // ~300ms OS round-trip per permission on every launch.
    if (Platform.isAndroid) {
      final needed = <Permission>[
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.location,
        Permission.nearbyWifiDevices,
        Permission.notification,
      ];
      final toRequest = <Permission>[];
      for (final p in needed) {
        if (!await p.isGranted) toRequest.add(p);
      }
      if (toRequest.isNotEmpty) await toRequest.request();
    } else {
      final needed = <Permission>[
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ];
      final toRequest = <Permission>[];
      for (final p in needed) {
        if (!await p.isGranted) toRequest.add(p);
      }
      if (toRequest.isNotEmpty) await toRequest.request();
    }
    // Do not wait for BT/Location services to be enabled — if they're off,
    // BLE/mesh simply won't start. The user can enable them later and the
    // 15-second _checkAndRestart timer will pick it up automatically.
  }

  Future<void> _initialize() async {
    try {
      final keyManager = KeyManager();
      _pendingKeyManager = keyManager;

      // Single secure-storage read — loads keys + username in one pass.
      // Request permissions in parallel since neither depends on the other.
      final results = await Future.wait([
        keyManager.loadExistingKeys(),
        _requestPermissions().then((_) => false), // returns false, ignored
      ]);
      final hasKey = results[0];

      if (!hasKey) {
        // No key on device — show onboarding (Start Fresh / Restore)
        if (mounted) {
          setState(() {
            _isLoading = false;
            _needsOnboarding = true;
          });
        }
        return;
      }

      await _completeInitialization(keyManager);
    } catch (_) {
      _updateStatus('Setup failed. Please restart the app.', 0.0);
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) _initialize();
    }
  }

  // Called after onboarding (Start Fresh or Restore) completes
  Future<void> _onOnboardingComplete(KeyManager keyManager) async {
    if (!mounted) return;
    setState(() {
      _needsOnboarding = false;
      _isLoading = true;
      _statusText = 'Setting up...';
      _progress = 0.5;
    });
    await _completeInitialization(keyManager);
  }

  Future<void> _completeInitialization(KeyManager keyManager) async {
    try {
      _updateStatus('Setting up services...', 0.6);
      final nostrService = NostrService();
      final dbService = DatabaseService();
      _dbService = dbService;
      final bitchatService = BitChatService(dbService: dbService);
      _bitchatService = bitchatService;

      final messageService = MessageService(
        nostrService: nostrService,
        bitchatService: bitchatService,
        dbService: dbService,
        keyManager: keyManager,
      );
      _messageService = messageService;

      // Set up SignalingService — WebSocket call signaling
      final signalingService = SignalingService();

      // Set up CallService — routes WebRTC signals
      final callService = CallService(
        nostrService: nostrService,
        signalingService: signalingService,
      );
      if (keyManager.publicKey != null) {
        callService.setMyPubkey(keyManager.publicKey!);
      }
      callService.setMyName(keyManager.username);
      _callService = callService;

      // Wire SignalingService into MessageService for real-time send + receive
      messageService.setSignalingService(signalingService);

      // Route messaging payloads (dm, receipts, ack) into MessageService
      signalingService.onMessageReceived = (payload) {
        messageService.handleWebSocketPayload(payload);
      };

      // Route call signals arriving from the WebSocket server into CallService
      signalingService.onSignalReceived = (payload) {
        final type = payload['__type'] as String? ?? payload['type'] as String? ?? '';
        final callId = payload['callId'] as String? ?? '';
        switch (type) {
          case 'call_offer':
            callService.handleIncomingOffer(
              callId: callId,
              callerPubkey: payload['senderPubkey'] as String? ?? '',
              callerName: payload['callerName'] as String?,
              sdp: payload['sdp'] as String? ?? '',
              sdpType: payload['sdpType'] as String? ?? 'offer',
              isVideo: payload['isVideo'] as bool? ?? false,
            );
          case 'call_answer':
            callService.handleCallAnswer(
              callId: callId,
              sdp: payload['sdp'] as String? ?? '',
              sdpType: payload['sdpType'] as String? ?? 'answer',
            );
          case 'call_ice':
            callService.handleIceCandidate(
              callId: callId,
              candidate: payload['candidate'] as String? ?? '',
              sdpMid: payload['sdpMid'] as String? ?? '',
              sdpMLineIndex: (payload['sdpMLineIndex'] as int?) ?? 0,
            );
          case 'call_ended':
            callService.handleCallEnded(callId);
          case 'call_declined':
            callService.handleCallDeclined(callId);
          case 'call_busy':
            callService.handleCallBusy(callId);
        }
      };

      // Persist call logs to DB
      callService.onCallLogged = (log) => dbService.insertCallLog(log);

      // ── CallKit (full-screen incoming call UI when app was killed) ───────
      // Answer/Decline on the native ringing screen; the WebRTC offer itself
      // arrives via WS replay once the app connects, so Answer just arms
      // auto-accept for the offer that's about to land.
      FlutterCallkitIncoming.onEvent.listen((event) {
        switch (event) {
          case CallEventActionCallAccept():
            final cur = callService.currentCall;
            if (cur != null &&
                cur.state == CallState.ringing &&
                cur.direction == CallDirection.incoming) {
              // Offer already arrived while the ringing screen was up.
              callService.acceptCall();
            } else {
              // Offer hasn't arrived yet (app cold-starting) — arm auto-accept
              // for when the WS replays it.
              callService.autoAnswerNextOffer = true;
            }
          case CallEventActionCallDecline():
          case CallEventActionCallTimeout():
            callService.autoAnswerNextOffer = false;
          default:
            break;
        }
      });
      // Cold start from an accepted CallKit call (event may have fired
      // before this listener attached) — best effort check.
      try {
        final active = await FlutterCallkitIncoming.activeCalls();
        if (active.any((c) => c.isAccepted)) {
          callService.autoAnswerNextOffer = true;
        }
      } catch (_) {}
      // Dismiss the ringing UI when the call session ends for any reason
      // (caller hung up, timeout, answered elsewhere).
      callService.callStateStream.listen((session) {
        if (session == null) FlutterCallkitIncoming.endAllCalls();
      });

      // Contact resolver — auto-resolves pending contacts via server or BLE
      final contactResolver = ContactResolverService(dbService: dbService);
      contactResolver.onContactResolved = (pubkey) {
        // Trigger immediate retry of any queued messages for the resolved contact
        messageService.retryPendingMessages();
      };
      _contactResolver = contactResolver;

      // Let screens trigger resolution on demand (e.g. right after saving a
      // pending contact) instead of waiting for a restart or connectivity flip.
      messageService.resolvePendingContacts = () => contactResolver.resolveNow(
            hasInternet: messageService.hasInternet,
            nearbyPubkeys: messageService.nearbyUsers,
          );

      // Authenticate with server — fire-and-forget, never blocks startup.
      // connectAndRegister wakes Render first (up to 50 s) then retries auth,
      // so .then() may fire well after the HomeScreen is already visible.
      if (keyManager.hasKeys) {
        ServerService().connectAndRegister(
          privateKey: keyManager.privateKey!,
          publicKey: keyManager.publicKey!,
          shortId: Contact.shortIdFor(keyManager.publicKey!),
          displayName: keyManager.username ?? '',
          onAuthenticated: () {
            // JWT is ready — connect WebSocket immediately.
            // FCM token + short-ID registration continue in parallel.
            signalingService.connect();
          },
        ).then((_) async {
          // Full registration done — catch up on missed messages.
          await messageService.fetchMissedServerMessages();
          messageService.retryPendingMessages();

          // Server is awake and authenticated — pending contacts saved while
          // it was cold-starting can resolve now.
          contactResolver.resolveNow(
            hasInternet: messageService.hasInternet,
            nearbyPubkeys: messageService.nearbyUsers,
          );

          // Restore contacts on first launch (needs auth to decrypt backup)
          final existing = await dbService.getAllContacts();
          if (existing.isEmpty) {
            ContactsBackupService().restore(
              dbService: dbService,
              privateKey: keyManager.privateKey!,
              publicKey: keyManager.publicKey!,
            );
          }
        });
      }

      // initialize() now returns quickly — BLE starts in background
      await messageService.initialize();

      // Expose to notification tap handler before showing HomeScreen
      _globalMessageService = messageService;
      _globalDbService = dbService;

      // Show HomeScreen immediately — user sees the app right away
      if (mounted) setState(() => _isLoading = false);

      // Run remaining startup tasks in background after UI is visible
      contactResolver.start(
        hasInternet: messageService.hasInternet,
        nearbyPubkeys: messageService.nearbyUsers,
        internetStream: messageService.internetStream,
        nearbyStream: messageService.nearbyChangedStream,
      );

      // Foreground service keeps BLE alive when screen locks — not urgent
      ForegroundServiceHelper.start();
    } catch (_) {
      _updateStatus('Setup failed. Please restart the app.', 0.0);
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) _initialize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_needsOnboarding && _pendingKeyManager != null) {
      return OnboardingScreen(
        keyManager: _pendingKeyManager!,
        onComplete: _onOnboardingComplete,
      );
    }

    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated mesh icon
              AnimatedBuilder(
                animation: _pulseController,
                builder: (_, __) {
                  final v = _pulseController.value;
                  return Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primary.withAlpha((40 + v * 30).toInt()),
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary.withAlpha((8 + v * 12).toInt()),
                        ),
                        child: Icon(
                          Icons.hub,
                          size: 30,
                          color: AppColors.primary.withAlpha((160 + v * 95).toInt()),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 80),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: AppColors.divider,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                    minHeight: 2,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _statusText,
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return HomeScreen(
      dbService: _dbService!,
      messageService: _messageService!,
      callService: _callService!,
    );
  }
}
