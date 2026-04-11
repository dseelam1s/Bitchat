class AppConstants {
  static const String appName = 'BitChat Messenger';

  // BitChat comfort-layer server
  // For local testing: use your PC's local network IP (run `ipconfig` to find it)
  // e.g. 'http://192.168.1.5:8000'
  // Change to your production URL before release.
  static const String serverBaseUrl = 'https://messanger-backend-1.onrender.com';

  // WebSocket signaling server — same host as REST, different scheme
  // http → ws, https → wss
  static const String signalingUrl = 'wss://messanger-backend-1.onrender.com/ws/signal/';

  // Default Nostr relays
  static const List<String> defaultRelays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.snort.social',
    'wss://relay.primal.net',
  ];

  // BitChat mesh settings
  static const int defaultTTL = 5;
  static const int messageExpiryHours = 24;
  static const int bleScanIntervalSeconds = 30;

  // BLE service UUID for BitChat discovery
  static const String bleServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  // Message types
  static const String typeText = 'text';
  static const String typeImage = 'image';

  // Connection modes
  static const String modeOnline = 'online';
  static const String modeOffline = 'offline';
  static const String modeAuto = 'auto';

  // Channel settings
  static const String defaultChannelId = 'nearby';
  static const String defaultChannelName = 'Nearby';
  static const int channelAnnouncementIntervalSeconds = 30;
  static const int channelExpirySeconds = 120; // 2 minutes without announcement = gone
  static const int channelMessageRetentionHours = 2; // scroll-back window
  static const int channelMessageTTL = 3;

  // Message types (channel)
  static const String typeChannelMessage = 'channel_message';
  static const String typeChannelAnnouncement = 'channel_announcement';

  // Ephemeral / reaction types
  static const String typeTypingIndicator = 'typing_indicator';
  static const String typeReaction = 'reaction';
}
