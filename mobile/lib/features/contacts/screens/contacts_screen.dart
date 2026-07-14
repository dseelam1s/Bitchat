import 'dart:async';
import 'dart:io' as dart_io;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/calls/models/call_log.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_sync_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/calls/screens/in_call_screen.dart';
import 'package:bitchat_messenger/features/chat/screens/chat_screen.dart';

// Beacon family — keep in sync with the palette in chats_screen.dart.
const List<Color> _kAvatarPalette = [
  Color(0xFF3D5AFE), Color(0xFF00A8B5), Color(0xFFFF5C39),
  Color(0xFF7C4DFF), Color(0xFF0091EA), Color(0xFFFF8F00),
  Color(0xFF2E9E5B), Color(0xFFD81B60), Color(0xFF5C74FF),
  Color(0xFF00B8D4),
];

Color _avatarColor(String pubkey) {
  if (pubkey.isEmpty) return _kAvatarPalette[0];
  int hash = 0;
  for (final c in pubkey.codeUnits) { hash = (hash * 31 + c) & 0x7FFFFFFF; }
  return _kAvatarPalette[hash % _kAvatarPalette.length];
}

class ContactsScreen extends StatelessWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;

  const ContactsScreen({
    super.key,
    required this.dbService,
    required this.messageService,
    this.callService,
  });

  @override
  Widget build(BuildContext context) {
    // Calls page = recents only. The contacts manager and dialpad that used
    // to live here duplicated what Chats (merged contacts) and Radar (search
    // by ID) now do — two parallel ways to do everything is confusion.
    return Scaffold(
      appBar: AppBar(title: const Text('Calls')),
      body: _RecentsTab(
        dbService: dbService,
        messageService: messageService,
        callService: callService,
      ),
    );
  }
}

// ── Contacts List Screen (pushed from icon) ───────────────────────────────────

class _ContactsListScreen extends StatelessWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;

  const _ContactsListScreen({
    required this.dbService,
    required this.messageService,
    this.callService,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: _ContactsTab(
        dbService: dbService,
        messageService: messageService,
        callService: callService,
      ),
    );
  }
}

// ── Recents Tab ──────────────────────────────────────────────────────────────

class _RecentsTab extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;

  const _RecentsTab({
    required this.dbService,
    required this.messageService,
    this.callService,
  });

  @override
  State<_RecentsTab> createState() => _RecentsTabState();
}

class _RecentsTabState extends State<_RecentsTab> {
  List<CallLog> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
    // Refresh when a call ends
    widget.callService?.callStateStream.listen((session) {
      if (session == null) _load();
    });
  }

  Future<void> _load() async {
    final logs = await widget.dbService.getCallLogs();
    if (mounted) setState(() => _logs = logs);
  }

  Future<void> _call(CallLog log) async {
    final cs = widget.callService;
    if (cs == null || !widget.messageService.hasInternet) return;
    if (cs.hasActiveCall) return;

    // Look up contact name from DB
    final contacts = await widget.dbService.getContacts();
    final contact = contacts.firstWhere(
      (c) => c.pubkey == log.remotePubkey,
      orElse: () => Contact(pubkey: log.remotePubkey),
    );

    final err = await cs.startCall(log.remotePubkey, remoteName: contact.name ?? log.remoteName);
    if (!mounted) return;
    if (err != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err))); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)));
  }

  Future<void> _deleteLog(CallLog log) async {
    await widget.dbService.deleteCallLog(log.id);
    _load();
  }

  Future<void> _showDialpad() async {
    String digits = '';
    bool isLooking = false;
    String? errorMessage;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void addDigit(String d) {
              if (digits.length < 8) {
                setSheetState(() {
                  digits += d;
                  errorMessage = null;
                });
              }
            }

            void backspace() {
              if (digits.isNotEmpty) {
                setSheetState(() {
                  digits = digits.substring(0, digits.length - 1);
                  errorMessage = null;
                });
              }
            }

            Future<void> callByShortId() async {
              if (digits.length != 8) return;
              final cs = widget.callService;
              if (cs == null) return;
              if (!widget.messageService.hasInternet) {
                setSheetState(() => errorMessage = 'Internet required to call by Short ID');
                return;
              }
              if (cs.hasActiveCall) {
                setSheetState(() => errorMessage = 'Already on a call');
                return;
              }

              setSheetState(() { isLooking = true; errorMessage = null; });

              try {
                final result = await ServerService().lookupByShortId(digits);
                if (!ctx.mounted) return;

                if (result == null) {
                  setSheetState(() {
                    isLooking = false;
                    errorMessage = 'No user found with Short ID #$digits';
                  });
                  return;
                }

                final pubkey = result['pubkey'] as String;
                final name = (result['display_name'] as String?)?.isNotEmpty == true
                    ? result['display_name'] as String
                    : null;

                Navigator.of(ctx).pop();
                final err = await cs.startCall(pubkey, remoteName: name);
                if (!mounted) return;
                if (err != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err))); return; }
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => InCallScreen(callService: cs),
                ));
              } catch (e) {
                if (!ctx.mounted) return;
                setSheetState(() {
                  isLooking = false;
                  errorMessage = 'Lookup failed. Try again.';
                });
              }
            }

            final canCall = digits.length == 8 && !isLooking;
            final theme = Theme.of(ctx);
            final isDark = theme.brightness == Brightness.dark;

            final keyBg = isDark ? AppColors.darkCard : AppColors.card;
            final keyTextColor = isDark ? AppColors.darkTextPrimary : AppColors.textPrimary;
            final keySubColor = isDark ? AppColors.darkTextMuted : AppColors.textSecondary;

            Widget dialKey(String label, {String? sub, VoidCallback? onTap, Widget? child}) {
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: keyBg,
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withAlpha(20),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: child ?? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(label,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                          color: keyTextColor,
                          height: 1.1,
                        ),
                      ),
                      if (sub != null)
                        Text(sub,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: keySubColor,
                            letterSpacing: 1.5,
                            height: 1.0,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }

            final keys = [
              ['1', ''],   ['2', 'ABC'],  ['3', 'DEF'],
              ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'],
              ['7', 'PQRS'],['8', 'TUV'], ['9', 'WXYZ'],
            ];

            return Container(
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: AppColors.textMuted.withAlpha(80),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Digit display
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          digits.isEmpty ? '#________' : '#$digits${'_' * (8 - digits.length)}',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 6,
                            color: digits.isEmpty
                                ? AppColors.textMuted.withAlpha(100)
                                : null,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Error
                  if (errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Digit grid (1-9)
                  for (int row = 0; row < 3; row++) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (int col = 0; col < 3; col++) ...[
                          dialKey(
                            keys[row * 3 + col][0],
                            sub: keys[row * 3 + col][1].isNotEmpty ? keys[row * 3 + col][1] : null,
                            onTap: () => addDigit(keys[row * 3 + col][0]),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Bottom row: empty, 0, backspace
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const SizedBox(width: 72),
                        dialKey('0', onTap: () => addDigit('0')),
                        GestureDetector(
                          onTap: backspace,
                          onLongPress: () => setSheetState(() {
                            digits = '';
                            errorMessage = null;
                          }),
                          child: SizedBox(
                            width: 72, height: 72,
                            child: Icon(
                              Icons.backspace_outlined,
                              color: digits.isEmpty
                                  ? AppColors.textMuted.withAlpha(60)
                                  : keyTextColor,
                              size: 24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Call button
                  GestureDetector(
                    onTap: canCall ? callByShortId : null,
                    child: Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: canCall
                            ? AppColors.mint
                            : AppColors.mint.withAlpha(60),
                      ),
                      child: isLooking
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.call, color: Colors.white, size: 30),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _logs.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.call_outlined, size: 48, color: AppColors.textMuted.withAlpha(80)),
                const SizedBox(height: 16),
                const Text('No recent calls', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  'Calls appear here after you make or receive one',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted.withAlpha(180)),
                ),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 100),
            itemCount: _logs.length,
            separatorBuilder: (_, __) => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Divider(height: 1, color: AppColors.divider),
            ),
            itemBuilder: (_, i) => _buildLogTile(_logs[i]),
          );

    return body;
  }

  Widget _buildLogTile(CallLog log) {
    final name = (log.remoteName?.isNotEmpty == true)
        ? log.remoteName!
        : '#${Contact.shortIdFor(log.remotePubkey)}';
    final initial = (name.startsWith('#') ? name.substring(1) : name)
        .substring(0, 1).toUpperCase();
    final isMissed = log.isMissed;
    final avatarColor = _avatarColor(log.remotePubkey);
    final dt = DateTime.fromMillisecondsSinceEpoch(log.startedAt * 1000);
    final timeLabel = _formatTime(dt);

    return Dismissible(
      key: Key(log.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: AppColors.error.withAlpha(20),
        child: const Icon(Icons.delete_outline, color: AppColors.error),
      ),
      onDismissed: (_) => _deleteLog(log),
      child: InkWell(
        onTap: () => _call(log),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              // Circular avatar
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(shape: BoxShape.circle, color: avatarColor),
                child: Center(
                  child: Text(
                    initial,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isMissed ? AppColors.error : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          _directionIcon(log),
                          size: 14,
                          color: isMissed ? AppColors.error : AppColors.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _statusLabel(log),
                          style: TextStyle(
                            fontSize: 13,
                            color: isMissed ? AppColors.error : AppColors.textMuted,
                          ),
                        ),
                        if (log.isAnswered && log.duration > 0)
                          Text(
                            ' · ${_formatDuration(log.duration)}',
                            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // Time + call-back button
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeLabel,
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted.withAlpha(160)),
                  ),
                  if (widget.callService != null && widget.messageService.hasInternet) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => _call(log),
                      child: Icon(Icons.call_outlined, size: 20, color: AppColors.mint),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _directionIcon(CallLog log) {
    if (log.isMissed) return Icons.call_missed;
    if (log.isIncoming) return Icons.call_received;
    return Icons.call_made;
  }

  String _statusLabel(CallLog log) {
    if (log.isMissed) return 'Missed';
    if (log.status == 'declined') return log.isIncoming ? 'Declined' : 'Not answered';
    if (log.status == 'no_answer') return 'No answer';
    return log.isIncoming ? 'Incoming' : 'Outgoing';
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[dt.weekday - 1];
    }
    return '${dt.day}/${dt.month}';
  }
}

// ── Contacts Tab ─────────────────────────────────────────────────────────────

class _ContactsTab extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final CallService? callService;

  const _ContactsTab({
    required this.dbService,
    required this.messageService,
    this.callService,
  });

  @override
  State<_ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<_ContactsTab> {
  List<Contact> _allContacts = [];
  List<Contact> _filtered = [];
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final contacts = await widget.dbService.getContacts();
    if (!mounted) return;
    setState(() {
      _allContacts = contacts;
      _applyFilter(_searchController.text);
    });
    if (widget.messageService.hasInternet) {
      _refreshProfilePictures(contacts);
    }
  }

  Future<void> _refreshProfilePictures(List<Contact> contacts) async {
    final pubkeys = contacts.where((c) => !c.isPending).map((c) => c.pubkey).toList();
    await ProfileSyncService().syncAll(
      pubkeys,
      widget.dbService,
      onContactUpdated: (_) {
        if (mounted) _loadContactsSilent();
      },
    );
  }

  Future<void> _loadContactsSilent() async {
    final contacts = await widget.dbService.getContacts();
    if (!mounted) return;
    setState(() {
      _allContacts = contacts;
      _applyFilter(_searchController.text);
    });
  }

  void _onSearch() => setState(() => _applyFilter(_searchController.text));

  void _applyFilter(String query) {
    final q = query.trim().toLowerCase().replaceAll('#', '');
    if (q.isEmpty) {
      _filtered = List.from(_allContacts);
    } else {
      _filtered = _allContacts.where((c) {
        final nameMatch = c.name?.toLowerCase().contains(q) ?? false;
        final shortIdMatch = c.shortId.contains(q);
        final pubkeyMatch = c.pubkey.toLowerCase().contains(q);
        return nameMatch || shortIdMatch || pubkeyMatch;
      }).toList();
    }
    _filtered.sort((a, b) {
      final nearby = widget.messageService.nearbyUsers;
      final aNearby = nearby.contains(a.pubkey) ? 0 : 1;
      final bNearby = nearby.contains(b.pubkey) ? 0 : 1;
      if (aNearby != bNearby) return aNearby - bNearby;
      final aName = a.name ?? a.shortId;
      final bName = b.name ?? b.shortId;
      return aName.compareTo(bName);
    });
  }

  void _openChat(Contact contact) {
    if (contact.isPending) {
      _showPendingDialog(contact);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactPubkey: contact.pubkey,
          contactName: contact.name,
          contactProfilePictureUrl: contact.profilePictureUrl,
          contactProfilePictureLocalPath: contact.profilePictureLocalPath,
          messageService: widget.messageService,
          callService: widget.callService,
        ),
      ),
    ).then((_) => _loadContacts());
  }

  void _showPendingDialog(Contact contact) {
    final label = contact.name?.isNotEmpty == true
        ? contact.name!
        : '#${contact.shortId}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contact Pending'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label hasn\'t been found yet.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            const Text(
              'They\'ll be resolved automatically when:',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            const Text('• You connect to the internet',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const Text('• They come within Bluetooth range',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _startCall(Contact contact, {bool isVideo = false}) async {
    if (contact.isPending) return;
    final cs = widget.callService;
    if (cs == null || !widget.messageService.hasInternet) return;
    if (cs.hasActiveCall) return;
    final err = await cs.startCall(contact.pubkey, remoteName: contact.name, isVideo: isVideo);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => InCallScreen(callService: cs)));
  }

  void _addContact() {
    showDialog(
      context: context,
      builder: (ctx) => _AddContactDialog(
        onSave: (pubkey, name, profilePictureUrl) async {
          // Check if contact already exists
          final existing = _allContacts.where((c) => c.pubkey == pubkey).toList();
          if (existing.isNotEmpty && mounted) {
            final existingLabel = existing.first.name ?? '#${existing.first.shortId}';
            showDialog(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Already in Contacts'),
                content: Text('$existingLabel is already saved. Do you want to update their info?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await widget.dbService.insertContact(Contact(
                        pubkey: pubkey,
                        name: name.isNotEmpty ? name : existing.first.name,
                        isNameCustomized: name.isNotEmpty || existing.first.isNameCustomized,
                        profilePictureUrl: profilePictureUrl ?? existing.first.profilePictureUrl,
                      ));
                      _loadContacts();
                      if (c.mounted) Navigator.pop(c);
                    },
                    child: const Text('Update'),
                  ),
                ],
              ),
            );
            return;
          }
          await widget.dbService.insertContact(Contact(
            pubkey: pubkey,
            name: name.isNotEmpty ? name : null,
            isNameCustomized: name.isNotEmpty,
            profilePictureUrl: profilePictureUrl,
          ));
          // Download profile picture locally so it shows when offline
          if (profilePictureUrl != null && profilePictureUrl.isNotEmpty) {
            ProfilePictureCacheService().download(pubkey, profilePictureUrl).then((localPath) {
              if (localPath != null) {
                widget.dbService.updateContactLocalProfilePicture(pubkey, localPath);
              }
            });
          }
          // Back up updated contact list to server
          widget.messageService.triggerContactsBackup();
          _loadContacts();
        },
        onSavePending: (shortId, name) async {
          // Check if already saved (pending or resolved)
          final alreadyPending = _allContacts
              .any((c) => c.isPending && c.savedShortId == shortId);
          final alreadyResolved = _allContacts.any((c) =>
              !c.isPending && Contact.shortIdFor(c.pubkey) == shortId);
          if ((alreadyPending || alreadyResolved) && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('#$shortId is already in your contacts')),
            );
            return;
          }
          await widget.dbService.insertContact(Contact.pending(
            shortId: shortId,
            name: name.isNotEmpty ? name : null,
          ));
          _loadContacts();
          // Try to resolve right away — otherwise a contact saved while the
          // server lookup failed stays pending until the next app restart.
          final resolve = widget.messageService.resolvePendingContacts;
          if (resolve != null) {
            await resolve();
            _loadContacts();
          }
        },
        hasInternet: widget.messageService.hasInternet,
      ),
    );
  }

  void _editContact(Contact contact) {
    final nameController = TextEditingController(text: contact.name ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(
                  '#${contact.shortId}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mint,
                    letterSpacing: 3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              await widget.dbService.insertContact(
                contact.copyWith(
                  name: name.isNotEmpty ? name : null,
                  isNameCustomized: name.isNotEmpty,
                ),
              );
              _loadContacts();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _deleteContact(Contact contact) {
    final label = contact.name ?? '#${contact.shortId}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Contact'),
        content: Text('Remove $label from your contacts?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await widget.dbService.deleteContact(contact.pubkey);
              _loadContacts();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Remove', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nearby = widget.messageService.nearbyUsers;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name or #ID...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
            child: Row(
              children: [
                Text(
                  _filtered.isEmpty
                      ? 'No contacts'
                      : '${_filtered.length} contact${_filtered.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted.withAlpha(150)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? _buildEmpty()
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 100),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const Padding(
                      padding: EdgeInsets.only(left: 86),
                      child: Divider(height: 1, color: AppColors.divider),
                    ),
                    itemBuilder: (_, i) => _buildContactTile(_filtered[i], nearby),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContact,
        child: const Icon(Icons.person_add_alt_1, size: 22),
      ),
    );
  }

  Widget _buildContactTile(Contact contact, Set<String> nearby) {
    final isNearby = nearby.contains(contact.pubkey);
    final label = contact.name?.isNotEmpty == true ? contact.name! : '#${contact.shortId}';
    final canCall = !contact.isPending &&
        widget.callService != null &&
        widget.messageService.hasInternet;

    return InkWell(
      onTap: () => _openChat(contact),
      onLongPress: () => _showContactOptions(contact),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            _contactAvatar(contact, label, isNearby),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: contact.isPending ? AppColors.textMuted : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  contact.isPending
                      ? Text(
                          'Pending · #${contact.shortId}',
                          style: TextStyle(fontSize: 13, color: AppColors.textMuted.withAlpha(160)),
                        )
                      : Text(
                          '#${contact.shortId}',
                          style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                        ),
                ],
              ),
            ),
            if (isNearby) ...[
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.online),
              ),
              const SizedBox(width: 10),
            ],
            if (canCall) ...[
              GestureDetector(
                onTap: () => _startCall(contact),
                child: const Icon(Icons.call_outlined, size: 22, color: AppColors.mint),
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () => _startCall(contact, isVideo: true),
                child: const Icon(Icons.videocam_outlined, size: 24, color: AppColors.mint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showContactOptions(Contact contact) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (!contact.isPending)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Open Chat'),
                onTap: () { Navigator.pop(ctx); _openChat(contact); },
              ),
            if (!contact.isPending &&
                widget.callService != null &&
                widget.messageService.hasInternet) ...[
              ListTile(
                leading: const Icon(Icons.call_outlined, color: AppColors.mint),
                title: const Text('Voice Call'),
                onTap: () { Navigator.pop(ctx); _startCall(contact); },
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, color: AppColors.mint),
                title: const Text('Video Call'),
                onTap: () { Navigator.pop(ctx); _startCall(contact, isVideo: true); },
              ),
            ],
            if (contact.isPending)
              ListTile(
                leading: const Icon(Icons.schedule, color: AppColors.textMuted),
                title: const Text('Waiting to be found'),
                subtitle: const Text(
                    'Will resolve when online or in Bluetooth range',
                    style: TextStyle(fontSize: 11)),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit Name'),
              onTap: () { Navigator.pop(ctx); _editContact(contact); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.error),
              title: const Text('Remove Contact', style: TextStyle(color: AppColors.error)),
              onTap: () { Navigator.pop(ctx); _deleteContact(contact); },
            ),
          ],
        ),
      ),
    );
  }

  Widget _contactAvatar(Contact contact, String label, bool isNearby) {
    final color = _avatarColor(contact.pubkey);
    final initial = (label.startsWith('#') ? label.substring(1) : label)
        .substring(0, 1).toUpperCase();

    Widget fallback = Center(
      child: Text(initial, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
    );

    Widget image;
    if (contact.profilePictureLocalPath != null) {
      image = Image.file(
        dart_io.File(contact.profilePictureLocalPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => contact.profilePictureUrl != null
            ? CachedNetworkImage(imageUrl: contact.profilePictureUrl!, fit: BoxFit.cover, errorWidget: (_, __, ___) => fallback)
            : fallback,
      );
    } else if (contact.profilePictureUrl != null) {
      image = CachedNetworkImage(imageUrl: contact.profilePictureUrl!, fit: BoxFit.cover, errorWidget: (_, __, ___) => fallback);
    } else {
      image = fallback;
    }

    return Stack(
      children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          clipBehavior: Clip.antiAlias,
          child: image,
        ),
        if (isNearby)
          Positioned(
            bottom: 0, right: 0,
            child: Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.online,
                border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty() {
    final isSearching = _searchController.text.isNotEmpty;

    if (isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 40, color: AppColors.textMuted.withAlpha(80)),
            const SizedBox(height: 16),
            const Text('No contacts match', style: TextStyle(fontSize: 15)),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withAlpha(15),
                border: Border.all(color: AppColors.primary.withAlpha(40), width: 1.5),
              ),
              child: Icon(Icons.people_outline, size: 32, color: AppColors.primary.withAlpha(160)),
            ),
            const SizedBox(height: 20),
            const Text(
              'No contacts yet',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Add a contact using their short ID to start messaging.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _addContact,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Add Contact'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Add Contact Dialog ───────────────────────────────────────────────────────

class _AddContactDialog extends StatefulWidget {
  final Future<void> Function(String pubkey, String name, String? profilePictureUrl) onSave;
  final Future<void> Function(String shortId, String name) onSavePending;
  final bool hasInternet;

  const _AddContactDialog({
    required this.onSave,
    required this.onSavePending,
    required this.hasInternet,
  });

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _shortIdController = TextEditingController();
  final _pubkeyController = TextEditingController();
  final _nameController = TextEditingController();

  bool _isSaving = false;
  bool _showPubkeyField = false;

  @override
  void initState() {
    super.initState();
    _shortIdController.addListener(() => setState(() {}));
    _pubkeyController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _shortIdController.dispose();
    _pubkeyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_isSaving) return false;
    return _shortIdController.text.trim().replaceAll('#', '').isNotEmpty ||
        _pubkeyController.text.trim().isNotEmpty;
  }

  Future<void> _save() async {
    final shortId = _shortIdController.text.trim().replaceAll('#', '');
    final pubkey = _pubkeyController.text.trim();
    final name = _nameController.text.trim();

    // Manual pubkey entry — save directly
    if (pubkey.isNotEmpty) {
      await widget.onSave(pubkey, name, null);
      if (mounted) Navigator.pop(context);
      return;
    }

    if (shortId.isEmpty) return;
    setState(() => _isSaving = true);

    // Try server lookup silently if online
    if (widget.hasInternet) {
      try {
        final result = await ServerService().lookupByShortId(shortId);
        if (!mounted) return;
        if (result != null) {
          final resolvedPubkey = result['pubkey'] as String? ?? '';
          final serverName = (result['display_name'] as String? ?? '').trim();
          final picUrl = result['profile_picture_url'] as String?;
          if (resolvedPubkey.isNotEmpty) {
            // Resolved immediately — save as full contact
            await widget.onSave(
              resolvedPubkey,
              name.isNotEmpty ? name : serverName,
              picUrl,
            );
            if (mounted) Navigator.pop(context);
            return;
          }
        }
      } catch (_) {}
    }

    // Not found or offline — save as pending
    if (!mounted) return;
    await widget.onSavePending(shortId, name);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Contact'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Contact name',
              ),
            ),
            const SizedBox(height: 14),
            // Short ID
            TextField(
              controller: _shortIdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Short ID',
                hintText: '729134',
                prefixText: '# ',
              ),
            ),
            if (!widget.hasInternet) ...[
              const SizedBox(height: 6),
              Text(
                'Offline — contact will resolve when you go online or they come nearby.',
                style: TextStyle(fontSize: 10, color: AppColors.textMuted.withAlpha(130)),
              ),
            ],
            const SizedBox(height: 12),
            // Optional public key — collapsible
            GestureDetector(
              onTap: () => setState(() => _showPubkeyField = !_showPubkeyField),
              child: Row(
                children: [
                  Icon(
                    _showPubkeyField ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Add public key manually',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            if (_showPubkeyField) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _pubkeyController,
                decoration: const InputDecoration(
                  hintText: 'Paste 64-character hex key',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                maxLines: 2,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _canSave ? _save : null,
          child: _isSaving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
