// 文件: lib/services/group_chat_service.dart

import 'dart:core';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/message.dart';
import 'database_service.dart';

const Set<String> _chineseStopwords = {
  '的',
  '了',
  '我',
  '你',
  '他',
  '她',
  '它',
  '们',
  '是',
  '在',
  '也',
  '有',
  '就',
  '不',
  '都',
  '而',
  '及',
  '与',
  '且',
  '或',
  '个',
  '这',
  '那',
  '一',
  '啊',
  '哦',
  '嗯',
  '呢',
  '吧',
  '呀',
  '嘛',
  '哈',
  '嘿',
  '哼',
  '哎',
  '唉',
  '一个',
  '一些',
  '什么',
  '那个',
  '这个',
  '怎么',
  '我们',
  '你们',
  '他们',
  '然后',
  '但是',
  '所以',
  '因为',
  '知道',
  '觉得',
  '就是',
  '没有',
  '现在',
  '不是',
  '可以',
  '这么',
  '那么',
  '还有',
  '如果',
  '的话',
  '可能',
  '出来',
  '还是',
  '一样',
  '这样',
  '那样',
  '自己',
  '之后',
  '之前',
  '时候',
  '东西',
  '什么样',
  '卧槽',
  '我靠',
  '淦',
};

class GroupChatInfo {
  final String username;
  final String displayName;
  final int memberCount;
  final String? avatarUrl;

  GroupChatInfo({
    required this.username,
    required this.displayName,
    required this.memberCount,
    this.avatarUrl,
  });
}

class GroupMember {
  final String username;
  final String displayName;
  final String? avatarUrl;
  GroupMember({
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });
  Map<String, dynamic> toJson() => {
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
  };
}

class GroupMessageRank {
  final GroupMember member;
  final int messageCount;
  GroupMessageRank({required this.member, required this.messageCount});
}

class DailyMessageCount {
  final DateTime date;
  final int count;
  DailyMessageCount({required this.date, required this.count});
}

class GroupChatService {
  final DatabaseService _databaseService;

  GroupChatService(this._databaseService);

  Future<Map<int, int>> getGroupMediaTypeStats({
    required String chatroomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    // --- 服务层日志 ---

    return await _databaseService.getGroupMediaTypeStats(
      chatroomId: chatroomId,
      startDate: startDate,
      endDate: endDate,
    );
  }

  // 新增：群聊活跃时段分析
  Future<Map<int, int>> getGroupActiveHours({
    required String chatroomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    // 直接调用底层的 DatabaseService 方法
    return await _databaseService.getGroupActiveHours(
      chatroomId: chatroomId,
      startDate: startDate,
      endDate: endDate,
    );
  }

  // --- 新增：专门用于从中文文本中提取词语（二元组合）的方法 ---
  List<String> _tokenizeChineseForWords(String text) {
    final words = <String>[];
    // 正则表达式只匹配连续的汉字块
    final chinesePattern = RegExp(r'[\u4e00-\u9fa5]+');

    final matches = chinesePattern.allMatches(text);
    for (final match in matches) {
      final segment = match.group(0)!;
      // 只对长度大于等于2的汉字块进行处理
      if (segment.length >= 2) {
        // 使用滑动窗口生成二元词组 (bigrams)
        for (int i = 0; i < segment.length - 1; i++) {
          words.add(segment.substring(i, i + 2));
        }
      }
      // 忽略单个汉字
    }
    return words;
  }

  // --- 提取其他令牌（英文、数字、Emoji）的方法 ---
  List<String> _tokenizeOthers(String text) {
    final regex = RegExp(
      r'([\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]+)|([a-zA-Z0-9]+)',
      unicode: true,
    );

    return regex
        .allMatches(text)
        .map((m) => m.group(0)!.toLowerCase())
        .toList();
  }

  Future<Map<String, int>> getMemberWordFrequency({
    required String chatroomId,
    required String memberUsername,
    required DateTime startDate,
    required DateTime endDate,
    int topN = 100,
  }) async {
    final endOfDay = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      23,
      59,
      59,
    );

    try {
      final messages = await _databaseService.getMessagesByDate(
        chatroomId,
        startDate.millisecondsSinceEpoch ~/ 1000,
        endOfDay.millisecondsSinceEpoch ~/ 1000,
      );

      final textContent = messages
          .where(
            (m) =>
                m.senderUsername == memberUsername &&
                (m.isTextMessage || m.localType == 244813135921) &&
                m.displayContent.isNotEmpty &&
                !m.displayContent.startsWith('[') &&
                !m.displayContent.startsWith('<?xml') &&
                !m.displayContent.contains('<msg>'),
          )
          .map((m) => m.displayContent)
          .join(' ');

      if (textContent.isEmpty) {
        return {};
      }

      // --- 使用新的分词组合策略 ---
      final List<String> chineseWords = _tokenizeChineseForWords(textContent);
      final List<String> otherTokens = _tokenizeOthers(textContent);

      final allTokens = [...chineseWords, ...otherTokens];

      final wordCounts = <String, int>{};
      for (final token in allTokens) {
        // 过滤条件：长度至少为2，且不是停用词
        if (token.length >= 2 && !_chineseStopwords.contains(token)) {
          wordCounts[token] = (wordCounts[token] ?? 0) + 1;
        }
      }

      if (wordCounts.isEmpty) {
        return {};
      }

      final sortedEntries = wordCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topEntries = sortedEntries.take(topN);

      return Map.fromEntries(topEntries);
    } catch (e) {
      return {};
    }
  }

  Future<List<GroupChatInfo>> getGroupChats() async {
    final sessions = await _databaseService.getSessions();
    final groupSessions = sessions.where((s) => s.isGroup).toList();
    final List<GroupChatInfo> result = [];
    final usernames = groupSessions.map((s) => s.username).toList();
    final displayNames = await _databaseService.getDisplayNames(usernames);

    Map<String, String> avatarUrls = {};
    try {
      avatarUrls = await _databaseService.getAvatarUrls(usernames);
    } catch (e) {
      // 忽略头像获取错误
    }

    for (final session in groupSessions) {
      final memberCount = await _getGroupMemberCount(session.username);
      result.add(
        GroupChatInfo(
          username: session.username,
          displayName: displayNames[session.username] ?? session.username,
          memberCount: memberCount,
          avatarUrl: avatarUrls[session.username],
        ),
      );
    }
    result.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    return result;
  }

  Future<int> _getGroupMemberCount(String chatroomId) async {
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) return 0;
      final db = await databaseFactoryFfi.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final result = await db.rawQuery(
          '''
          SELECT COUNT(*) as count FROM chatroom_member 
          WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?)
          ''',
          [chatroomId],
        );
        return (result.first['count'] as int?) ?? 0;
      } finally {
        await db.close();
      }
    } catch (e) {
      return 0;
    }
  }

  Future<List<GroupMember>> getGroupMembers(String chatroomId) async {
    final List<GroupMember> members = [];
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) return [];

      final db = await databaseFactoryFfi.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(readOnly: true),
      );

      try {
        final memberRows = await db.rawQuery(
          '''
          SELECT n.username, c.small_head_url FROM chatroom_member m
          JOIN name2id n ON m.member_id = n.rowid
          LEFT JOIN contact c ON n.username = c.username
          WHERE m.room_id = (SELECT rowid FROM name2id WHERE username = ?)
          ''',
          [chatroomId],
        );

        if (memberRows.isEmpty) return [];

        final usernames = memberRows
            .where((row) => row['username'] != null)
            .map((row) => row['username'] as String)
            .toList();

        final displayNames = await _databaseService.getDisplayNames(usernames);

        final avatarMap = {
          for (var row in memberRows)
            if (row['username'] != null)
              row['username'] as String: row['small_head_url'] as String?,
        };

        for (final username in usernames) {
          members.add(
            GroupMember(
              username: username,
              displayName: displayNames[username] ?? username,
              avatarUrl: avatarMap[username],
            ),
          );
        }
      } finally {
        await db.close();
      }
    } catch (e) {
      // Failed to get members, return empty list
    }
    return members;
  }

  Future<List<GroupMessageRank>> getGroupMessageRanking({
    required String chatroomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final endOfDay = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      23,
      59,
      59,
    );
    final messages = await _databaseService.getMessagesByDate(
      chatroomId,
      startDate.millisecondsSinceEpoch ~/ 1000,
      endOfDay.millisecondsSinceEpoch ~/ 1000,
    );
    final Map<String, int> messageCounts = {};
    final Set<String> senderUsernames = {};
    for (final Message message in messages) {
      if (message.senderUsername != null &&
          message.senderUsername!.isNotEmpty) {
        final username = message.senderUsername!;
        messageCounts[username] = (messageCounts[username] ?? 0) + 1;
        senderUsernames.add(username);
      }
    }
    if (senderUsernames.isEmpty) return [];

    final allMembers = await getGroupMembers(chatroomId);
    final memberMap = {for (var m in allMembers) m.username: m};

    final List<GroupMessageRank> ranking = [];
    messageCounts.forEach((username, count) {
      final member =
          memberMap[username] ??
          GroupMember(username: username, displayName: username);
      ranking.add(GroupMessageRank(member: member, messageCount: count));
    });
    ranking.sort((a, b) => b.messageCount.compareTo(a.messageCount));
    return ranking;
  }

  Future<List<DailyMessageCount>> getMemberDailyMessageCount({
    required String chatroomId,
    required String memberUsername,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final endOfDay = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      23,
      59,
      59,
    );
    final messages = await _databaseService.getMessagesByDate(
      chatroomId,
      startDate.millisecondsSinceEpoch ~/ 1000,
      endOfDay.millisecondsSinceEpoch ~/ 1000,
    );
    final memberMessages = messages.where(
      (m) => m.senderUsername == memberUsername,
    );
    final Map<String, int> dailyCounts = {};
    final dateFormat = DateFormat('yyyy-MM-dd');
    for (final message in memberMessages) {
      final dateStr = dateFormat.format(
        DateTime.fromMillisecondsSinceEpoch(message.createTime * 1000),
      );
      dailyCounts[dateStr] = (dailyCounts[dateStr] ?? 0) + 1;
    }
    final result = dailyCounts.entries.map((entry) {
      return DailyMessageCount(
        date: DateTime.parse(entry.key),
        count: entry.value,
      );
    }).toList();
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }
}
