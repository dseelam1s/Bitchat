import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

/// Silently syncs a contact's profile (name + picture) from the server.
///
/// Rules:
///   - Name: only updated when `isNameCustomized = false` (enforced by DB layer)
///   - Picture: always updated — URL saved to DB, image downloaded to documents dir
///   - Throttled: each pubkey is only synced once per hour across the app lifetime
///
/// Call patterns:
///   - ChatScreen.initState() — single contact, fire-and-forget
///   - ChatsScreen.initState() — batch all contacts, fire-and-forget
class ProfileSyncService {
  static final ProfileSyncService _instance = ProfileSyncService._internal();
  factory ProfileSyncService() => _instance;
  ProfileSyncService._internal();

  // Prevent duplicate in-flight requests for the same pubkey
  final Set<String> _inFlight = {};

  // Track last sync time per pubkey — skip if synced within the last hour
  final Map<String, DateTime> _lastSynced = {};
  static const _syncInterval = Duration(hours: 1);

  /// Fetch the latest profile for [pubkey] from server and write to local DB.
  ///
  /// Returns updated values (name, localPath) so the caller can update UI
  /// without a DB round-trip. Returns null if nothing changed or on error.
  Future<({String? name, String? localPath})?> syncContact(
    String pubkey,
    DatabaseService dbService, {
    bool force = false,
  }) async {
    if (_inFlight.contains(pubkey)) return null;
    // Skip if recently synced (unless forced e.g. user manually refreshes)
    final last = _lastSynced[pubkey];
    if (!force && last != null && DateTime.now().difference(last) < _syncInterval) {
      return null;
    }
    _inFlight.add(pubkey);
    try {
      final result = await ServerService().getProfile(pubkey);
      if (result == null) return null;

      final name = result['display_name'] as String?;
      final picUrl = result['profile_picture_url'] as String?;

      if (name != null && name.isNotEmpty) {
        // DB layer only writes if isNameCustomized = false
        await dbService.updateContactName(pubkey, name);
      }

      String? localPath;
      if (picUrl != null && picUrl.isNotEmpty) {
        await dbService.updateContactProfilePicture(pubkey, picUrl);
        localPath = await ProfilePictureCacheService().download(pubkey, picUrl);
        if (localPath != null) {
          await dbService.updateContactLocalProfilePicture(pubkey, localPath);
        }
      }

      _lastSynced[pubkey] = DateTime.now();
      final changed = (name?.isNotEmpty == true) || localPath != null;
      return changed ? (name: name, localPath: localPath) : null;
    } catch (_) {
      return null;
    } finally {
      _inFlight.remove(pubkey);
    }
  }

  /// Batch sync all provided pubkeys. Runs concurrently (max 5 at a time).
  /// Calls [onContactUpdated] for each pubkey where data changed,
  /// so the caller can refresh its state incrementally.
  Future<void> syncAll(
    List<String> pubkeys,
    DatabaseService dbService, {
    void Function(String pubkey)? onContactUpdated,
  }) async {
    // Process in chunks of 5 to avoid hammering the server
    const chunkSize = 5;
    for (var i = 0; i < pubkeys.length; i += chunkSize) {
      final chunk = pubkeys.skip(i).take(chunkSize).toList();
      await Future.wait(chunk.map((pubkey) async {
        final updated = await syncContact(pubkey, dbService);
        if (updated != null) onContactUpdated?.call(pubkey);
      }));
    }
  }
}
