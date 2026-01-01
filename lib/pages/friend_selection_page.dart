import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/database_service.dart';
import '../services/advanced_analytics_service.dart';
import '../models/advanced_analytics_data.dart';
import '../providers/app_state.dart';
import 'dual_report_browser_page.dart';

/// 好友选择页面 - 用于双人报告
class FriendSelectionPage extends StatefulWidget {
  final DatabaseService databaseService;

  const FriendSelectionPage({super.key, required this.databaseService});

  @override
  State<FriendSelectionPage> createState() => _FriendSelectionPageState();
}

class _FriendSelectionPageState extends State<FriendSelectionPage> {
  late final AdvancedAnalyticsService _analyticsService;
  List<FriendshipRanking> _friendList = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _analyticsService = AdvancedAnalyticsService(widget.databaseService);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final appState = context.read<AppState>();
      final excluded = await appState.configService
          .getAnalyticsExcludedUsernames();
      final normalized = excluded.map((e) => e.toLowerCase()).toSet();
      normalized.add('filehelper');
      final myWxid =
          widget.databaseService.currentAccountWxid ??
          await appState.configService.getManualWxid();
      if (myWxid != null && myWxid.isNotEmpty) {
        normalized.add(myWxid.toLowerCase());
      }
      _analyticsService.setExcludedUsernames(normalized);
      _loadFriendList();
    });
  }

  /// 加载好友列表（按聊天数量排序）
  Future<void> _loadFriendList() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 获取按总互动数排名的好友列表（不限数量）
      final friends = await _analyticsService.getAbsoluteCoreFriends(999);

      setState(() {
        _friendList = friends;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '加载好友列表失败: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择好友'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载好友列表...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadFriendList, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_friendList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_outline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('暂无聊天记录', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 顶部提示
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.3),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '按聊天总数量排序，选择一位好友查看双人报告',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 好友列表
        Expanded(
          child: ListView.separated(
            itemCount: _friendList.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final friend = _friendList[index];
              return _buildFriendItem(friend, index + 1);
            },
          ),
        ),
      ],
    );
  }

  /// 构建好友列表项
  Widget _buildFriendItem(FriendshipRanking friend, int rank) {
    final wechatGreen = const Color(0xFF07C160);
    final appState = context.watch<AppState>();
    final avatarUrl = appState.getAvatarUrl(friend.username);

    return InkWell(
      onTap: () {
        // 跳转到双人报告页面
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DualReportBrowserPage(
              friendUsername: friend.username,
              friendName: friend.displayName,
              databaseService: widget.databaseService,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 排名
            SizedBox(
              width: 40,
              child: Text(
                _getRankText(rank),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: rank <= 3 ? wechatGreen : Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ),

            // 头像
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: ClipOval(
                child: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: avatarUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            _buildAvatarPlaceholder(friend),
                        errorWidget: (context, url, error) =>
                            _buildAvatarPlaceholder(friend),
                      )
                    : _buildAvatarPlaceholder(friend),
              ),
            ),

            const SizedBox(width: 12),

            // 好友信息
            Expanded(
              child: Text(
                friend.displayName,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // 消息数量
            Text(
              friend.count.toLocaleString(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),

            const SizedBox(width: 8),

            // 箭头图标
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  /// 构建头像占位符
  Widget _buildAvatarPlaceholder(FriendshipRanking friend) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Center(
        child: Text(
          friend.displayName.isNotEmpty
              ? friend.displayName[0].toUpperCase()
              : '?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  /// 获取排名文本
  String _getRankText(int rank) {
    if (rank == 1) return '🥇';
    if (rank == 2) return '🥈';
    if (rank == 3) return '🥉';
    return '$rank';
  }
}

/// 数字格式化扩展
extension NumberFormatter on int {
  String toLocaleString() {
    if (this >= 10000) {
      return '${(this / 10000).toStringAsFixed(1)}万';
    }
    return toString();
  }
}
