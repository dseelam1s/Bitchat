import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// One avatar for the whole app — profile picture when available
/// (local cache first, then network), initial letter otherwise.
/// Used by chats, radar, calls, nearby strip, and peer cards so a person
/// looks the same everywhere.
class PeerAvatar extends StatelessWidget {
  final String name;
  final String? localPath;
  final String? picUrl;
  final double size;
  final Color bgColor;
  final Border? border;
  final List<BoxShadow>? boxShadow;

  const PeerAvatar({
    super.key,
    required this.name,
    this.localPath,
    this.picUrl,
    required this.size,
    required this.bgColor,
    this.border,
    this.boxShadow,
  });

  String get _initial {
    final n = name.trim();
    if (n.isEmpty || n == '?') return '?';
    final clean = n.startsWith('#') ? n.substring(1) : n;
    return clean.isNotEmpty ? clean[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback = Center(
      child: Text(
        _initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.38,
        ),
      ),
    );

    Widget content;
    if (localPath != null && File(localPath!).existsSync()) {
      content = Image.file(File(localPath!), fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback);
    } else if (picUrl != null && picUrl!.isNotEmpty) {
      content = CachedNetworkImage(
        imageUrl: picUrl!,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => fallback,
        placeholder: (_, __) => fallback,
      );
    } else {
      content = fallback;
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        border: border,
        boxShadow: boxShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
