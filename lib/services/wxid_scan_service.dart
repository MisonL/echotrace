import 'dart:io';

import 'package:path/path.dart' as p;

/// 微信账号候选项
class WxidCandidate {
  const WxidCandidate({
    required this.wxid,
    required this.modified,
    required this.path,
  });

  final String wxid;
  final DateTime modified;
  final String path;
}

/// 通过文件扫描 wxid
class WxidScanService {
  /// 扫描可能的微信目录，返回候选列表（按修改时间倒序）
  Future<List<WxidCandidate>> scanWxids({
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在从路径扫描微信账号...');
    final roots = await _candidateRoots();
    final loginTimes = await _loadLoginTimes();
    final bestByWxid = <String, WxidCandidate>{};

    for (final root in roots) {
      onProgress?.call('检查目录: $root');
      final dir = Directory(root);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        final normalized = _normalizeWxid(name);
        if (normalized == null) continue;

        final keyInfo = File(p.join(entity.path, 'key_info.dat'));
        final dbStorageDir = Directory(p.join(entity.path, 'db_storage'));

        // 没有关键文件或 db_storage 的目录忽略，避免误报
        if (!await dbStorageDir.exists() && !await keyInfo.exists()) {
          continue;
        }

        DateTime modified;
        if (await keyInfo.exists()) {
          modified = (await keyInfo.stat()).modified;
        } else {
          modified = (await entity.stat()).modified;
        }
        // 优先使用 login 目录中的登录时间
        modified = loginTimes[normalized] ?? modified;
        final candidate = WxidCandidate(
          // 保留完整目录名用于后续拼接路径
          wxid: name,
          modified: modified,
          path: entity.path,
        );

        final prev = bestByWxid[normalized];
        if (prev == null || candidate.modified.isAfter(prev.modified)) {
          bestByWxid[normalized] = candidate;
        }
      }
    }

    final candidates = bestByWxid.values.toList();
    candidates.sort((a, b) => b.modified.compareTo(a.modified));
    if (candidates.isEmpty) {
      onProgress?.call('未在路径中找到 wxid 目录');
    } else {
      onProgress?.call('找到 ${candidates.length} 个账号候选');
    }
    return candidates;
  }

  /// 从 login 目录读取各账号最近登录时间
  Future<Map<String, DateTime>> _loadLoginTimes() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      if (userProfile.isEmpty) return {};

      final loginRoot = Directory(
        p.join(
          userProfile,
          'AppData',
          'Roaming',
          'Tencent',
          'xwechat',
          'login',
        ),
      );
      if (!await loginRoot.exists()) return {};

      final Map<String, DateTime> result = {};
      await for (final entity in loginRoot.list()) {
        if (entity is! Directory) continue;
        final wxid = _normalizeWxid(p.basename(entity.path));
        if (wxid == null) continue;

        final latest = await _latestModified(entity);
        result[wxid] = latest;
      }
      return result;
    } else if (Platform.isMacOS) {
      // macOS 没有类似 Windows 的 login 目录结构
      // 直接返回空，使用目录修改时间
      return {};
    }
    return {};
  }

  Future<DateTime> _latestModified(Directory dir) async {
    DateTime latest = (await dir.stat()).modified;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(latest)) {
          latest = stat.modified;
        }
      } catch (_) {
        continue;
      }
    }
    return latest;
  }

  /// 返回优先的 WeChat 目录
  Future<String?> findWeChatFilesRoot() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      if (userProfile.isEmpty) return null;

      // 数据库根目录优先顺序：xwechat_files -> WeChat Files
      final dbRoots = <String>[
        p.join(userProfile, 'Documents', 'xwechat_files'),
        p.join(userProfile, 'Documents', 'WeChat Files'),
      ];

      for (final root in dbRoots) {
        if (await Directory(root).exists()) return root;
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return null;

      // macOS 微信数据路径 - 优先 xwechat_files
      final xwechatFiles = p.join(
        home,
        'Library',
        'Containers',
        'com.tencent.xinWeChat',
        'Data',
        'Documents',
        'xwechat_files',
      );

      if (await Directory(xwechatFiles).exists()) {
        return xwechatFiles;
      }

      // 备选：Application Support 路径
      final wechatContainer = p.join(
        home,
        'Library',
        'Containers',
        'com.tencent.xinWeChat',
        'Data',
        'Library',
        'Application Support',
        'com.tencent.xinWeChat',
      );

      if (await Directory(wechatContainer).exists()) {
        return wechatContainer;
      }
    }

    return null;
  }

  /// 组合可能的根目录
  Future<List<String>> _candidateRoots() async {
    final roots = <String>[];

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      if (userProfile.isNotEmpty) {
        // 微信4的路径
        roots.add(p.join(userProfile, 'Documents', 'xwechat_files'));
        // 微信3的路径
        roots.add(p.join(userProfile, 'Documents', 'WeChat Files'));
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        // macOS 微信 xwechat_files 路径（与 Windows 结构类似）
        final xwechatFiles = p.join(
          home,
          'Library',
          'Containers',
          'com.tencent.xinWeChat',
          'Data',
          'Documents',
          'xwechat_files',
        );

        if (await Directory(xwechatFiles).exists()) {
          roots.add(xwechatFiles);
        }
      }
    }

    return roots;
  }

  /// 纠正 wxid 目录名，去掉末尾的后缀
  String? _normalizeWxid(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.toLowerCase().startsWith('wxid_')) {
      final match = RegExp(
        r'^(wxid_[^_]+)',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (match != null) return match.group(1);
      return trimmed;
    }

    final suffixMatch = RegExp(r'^(.+)_([a-zA-Z0-9]{4})$').firstMatch(trimmed);
    if (suffixMatch != null) return suffixMatch.group(1);

    return trimmed;
  }
}
