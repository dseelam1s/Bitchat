import 'dart:async';

import 'database_service.dart';
import 'image_sharing_service.dart';

enum DownloadState { downloading, done, failed }

class ImageDownloadEvent {
  final String messageId;
  final DownloadState state;
  final String? localPath; // non-null only when state == done
  const ImageDownloadEvent({
    required this.messageId,
    required this.state,
    this.localPath,
  });
}

/// Manages downloading online image messages to local storage.
///
/// WhatsApp/Telegram pattern:
///   1. Message arrives with URL as content — show immediately via network image.
///   2. Download to local file in background so image persists offline.
///   3. Update DB content to local path — future opens use Image.file().
///   4. On failure: expose state so UI can show retry button.
class ImageDownloadService {
  static final ImageDownloadService _instance = ImageDownloadService._internal();
  factory ImageDownloadService() => _instance;
  ImageDownloadService._internal();

  final _controller = StreamController<ImageDownloadEvent>.broadcast();
  Stream<ImageDownloadEvent> get events => _controller.stream;

  // messageId → current state (survives widget rebuilds within a session)
  final Map<String, DownloadState> _states = {};
  // messageId → downloaded local path
  final Map<String, String> _localPaths = {};

  final Set<String> _inFlight = {};

  DownloadState? stateFor(String messageId) => _states[messageId];
  String? localPathFor(String messageId) => _localPaths[messageId];

  /// Start downloading [url] for [messageId]. No-ops if already downloading or done.
  Future<void> download(
    String messageId,
    String url,
    DatabaseService dbService,
    ImageSharingService imageSharingService,
  ) async {
    if (_inFlight.contains(messageId)) return;
    if (_states[messageId] == DownloadState.done) return;

    _inFlight.add(messageId);
    _states[messageId] = DownloadState.downloading;
    _controller.add(ImageDownloadEvent(
      messageId: messageId,
      state: DownloadState.downloading,
    ));

    try {
      final localPath = await imageSharingService.decodeFromUrl(messageId, url);
      if (localPath != null) {
        await dbService.updateMessageContent(messageId, localPath);
        _localPaths[messageId] = localPath;
        _states[messageId] = DownloadState.done;
        _controller.add(ImageDownloadEvent(
          messageId: messageId,
          state: DownloadState.done,
          localPath: localPath,
        ));
      } else {
        _states[messageId] = DownloadState.failed;
        _controller.add(ImageDownloadEvent(
          messageId: messageId,
          state: DownloadState.failed,
        ));
      }
    } catch (_) {
      _states[messageId] = DownloadState.failed;
      _controller.add(ImageDownloadEvent(
        messageId: messageId,
        state: DownloadState.failed,
      ));
    } finally {
      _inFlight.remove(messageId);
    }
  }

  /// Clear failed state so a retry call to [download] proceeds.
  void resetForRetry(String messageId) {
    _states.remove(messageId);
  }
}
