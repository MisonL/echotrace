// 文件: group_members_page.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_saver/file_saver.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';

// 可复用的头像 Widget (保持不变)
class UserAvatar extends StatelessWidget {
  final GroupMember member;
  const UserAvatar({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    final hasAvatar = member.avatarUrl != null && member.avatarUrl!.isNotEmpty;
    return CircleAvatar(
      backgroundImage: hasAvatar ? NetworkImage(member.avatarUrl!) : null,
      child: hasAvatar
          ? null
          : Text(
              member.displayName.isNotEmpty
                  ? member.displayName[0].toUpperCase()
                  : '?',
            ),
    );
  }
}

// 保留原页面，用于可能的独立调用
class GroupMembersPage extends StatelessWidget {
  final GroupChatInfo groupInfo;
  const GroupMembersPage({super.key, required this.groupInfo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${groupInfo.displayName} 成员')),
      body: GroupMembersContent(groupInfo: groupInfo),
    );
  }
}

// --- 新增：抽离出来的核心内容组件 ---
class GroupMembersContent extends StatefulWidget {
  final GroupChatInfo groupInfo;
  const GroupMembersContent({super.key, required this.groupInfo});

  @override
  State<GroupMembersContent> createState() => _GroupMembersContentState();
}

class _GroupMembersContentState extends State<GroupMembersContent> {
  late final GroupChatService _groupChatService;
  List<GroupMember> _members = [];
  List<GroupMember> _filteredMembers = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
    _loadMembers();
    _searchController.addListener(_filterMembers);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    // 确保组件挂载
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final members = await _groupChatService.getGroupMembers(
        widget.groupInfo.username,
      );
      if (!mounted) return;
      setState(() {
        _members = members;
        _filteredMembers = members;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载成员列表失败: $e')));
    }
  }

  void _filterMembers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredMembers = _members
          .where((member) => member.displayName.toLowerCase().contains(query))
          .toList();
    });
  }

  Future<void> _exportToJson() async {
    if (_members.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有成员数据可以导出')));
      return;
    }
    final jsonString = jsonEncode(_members.map((m) => m.toJson()).toList());
    try {
      final fileName = 'group_members_${widget.groupInfo.displayName}.json';
      await FileSaver.instance.saveFile(
        name: fileName,
        bytes: utf8.encode(jsonString),
        mimeType: MimeType.json,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('成功导出到下载目录: $fileName')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // --- 顶部工具栏 ---
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索成员昵称...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Text('共 ${_filteredMembers.length} 人'),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.save_alt),
                onPressed: _exportToJson,
                tooltip: '导出为JSON',
                color: Theme.of(context).primaryColor,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // --- 成员列表 ---
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filteredMembers.isEmpty
              ? const Center(child: Text('未找到匹配的成员'))
              : ListView.builder(
                  itemCount: _filteredMembers.length,
                  itemBuilder: (context, index) {
                    final member = _filteredMembers[index];
                    return ListTile(
                      leading: UserAvatar(member: member),
                      title: Text(member.displayName),
                      subtitle: Text(
                        member.username,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
