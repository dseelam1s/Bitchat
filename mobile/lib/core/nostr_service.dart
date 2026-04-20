import 'dart:async';
import 'package:bitchat_messenger/features/chat/models/message.dart';

/// Nostr relay transport — stubbed out.
/// Internet messaging uses the server (WebSocket + REST).
/// Offline messaging uses BLE mesh.
class NostrService {
  final _messageController = StreamController<Message>.broadcast();
  final _channelMessageController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Map<String, dynamic>> get channelMessageStream => _channelMessageController.stream;
  bool get isConnected => false;
  int get connectedCount => 0;
  List<String> get relayUrls => [];
  Map<String, bool> get relayStatuses => {};

  void setKeys(String privateKey, String publicKey) {}
  void setLastEventTimestamp(int timestamp) {}
  void subscribe(String pubkey) {}
  void subscribeToChannel(String channelId) {}
  void unsubscribeFromChannel(String channelId) {}

  Future<void> connect() async {}
  Future<void> addRelay(String url) async {}
  Future<void> removeRelay(String url) async {}
  Future<void> sendMessage(Message message) async {}
  Future<void> sendCallSignal({required String recipientPubkey, required Map<String, dynamic> payload}) async {}
  Future<void> sendGroupInviteDm({required String recipientPubkey, required String channelId, required String channelName, required String adminPubkey}) async {}
  Future<void> sendGroupRemovalDm({required String recipientPubkey, required String channelId}) async {}
  Future<void> publishProfile({String? username, required String shortId}) async {}
  Future<List<Map<String, String>>> lookupByShortId(String shortId) async => [];

  void disconnect() {}
  void dispose() {
    _messageController.close();
    _channelMessageController.close();
  }
}
