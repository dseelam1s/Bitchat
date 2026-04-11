import 'dart:async';

import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

/// Watches for internet availability and BLE nearby changes.
/// When either becomes available, tries to resolve any pending contacts
/// (contacts saved by Short ID with no pubkey yet).
///
/// On successful resolution, calls [onContactResolved] so the caller
/// (e.g. MessageService) can retry queued messages immediately.
class ContactResolverService {
  final DatabaseService _dbService;

  StreamSubscription? _internetSub;
  StreamSubscription? _nearbySub;
  bool _started = false;

  /// Called after a pending contact is successfully resolved.
  /// Passes the real pubkey so the message layer can retry immediately.
  void Function(String resolvedPubkey)? onContactResolved;

  ContactResolverService({required DatabaseService dbService})
      : _dbService = dbService;

  /// Call once after MessageService is initialized.
  /// Safe to call multiple times — only the first call takes effect.
  void start({
    required bool hasInternet,
    required Set<String> nearbyPubkeys,
    required Stream<bool> internetStream,
    required Stream<Set<String>> nearbyStream,
  }) {
    if (_started) return;
    _started = true;

    // Resolve immediately with current state
    if (hasInternet) _resolveViaServer();
    if (nearbyPubkeys.isNotEmpty) _resolveViaBle(nearbyPubkeys);

    // Re-resolve whenever internet becomes available
    _internetSub = internetStream.listen((online) {
      if (online) _resolveViaServer();
    });

    // Re-resolve whenever new devices appear nearby
    _nearbySub = nearbyStream.listen((pubkeys) {
      if (pubkeys.isNotEmpty) _resolveViaBle(pubkeys);
    });
  }

  /// Try to resolve all pending contacts via server lookup.
  Future<void> _resolveViaServer() async {
    final pending = await _dbService.getPendingContacts();
    for (final contact in pending) {
      final shortId = contact.savedShortId;
      if (shortId == null) continue;
      try {
        final result = await ServerService().lookupByShortId(shortId);
        if (result == null) continue;

        final pubkey = result['pubkey'] as String?;
        if (pubkey == null || pubkey.isEmpty) continue;

        final name = result['display_name'] as String?;
        final picUrl = result['profile_picture_url'] as String?;

        await _dbService.resolvePendingContact(
          shortId,
          pubkey,
          name: name,
          profilePictureUrl: picUrl,
        );

        // Download and cache profile picture locally so it shows when offline
        if (picUrl != null && picUrl.isNotEmpty) {
          final localPath = await ProfilePictureCacheService().download(pubkey, picUrl);
          if (localPath != null) {
            await _dbService.updateContactLocalProfilePicture(pubkey, localPath);
          }
        }

        onContactResolved?.call(pubkey);
      } catch (_) {
        // Server unreachable — will retry next time internet is available
      }
    }
  }

  /// Try to resolve pending contacts by matching Short IDs against
  /// nearby BLE pubkeys. No server needed — purely local.
  Future<void> _resolveViaBle(Set<String> nearbyPubkeys) async {
    final pending = await _dbService.getPendingContacts();
    if (pending.isEmpty) return;

    for (final contact in pending) {
      final shortId = contact.savedShortId;
      if (shortId == null) continue;

      for (final pubkey in nearbyPubkeys) {
        if (Contact.shortIdFor(pubkey) == shortId) {
          await _dbService.resolvePendingContact(shortId, pubkey);
          onContactResolved?.call(pubkey);
          break;
        }
      }
    }
  }

  /// Manually trigger resolution (e.g. called from pull-to-refresh).
  Future<void> resolveNow({
    required bool hasInternet,
    required Set<String> nearbyPubkeys,
  }) async {
    if (hasInternet) await _resolveViaServer();
    if (nearbyPubkeys.isNotEmpty) await _resolveViaBle(nearbyPubkeys);
  }

  void dispose() {
    _internetSub?.cancel();
    _nearbySub?.cancel();
  }
}
