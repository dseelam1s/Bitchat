# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep FlutterSecureStorage (uses reflection)
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Keep FlutterBluePlus native bindings
-keep class com.boskokg.flutter_blue_plus.** { *; }

# Keep NearbyConnections native bindings
-keep class com.pkmnapps.nearby_connections.** { *; }

# Keep WebSocket classes
-keep class org.java_websocket.** { *; }

# Suppress warnings for common dependencies
-dontwarn com.google.android.play.core.**
-dontwarn kotlin.**
