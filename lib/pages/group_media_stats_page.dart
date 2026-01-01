// 文件: lib/pages/group_media_stats_page.dart

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';
import '../models/message.dart'; // 需要 Message 模型来获取类型描述

class GroupMediaStatsContent extends StatefulWidget {
  final GroupChatInfo groupInfo;
  const GroupMediaStatsContent({super.key, required this.groupInfo});

  @override
  State<GroupMediaStatsContent> createState() => _GroupMediaStatsContentState();
}

class _GroupMediaStatsContentState extends State<GroupMediaStatsContent> {
  late final GroupChatService _groupChatService;
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  bool _isLoading = false;
  Map<int, int>? _mediaData;
  int? _touchedIndex; // 用于饼图交互

  // 定义媒体类型和对应的颜色/图标
  static const Map<int, Map<String, dynamic>> _mediaTypeInfo = {
    1: {'name': '文本', 'color': Colors.blue, 'icon': Icons.text_fields},
    3: {'name': '图片', 'color': Colors.green, 'icon': Icons.image},
    34: {'name': '语音', 'color': Colors.orange, 'icon': Icons.mic},
    43: {'name': '视频', 'color': Colors.purple, 'icon': Icons.videocam},
    47: {'name': '表情包', 'color': Colors.pink, 'icon': Icons.emoji_emotions},
    49: {'name': '链接/文件', 'color': Colors.teal, 'icon': Icons.attach_file},
    48: {'name': '位置', 'color': Colors.brown, 'icon': Icons.location_on},
    // 可以根据需要添加更多 localType
  };

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
    _fetchMediaStats();
  }

  Future<void> _selectDate(BuildContext context, bool isStart) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
    }
  }

  Future<void> _fetchMediaStats() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _mediaData = null;
    });

    try {
      final data = await _groupChatService.getGroupMediaTypeStats(
        chatroomId: widget.groupInfo.username,
        startDate: _startDate,
        endDate: _endDate,
      );

      if (!mounted) return;
      setState(() {
        _mediaData = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('生成统计失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy-MM-dd');
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: [
              ActionChip(
                avatar: const Icon(Icons.calendar_today, size: 16),
                label: Text('开始: ${dateFormat.format(_startDate)}'),
                onPressed: () => _selectDate(context, true),
              ),
              ActionChip(
                avatar: const Icon(Icons.calendar_today, size: 16),
                label: Text('结束: ${dateFormat.format(_endDate)}'),
                onPressed: () => _selectDate(context, false),
              ),
              ElevatedButton.icon(
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.pie_chart_outline),
                label: const Text('生成统计'),
                onPressed: _isLoading ? null : _fetchMediaStats,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildContent(),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_mediaData == null) {
      return const Center(
        key: ValueKey('initial'),
        child: Text('请选择日期范围并生成统计'),
      );
    }

    // --- 在这里添加过滤逻辑 ---
    final filteredData = _mediaData!.entries.where((entry) {
      // 过滤掉数量为0的类型 和 localType为48(位置)的类型
      return entry.value > 0 && entry.key != 48;
    }).toList()..sort((a, b) => b.value.compareTo(a.value)); // 按数量降序排序

    if (filteredData.isEmpty) {
      return const Center(key: ValueKey('empty'), child: Text('该时间段内无消息记录'));
    }

    final totalMessages = filteredData.fold<int>(
      0,
      (sum, item) => sum + item.value,
    );

    return LayoutBuilder(
      key: const ValueKey('stats'),
      builder: (context, constraints) {
        // 在窄屏幕上使用垂直布局，宽屏幕上使用水平布局
        bool useHorizontalLayout = constraints.maxWidth > 600;
        return useHorizontalLayout
            ? Row(
                children: [
                  Expanded(child: _buildPieChart(filteredData, totalMessages)),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildLegend(filteredData, totalMessages)),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  children: [
                    SizedBox(
                      height: 300,
                      child: _buildPieChart(filteredData, totalMessages),
                    ),
                    const Divider(height: 1),
                    _buildLegend(filteredData, totalMessages),
                  ],
                ),
              );
      },
    );
  }

  Widget _buildPieChart(List<MapEntry<int, int>> data, int total) {
    return PieChart(
      PieChartData(
        pieTouchData: PieTouchData(
          touchCallback: (FlTouchEvent event, pieTouchResponse) {
            setState(() {
              if (!event.isInterestedForInteractions ||
                  pieTouchResponse == null ||
                  pieTouchResponse.touchedSection == null) {
                _touchedIndex = -1;
                return;
              }
              _touchedIndex =
                  pieTouchResponse.touchedSection!.touchedSectionIndex;
            });
          },
        ),
        borderData: FlBorderData(show: false),
        sectionsSpace: 2,
        centerSpaceRadius: 60,
        sections: List.generate(data.length, (i) {
          final entry = data[i];
          final type = entry.key;
          final count = entry.value;
          final percentage = (count / total * 100);
          final isTouched = i == _touchedIndex;
          final fontSize = isTouched ? 18.0 : 14.0;
          final radius = isTouched ? 70.0 : 60.0;
          final typeInfo =
              _mediaTypeInfo[type] ?? {'name': '其他', 'color': Colors.grey};

          return PieChartSectionData(
            color: typeInfo['color'],
            value: count.toDouble(),
            title: '${percentage.toStringAsFixed(1)}%',
            radius: radius,
            titleStyle: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLegend(List<MapEntry<int, int>> data, int total) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: data.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 40),
      itemBuilder: (context, index) {
        final entry = data[index];
        final type = entry.key;
        final count = entry.value;
        final typeInfo =
            _mediaTypeInfo[type] ??
            {
              'name': Message.getTypeDescriptionFromInt(type),
              'color': Colors.grey,
              'icon': Icons.help_outline,
            };
        final percentage = (count / total * 100).toStringAsFixed(1);
        final isTouched = index == _touchedIndex;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isTouched
                ? (typeInfo['color'] as Color).withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              Icon(typeInfo['icon'], color: typeInfo['color'], size: 20),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  typeInfo['name'],
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '$count 条',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 60,
                child: Text(
                  '($percentage%)',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
