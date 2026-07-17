import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/theme.dart';

/// The Ember shelf — one kept moment per burned campfire.
/// Visible only to you; there is no sharing surface by design.
class EmberShelfScreen extends StatefulWidget {
  final DatabaseService dbService;
  const EmberShelfScreen({super.key, required this.dbService});

  @override
  State<EmberShelfScreen> createState() => _EmberShelfScreenState();
}

class _EmberShelfScreenState extends State<EmberShelfScreen> {
  List<Map<String, dynamic>> _embers = [];

  @override
  void initState() {
    super.initState();
    widget.dbService.getEmbers().then((rows) {
      if (mounted) setState(() => _embers = rows);
    });
  }

  String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Embers',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5)),
      ),
      body: _embers.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('🔥', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 12),
                Text('No embers yet',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.darkTextMuted
                            : AppColors.textSecondary)),
                const SizedBox(height: 6),
                Text(
                  'Join a campfire — when it burns out,\nthe one moment you keep lands here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color:
                          isDark ? AppColors.darkTextMuted : AppColors.textMuted),
                ),
              ]),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(14),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.15,
              ),
              itemCount: _embers.length,
              itemBuilder: (_, i) {
                final e = _embers[i];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard : AppColors.card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child:
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: AppColors.coral, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(_dateLabel((e['burnedAt'] as int?) ?? 0),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppColors.darkTextMuted
                                  : AppColors.textMuted)),
                      const Spacer(),
                      Text('${e['headcount'] ?? ''} 🔥',
                          style: const TextStyle(fontSize: 10)),
                    ]),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Text('“${e['body']}”',
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppColors.darkTextPrimary
                                  : AppColors.textPrimary)),
                    ),
                    Text('— ${e['senderName'] ?? ''}',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: isDark
                                ? AppColors.darkTextMuted
                                : AppColors.textMuted)),
                  ]),
                );
              },
            ),
    );
  }
}
