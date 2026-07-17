import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/widgets/peer_avatar.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/groups/services/group_service.dart';

class CreateGroupScreen extends StatefulWidget {
  final DatabaseService dbService;
  final GroupService groupService;
  const CreateGroupScreen({
    super.key,
    required this.dbService,
    required this.groupService,
  });

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  List<Contact> _contacts = [];
  final Set<String> _selected = {};
  bool _membersVisible = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    widget.dbService.getContacts().then((c) {
      if (mounted) {
        setState(() => _contacts = c.where((x) => !x.isPending).toList());
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    setState(() => _creating = true);
    final groupId = await widget.groupService.createGroup(
      name: name,
      membersVisible: _membersVisible,
      members: _selected.toList(),
    );
    if (!mounted) return;
    setState(() => _creating = false);
    if (groupId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create group — try again')),
      );
      return;
    }
    Navigator.pop(context, groupId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          if (_creating)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(
              onPressed:
                  _nameController.text.trim().isEmpty || _selected.isEmpty
                      ? null
                      : _create,
              child: const Text('Create',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _nameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Group name',
                prefixIcon: Icon(Icons.groups_outlined),
              ),
            ),
          ),
          // Blind-group toggle — the headline feature.
          SwitchListTile(
            value: _membersVisible,
            onChanged: (v) => setState(() => _membersVisible = v),
            title: const Text('Members can see each other'),
            subtitle: Text(
              _membersVisible
                  ? 'Everyone sees who else is in the group'
                  : 'Blind group — only you (admin) see the members; '
                      'they appear to each other as “Member 1, 2, 3…”',
              style: const TextStyle(fontSize: 12),
            ),
            secondary: Icon(
              _membersVisible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: _membersVisible ? AppColors.primary : AppColors.coral,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Text('ADD MEMBERS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: AppColors.textMuted)),
                const Spacer(),
                Text('${_selected.length} selected',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted)),
              ],
            ),
          ),
          Expanded(
            child: _contacts.isEmpty
                ? const Center(
                    child: Text('No contacts yet — save people from the Radar first',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted)))
                : ListView.builder(
                    itemCount: _contacts.length,
                    itemBuilder: (_, i) {
                      final c = _contacts[i];
                      final sel = _selected.contains(c.pubkey);
                      final name = c.name ?? '#${c.shortId}';
                      return CheckboxListTile(
                        value: sel,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(c.pubkey);
                          } else {
                            _selected.remove(c.pubkey);
                          }
                        }),
                        secondary: PeerAvatar(
                          name: name,
                          localPath: c.profilePictureLocalPath,
                          picUrl: c.profilePictureUrl,
                          size: 42,
                          bgColor: AppColors.primary,
                        ),
                        title: Text(name),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
