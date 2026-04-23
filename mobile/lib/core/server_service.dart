import 'dart:convert';
import 'dart:io';
import 'package:mime/mime.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:nostr_tools/nostr_tools.dart';

import 'package:bitchat_messenger/core/constants.dart';

/// Handles all communication with the BitChat comfort-layer server.
///
/// All methods silently swallow errors — if the server is unreachable the
/// app keeps working through BLE mesh exactly as before.
class ServerService {
  static final ServerService _instance = ServerService._internal();
  factory ServerService() => _instance;
  ServerService._internal();

  final _secureStorage = const FlutterSecureStorage();
  final _eventApi = EventApi();
  final _client = http.Client();

  String? _accessToken;
  String? _refreshToken;


  // ── Token access ─────────────────────────────────────────────────────────

  /// Returns the current JWT access token, or null if not authenticated.
  /// Used by SignalingService to connect the WebSocket.
  Future<String?> getAccessToken() async {
    if (_accessToken == null) await _loadTokens();
    return _accessToken;
  }

  // ── Token persistence ────────────────────────────────────────────────────

  Future<void> _loadTokens() async {
    _accessToken = await _secureStorage.read(key: 'server_access_token');
    _refreshToken = await _secureStorage.read(key: 'server_refresh_token');
  }

  Future<void> _saveTokens(String access, String refresh) async {
    _accessToken = access;
    _refreshToken = refresh;
    await _secureStorage.write(key: 'server_access_token', value: access);
    await _secureStorage.write(key: 'server_refresh_token', value: refresh);
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    await _secureStorage.delete(key: 'server_access_token');
    await _secureStorage.delete(key: 'server_refresh_token');
  }

  // ── HTTP helpers ─────────────────────────────────────────────────────────

  Uri _uri(String path) =>
      Uri.parse('${AppConstants.serverBaseUrl}/api/v1/bitchat/$path');

  Map<String, String> _authHeaders({bool includeAuth = true}) => {
        'Content-Type': 'application/json',
        if (includeAuth && _accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  /// POST with JSON body; returns decoded body or null on any error.
  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = false,
  }) async {
    try {
      if (authenticated) await _loadTokens();
      final res = await _client
          .post(_uri(path),
              headers: _authHeaders(includeAuth: authenticated), body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      // 401 → try refresh once, then give up
      if (res.statusCode == 401 && authenticated && _refreshToken != null) {
        final refreshed = await _refreshAccessToken();
        if (refreshed) {
          final retry = await _client
              .post(_uri(path),
                  headers: _authHeaders(includeAuth: authenticated), body: jsonEncode(body))
              .timeout(const Duration(seconds: 10));
          if (retry.statusCode >= 200 && retry.statusCode < 300) {
            return jsonDecode(retry.body) as Map<String, dynamic>;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET with optional query params; returns decoded body or null on any error.
  Future<Map<String, dynamic>?> _get(
    String path, {
    Map<String, String>? queryParams,
    bool authenticated = false,
  }) async {
    try {
      if (authenticated) await _loadTokens();
      final uri = _uri(path).replace(queryParameters: queryParams);
      final res = await _client
          .get(uri, headers: _authHeaders(includeAuth: authenticated))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _refreshAccessToken() async {
    try {
      final res = await _client
          .post(
            Uri.parse('${AppConstants.serverBaseUrl}/api/v1/token/refresh/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh': _refreshToken}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _accessToken = data['access'] as String;
        await _secureStorage.write(
            key: 'server_access_token', value: _accessToken);
        return true;
      }
    } catch (e) {
      // Network error or timeout — do not clear tokens, allow retry on next request
      return false;
    }
    // Server rejected the refresh token (e.g. 401/400) — tokens are invalid; clear them
    await _clearTokens();
    return false;
  }

  // ── Auth ─────────────────────────────────────────────────────────────────

  /// Sign in with the user's keypair.
  ///
  /// Returns `{'access': ..., 'refresh': ..., 'is_registered': bool}` or null.
  Future<Map<String, dynamic>?> authenticate(
      String privateKey, String publicKey) async {
    // 1. Fetch challenge
    final challengeData = await _get('challenge/');
    if (challengeData == null) return null;
    final challenge = challengeData['challenge'] as String?;
    if (challenge == null) return null;

    // 2. Build kind:27235 auth event signed with the user's private key
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final event = Event(
      kind: 27235,
      tags: [
        ['challenge', challenge]
      ],
      content: '',
      created_at: now,
      pubkey: publicKey,
    );
    final signed = _eventApi.finishEvent(event, privateKey);

    // 3. Send to /auth/
    final authData = await _post('auth/', {
      'id': signed.id,
      'pubkey': signed.pubkey,
      'created_at': signed.created_at,
      'kind': signed.kind,
      'tags': signed.tags,
      'content': signed.content,
      'sig': signed.sig,
    });
    if (authData == null) return null;

    final access = authData['access'] as String?;
    final refresh = authData['refresh'] as String?;
    if (access != null && refresh != null) {
      await _saveTokens(access, refresh);
    }
    return authData;
  }

  // ── Registration ─────────────────────────────────────────────────────────

  /// Register a short ID on the server.
  ///
  /// Returns `{'short_id': ..., 'recovery_code': ..., 'already_registered': bool}` or null.
  Future<Map<String, dynamic>?> registerShortId(
      String shortId, String displayName) async {
    return _post(
      'register/',
      {'short_id': shortId, 'display_name': displayName},
      authenticated: true,
    );
  }

  // ── Lookup ───────────────────────────────────────────────────────────────

  /// Look up a pubkey by 8-digit short ID.
  ///
  /// Returns `{'pubkey': ..., 'short_id': ..., 'display_name': ..., 'profile_picture_url': ...}` or null.
  Future<Map<String, dynamic>?> lookupByShortId(String shortId) async {
    return _get('lookup/', queryParams: {'short_id': shortId});
  }

  // ── Backup / Restore ─────────────────────────────────────────────────────

  /// Upload the client-side encrypted key backup blob.
  ///
  /// The blob must be encrypted by the user's backup password *before* calling
  /// this method — the server stores ciphertext only.
  Future<bool> backupEncryptedKey(String encryptedBlob) async {
    final result = await _post(
      'backup/',
      {'encrypted_backup': encryptedBlob},
      authenticated: true,
    );
    return result != null;
  }

  /// Retrieve the encrypted backup blob by short_id.
  ///
  /// The blob is decrypted on-device using the user's backup password.
  /// Returns ciphertext or null if not found / rate-limited.
  Future<String?> restoreEncryptedKey(String shortId) async {
    final result = await _post('restore/', {'short_id': shortId});
    return result?['encrypted_backup'] as String?;
  }

  // ── Push Tokens ──────────────────────────────────────────────────────────

  /// Register or update an FCM (Android) push token.
  Future<bool> registerFcmToken(String token) async {
    final result = await _post(
      'push-token/',
      {'platform': 'fcm', 'token': token},
      authenticated: true,
    );
    return result != null;
  }

  /// Register or update an APNs (iOS) push token.
  Future<bool> registerApnsToken(String token) async {
    final result = await _post(
      'push-token/',
      {'platform': 'apns', 'token': token},
      authenticated: true,
    );
    return result != null;
  }

  // ── Profile ──────────────────────────────────────────────────────────────

  /// Fetch public profile for any pubkey — no auth required.
  Future<Map<String, dynamic>?> getProfile(String pubkey) async {
    return _get('profile/$pubkey/');
  }

  /// Check if the server is reachable. Returns true if any response received.
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(_uri('health/'))
          .timeout(const Duration(seconds: 5));
      // 200 = healthy; 404 = old backend without health endpoint but server is up
      return res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Wake the server from a cold start before attempting auth.
  ///
  /// Render free tier sleeps after 15 minutes of inactivity and takes
  /// 30–45 seconds to spin back up. This uses a long timeout to cover
  /// that window so auth never races against a sleeping server.
  ///
  /// Returns true once the server responds, false if unreachable.
  Future<bool> wakeup() async {
    try {
      final res = await _client
          .get(_uri('health/'))
          .timeout(const Duration(seconds: 50));
      return res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Upload a profile picture file.
  ///
  /// Returns the public URL on success, or throws a [ServerUploadException]
  /// with a human-readable reason on failure.
  Future<String> uploadProfilePicture(File imageFile) async {
    final reachable = await ping();
    if (!reachable) throw ServerUploadException('Server unreachable — check your connection');

    await _loadTokens();
    if (_accessToken == null) throw ServerUploadException('Not signed in to server');

    try {
      // Detect MIME type from file extension — explicit is safer than relying on platform inference
      final mimeType = lookupMimeType(imageFile.path) ?? 'image/jpeg';
      final mimeTypeParts = mimeType.split('/');

      Future<http.Response> doUpload() async {
        final uri = _uri('profile/upload-picture/');
        final request = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $_accessToken'
          ..files.add(await http.MultipartFile.fromPath(
            'image',
            imageFile.path,
            contentType: MediaType(mimeTypeParts[0], mimeTypeParts[1]),
          ));
        final streamed = await request.send().timeout(const Duration(seconds: 30));
        return http.Response.fromStream(streamed);
      }

      var response = await doUpload();

      // If 401, try refreshing the token once and retry
      if (response.statusCode == 401 && _refreshToken != null) {
        final refreshed = await _refreshAccessToken();
        if (refreshed) {
          response = await doUpload();
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final url = data['url'] as String?;
        if (url == null || url.isEmpty) throw ServerUploadException('Server returned no URL');
        return url;
      }
      if (response.statusCode == 401) throw ServerUploadException('Session expired — sign out and back in to re-authenticate');
      if (response.statusCode == 413) throw ServerUploadException('Image too large — please choose a smaller photo');
      if (response.statusCode == 400) {
        // Parse server error message if available
        try {
          final body = jsonDecode(response.body) as Map?;
          final detail = body?['detail'] as String?;
          if (detail != null) throw ServerUploadException(detail);
        } catch (e) {
          if (e is ServerUploadException) rethrow;
        }
      }
      throw ServerUploadException('Upload failed — please try again');
    } on ServerUploadException {
      rethrow;
    } catch (e) {
      if (e is ServerUploadException) rethrow;
      throw ServerUploadException('Upload failed — please try again');
    }
  }

  /// Update display name and/or profile picture URL for the authenticated user.
  ///
  /// [profilePictureUrl] should be a URL already uploaded to cloud storage by the client.
  Future<bool> updateProfile({
    String? displayName,
    String? profilePictureUrl,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (profilePictureUrl != null) body['profile_picture_url'] = profilePictureUrl;
    if (body.isEmpty) return true;
    final result = await _post('profile/', body, authenticated: true);
    return result != null;
  }

  // ── Contacts Backup ──────────────────────────────────────────────────────

  /// Upload encrypted contact list. Client encrypts before calling.
  Future<bool> saveContactsBackup(String encryptedBlob) async {
    final result = await _post(
      'contacts/backup/',
      {'contacts_backup': encryptedBlob},
      authenticated: true,
    );
    return result != null;
  }

  /// Fetch encrypted contact list backup. Decrypted on-device.
  Future<String?> fetchContactsBackup() async {
    final result = await _get('contacts/backup/fetch/', authenticated: true);
    return result?['contacts_backup'] as String?;
  }

  // ── Session ──────────────────────────────────────────────────────────────

  bool get isAuthenticated => _accessToken != null;

  Future<void> signOut() async => _clearTokens();

  void dispose() => _client.close();

  // ── Startup flow ─────────────────────────────────────────────────────────

  /// Called once at app startup. Authenticates with the server and registers
  /// the short ID if not already done. Completely fire-and-forget — if the
  /// server is unreachable nothing happens and the app works as normal.
  ///
  /// Handles Render free-tier cold starts by waking the server first (up to
  /// 50 s) then retrying auth up to 3 times before giving up.
  Future<void> connectAndRegister({
    required String privateKey,
    required String publicKey,
    required String shortId,
    required String displayName,
    void Function()? onAuthenticated,
  }) async {
    try {
      // ── Step 1: Wake the server ───────────────────────────────────────────
      final isUp = await wakeup();
      if (!isUp) return;

      // ── Step 2: Authenticate with retry ──────────────────────────────────
      Map<String, dynamic>? authResult;
      for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) await Future.delayed(const Duration(seconds: 5));
        authResult = await authenticate(privateKey, publicKey);
        if (authResult != null) break;
      }
      if (authResult == null) return;

      // ── Auth done — notify caller immediately so WebSocket can connect ────
      // FCM registration and short-ID registration happen in parallel after this.
      onAuthenticated?.call();

      // ── Steps 3 & 4 in parallel ──────────────────────────────────────────
      await Future.wait([
        () async {
          try {
            final fcmToken = await FirebaseMessaging.instance.getToken();
            if (fcmToken != null) await registerFcmToken(fcmToken);
            FirebaseMessaging.instance.onTokenRefresh.listen(registerFcmToken);
          } catch (_) {}
        }(),
        registerShortId(shortId, displayName),
      ]);
    } catch (_) {
      // Server errors must never surface to the user
    }
  }

  /// Send a push notification to a recipient via the server.
  /// Fire-and-forget — if server is down nothing happens.
  Future<void> notifyRecipient(String recipientPubkey, String senderName) async {
    await _post('notify/', {
      'recipient_pubkey': recipientPubkey,
      'sender_name': senderName,
      'notification_type': 'message',
    }, authenticated: true);
  }

  /// Send an incoming call push notification to a recipient.
  /// Fire-and-forget — if server is down the call still works when app is open.
  Future<void> notifyCall({
    required String recipientPubkey,
    String? callerName,
  }) async {
    await _post('notify/', {
      'recipient_pubkey': recipientPubkey,
      'sender_name': callerName ?? 'Someone',
      'notification_type': 'call',
    }, authenticated: true);
  }

  // ── Online Messaging (WhatsApp-style) ───────────────────────────────────

  /// Send a message via server. Used when internet is available.
  /// Returns true on success.
  Future<bool> sendOnlineMessage({
    required String messageId,
    required String receiverPubkey,
    required String encryptedContent,
    required int timestamp,
    String messageType = 'dm',
    String senderName = '',
  }) async {
    final result = await _post('messages/send/', {
      'message_id':        messageId,
      'receiver_pubkey':   receiverPubkey,
      'encrypted_content': encryptedContent,
      'timestamp':         timestamp,
      'message_type':      messageType,
      'sender_name':       senderName,
    }, authenticated: true);
    return result != null;
  }

  /// Fetch undelivered messages from server.
  /// Called on app open and internet reconnect.
  Future<List<Map<String, dynamic>>> fetchOnlineMessages() async {
    try {
      final result = await _get('messages/', authenticated: true);
      final messages = result?['messages'] as List<dynamic>?;
      if (messages == null) return [];
      return messages.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Mark a message as delivered or read.
  Future<void> sendReceipt(String messageId, String receiptStatus) async {
    await _post('messages/receipt/', {
      'message_id': messageId,
      'status':     receiptStatus,
    }, authenticated: true);
  }

  /// Fetch delivery/read status of sent messages (for tick marks).
  Future<List<Map<String, dynamic>>> fetchMessageStatuses() async {
    try {
      final result = await _get('messages/status/', authenticated: true);
      final statuses = result?['statuses'] as List<dynamic>?;
      if (statuses == null) return [];
      return statuses.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ── Mesh Relay ───────────────────────────────────────────────────────────

  /// Called by any device (C) that receives a BLE message not meant for it
  /// and has internet. Forwards the encrypted payload to the server so the
  /// server can push-notify B and store the message for B to fetch later.
  /// No auth required — fire-and-forget.
  Future<void> relayMeshMessage({
    required String messageId,
    required String senderPubkey,
    required String receiverPubkey,
    required String encryptedContent,
    required int timestamp,
    String messageType = 'dm',
    String senderName = 'Someone',
  }) async {
    await _post('relay/', {
      'message_id': messageId,
      'sender_pubkey': senderPubkey,
      'receiver_pubkey': receiverPubkey,
      'encrypted_content': encryptedContent,
      'timestamp': timestamp,
      'message_type': messageType,
      'sender_name': senderName,
    });
  }

  /// Fetch pending mesh-relayed messages from the server.
  /// Called on app open and when internet reconnects.
  /// Returns raw maps with NIP-44 encrypted_content — decrypted on-device.
  Future<List<Map<String, dynamic>>> fetchPendingMessages() async {
    try {
      final result = await _get('messages/pending/', authenticated: true);
      final messages = result?['messages'] as List<dynamic>?;
      if (messages == null) return [];
      return messages.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

}

class ServerUploadException implements Exception {
  final String message;
  ServerUploadException(this.message);
  @override
  String toString() => message;
}
