import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ImageSharingService {
  final _picker = ImagePicker();

  /// Pick an image from gallery or camera.
  /// Compressed to max 800×800 at 60% quality before returning.
  /// Returns the local file path or null if cancelled / permission denied.
  Future<String?> pickImage({bool fromCamera = false}) async {
    try {
      final picked = await _picker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 60,
      );
      return picked?.path;
    } catch (_) {
      return null;
    }
  }

  /// Read [filePath] and return its bytes as a base64 string.
  /// [forBle] — if true, compress to max 50KB (320×320, quality 40) so
  /// multi-hop BLE relay completes in ~8s per hop.
  /// Returns null if the file is missing or encoding fails.
  Future<String?> encodeToBase64(String filePath, {bool forBle = false}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();

      if (forBle && bytes.length > 50 * 1024) {
        // Decode → resize to 320×320 max → re-encode as JPEG at quality 40
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        final resized = img.copyResize(decoded, width: 320, height: 320);
        final compressed = img.encodeJpg(resized, quality: 40);
        return base64Encode(compressed);
      }

      if (bytes.length > 1024 * 1024) return null; // 1 MB hard cap for Wi-Fi P2P
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Decode [base64Data] and save the image to the app's documents directory.
  /// Returns the local file path on success, null on failure.
  Future<String?> decodeFromBase64(String messageId, String base64Data) async {
    try {
      final bytes = base64Decode(base64Data);
      final dir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(dir.path, 'received_images'));
      if (!await imagesDir.exists()) await imagesDir.create(recursive: true);
      final filePath = p.join(imagesDir.path, '$messageId.jpg');
      await File(filePath).writeAsBytes(bytes);
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// Download an image from [url] and save it to the received_images directory.
  /// Same storage location as [decodeFromBase64] so BLE and online images are
  /// treated identically once saved — content in the DB is always a local path.
  /// Returns the local file path on success, null on failure.
  Future<String?> decodeFromUrl(String messageId, String url) async {
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final dir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(dir.path, 'received_images'));
      if (!await imagesDir.exists()) await imagesDir.create(recursive: true);
      final filePath = p.join(imagesDir.path, '$messageId.jpg');
      await File(filePath).writeAsBytes(response.bodyBytes);
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// Delete a saved received image by [messageId].
  Future<void> deleteImage(String messageId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'received_images', '$messageId.jpg'));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
