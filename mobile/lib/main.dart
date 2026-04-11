import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
import 'package:bitchat_messenger/features/channels/services/channel_service.dart';
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

// Must be top-level — called by FCM when app is in background/terminated
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // No work needed — FCM notification messages are shown automatically by Android
  // when the app is not in foreground. This handler just keeps the process alive.
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
        // Tap on foreground local notification
        final payload = details.payload;
        if (payload != null && payload.isNotEmpty) {
          _openChatFromPubkey(payload);
        }
      },
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    // Show notification when FCM arrives in foreground
    FirebaseMessaging.onMessage.listen((message) {
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
        payload: senderPubkey, // passed to onDidReceiveNotificationResponse
      );
    });

    // App in background — user taps notification
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final senderPubkey = message.data['senderPubkey'] as String?;
      if (senderPubkey != null && senderPubkey.isNotEmpty) {
        _openChatFromPubkey(senderPubkey);
      }
    });

    // App was terminated — user taps notification that launched the app
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final senderPubkey = initialMessage.data['senderPubkey'] as String?;
      if (senderPubkey != null && senderPubkey.isNotEmpty) {
        // Delay until the app's navigator is ready
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openChatFromPubkey(senderPubkey);
        });
      }
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
  ChannelService? _channelService;
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
    _channelService?.dispose();
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
    _updateStatus('Requesting permissions...', 0.1);

    if (Platform.isAndroid) {
      // Android needs location for BLE scanning + nearbyWifi for mesh
      await [
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.location,
        Permission.nearbyWifiDevices,
        Permission.notification, // Android 13+ requires explicit permission
      ].request();

      // Android BLE scanning requires location service enabled
      final locationEnabled = await Permission.location.serviceStatus.isEnabled;
      if (!locationEnabled) {
        _updateStatus('Please enable Location to allow nearby device discovery...', 0.15);
        bool enabled = false;
        for (int i = 0; i < 30; i++) {
          await Future.delayed(const Duration(seconds: 1));
          if (await Permission.location.serviceStatus.isEnabled) { enabled = true; break; }
        }
        if (!enabled) _updateStatus('Continuing without Location — nearby features limited.', 0.15);
      }
    } else {
      // iOS: BLE does not require location permission
      await [
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();
    }

    // Wait for Bluetooth to be enabled on all platforms
    final bluetoothEnabled = await Permission.bluetooth.serviceStatus.isEnabled;
    if (!bluetoothEnabled) {
      _updateStatus('Please enable Bluetooth to communicate with nearby devices...', 0.2);
      bool enabled = false;
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (await Permission.bluetooth.serviceStatus.isEnabled) { enabled = true; break; }
      }
      if (!enabled) _updateStatus('Continuing without Bluetooth — offline messaging unavailable.', 0.2);
    }
  }

  Future<void> _initialize() async {
    try {
      await _requestPermissions();

      final keyManager = KeyManager();
      _pendingKeyManager = keyManager;

      final hasKey = await keyManager.hasStoredKey();
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

      // Key exists — load and proceed normally
      _updateStatus('Loading keys...', 0.4);
      await keyManager.generateKeyPair();
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

      final channelService = ChannelService(
        dbService: dbService,
        bitChatService: bitchatService,
        nostrService: nostrService,
      );
      _channelService = channelService;

      // Route group invite/removal DMs from MessageService → ChannelService
      messageService.onGroupInvite = (channelId, channelName, adminPubkey) {
        channelService.receiveGroupInvite(channelId, channelName, adminPubkey);
      };
      messageService.onGroupRemoval = (channelId) {
        channelService.leavePrivateGroup(channelId);
      };
      messageService.onUsernameChanged = (username) {
        channelService.setUsername(username);
      };

      // Set up SignalingService — WebSocket call signaling (Nostr is fallback)
      final signalingService = SignalingService();

      // Set up CallService — routes WebRTC signals
      final callService = CallService(
        nostrService: nostrService,
        signalingService: signalingService,
      );
      if (keyManager.publicKey != null) {
        callService.setMyPubkey(keyManager.publicKey!);
      }
      _callService = callService;

      // Wire SignalingService into MessageService for real-time send + receive
      messageService.setSignalingService(signalingService);

      // Route messaging payloads (dm, reaction, receipts, ack) into MessageService
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

      // Route signals arriving via Nostr (fallback) into CallService
      messageService.onCallOffer = (callId, callerPubkey, callerName, sdp, sdpType, isVideo) {
        callService.handleIncomingOffer(
          callId: callId,
          callerPubkey: callerPubkey,
          callerName: callerName,
          sdp: sdp,
          sdpType: sdpType,
          isVideo: isVideo,
        );
      };
      messageService.onCallAnswer = (callId, sdp, sdpType) {
        callService.handleCallAnswer(callId: callId, sdp: sdp, sdpType: sdpType);
      };
      messageService.onCallIce = (callId, candidate, sdpMid, sdpMLineIndex) {
        callService.handleIceCandidate(
          callId: callId,
          candidate: candidate,
          sdpMid: sdpMid,
          sdpMLineIndex: sdpMLineIndex,
        );
      };
      messageService.onCallEnded = callService.handleCallEnded;
      messageService.onCallDeclined = callService.handleCallDeclined;
      messageService.onCallBusy = callService.handleCallBusy;

      // Persist call logs to DB
      callService.onCallLogged = (log) => dbService.insertCallLog(log);

      // Contact resolver — auto-resolves pending contacts via server or BLE
      final contactResolver = ContactResolverService(dbService: dbService);
      contactResolver.onContactResolved = (pubkey) {
        // Trigger immediate retry of any queued messages for the resolved contact
        messageService.retryPendingMessages();
      };
      _contactResolver = contactResolver;

      _updateStatus('Connecting...', 0.7);

      // Authenticate with server first so JWT tokens are ready before
      // messageService.initialize() tries to send/fetch via server.
      // Fire-and-forget — if server unreachable, app works offline normally.
      if (keyManager.hasKeys) {
        ServerService().connectAndRegister(
          privateKey: keyManager.privateKey!,
          publicKey: keyManager.publicKey!,
          shortId: Contact.shortIdFor(keyManager.publicKey!),
          displayName: keyManager.username ?? '',
        ).then((_) async {
          // Connect WebSocket signaling once JWT tokens are ready.
          // SignalingService fetches the token itself and self-heals on expiry.
          signalingService.connect();

          // Restore contact list from server if local DB is empty (reinstall).
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

      _updateStatus('Connecting...', 0.8);
      await messageService.initialize();

      // Start contact resolver — runs in background, never blocks startup
      contactResolver.start(
        hasInternet: messageService.hasInternet,
        nearbyPubkeys: messageService.nearbyUsers,
        internetStream: messageService.internetStream,
        nearbyStream: messageService.nearbyChangedStream,
      );

      if (keyManager.publicKey != null) {
        await channelService.start(
          keyManager.publicKey!,
          username: keyManager.username,
        );
      }

      _updateStatus('Ready', 1.0);
      await Future.delayed(const Duration(milliseconds: 300));

      // Start foreground service so BLE mesh stays alive when screen locks
      await ForegroundServiceHelper.start();

      // Expose to notification tap handler
      _globalMessageService = messageService;
      _globalDbService = dbService;

      if (mounted) setState(() => _isLoading = false);
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
                        color: AppColors.mint.withAlpha((40 + v * 30).toInt()),
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.mint.withAlpha((8 + v * 12).toInt()),
                        ),
                        child: Icon(
                          Icons.hub,
                          size: 30,
                          color: AppColors.mint.withAlpha((160 + v * 95).toInt()),
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
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.mint),
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
      channelService: _channelService!,
      callService: _callService!,
    );
  }
}
