import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_lame/flutter_lame.dart';
import 'package:path/path.dart' as p;
import '../services/app_path_service.dart';

import '../models/message.dart';
import '../utils/path_utils.dart';
import 'database_service.dart';
import 'bulk_worker_pool.dart';
import 'logger_service.dart';

/// 语音消息服务：从 media_[0-99].db 中读取 voice_data，调用内置解码器转为 PCM，再编码为 MP3 缓存到本地。
class VoiceMessageService {
  VoiceMessageService(this.databaseService);

  final DatabaseService databaseService;
  BulkWorkerPool? bulkPool;
  final Map<String, Future<File>> _ongoingDecodes = {};
  final Map<String, Future<int?>> _ongoingDuration = {};
  final StreamController<String> _decodeFinishedController =
      StreamController<String>.broadcast();

  static const _sampleRate = 24000;
  static const _assetsSilk = 'assets/silk_v3_decoder.exe';

  Stream<String> get decodeFinishedStream => _decodeFinishedController.stream;

  /// 检查本地是否已有解码后的 mp3
  Future<File?> findExistingVoiceFile(
    Message message,
    String sessionUsername,
  ) async {
    final outputFile = await _buildOutputFile(message, sessionUsername);
    if (await outputFile.exists()) {
      await logger.debug(
        'VoiceMessageService',
        'hit cached mp3: ${outputFile.path}',
      );
      return outputFile;
    }

    // 兼容旧版本已生成的 wav
    final legacyWav = await _buildOutputFile(
      message,
      sessionUsername,
      extension: '.wav',
    );
    if (await legacyWav.exists()) {
      await logger.debug(
        'VoiceMessageService',
        'hit legacy wav: ${legacyWav.path}',
      );
      return legacyWav;
    }
    return null;
  }

  /// 确保语音已解码，如未解码则执行解码并返回 mp3 文件。
  Future<File> ensureVoiceDecoded(
    Message message,
    String sessionUsername,
  ) async {
    if (message.isSend == 1) {
      throw SelfSentVoiceNotSupportedException();
    }

    final outputFile = await _buildOutputFile(message, sessionUsername);
    if (await outputFile.exists()) {
      await logger.debug(
        'VoiceMessageService',
        'ensureVoiceDecoded: already exists ${outputFile.path}',
      );
      _notifyDecodeFinished(outputFile);
      return outputFile;
    }

    final key = outputFile.path;
    if (_ongoingDecodes.containsKey(key)) {
      await logger.debug(
        'VoiceMessageService',
        'ensureVoiceDecoded: join ongoing $key',
      );
      return _ongoingDecodes[key]!;
    }

    final future = _decodeAndSave(message, sessionUsername, outputFile)
        .then((file) {
          _notifyDecodeFinished(file);
          return file;
        })
        .whenComplete(() => _ongoingDecodes.remove(key));
    _ongoingDecodes[key] = future;
    return future;
  }

  /// 获取解码后文件的路径（不触发解码）
  Future<File> getOutputFile(Message message, String sessionUsername) {
    return _buildOutputFile(message, sessionUsername);
  }

  /// 获取语音时长（秒），仅依赖数据库中的 voice_data，不保存文件。
  Future<int?> fetchDurationSeconds(Message message) async {
    final key =
        'dur_${message.createTime}_${message.localId}_${message.senderUsername ?? ""}';
    if (_ongoingDuration.containsKey(key)) {
      return _ongoingDuration[key]!;
    }
    final future = _calcDuration(message).whenComplete(() {
      _ongoingDuration.remove(key);
    });
    _ongoingDuration[key] = future;
    return future;
  }

  Future<File> _decodeAndSave(
    Message message,
    String sessionUsername,
    File outputFile,
  ) async {
    final senderWxid = message.senderUsername;
    final myWxid = message.myWxid;
    final lookupWxid = _voiceLookupWxidCandidate(message);
    if (lookupWxid == null || lookupWxid.isEmpty) {
      throw Exception('未找到语音关联 wxid，无法定位语音数据');
    }

    final voiceBytes = await databaseService.fetchVoiceData(
      senderWxid: lookupWxid,
      createTime: message.createTime,
    );
    if (voiceBytes == null || voiceBytes.isEmpty) {
      throw Exception(
        '未在媒体数据库中找到语音原始数据（create_time=${message.createTime}, '
        'lookup=$lookupWxid, sender=$senderWxid, my=$myWxid）',
      );
    }

    final binaries = await _ensureBinariesReady();
    await logger.info(
      'VoiceMessageService',
      'start decode: sender=$senderWxid create=${message.createTime} '
          'localId=${message.localId} bytes=${voiceBytes.length} '
          'lookupWxid=$lookupWxid silk=${binaries.silkDecoder}',
    );

    final tempDir = await AppPathService.getDocumentsDirectory();
    final tempTag = lookupWxid.replaceAll(RegExp(r'[^a-zA-Z0-9_@.-]'), '_');
    final silkPath = PathUtils.join(
      tempDir.path,
      'voice_${message.createTime}_$tempTag.silk',
    );
    final pcmPath = PathUtils.replaceExtension(silkPath, '.pcm');
    final tempMp3Path = PathUtils.replaceExtension(silkPath, '.mp3');

    await File(silkPath).writeAsBytes(voiceBytes, flush: true);

    final silkEnv = _buildProcessEnv(binaries.silkDecoder);

    // Silk -> PCM
    final decodeResult = await _runProcessWithTimeout(
      binaries.silkDecoder,
      [silkPath, pcmPath, '-Fs_API', '$_sampleRate'],
      workingDirectory: p.dirname(binaries.silkDecoder),
      environment: silkEnv,
      timeout: const Duration(seconds: 45),
    );
    if (decodeResult.exitCode != 0 || !File(pcmPath).existsSync()) {
      final stderrMsg = decodeResult.stderr?.toString() ?? '';
      throw Exception('Silk 解码失败: $stderrMsg');
    }

    // PCM -> MP3（使用内置 LAME 编码）
    await _encodePcmToMp3(
      inputPcmPath: pcmPath,
      outputMp3Path: tempMp3Path,
      sampleRate: _sampleRate,
      channels: 1,
    );

    await logger.info(
      'VoiceMessageService',
      'decode success -> ${outputFile.path}',
    );

    await PathUtils.ensureParentExists(outputFile.path);
    await File(tempMp3Path).copy(outputFile.path);

    // 清理临时文件
    try {
      File(silkPath).deleteSync();
      File(pcmPath).deleteSync();
      File(tempMp3Path).deleteSync();
    } catch (_) {}

    await logger.info('VoiceMessageService', '语音解码完成: ${outputFile.path}');
    _notifyDecodeFinished(outputFile);

    return outputFile;
  }

  void _notifyDecodeFinished(File outputFile) {
    try {
      if (!_decodeFinishedController.isClosed) {
        _decodeFinishedController.add(outputFile.path);
      }
    } catch (_) {}
  }

  Future<ProcessResult> _runProcessWithTimeout(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      exitCode = -1;
    }
    String stdoutText = '';
    String stderrText = '';
    try {
      stdoutText = await stdoutFuture.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      stdoutText = '';
    }
    try {
      stderrText = await stderrFuture.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      stderrText = '';
    }
    return ProcessResult(process.pid, exitCode, stdoutText, stderrText);
  }

  Future<_BinaryPaths> _ensureBinariesReady() async {
    // macOS 暂不支持语音解码（需要 silk_v3_decoder 的 macOS 版本）
    if (Platform.isMacOS) {
      throw VoiceDecodingNotSupportedException(
        'macOS 暂不支持语音消息解码。'
        '语音解码需要 silk_v3_decoder 的 macOS 版本，目前仅支持 Windows。',
      );
    }
    
    if (!Platform.isWindows) {
      throw VoiceDecodingNotSupportedException(
        '当前平台不支持语音消息解码。',
      );
    }

    final docs = await AppPathService.getDocumentsDirectory();
    final binDir = Directory(PathUtils.join(docs.path, 'EchoTrace', 'bin'));
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }

    final silkPath = await _ensureBinary(
      assetPath: _assetsSilk,
      fileName: 'silk_v3_decoder.exe',
      binDir: binDir,
    );

    return _BinaryPaths(silkDecoder: silkPath);
  }

  Future<String> _ensureBinary({
    required String assetPath,
    required String fileName,
    required Directory binDir,
  }) async {
    // 1) 优先使用打包后可直接访问的文件（如 Windows data/flutter_assets/assets）
    final packed = _tryLocatePackedBinary(fileName);
    if (packed != null) {
      return packed;
    }

    // 2) fallback：从 assets 解包到可写目录
    final dest = File(PathUtils.join(binDir.path, fileName));
    if (await dest.exists()) {
      return dest.path;
    }

    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }

  /// 尝试找到 Flutter 打包输出目录中的二进制（无需解包）
  String? _tryLocatePackedBinary(String fileName) {
    try {
      final execDir = p.dirname(Platform.resolvedExecutable);
      final parentDir = p.dirname(execDir);

      final bases = <String>{execDir, parentDir};
      final candidates = <String>[
        for (final base in bases) ...[
          // 同目录（便携版/本地开发）
          PathUtils.join(base, fileName),
          // Windows 桌面默认结构：<exe>/data/flutter_assets/assets/xxx
          PathUtils.join(
            PathUtils.join(PathUtils.join(base, 'data'), 'flutter_assets'),
            'assets',
            fileName,
          ),
          // 兼容部分打包脚本：直接位于 flutter_assets 下
          PathUtils.join(
            PathUtils.join(base, 'data'),
            'flutter_assets',
            fileName,
          ),
        ],
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          unawaited(
            logger.debug(
              'VoiceMessageService',
              'use packed binary: $path (resolvedExecutable=$execDir)',
            ),
          );
          return path;
        }
      }
      unawaited(
        logger.debug(
          'VoiceMessageService',
          'packed binary not found; candidates=${candidates.join(", ")}',
        ),
      );
    } catch (_) {}
    return null;
  }

  Map<String, String>? _buildProcessEnv(String binaryPath) {
    try {
      final binDir = p.dirname(binaryPath);
      final dllDir = PathUtils.join(binDir, 'dll');
      final env = Map<String, String>.from(Platform.environment);
      final pathKey = env.keys.firstWhere(
        (k) => k.toUpperCase() == 'PATH',
        orElse: () => 'PATH',
      );
      final pathSep = Platform.isWindows ? ';' : ':';
      final currentPath = env[pathKey] ?? '';
      final additions = [binDir, if (Directory(dllDir).existsSync()) dllDir];
      final extra = additions.join(pathSep);
      env[pathKey] = [
        extra,
        if (currentPath.isNotEmpty) currentPath,
      ].where((e) => e.isNotEmpty).join(pathSep);
      return env;
    } catch (_) {
      return null;
    }
  }

  Future<File> _buildOutputFile(
    Message message,
    String sessionUsername, {
    String extension = '.mp3',
  }) async {
    final docs = await AppPathService.getDocumentsDirectory();
    final voicesDir = Directory(
      PathUtils.join(docs.path, 'EchoTrace', 'voice', sessionUsername),
    );
    if (!await voicesDir.exists()) {
      await voicesDir.create(recursive: true);
    }

    final sender = message.senderUsername ?? message.myWxid ?? 'unknown';
    final fileName =
        '${message.createTime}_${message.localId}_${sender.replaceAll(RegExp(r"[^a-zA-Z0-9_@.-]"), "_")}$extension';
    return File(PathUtils.join(voicesDir.path, fileName));
  }

  Future<void> _encodePcmToMp3({
    required String inputPcmPath,
    required String outputMp3Path,
    required int sampleRate,
    required int channels,
  }) async {
    final pool = bulkPool;
    if (pool != null && !pool.isClosed) {
      await pool.encodePcmToMp3(
        inputPcmPath: inputPcmPath,
        outputMp3Path: outputMp3Path,
        sampleRate: sampleRate,
        channels: channels,
      );
      return;
    }

    // 使用 Isolate 进行 MP3 编码，避免批量任务时阻塞 UI。
    await Isolate.run(() async {
      final pcmFile = File(inputPcmPath);
      if (!pcmFile.existsSync()) {
        throw Exception('未找到 PCM 文件: $inputPcmPath');
      }

      final encoder = LameMp3EncoderSync(
        sampleRate: sampleRate,
        numChannels: channels,
      );
      final sink = File(outputMp3Path).openWrite();
      Uint8List? pendingByte;

      try {
        await for (final chunk in pcmFile.openRead()) {
          if (chunk.isEmpty) continue;
          Uint8List data;
          if (pendingByte != null && pendingByte.isNotEmpty) {
            data = Uint8List(pendingByte.length + chunk.length)
              ..setRange(0, pendingByte.length, pendingByte)
              ..setRange(
                pendingByte.length,
                pendingByte.length + chunk.length,
                chunk,
              );
            pendingByte = null;
          } else {
            data = Uint8List.fromList(chunk);
          }

          final evenLength = data.length & ~1; // 保证 2 字节对齐
          if (evenLength != data.length) {
            pendingByte = data.sublist(data.length - 1);
          }
          if (evenLength == 0) continue;

          final sampleCount = evenLength ~/ 2;
          final samples = Int16List.view(
            data.buffer,
            data.offsetInBytes,
            sampleCount,
          );

          final frame = encoder.encode(leftChannel: samples);
          if (frame.isNotEmpty) {
            sink.add(frame);
          }
        }

        final last = encoder.flush();
        if (last.isNotEmpty) {
          sink.add(last);
        }
        await sink.flush();
      } finally {
        await sink.close();
        try {
          encoder.close();
        } catch (_) {}
      }

      final outFile = File(outputMp3Path);
      if (!outFile.existsSync() || outFile.lengthSync() == 0) {
        throw Exception('MP3 编码失败: 未生成输出文件');
      }
    });
  }

  Future<int?> _calcDuration(Message message) async {
    final lookupWxid = _voiceLookupWxidCandidate(message);
    if (lookupWxid == null || lookupWxid.isEmpty) return null;

    final voiceBytes = await databaseService.fetchVoiceData(
      senderWxid: lookupWxid,
      createTime: message.createTime,
    );
    if (voiceBytes == null || voiceBytes.isEmpty) return null;

    final binaries = await _ensureBinariesReady();
    final tempDir = await AppPathService.getDocumentsDirectory();
    final silkPath = PathUtils.join(
      tempDir.path,
      'voice_${message.createTime}_${lookupWxid}_dur.silk',
    );
    final pcmPath = PathUtils.replaceExtension(silkPath, '.pcm');

    await File(silkPath).writeAsBytes(voiceBytes, flush: true);

    final silkEnv = _buildProcessEnv(binaries.silkDecoder);

    final decodeResult = await Process.run(
      binaries.silkDecoder,
      [silkPath, pcmPath, '-Fs_API', '$_sampleRate'],
      workingDirectory: p.dirname(binaries.silkDecoder),
      environment: silkEnv,
    );
    if (decodeResult.exitCode != 0 || !File(pcmPath).existsSync()) {
      try {
        File(silkPath).deleteSync();
      } catch (_) {}
      return null;
    }

    final pcmFile = File(pcmPath);
    final bytes = await pcmFile.readAsBytes();
    final durationSeconds = (bytes.length / (_sampleRate * 2)).round();

    try {
      File(silkPath).deleteSync();
      File(pcmPath).deleteSync();
    } catch (_) {}

    return durationSeconds;
  }

  String? _voiceLookupWxidCandidate(Message message) {
    final senderWxid = message.senderUsername;
    final myWxid = message.myWxid;
    final isFromMe = (message.isSend ?? 0) == 1;

    final v =
        (isFromMe ? myWxid : senderWxid) ?? (isFromMe ? senderWxid : myWxid);
    return v?.trim();
  }
}

class _BinaryPaths {
  _BinaryPaths({required this.silkDecoder});

  final String silkDecoder;
}

class SelfSentVoiceNotSupportedException implements Exception {
  @override
  String toString() =>
      'SelfSentVoiceNotSupportedException: Cannot decrypt self-sent voice messages';
}

class VoiceDecodingNotSupportedException implements Exception {
  VoiceDecodingNotSupportedException(this.message);

  final String message;

  @override
  String toString() => 'VoiceDecodingNotSupportedException: $message';
}
