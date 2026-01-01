// 文件: group_chat_analysis_page.dart

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';
import '../utils/string_utils.dart';
import 'group_members_page.dart'; // 导入新组件
import 'group_ranking_page.dart'; // 导入新组件
import 'group_active_hours_page.dart'; // <<< 导入新文件
import 'group_media_stats_page.dart';

// 新的、更清晰的枚举
enum AnalysisFunction {
  memberList, // 群成员查看
  messageRanking, // 群聊发言排行
  activeHours, // 群聊活跃时段
  mediaStats, // 媒体内容统计
}

class GroupChatAnalysisPage extends StatefulWidget {
  const GroupChatAnalysisPage({super.key});

  @override
  State<GroupChatAnalysisPage> createState() => _GroupChatAnalysisPageState();
}

class _GroupChatAnalysisPageState extends State<GroupChatAnalysisPage>
    with TickerProviderStateMixin {
  late final GroupChatService _groupChatService;
  List<GroupChatInfo> _allGroups = [];
  List<GroupChatInfo> _filteredGroups = [];
  bool _isLoading = true;

  GroupChatInfo? _selectedGroup;
  AnalysisFunction? _selectedFunction;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late AnimationController _searchAnimationController;
  late Animation<double> _searchAnimation;
  late AnimationController _refreshController;

  static List<GroupChatInfo>? _cachedGroupChats;

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);

    _searchAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _searchAnimation = CurvedAnimation(
      parent: _searchAnimationController,
      curve: Curves.easeInOut,
    );
    _refreshController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _searchController.addListener(_filterGroups);
    _loadGroupChats();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchAnimationController.dispose();
    _refreshController.dispose();
    super.dispose();
  }

  Future<void> _loadGroupChats() async {
    setState(() {
      _isLoading = true;
      _selectedGroup = null;
      _selectedFunction = null;
    });
    _refreshController.repeat();

    // 使用缓存以提高性能
    if (_cachedGroupChats != null) {
      if (mounted) {
        setState(() {
          _allGroups = _cachedGroupChats!;
          _filteredGroups = _cachedGroupChats!;
          _isLoading = false;
        });
      }
      _refreshController.stop();
      return;
    }

    try {
      final groups = await _groupChatService.getGroupChats();
      _cachedGroupChats = groups;
      if (mounted) {
        setState(() {
          _allGroups = groups;
          _filteredGroups = groups;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载群聊列表失败: $e')));
      }
    } finally {
      if (mounted) _refreshController.stop();
    }
  }

  Future<void> _refreshGroupChats() async {
    _cachedGroupChats = null;
    await _loadGroupChats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('刷新成功'), duration: Duration(seconds: 2)),
      );
    }
  }

  void _filterGroups() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredGroups = _allGroups
          .where((group) => group.displayName.toLowerCase().contains(query))
          .toList();
    });
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (_isSearching) {
        _searchAnimationController.forward();
        _searchFocusNode.requestFocus();
      } else {
        _searchAnimationController.reverse();
        _searchController.clear();
        _searchFocusNode.unfocus();
      }
    });
  }

  void _onGroupSelected(GroupChatInfo group) {
    setState(() {
      if (_selectedGroup?.username != group.username) {
        _selectedGroup = group;
        _selectedFunction = null;
      }
    });
  }

  void _onFunctionSelected(AnalysisFunction type) {
    setState(() => _selectedFunction = type);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [_buildGroupListPanel(), _buildDetailPanel()]);
  }

  Widget _buildGroupListPanel() {
    // ... (这部分代码与上次相同，无需修改) ...
    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Colors.grey.shade200, width: 1.0),
        ),
      ),
      child: Column(
        children: [
          _buildGroupListHeader(),
          _buildSearchBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredGroups.isEmpty
                ? _buildEmptyState()
                : _buildGroupListView(),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupListHeader() {
    // ... (这部分代码与上次相同，无需修改) ...
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Text(
            '群聊列表',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
            tooltip: _isSearching ? '关闭搜索' : '搜索群聊',
          ),
          IconButton(
            icon: RotationTransition(
              turns: _refreshController,
              child: const Icon(Icons.refresh),
            ),
            onPressed: _isLoading ? null : _refreshGroupChats,
            tooltip: '刷新列表',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    // ... (这部分代码与上次相同，无需修改) ...
    return SizeTransition(
      sizeFactor: _searchAnimation,
      axisAlignment: -1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Colors.grey.shade50,
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          decoration: InputDecoration(
            hintText: '搜索群聊名称...',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () => _searchController.clear(),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            isDense: true,
          ),
        ),
      ),
    );
  }

  Widget _buildGroupListView() {
    return ListView.builder(
      itemCount: _filteredGroups.length,
      itemBuilder: (context, index) {
        final group = _filteredGroups[index];
        final isSelected = _selectedGroup?.username == group.username;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _onGroupSelected(group),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isSelected
                    ? Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withValues(alpha: 0.5)
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  _buildGroupAvatar(context, group),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          StringUtils.cleanOrDefault(
                            group.displayName,
                            '未命名群聊',
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${group.memberCount} 位成员',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailPanel() {
    return Expanded(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _selectedGroup == null
            ? _buildInitialPlaceholder()
            : _selectedFunction == null
            ? _buildFunctionMenu()
            : _buildFunctionContent(),
      ),
    );
  }

  Widget _buildInitialPlaceholder() {
    // ... (这部分代码与上次相同，无需修改) ...
    return const Center(
      key: ValueKey('placeholder'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.group_add_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 20),
          Text(
            '请从左侧选择一个群聊进行分析',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // --- 核心修改：更新功能菜单 ---
  Widget _buildFunctionMenu() {
    return Center(
      key: ValueKey('menu_${_selectedGroup?.username}'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildGroupAvatar(context, _selectedGroup!, radius: 40),
            const SizedBox(height: 16),
            Text(
              _selectedGroup!.displayName,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            Text(
              '${_selectedGroup!.memberCount} 位成员',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 48),
            Wrap(
              spacing: 20,
              runSpacing: 20,
              alignment: WrapAlignment.center,
              children: [
                _buildFunctionMenuItem(
                  type: AnalysisFunction.memberList,
                  icon: Icons.people_outline,
                  label: '群成员查看',
                ),
                _buildFunctionMenuItem(
                  type: AnalysisFunction.messageRanking,
                  icon: Icons.bar_chart,
                  label: '群聊发言排行',
                ),
                _buildFunctionMenuItem(
                  // 新功能：群聊活跃时段
                  type: AnalysisFunction.activeHours, // <<< 修改后
                  icon: Icons.hourglass_bottom, // 图标：沙漏，代表时间
                  label: '群聊活跃时段',
                ),
                _buildFunctionMenuItem(
                  // 新功能：媒体内容统计
                  type: AnalysisFunction.mediaStats, // <<< 修改后
                  icon: Icons.perm_media_outlined, // 图标：图片/文件集合
                  label: '媒体内容统计',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFunctionMenuItem({
    required AnalysisFunction type,
    required IconData icon,
    required String label,
  }) {
    // ... (这部分代码与上次相同，无需修改) ...
    return InkWell(
      onTap: () => _onFunctionSelected(type),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 150,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(icon, size: 40, color: Theme.of(context).primaryColor),
            const SizedBox(height: 12),
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // --- 核心修改：更新功能内容展示区 ---
  Widget _buildFunctionContent() {
    return Container(
      key: ValueKey('content_${_selectedGroup?.username}_$_selectedFunction'),
      color: Colors.grey.shade50,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            color: Colors.white,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedFunction = null),
                ),
                const SizedBox(width: 8),
                Text(
                  _getFunctionName(_selectedFunction!),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (_selectedFunction!) {
              AnalysisFunction.memberList => GroupMembersContent(
                groupInfo: _selectedGroup!,
              ),
              AnalysisFunction.messageRanking => GroupRankingContent(
                groupInfo: _selectedGroup!,
              ),

              // --- 新增：处理“群聊活跃时段” ---
              // 当 _selectedFunction 是 activeHours 时，加载我们新创建的页面
              AnalysisFunction.activeHours => GroupActiveHoursContent(
                groupInfo: _selectedGroup!,
              ),
              AnalysisFunction.mediaStats => GroupMediaStatsContent(
                groupInfo: _selectedGroup!,
              ),
            },
          ),
        ],
      ),
    );
  }

  String _getFunctionName(AnalysisFunction type) {
    switch (type) {
      case AnalysisFunction.memberList:
        return '群成员查看';
      case AnalysisFunction.messageRanking:
        return '群聊发言排行';
      case AnalysisFunction.activeHours:
        return '群聊活跃时段';
      case AnalysisFunction.mediaStats:
        return '媒体内容统计';
    }
  }

  Widget _buildEmptyState() {
    // ... (这部分代码与上次相同，无需修改) ...
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _isSearching ? Icons.search_off : Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            _isSearching ? '未找到匹配的群聊' : '暂无群聊数据',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildGroupAvatar(
    BuildContext context,
    GroupChatInfo group, {
    double radius = 24,
  }) {
    final hasAvatar = group.avatarUrl != null && group.avatarUrl!.isNotEmpty;
    final fallbackText = StringUtils.getFirstChar(
      group.displayName,
      defaultChar: '群',
    );

    if (hasAvatar) {
      return CachedNetworkImage(
        imageUrl: group.avatarUrl!,
        imageBuilder: (context, imageProvider) => CircleAvatar(
          radius: radius,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.05),
          backgroundImage: imageProvider,
        ),
        placeholder: (context, url) => CircleAvatar(
          radius: radius,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.15),
          child: Text(
            fallbackText,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: radius / 1.6,
            ),
          ),
        ),
        errorWidget: (context, url, error) => CircleAvatar(
          radius: radius,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.15),
          child: Text(
            fallbackText,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: radius / 1.6,
            ),
          ),
        ),
      );
    } else {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.15),
        child: Text(
          fallbackText,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: radius / 1.6,
          ),
        ),
      );
    }
  }
}
