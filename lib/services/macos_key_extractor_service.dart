// macOS 微信密钥提取服务
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'logger_service.dart';

/// macOS 微信密钥提取服务
/// 使用 lldb 调试器从微信进程内存中提取数据库解密密钥
class MacOSKeyExtractorService {
  static const String _tag = 'MacOSKeyExtractor';

  /// 检查是否可以提取密钥（SIP 状态、微信进程等）
  Future<KeyExtractorStatus> checkStatus() async {
    if (!Platform.isMacOS) {
      return KeyExtractorStatus(
        canExtract: false,
        message: '此功能仅支持 macOS',
        sipEnabled: false,
        wechatRunning: false,
      );
    }

    // 检查 SIP 状态
    final sipEnabled = await _checkSipEnabled();

    // 检查微信进程
    final wechatPid = await _findWeChatProcess();
    final wechatRunning = wechatPid != null;

    if (sipEnabled) {
      return KeyExtractorStatus(
        canExtract: false,
        message:
            '系统完整性保护 (SIP) 已启用，无法自动提取密钥。\n\n'
            '请在恢复模式下运行 "csrutil disable" 禁用 SIP，或手动输入密钥。',
        sipEnabled: true,
        wechatRunning: wechatRunning,
        wechatPid: wechatPid,
      );
    }

    if (!wechatRunning) {
      return KeyExtractorStatus(
        canExtract: false,
        message: '未检测到微信进程，请先启动微信并登录',
        sipEnabled: false,
        wechatRunning: false,
      );
    }

    return KeyExtractorStatus(
      canExtract: true,
      message: '可以提取密钥',
      sipEnabled: false,
      wechatRunning: true,
      wechatPid: wechatPid,
    );
  }

  /// 提取微信数据库密钥
  /// 返回 64 字符的十六进制密钥字符串，失败返回 null
  Future<String?> extractKey() async {
    if (!Platform.isMacOS) {
      await logger.error(_tag, '密钥提取仅支持 macOS');
      return null;
    }

    final status = await checkStatus();
    if (!status.canExtract) {
      await logger.error(_tag, '无法提取密钥: ${status.message}');
      return null;
    }

    try {
      await logger.info(_tag, '开始提取微信密钥，PID=${status.wechatPid}');

      // 使用 lldb 脚本提取密钥
      final key = await _extractKeyWithLldb(status.wechatPid!);

      if (key != null && key.length == 64) {
        await logger.info(_tag, '密钥提取成功');
        return key;
      }

      await logger.warning(_tag, '密钥格式无效: ${key?.length ?? 0} 字符');
      return null;
    } catch (e, stackTrace) {
      await logger.error(_tag, '密钥提取失败', e, stackTrace);
      return null;
    }
  }

  /// 检查 SIP 是否启用
  Future<bool> _checkSipEnabled() async {
    try {
      final result = await Process.run('csrutil', ['status']);
      final output = result.stdout.toString().toLowerCase();
      return output.contains('enabled') && !output.contains('disabled');
    } catch (e) {
      await logger.warning(_tag, '无法检查 SIP 状态: $e');
      return true; // 默认假设启用
    }
  }

  /// 查找微信进程 ID
  Future<int?> _findWeChatProcess() async {
    try {
      final result = await Process.run('pgrep', ['-x', 'WeChat']);
      if (result.exitCode == 0) {
        final pidStr = result.stdout.toString().trim();
        return int.tryParse(pidStr);
      }
    } catch (e) {
      await logger.warning(_tag, '查找微信进程失败: $e');
    }
    return null;
  }

  /// 使用 lldb 提取密钥
  Future<String?> _extractKeyWithLldb(int pid) async {
    // 创建 lldb 命令脚本
    final tempDir = Directory.systemTemp;
    final scriptFile = File(p.join(tempDir.path, 'wechat_key_extract.lldb'));
    final outputFile = File(p.join(tempDir.path, 'wechat_key_output.txt'));

    try {
      // 写入 lldb 脚本
      // 使用 Python 脚本来解析内存并输出密钥
      await scriptFile.writeAsString('''
# LLDB 密钥提取脚本
process handle SIGSTOP -n true -p true -s false

# 设置断点在 sqlite3_key
breakpoint set --name sqlite3_key --one-shot true

# 设置断点动作：读取密钥并输出
breakpoint command add 1
script
import lldb
frame = lldb.frame
# 第二个参数 (rsi on x86, x1 on ARM) 包含密钥指针
arch = frame.GetThread().GetProcess().GetTarget().GetTriple()
if 'arm64' in arch or 'aarch64' in arch:
    key_ptr = frame.FindRegister('x1').GetValueAsUnsigned()
else:
    key_ptr = frame.FindRegister('rsi').GetValueAsUnsigned()

# 读取 32 字节密钥
error = lldb.SBError()
key_data = frame.GetThread().GetProcess().ReadMemory(key_ptr, 32, error)
if error.Success():
    key_hex = ''.join(format(b, '02x') for b in key_data)
    with open('${outputFile.path}', 'w') as f:
        f.write(key_hex)
    print('KEY_EXTRACTED:', key_hex)
else:
    print('KEY_ERROR:', error.GetCString())
DONE

# 继续执行，等待断点触发
continue

# 等待几秒后退出
script import time; time.sleep(3)
quit
''');

      // 运行 lldb
      await logger.info(_tag, '正在运行 lldb 提取密钥...');

      final result =
          await Process.run(
            'lldb',
            ['-p', pid.toString(), '-s', scriptFile.path],
            stderrEncoding: utf8,
            stdoutEncoding: utf8,
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw TimeoutException('lldb 执行超时', const Duration(seconds: 30));
            },
          );

      await logger.debug(_tag, 'lldb 输出: ${result.stdout}');

      // 检查输出文件
      if (await outputFile.exists()) {
        final key = (await outputFile.readAsString()).trim();
        if (key.isNotEmpty && key.length == 64 && _isValidHex(key)) {
          return key;
        }
      }

      // 从 stdout 解析
      final stdout = result.stdout.toString();
      final keyMatch = RegExp(
        r'KEY_EXTRACTED:\s*([a-fA-F0-9]{64})',
      ).firstMatch(stdout);
      if (keyMatch != null) {
        return keyMatch.group(1);
      }

      return null;
    } finally {
      // 清理临时文件
      try {
        if (await scriptFile.exists()) await scriptFile.delete();
        if (await outputFile.exists()) await outputFile.delete();
      } catch (_) {}
    }
  }

  bool _isValidHex(String s) {
    return RegExp(r'^[a-fA-F0-9]+$').hasMatch(s);
  }
}

/// 密钥提取器状态
class KeyExtractorStatus {
  final bool canExtract;
  final String message;
  final bool sipEnabled;
  final bool wechatRunning;
  final int? wechatPid;

  KeyExtractorStatus({
    required this.canExtract,
    required this.message,
    required this.sipEnabled,
    required this.wechatRunning,
    this.wechatPid,
  });
}

class TimeoutException implements Exception {
  final String message;
  final Duration timeout;
  TimeoutException(this.message, this.timeout);
  @override
  String toString() => 'TimeoutException: $message (after $timeout)';
}
