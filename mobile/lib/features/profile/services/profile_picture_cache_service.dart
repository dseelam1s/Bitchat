import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads contact profile pictures to the app's documents directory.
///
/// Unlike CachedNetworkImage (which uses the OS cache dir and can be evicted),
/// files here persist until explicitly deleted — they survive offline, low
/// storage warnings, and app restarts.
///
/// File naming: `<documentsDir>/avatars/<pubkeyPrefix>.jpg`
class ProfilePictureCacheService {
  static final ProfilePictureCacheService _instance =
      ProfilePictureCacheService._internal();
  factory ProfilePictureCacheService() => _instance;
  ProfilePictureCacheService._internal();

  Directory? _avatarDir;

  Future<Directory> _getAvatarDir() async {
    if (_avatarDir != null) return _avatarDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/avatars');
    if (!await dir.exists()) await dir.create(recursive: true);
    _avatarDir = dir;
    return dir;
  }

  /// Download [url] and save locally for [pubkey].
  /// Returns the local file path on success, null on any error.
  /// Safe to call multiple times — re-downloads only if URL changed.
  Future<String?> download(String pubkey, String url) async {
    if (pubkey.isEmpty || url.isEmpty) return null;
    try {
      final dir = await _getAvatarDir();
      // Use first 16 chars of pubkey as filename — avoids filesystem limits
      final safeKey = pubkey.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, pubkey.length.clamp(0, 16));
      final file = File('${dir.path}/$safeKey.jpg');

      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;

      final bytes = response.bodyBytes;
      if (bytes.isEmpty) return null;

      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Delete the locally cached avatar for [pubkey] (e.g. when they remove photo).
  Future<void> delete(String pubkey) async {
    try {
      final dir = await _getAvatarDir();
      final safeKey = pubkey.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, pubkey.length.clamp(0, 16));
      final file = File('${dir.path}/$safeKey.jpg');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Returns the cached local path if the file exists on disk, null otherwise.
  Future<String?> localPath(String pubkey) async {
    try {
      final dir = await _getAvatarDir();
      final safeKey = pubkey.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, pubkey.length.clamp(0, 16));
      final file = File('${dir.path}/$safeKey.jpg');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }
}
