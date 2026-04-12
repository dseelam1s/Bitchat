import 'dart:async';
import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/channels/services/channel_service.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/calls/screens/incoming_call_screen.dart';
import 'package:bitchat_messenger/features/chat/screens/chats_screen.dart';
import 'package:bitchat_messenger/features/contacts/screens/contacts_screen.dart';
import 'package:bitchat_messenger/features/profile/screens/profile_screen.dart';

class HomeScreen extends StatefulWidget {
  final DatabaseService dbService;
  final MessageService messageService;
  final ChannelService channelService;
  final CallService callService;

  const HomeScreen({
    super.key,
    required this.dbService,
    required this.messageService,
    required this.channelService,
    required this.callService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  int _totalUnread = 0;
  StreamSubscription? _messageSub;
  StreamSubscription? _callSub;
  bool _incomingCallShowing = false;
  Timer? _unreadDebounce;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _loadUnread();
    _messageSub = widget.messageService.messageStream.listen((_) {
      if (_currentIndex == 1) return; // chats tab visible — badge not shown
      _unreadDebounce?.cancel();
      _unreadDebounce = Timer(const Duration(milliseconds: 300), _loadUnread);
    });

    // Show incoming call screen when a call arrives
    _callSub = widget.callService.callStateStream.listen((session) {
      if (session != null &&
          session.state == CallState.ringing &&
          session.direction == CallDirection.incoming) {
        _showIncomingCall(session);
      }
    });

    // Handle the case where a call offer arrived before HomeScreen was mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = widget.callService.currentCall;
      if (pending != null &&
          pending.state == CallState.ringing &&
          pending.direction == CallDirection.incoming) {
        _showIncomingCall(pending);
      }
    });

    _screens = [
      // Tab 0 — Recents (calls)
      ContactsScreen(
        dbService: widget.dbService,
        messageService: widget.messageService,
        callService: widget.callService,
      ),
      // Tab 1 — Chats (DMs + channels unified)
      ChatsScreen(
        dbService: widget.dbService,
        messageService: widget.messageService,
        channelService: widget.channelService,
        callService: widget.callService,
      ),
      // Tab 2 — Profile + Settings
      ProfileScreen(
        messageService: widget.messageService,
      ),
    ];
  }

  void _showIncomingCall(CallSession session) {
    if (!mounted || _incomingCallShowing) return;
    _incomingCallShowing = true;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          session: session,
          callService: widget.callService,
        ),
      ),
    ).whenComplete(() => _incomingCallShowing = false);
  }

  Future<void> _loadUnread() async {
    final counts = await widget.messageService.getUnreadCounts();
    final total = counts.values.fold(0, (sum, c) => sum + c);
    if (mounted) setState(() => _totalUnread = total);
  }

  @override
  void dispose() {
    _unreadDebounce?.cancel();
    _messageSub?.cancel();
    _callSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider, width: 0.5)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
            // Reload badge count when switching away from chats — do not zero manually,
            // let _loadUnread() compute the real count from DB
            if (index != 1) _loadUnread();
          },
          height: 60,
          destinations: <NavigationDestination>[
            const NavigationDestination(
              icon: Icon(Icons.people_outline, size: 22),
              selectedIcon: Icon(Icons.people, size: 22),
              label: 'People',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: _totalUnread > 0 && _currentIndex != 1,
                label: Text(
                  _totalUnread > 99 ? '99+' : '$_totalUnread',
                  style: const TextStyle(fontSize: 9),
                ),
                backgroundColor: AppColors.primary,
                textColor: Colors.white,
                child: const Icon(Icons.chat_bubble_outline, size: 22),
              ),
              selectedIcon: const Icon(Icons.chat_bubble, size: 22),
              label: 'Chats',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline, size: 22),
              selectedIcon: Icon(Icons.person, size: 22),
              label: 'Me',
            ),
          ],
        ),
      ),
    );
  }
}
