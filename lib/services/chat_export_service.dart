import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_xlsio/xlsio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/message.dart';
import '../models/chat_session.dart';
import '../models/contact_record.dart';
import '../utils/path_utils.dart';
import 'config_service.dart';
import 'database_service.dart';
import 'image_decrypt_service.dart';
import 'image_service.dart';
import 'logger_service.dart';
import 'voice_message_service.dart';
import 'app_path_service.dart';

class MediaExportOptions {
  final bool exportImages;
  final bool exportVoices;
  final bool exportEmojis;
  final String exportDir;
  final String sessionUsername;
  final String mediaDirName;
  final ConfigService? configService;
  final VoiceMessageService? voiceService;
  final String? dataPath;
  final void Function(MediaExportProgress progress)? onProgress;

  const MediaExportOptions({
    required this.exportImages,
    required this.exportVoices,
    required this.exportEmojis,
    required this.exportDir,
    required this.sessionUsername,
    this.mediaDirName = 'media',
    this.configService,
    this.voiceService,
    this.dataPath,
    this.onProgress,
  });

  bool get enabled => exportImages || exportVoices || exportEmojis;

  String get mediaRoot => p.join(exportDir, mediaDirName);
}

class _MediaExportItem {
  final String relativePath;
  final String kind;

  const _MediaExportItem({required this.relativePath, required this.kind});
}

class MediaExportProgress {
  final int exportedCount;
  final int exportedImages;
  final int exportedVoices;
  final int exportedEmojis;
  final String stage;
  final String kind;
  final bool success;

  const MediaExportProgress({
    required this.exportedCount,
    required this.exportedImages,
    required this.exportedVoices,
    required this.exportedEmojis,
    required this.stage,
    required this.kind,
    required this.success,
  });
}

class _MediaExportHelper {
  _MediaExportHelper(this._databaseService, this._options);

  final DatabaseService _databaseService;
  final MediaExportOptions _options;
  final Map<String, _MediaExportItem> _cache = {};
  final Map<String, String> _decryptedIndex = {};
  final Map<String, List<String>> _datCandidatesCache = {};
  final Map<String, Future<_MediaExportItem?>> _inflight = {};
  final Map<String, Map<String, String>> _exportedIndex = {};
  ImageService? _imageService;
  bool _imageServiceReady = false;
  bool _mediaDirsReady = false;
  bool _prepared = false;
  int _exportedCount = 0;
  int _exportedImageCount = 0;
  int _exportedVoiceCount = 0;
  int _exportedEmojiCount = 0;

  Future<void> prepareForMessages(
    List<Message> messages, {
    void Function(int done, int total, String stage)? onProgress,
  }) async {
    if (_prepared || messages.isEmpty) return;
    await logger.info(
      'ChatExportMedia',
      'prepare start: messages=${messages.length} '
          'images=${_options.exportImages} '
          'voices=${_options.exportVoices} '
          'emojis=${_options.exportEmojis}',
    );
    final tasks = <_MediaTask>[];
    final seen = <String>{};
    _notifyStage('索引媒体资源...');
    onProgress?.call(0, 0, '索引媒体资源...');
    for (final msg in messages) {
      final task = _taskFromMessage(msg);
      if (task == null) continue;
      final dedupeKey = '${task.kind}:${task.key}';
      if (!seen.add(dedupeKey)) continue;
      tasks.add(task);
    }
    if (tasks.isEmpty) {
      await logger.info('ChatExportMedia', 'no media tasks');
      _prepared = true;
      return;
    }
    final total = tasks.length;
    _notifyStage('索引完成：$total 个媒体待处理');
    await logger.info('ChatExportMedia', 'media tasks=$total');

    final concurrency = _resolveConcurrency();
    var done = 0;
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor;
        if (index >= total) return;
        cursor += 1;
        final task = tasks[index];
        await logger.debug(
          'ChatExportMedia',
          'task start kind=${task.kind} key=${task.key}',
        );
        try {
          switch (task.kind) {
            case 'image':
              await _exportImage(
                task.message,
              ).timeout(const Duration(minutes: 2));
              break;
            case 'voice':
              await _exportVoice(
                task.message,
              ).timeout(const Duration(minutes: 2));
              break;
            case 'emoji':
              await _exportEmoji(
                task.message,
              ).timeout(const Duration(minutes: 2));
              break;
            default:
              break;
          }
        } on TimeoutException {
          await logger.warning(
            'ChatExportMedia',
            'task timeout kind=${task.kind} key=${task.key}',
          );
        }
        done += 1;
        await logger.debug(
          'ChatExportMedia',
          'task done kind=${task.kind} key=${task.key} progress=$done/$total',
        );
        onProgress?.call(done, total, '处理媒体资源...');
        await Future<void>.delayed(Duration.zero);
      }
    }

    _notifyStage('开始并行处理媒体（并发 $concurrency）');
    onProgress?.call(0, total, '处理媒体资源...');
    await Future.wait(List.generate(concurrency, (_) => worker()));
    await logger.info(
      'ChatExportMedia',
      'prepare done total=$total exported=$_exportedCount '
          'voices=$_exportedVoiceCount images=$_exportedImageCount '
          'emojis=$_exportedEmojiCount',
    );
    _prepared = true;
  }

  Future<_MediaExportItem?> exportForMessage(Message message) async {
    if (message.isImageMessage && _options.exportImages) {
      return _exportImage(message);
    }
    if (message.isVoiceMessage && _options.exportVoices) {
      return _exportVoice(message);
    }
    if (message.localType == 47 && _options.exportEmojis) {
      return _exportEmoji(message);
    }
    return null;
  }

  Future<void> _ensureMediaDirs() async {
    if (_mediaDirsReady) return;
    final mediaRoot = Directory(_options.mediaRoot);
    if (!await mediaRoot.exists()) {
      await mediaRoot.create(recursive: true);
    }
    for (final sub in const ['images', 'voices', 'emojis']) {
      final dir = Directory(p.join(mediaRoot.path, sub));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    await _buildExportedIndex();
    _mediaDirsReady = true;
  }

  String _relativePath(String subDir, String fileName) {
    final rel = p.join(_options.mediaDirName, subDir, fileName);
    return rel.replaceAll('\\', '/');
  }

  Future<_MediaExportItem?> _exportImage(Message message) async {
    final key =
        message.imageMd5 ?? message.imageDatName ?? 'img_${message.localId}';
    final inflightKey = 'image:$key';
    final inflight = _inflight[inflightKey];
    if (inflight != null) return await inflight;
    if (_prepared) {
      return _cache[key];
    }
    final future = _exportImageInternal(message, key);
    _inflight[inflightKey] = future;
    final result = await future;
    _inflight.remove(inflightKey);
    return result;
  }

  Future<_MediaExportItem?> _exportImageInternal(
    Message message,
    String key,
  ) async {
    await logger.debug(
      'ChatExportMedia',
      'image export start localId=${message.localId} md5=${message.imageMd5} '
          'dat=${message.imageDatName}',
    );
    _notifyMediaProgress('image', success: false);
    final cached = _cache[key];
    if (cached != null) {
      _notifyMediaProgress('image', success: true);
      return cached;
    }

    await _ensureMediaDirs();
    final exportedHit = _findExportedImageForMessage(message);
    if (exportedHit != null) {
      await logger.debug(
        'ChatExportMedia',
        'image export hit exported cache dest=$exportedHit',
      );
      _notifyMediaProgress('image', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('images', p.basename(exportedHit)),
        kind: 'image',
      );
      _cache[key] = item;
      _cacheImageAliases(message, item);
      return item;
    }

    final sourcePath = await _resolveImageSource(message);
    if (sourcePath != null) {
      final sourceFile = File(sourcePath);
      if (await sourceFile.exists()) {
        final baseName = _sanitizeFileName(p.basename(sourcePath));
        final cachedExport = _findExported('images', baseName);
        if (cachedExport != null) {
          await logger.debug(
            'ChatExportMedia',
            'image export hit exported cache dest=$cachedExport',
          );
          _notifyMediaProgress('image', success: true);
          final item = _MediaExportItem(
            relativePath: _relativePath('images', p.basename(cachedExport)),
            kind: 'image',
          );
          _cache[key] = item;
          return item;
        }
        final destPath = await _copyWithUniqueName(
          sourceFile,
          'images',
          baseName,
          key,
        );
        if (destPath != null) {
          await logger.debug(
            'ChatExportMedia',
            'image export copied src=$sourcePath dest=$destPath',
          );
          _notifyMediaProgress('image', success: true);
          final item = _MediaExportItem(
            relativePath: _relativePath('images', p.basename(destPath)),
            kind: 'image',
          );
          _cache[key] = item;
          _cacheImageAliases(message, item);
          return item;
        }
      }
    }

    final decrypted = await _decryptImageToExport(message, key);
    if (decrypted != null) {
      final baseName = _sanitizeFileName(p.basename(decrypted));
      final cachedExport = _findExported('images', baseName);
      if (cachedExport != null) {
        await logger.debug(
          'ChatExportMedia',
          'image export hit exported cache dest=$cachedExport',
        );
        _notifyMediaProgress('image', success: true);
        final item = _MediaExportItem(
          relativePath: _relativePath('images', p.basename(cachedExport)),
          kind: 'image',
        );
        _cache[key] = item;
        return item;
      }
      await logger.debug(
        'ChatExportMedia',
        'image export decrypted dest=$decrypted',
      );
      _notifyMediaProgress('image', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('images', p.basename(decrypted)),
        kind: 'image',
      );
      _cache[key] = item;
      _cacheImageAliases(message, item);
      return item;
    }
    return null;
  }

  Future<_MediaExportItem?> _exportVoice(Message message) async {
    if (message.isSend == 1) return null;
    final key = 'voice_${message.createTime}_${message.localId}';
    final inflightKey = 'voice:$key';
    final inflight = _inflight[inflightKey];
    if (inflight != null) return await inflight;
    if (_prepared) {
      return _cache[key];
    }
    final future = _exportVoiceInternal(message, key);
    _inflight[inflightKey] = future;
    final result = await future;
    _inflight.remove(inflightKey);
    return result;
  }

  Future<_MediaExportItem?> _exportVoiceInternal(
    Message message,
    String key,
  ) async {
    await logger.debug(
      'ChatExportMedia',
      'voice export start localId=${message.localId} time=${message.createTime}',
    );
    _notifyMediaProgress('voice', success: false);
    final cached = _cache[key];
    if (cached != null) {
      _notifyMediaProgress('voice', success: true);
      return cached;
    }

    final voiceService = _options.voiceService;
    if (voiceService == null) return null;
    await _ensureMediaDirs();

    final outputFile = await voiceService.getOutputFile(
      message,
      _options.sessionUsername,
    );
    final baseNameFromOutput = _sanitizeFileName(p.basename(outputFile.path));
    final exportedPath = _findExported('voices', baseNameFromOutput);
    if (exportedPath != null) {
      await logger.debug(
        'ChatExportMedia',
        'voice export hit exported cache dest=$exportedPath',
      );
      _notifyMediaProgress('voice', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('voices', p.basename(exportedPath)),
        kind: 'voice',
      );
      _cache[key] = item;
      return item;
    }

    File? voiceFile = await voiceService.findExistingVoiceFile(
      message,
      _options.sessionUsername,
    );
    if (voiceFile == null) {
      _notifyStage('语音解码中... localId=${message.localId}');
      final sw = Stopwatch()..start();
      Timer? heartbeat;
      heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        final secs = sw.elapsed.inSeconds;
        _notifyStage('语音解码中... 已等待 ${secs}s');
      });
      try {
        final decodeFuture = voiceService
            .ensureVoiceDecoded(message, _options.sessionUsername)
            // ignore: body_might_complete_normally_catch_error
            .catchError((_) {});
        await Future.any([
          decodeFuture,
          _waitForFileReady(outputFile, const Duration(seconds: 90)),
        ]);
        if (await outputFile.exists()) {
          voiceFile = outputFile;
        } else {
          await logger.warning(
            'ChatExportMedia',
            'voice export decode timeout localId=${message.localId}',
          );
          return null;
        }
      } catch (_) {
        await logger.warning(
          'ChatExportMedia',
          'voice export decode failed localId=${message.localId}',
        );
        heartbeat.cancel();
        return null;
      } finally {
        heartbeat.cancel();
        await logger.info(
          'ChatExportMedia',
          'voice decode duration localId=${message.localId} ms=${sw.elapsedMilliseconds}',
        );
      }
    }
    if (!await voiceFile.exists()) return null;

    _notifyStage('正在复制语音...');
    final baseName = _sanitizeFileName(p.basename(voiceFile.path));
    final destPath = await _copyWithUniqueName(
      voiceFile,
      'voices',
      baseName,
      key,
    );
    if (destPath == null) return null;
    await logger.debug(
      'ChatExportMedia',
      'voice export copied src=${voiceFile.path} dest=$destPath',
    );
    _notifyMediaProgress('voice', success: true);
    final item = _MediaExportItem(
      relativePath: _relativePath('voices', p.basename(destPath)),
      kind: 'voice',
    );
    _cache[key] = item;
    return item;
  }

  Future<void> _waitForFileReady(File file, Duration timeout) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (await file.exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<_MediaExportItem?> _exportEmoji(Message message) async {
    final url = message.emojiCdnUrl ?? '';
    final md5 = message.emojiMd5 ?? '';
    final key = md5.isNotEmpty ? md5 : url.hashCode.toUnsigned(32).toString();
    final inflightKey = 'emoji:$key';
    final inflight = _inflight[inflightKey];
    if (inflight != null) return await inflight;
    if (_prepared) {
      if (url.isEmpty && md5.isEmpty) return null;
      return _cache[key];
    }
    final future = _exportEmojiInternal(message, url, md5, key);
    _inflight[inflightKey] = future;
    final result = await future;
    _inflight.remove(inflightKey);
    return result;
  }

  Future<_MediaExportItem?> _exportEmojiInternal(
    Message message,
    String url,
    String md5,
    String key,
  ) async {
    await logger.debug(
      'ChatExportMedia',
      'emoji export start localId=${message.localId} md5=${message.emojiMd5} url=${message.emojiCdnUrl}',
    );
    _notifyMediaProgress('emoji', success: false);
    if (url.isEmpty && md5.isEmpty) return null;
    final cached = _cache[key];
    if (cached != null) {
      _notifyMediaProgress('emoji', success: true);
      return cached;
    }

    await _ensureMediaDirs();
    final cachedExport = _findExported('emojis', key);
    if (cachedExport != null) {
      await logger.debug(
        'ChatExportMedia',
        'emoji export hit exported cache dest=$cachedExport',
      );
      _notifyMediaProgress('emoji', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('emojis', p.basename(cachedExport)),
        kind: 'emoji',
      );
      _cache[key] = item;
      return item;
    }
    final existing = await _findCachedEmoji(md5, url);
    if (existing != null) {
      final baseName = _sanitizeFileName(p.basename(existing));
      final existingExport = _findExported('emojis', baseName);
      if (existingExport != null) {
        await logger.debug(
          'ChatExportMedia',
          'emoji export hit exported cache dest=$existingExport',
        );
        _notifyMediaProgress('emoji', success: true);
        final item = _MediaExportItem(
          relativePath: _relativePath('emojis', p.basename(existingExport)),
          kind: 'emoji',
        );
        _cache[key] = item;
        return item;
      }
      final destPath = await _copyWithUniqueName(
        File(existing),
        'emojis',
        baseName,
        key,
      );
      if (destPath == null) return null;
      await logger.debug(
        'ChatExportMedia',
        'emoji export copied src=$existing dest=$destPath',
      );
      _notifyMediaProgress('emoji', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('emojis', p.basename(destPath)),
        kind: 'emoji',
      );
      _cache[key] = item;
      return item;
    }

    if (url.isEmpty) return null;
    final baseForDownload = md5.isNotEmpty
        ? md5
        : url.hashCode.toUnsigned(32).toString();
    final existingDownloaded = _findExported('emojis', baseForDownload);
    if (existingDownloaded != null) {
      await logger.debug(
        'ChatExportMedia',
        'emoji export hit exported cache dest=$existingDownloaded',
      );
      _notifyMediaProgress('emoji', success: true);
      final item = _MediaExportItem(
        relativePath: _relativePath('emojis', p.basename(existingDownloaded)),
        kind: 'emoji',
      );
      _cache[key] = item;
      return item;
    }
    final downloaded = await _downloadEmojiToExport(url, md5);
    if (downloaded == null) return null;
    await logger.debug(
      'ChatExportMedia',
      'emoji export downloaded dest=$downloaded',
    );
    _notifyMediaProgress('emoji', success: true);
    final item = _MediaExportItem(
      relativePath: _relativePath('emojis', p.basename(downloaded)),
      kind: 'emoji',
    );
    _cache[key] = item;
    return item;
  }

  Future<String?> _resolveImageSource(Message message) async {
    final md5 = message.imageMd5;
    if (md5 != null && md5.isNotEmpty) {
      final path = await _getImagePathFromHardlink(md5);
      if (path != null) return path;
    }
    final cachedPath = await _findDecryptedImage(message);
    if (cachedPath != null) return cachedPath;
    return null;
  }

  Future<String?> _getImagePathFromHardlink(String md5) async {
    final dataPath = _options.dataPath ?? _databaseService.currentDataPath;
    if (dataPath == null || dataPath.isEmpty) return null;
    _imageService ??= ImageService();
    if (!_imageServiceReady) {
      await _imageService!.init(dataPath);
      _imageServiceReady = true;
    }
    try {
      return await _imageService!.getImagePath(md5, _options.sessionUsername);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findDecryptedImage(Message message) async {
    if (_decryptedIndex.isEmpty) {
      await _buildDecryptedIndex();
    }
    final byDat = message.imageDatName?.toLowerCase();
    if (byDat != null && _decryptedIndex.containsKey(byDat)) {
      return _decryptedIndex[byDat];
    }
    final byMd5 = message.imageMd5?.toLowerCase();
    if (byMd5 != null && _decryptedIndex.containsKey(byMd5)) {
      return _decryptedIndex[byMd5];
    }
    return null;
  }

  Future<void> _buildDecryptedIndex() async {
    try {
      final docs = await AppPathService.getDocumentsDirectory(
        configService: _options.configService,
      );
      final imagesRoot = Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) return;
      await for (final entity in imagesRoot.list(recursive: true)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!_isImageExtension(ext)) continue;
        final base = p.basenameWithoutExtension(entity.path).toLowerCase();
        _decryptedIndex.putIfAbsent(base, () => entity.path);
      }
    } catch (_) {}
  }

  bool _isImageExtension(String ext) {
    return ext == '.jpg' ||
        ext == '.jpeg' ||
        ext == '.png' ||
        ext == '.gif' ||
        ext == '.webp';
  }

  Future<String?> _decryptImageToExport(
    Message message,
    String cacheKey,
  ) async {
    final datName = message.imageDatName;
    final config = _options.configService;
    if (datName == null || datName.isEmpty || config == null) {
      return null;
    }

    final basePath = (await config.getDatabasePath()) ?? '';
    final rawWxid = await config.getManualWxid();
    if (basePath.isEmpty || rawWxid == null || rawWxid.isEmpty) {
      return null;
    }

    final accountDir = Directory(p.join(basePath, rawWxid));
    if (!await accountDir.exists()) return null;

    final candidates = await _findDatCandidates(accountDir, datName);
    if (candidates.isEmpty) return null;

    final xorKeyHex = await config.getImageXorKey();
    if (xorKeyHex == null || xorKeyHex.isEmpty) return null;
    final aesKeyHex = await config.getImageAesKey();
    final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
    Uint8List? aesKey;
    if (aesKeyHex != null && aesKeyHex.isNotEmpty) {
      try {
        aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
      } catch (_) {
        aesKey = null;
      }
    }

    final targetBase = _sanitizeFileName(datName);
    final existingExport = _findExportedByBase('images', targetBase);
    if (existingExport != null) {
      return existingExport;
    }
    final tempName = '${targetBase}_tmp.jpg';
    final outputPath = p.join(_options.mediaRoot, 'images', tempName);
    final outputFile = File(outputPath);

    final decryptService = ImageDecryptService();
    for (final datPath in candidates) {
      try {
        if (!await outputFile.exists()) {
          await decryptService.decryptDatAutoAsync(
            datPath,
            outputPath,
            xorKey,
            aesKey,
          );
        }
        if (!await outputFile.exists()) continue;
        final ext = await _detectImageExtensionFromFile(outputFile);
        final finalName = '$targetBase$ext';
        final finalPath = p.join(_options.mediaRoot, 'images', finalName);
        if (finalPath != outputPath) {
          await outputFile.rename(finalPath);
        }
        _recordExported('images', finalPath);
        return finalPath;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<List<String>> _findDatCandidates(
    Directory accountDir,
    String datName,
  ) async {
    final key = datName.toLowerCase();
    if (_datCandidatesCache.containsKey(key)) {
      return _datCandidatesCache[key]!;
    }
    final results = <String>[];
    try {
      await for (final entity in accountDir.list(recursive: true)) {
        if (entity is! File) continue;
        final lower = p.basename(entity.path).toLowerCase();
        if (!lower.contains(key)) continue;
        if (!lower.endsWith('.dat')) continue;
        results.add(entity.path);
        if (results.length >= 8) break;
      }
    } catch (_) {}
    _datCandidatesCache[key] = results;
    return results;
  }

  Future<String?> _findCachedEmoji(String md5, String url) async {
    try {
      final docs = await AppPathService.getDocumentsDirectory(
        configService: _options.configService,
      );
      final emojiDir = Directory(p.join(docs.path, 'EchoTrace', 'Emojis'));
      if (!await emojiDir.exists()) return null;
      final base = md5.isNotEmpty
          ? md5
          : url.hashCode.toUnsigned(32).toString();
      for (final ext in const ['.gif', '.png', '.webp', '.jpg', '.jpeg']) {
        final candidate = File(p.join(emojiDir.path, '$base$ext'));
        if (await candidate.exists()) return candidate.path;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _downloadEmojiToExport(String url, String md5) async {
    try {
      final response = await http.get(Uri.parse(url));
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 || bytes.isEmpty) {
        return null;
      }
      final contentType = response.headers['content-type'] ?? '';
      final ext =
          _detectImageExtension(bytes) ?? _pickExtension(url, contentType);
      final base = md5.isNotEmpty
          ? md5
          : url.hashCode.toUnsigned(32).toString();
      final fileName = _sanitizeFileName('$base$ext');
      final outPath = p.join(_options.mediaRoot, 'emojis', fileName);
      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _copyWithUniqueName(
    File source,
    String subDir,
    String baseName,
    String cacheKey,
  ) async {
    final dir = p.join(_options.mediaRoot, subDir);
    var candidate = _sanitizeFileName(baseName);
    if (candidate.isEmpty) {
      candidate = '${cacheKey}_${DateTime.now().millisecondsSinceEpoch}';
    }
    final exported = _findExported(subDir, candidate);
    if (exported != null) {
      return exported;
    }
    var destPath = p.join(dir, candidate);
    var suffix = 1;
    while (await File(destPath).exists()) {
      if (_sameFilePath(source.path, destPath)) return destPath;
      final ext = p.extension(candidate);
      final stem = p.basenameWithoutExtension(candidate);
      final next = '${stem}_$suffix$ext';
      destPath = p.join(dir, next);
      suffix += 1;
    }
    try {
      final copied = await _copyFileWithTimeout(
        source,
        destPath,
        const Duration(seconds: 20),
      );
      if (copied) {
        _recordExported(subDir, destPath);
        return destPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _sameFilePath(String a, String b) {
    try {
      return p.equals(a, b);
    } catch (_) {
      return a == b;
    }
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }

  Future<void> _buildExportedIndex() async {
    if (_exportedIndex.isNotEmpty) return;
    for (final sub in const ['images', 'voices', 'emojis']) {
      final dir = Directory(p.join(_options.mediaRoot, sub));
      if (!await dir.exists()) {
        _exportedIndex[sub] = {};
        continue;
      }
      final map = <String, String>{};
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        map[name] = entity.path;
      }
      _exportedIndex[sub] = map;
    }
  }

  String? _findExported(String subDir, String fileName) {
    final map = _exportedIndex[subDir];
    if (map == null || map.isEmpty) return null;
    return map[fileName];
  }

  String? _findExportedByBase(String subDir, String baseName) {
    final map = _exportedIndex[subDir];
    if (map == null || map.isEmpty) return null;
    final lower = baseName.toLowerCase();
    for (final entry in map.entries) {
      final name = p.basenameWithoutExtension(entry.key).toLowerCase();
      if (name == lower) return entry.value;
    }
    return null;
  }

  void _recordExported(String subDir, String path) {
    final map = _exportedIndex[subDir];
    if (map == null) return;
    map[p.basename(path)] = path;
  }

  String? _findExportedImageForMessage(Message message) {
    final md5 = message.imageMd5;
    if (md5 != null && md5.isNotEmpty) {
      final byBase = _findExportedByBase('images', md5);
      if (byBase != null) return byBase;
    }
    final dat = message.imageDatName;
    if (dat != null && dat.isNotEmpty) {
      final byBase = _findExportedByBase('images', dat);
      if (byBase != null) return byBase;
    }
    return null;
  }

  void _cacheImageAliases(Message message, _MediaExportItem item) {
    final md5 = message.imageMd5;
    if (md5 != null && md5.isNotEmpty) {
      _cache[md5] = item;
    }
    final dat = message.imageDatName;
    if (dat != null && dat.isNotEmpty) {
      _cache[dat] = item;
    }
  }

  Future<bool> _copyFileWithTimeout(
    File source,
    String destPath,
    Duration timeout,
  ) async {
    try {
      await logger.debug(
        'ChatExportMedia',
        'copy start src=${source.path} dest=$destPath',
      );
      await source.copy(destPath).timeout(timeout);
      await logger.debug('ChatExportMedia', 'copy done dest=$destPath');
      return true;
    } on TimeoutException {
      await logger.warning('ChatExportMedia', 'copy timeout dest=$destPath');
      return false;
    } catch (e) {
      await logger.warning(
        'ChatExportMedia',
        'copy failed dest=$destPath error=$e',
      );
      return false;
    }
  }

  String? _detectImageExtension(List<int> bytes) {
    if (bytes.length < 12) return null;
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return '.gif';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return '.png';
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return null;
  }

  Future<String> _detectImageExtensionFromFile(File file) async {
    try {
      final bytes = await file.openRead(0, 16).first;
      return _detectImageExtension(bytes) ?? '.jpg';
    } catch (_) {
      return '.jpg';
    }
  }

  String _pickExtension(String url, String contentType) {
    final uriExt = p.extension(Uri.parse(url).path);
    if (uriExt.isNotEmpty && uriExt.length <= 5) {
      return uriExt;
    }
    final lower = contentType.toLowerCase();
    if (lower.contains('png')) return '.png';
    if (lower.contains('webp')) return '.webp';
    if (lower.contains('jpeg') || lower.contains('jpg')) return '.jpg';
    return '.gif';
  }

  void _notifyStage(String stage) {
    final callback = _options.onProgress;
    if (callback == null) return;
    callback(
      MediaExportProgress(
        exportedCount: _exportedCount,
        exportedImages: _exportedImageCount,
        exportedVoices: _exportedVoiceCount,
        exportedEmojis: _exportedEmojiCount,
        stage: stage,
        kind: '',
        success: true,
      ),
    );
  }

  void _notifyMediaProgress(String kind, {required bool success}) {
    final callback = _options.onProgress;
    if (callback == null) return;
    if (success) {
      _exportedCount += 1;
      switch (kind) {
        case 'image':
          _exportedImageCount += 1;
          break;
        case 'voice':
          _exportedVoiceCount += 1;
          break;
        case 'emoji':
          _exportedEmojiCount += 1;
          break;
      }
    }
    final stage =
        '正在处理媒体：${_kindLabel(kind)}（总计 $_exportedCount 个，'
        '语音 $_exportedVoiceCount / 图片 $_exportedImageCount / 表情 $_exportedEmojiCount）';
    callback(
      MediaExportProgress(
        exportedCount: _exportedCount,
        exportedImages: _exportedImageCount,
        exportedVoices: _exportedVoiceCount,
        exportedEmojis: _exportedEmojiCount,
        stage: stage,
        kind: kind,
        success: success,
      ),
    );
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'image':
        return '图片';
      case 'voice':
        return '语音';
      case 'emoji':
        return '表情';
      default:
        return '媒体';
    }
  }

  int _resolveConcurrency() {
    try {
      final cpu = Platform.numberOfProcessors;
      final base = (cpu / 2).floor();
      if (base < 2) return 2;
      if (base > 6) return 6;
      return base;
    } catch (_) {
      return 3;
    }
  }

  _MediaTask? _taskFromMessage(Message msg) {
    if (msg.isImageMessage && _options.exportImages) {
      final key = msg.imageMd5 ?? msg.imageDatName ?? 'img_${msg.localId}';
      return _MediaTask(kind: 'image', key: key, message: msg);
    }
    if (msg.isVoiceMessage && _options.exportVoices) {
      if (msg.isSend == 1) return null;
      final key = 'voice_${msg.createTime}_${msg.localId}';
      return _MediaTask(kind: 'voice', key: key, message: msg);
    }
    if (msg.localType == 47 && _options.exportEmojis) {
      final url = msg.emojiCdnUrl ?? '';
      final md5 = msg.emojiMd5 ?? '';
      if (url.isEmpty && md5.isEmpty) return null;
      final key = md5.isNotEmpty ? md5 : url.hashCode.toUnsigned(32).toString();
      return _MediaTask(kind: 'emoji', key: key, message: msg);
    }
    return null;
  }
}

class _MediaTask {
  final String kind;
  final String key;
  final Message message;

  const _MediaTask({
    required this.kind,
    required this.key,
    required this.message,
  });
}

/// 聊天记录导出服务
class ChatExportService {
  final DatabaseService _databaseService;
  final Set<String> _missingDisplayNameLog = <String>{};
  final Map<String, String> _avatarBase64CacheByUrl = <String, String>{};
  ChatExportService(this._databaseService);

  /// 后台写入字符串到文件（在 Isolate 中执行以避免阻塞 UI）
  static bool _writeStringToFileSync(Map<String, String> params) {
    try {
      final file = File(params['path']!);
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      file.writeAsStringSync(params['content']!);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 后台写入字节到文件（在 Isolate 中执行以避免阻塞 UI）
  static bool _writeBytesToFileSync(Map<String, dynamic> params) {
    try {
      final file = File(params['path'] as String);
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      file.writeAsBytesSync(params['bytes'] as Uint8List);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 数据大小阈值：超过此大小则直接异步写入，避免 Isolate 间传输开销
  static const int _largeDataThreshold = 5 * 1024 * 1024; // 5MB

  /// 使用 compute 在后台写入字符串文件（智能选择策略）
  Future<bool> _writeStringInBackground(String path, String content) async {
    final contentBytes = content.length * 2; // UTF-16 估算
    await logger.info(
      'ChatExportService',
      '开始写入文件: $path, 内容大小: ${(contentBytes / (1024 * 1024)).toStringAsFixed(2)} MB',
    );

    try {
      final file = File(path);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // 对于大数据，直接使用异步IO（dart:io 内部使用IO线程池，不会阻塞主线程）
      // 避免 compute 序列化大数据到另一个 Isolate 的开销
      if (contentBytes > _largeDataThreshold) {
        await logger.info('ChatExportService', '数据较大，使用直接异步写入模式');
        await file.writeAsString(content);
      } else {
        await logger.info('ChatExportService', '数据较小，使用 compute 后台写入模式');
        final result = await compute(_writeStringToFileSync, {
          'path': path,
          'content': content,
        });
        if (!result) {
          await logger.error('ChatExportService', '后台写入失败: $path');
          return false;
        }
      }

      await logger.info('ChatExportService', '文件写入完成: $path');
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', '写入文件异常: $e\n$stack');
      return false;
    }
  }

  /// 使用 compute 在后台写入字节文件（智能选择策略）
  Future<bool> _writeBytesInBackground(String path, Uint8List bytes) async {
    await logger.info(
      'ChatExportService',
      '开始写入字节文件: $path, 大小: ${(bytes.length / (1024 * 1024)).toStringAsFixed(2)} MB',
    );

    try {
      final file = File(path);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // 对于大数据，直接使用异步IO
      if (bytes.length > _largeDataThreshold) {
        await logger.info('ChatExportService', '数据较大，使用直接异步写入模式');
        await file.writeAsBytes(bytes);
      } else {
        await logger.info('ChatExportService', '数据较小，使用 compute 后台写入模式');
        final result = await compute(_writeBytesToFileSync, {
          'path': path,
          'bytes': bytes,
        });
        if (!result) {
          await logger.error('ChatExportService', '后台写入失败: $path');
          return false;
        }
      }

      await logger.info('ChatExportService', '字节文件写入完成: $path');
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', '写入字节文件异常: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 JSON 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToJson(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      if (trimmedMyWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedMyWxid);
      }
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernameSet.add(myWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      var avatars = <String, Map<String, String>>{};
      if (exportAvatars) {
        onProgress?.call(0, totalMessages, '构建头像索引...');
        avatars = await _buildAvatarIndex(
          session: session,
          messages: messages,
          contactInfo: contactInfo,
          senderDisplayNames: senderDisplayNames,
          rawMyWxid: rawMyWxid,
          myDisplayName: myDisplayName,
        );
      }

      onProgress?.call(0, totalMessages, '处理消息数据...');
      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;
      if (mediaHelper != null) {
        onProgress?.call(0, totalMessages, '处理媒体资源...');
        await mediaHelper.prepareForMessages(
          messages,
          onProgress: (done, total, _) {
            if (total <= 0) return;
            final ratio = done / total;
            final current = (totalMessages * 0.2 * ratio).round();
            onProgress?.call(current, totalMessages, '处理媒体资源...');
          },
        );
      }

      // 分批处理消息以显示进度
      final messageItems = <Map<String, dynamic>>[];
      const batchSize = 1000;
      for (int i = 0; i < messages.length; i += batchSize) {
        final end = (i + batchSize < messages.length)
            ? i + batchSize
            : messages.length;
        for (int j = i; j < end; j++) {
          final msg = messages[j];
          final isSend = msg.isSend == 1;
          final senderName = _resolveSenderDisplayName(
            msg: msg,
            session: session,
            isSend: isSend,
            contactInfo: contactInfo,
            myContactInfo: myContactInfo,
            senderDisplayNames: senderDisplayNames,
            myDisplayName: myDisplayName,
          );
          final senderWxid = _resolveSenderUsername(
            msg: msg,
            session: session,
            isSend: isSend,
            myWxid: myWxid,
          );

          final mediaItem = mediaHelper == null
              ? null
              : await mediaHelper.exportForMessage(msg);
          final content = _resolveExportContent(msg, mediaItem);
          final item = <String, dynamic>{
            'localId': msg.localId,
            'createTime': msg.createTime,
            'formattedTime': msg.formattedCreateTime,
            'type': msg.typeDescription,
            'localType': msg.localType,
            'content': content,
            'isSend': msg.isSend,
            'senderUsername': senderWxid.isEmpty ? null : senderWxid,
            'senderDisplayName': senderName,
            'source': msg.source,
          };
          if (exportAvatars && senderWxid.isNotEmpty) {
            item['senderAvatarKey'] = senderWxid;
          }

          if (msg.localType == 47 && msg.emojiMd5 != null) {
            item['emojiMd5'] = msg.emojiMd5;
          }
          if (mediaItem != null) {
            item['mediaPath'] = mediaItem.relativePath;
          }

          messageItems.add(item);
        }

        // 每批处理后报告进度并让出主线程
        onProgress?.call(end, totalMessages, '处理消息数据...');
        await Future.delayed(Duration.zero);
      }

      final groupMembers = session.isGroup
          ? await _getGroupMemberExportData(session.username)
          : null;

      final data = {
        'session': {
          'wxid': _sanitizeUsername(session.username),
          'nickname':
              contactInfo['nickname'] ??
              session.displayName ??
              session.username,
          'remark': _getRemarkOrAlias(contactInfo),
          'displayName': session.displayName ?? session.username,
          'type': session.typeDescription,
          'lastTimestamp': session.lastTimestamp,
          'messageCount': messages.length,
        },
        'messages': messageItems,
        if (exportAvatars) 'avatars': avatars,
        if (groupMembers != null) 'groupMembers': groupMembers,
        'exportTime': DateTime.now().toIso8601String(),
      };
      if (mediaOptions != null && mediaOptions.enabled) {
        data['mediaBase'] = mediaOptions.mediaDirName;
      }

      onProgress?.call(totalMessages, totalMessages, '编码 JSON...');
      await logger.info(
        'ChatExportService',
        'exportToJson: 开始编码 JSON, 消息数: ${messages.length}',
      );

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);

      await logger.info(
        'ChatExportService',
        'exportToJson: JSON 编码完成, 字符串长度: ${jsonString.length}',
      );

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.json';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeStringInBackground(filePath, jsonString);
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToJson 失败: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 HTML 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToHtml(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      if (trimmedMyWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedMyWxid);
      }
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernameSet.add(myWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      var avatars = <String, Map<String, String>>{};
      if (exportAvatars) {
        onProgress?.call(0, totalMessages, '构建头像索引...');
        avatars = await _buildAvatarIndex(
          session: session,
          messages: messages,
          contactInfo: contactInfo,
          senderDisplayNames: senderDisplayNames,
          rawMyWxid: rawMyWxid,
          myDisplayName: myDisplayName,
        );
      }

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;
      if (mediaHelper != null) {
        onProgress?.call(0, totalMessages, '处理媒体资源...');
        await mediaHelper.prepareForMessages(
          messages,
          onProgress: (done, total, _) {
            if (total <= 0) return;
            final ratio = done / total;
            final current = (totalMessages * 0.2 * ratio).round();
            onProgress?.call(current, totalMessages, '处理媒体资源...');
          },
        );
      }

      onProgress?.call(0, totalMessages, '生成 HTML...');
      await logger.info(
        'ChatExportService',
        'exportToHtml: 开始生成 HTML, 消息数: ${messages.length}',
      );

      final messagesData = <Map<String, dynamic>>[];
      for (int i = 0; i < messages.length; i++) {
        final msg = messages[i];
        final mediaItem = mediaHelper == null
            ? null
            : await mediaHelper.exportForMessage(msg);
        final item = _buildHtmlMessageData(
          msg: msg,
          session: session,
          senderDisplayNames: senderDisplayNames,
          myWxid: myWxid,
          contactInfo: contactInfo,
          myDisplayName: myDisplayName,
          exportAvatars: exportAvatars,
          mediaItem: mediaItem,
        );
        messagesData.add(item);
        if ((i + 1) % 500 == 0 || i == messages.length - 1) {
          onProgress?.call(i + 1, totalMessages, '生成 HTML...');
        }
      }

      final html = _generateHtmlFromData(
        session: session,
        messagesData: messagesData,
        contactInfo: contactInfo,
        avatarIndex: avatars,
        mediaBase: mediaOptions != null && mediaOptions.enabled
            ? mediaOptions.mediaDirName
            : null,
      );

      await logger.info(
        'ChatExportService',
        'exportToHtml: HTML 生成完成, 长度: ${html.length}',
      );

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.html';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeStringInBackground(filePath, html);
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToHtml 失败: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 Excel 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToExcel(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    final Workbook workbook = Workbook();
    final totalMessages = messages.length;
    onProgress?.call(0, totalMessages, '准备工作簿...');
    try {
      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 使用或创建工作表
      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '聊天记录';
      } else {
        sheet = workbook.worksheets.addWithName('聊天记录');
      }
      int currentRow = 1;

      // 添加会话信息行
      _setTextSafe(sheet, currentRow, 1, '会话信息');
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '微信ID');
      _setTextSafe(sheet, currentRow, 2, _sanitizeUsername(session.username));
      _setTextSafe(sheet, currentRow, 3, '昵称');
      _setTextSafe(sheet, currentRow, 4, contactInfo['nickname'] ?? '');
      _setTextSafe(sheet, currentRow, 5, '备注');
      _setTextSafe(sheet, currentRow, 6, _getRemarkOrAlias(contactInfo));
      currentRow++;

      // 空行
      currentRow++;

      // 设置表头
      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '时间');
      _setTextSafe(sheet, currentRow, 3, '发送者昵称');
      _setTextSafe(sheet, currentRow, 4, '发送者微信ID');
      _setTextSafe(sheet, currentRow, 5, '发送者备注');
      _setTextSafe(sheet, currentRow, 6, '发送者身份');
      _setTextSafe(sheet, currentRow, 7, '消息类型');
      _setTextSafe(sheet, currentRow, 8, '内容');
      currentRow++;

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      if (trimmedAccountWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedAccountWxid);
      }
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernameSet.add(currentAccountWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      // 获取所有发送者的详细信息（nickname、remark）
      final senderContactInfos = <String, Map<String, String>>{};
      for (final username in senderUsernames) {
        senderContactInfos[username] = await _getContactInfo(username);
      }

      // 获取当前账户的联系人信息（用于“我”发送的消息）
      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      final avatars = exportAvatars
          ? await _buildAvatarIndex(
              session: session,
              messages: messages,
              contactInfo: contactInfo,
              senderDisplayNames: senderDisplayNames,
              rawMyWxid: rawAccountWxid,
              myDisplayName: myDisplayName,
            )
          : <String, Map<String, String>>{};
      final sanitizedAccountWxid = currentAccountWxid;
      if (sanitizedAccountWxid.isNotEmpty) {
        senderContactInfos[sanitizedAccountWxid] = currentAccountInfo;
      }
      final rawAccountWxidTrimmed = rawAccountWxid.trim();
      if (rawAccountWxidTrimmed.isNotEmpty) {
        senderContactInfos[rawAccountWxidTrimmed] = currentAccountInfo;
      }

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;
      if (mediaHelper != null) {
        onProgress?.call(0, totalMessages, '处理媒体资源...');
        await mediaHelper.prepareForMessages(
          messages,
          onProgress: (done, total, _) {
            if (total <= 0) return;
            final ratio = done / total;
            final current = (totalMessages * 0.2 * ratio).round();
            onProgress?.call(current, totalMessages, '处理媒体资源...');
          },
        );
      }

      // 添加数据行
      for (int i = 0; i < messages.length; i++) {
        final msg = messages[i];

        // 确定发送者信息
        String senderRole;
        String senderWxid;
        String senderNickname;
        String senderRemark;

        if (msg.isSend == 1) {
          senderRole = '我';
          senderWxid = sanitizedAccountWxid;
          senderNickname = myDisplayName;
          senderRemark = _getRemarkOrAlias(currentAccountInfo);
        } else if (session.isGroup && msg.senderUsername != null) {
          senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
          senderWxid = _sanitizeUsername(msg.senderUsername ?? '');
          final info = senderContactInfos[msg.senderUsername] ?? {};
          senderNickname = _resolvePreferredName(info, fallback: senderRole);
          senderRemark = _getRemarkOrAlias(info);
        } else {
          senderRole = session.displayName ?? session.username;
          senderWxid = _sanitizeUsername(session.username);
          senderNickname = _resolvePreferredName(
            contactInfo,
            fallback: senderRole,
          );
          senderRemark = _getRemarkOrAlias(contactInfo);
        }

        senderWxid = _sanitizeUsername(senderWxid);

        final mediaItem = mediaHelper == null
            ? null
            : await mediaHelper.exportForMessage(msg);
        final exportContent = _resolveExportContent(msg, mediaItem);

        sheet.getRangeByIndex(currentRow, 1).setNumber(i + 1);
        _setTextSafe(sheet, currentRow, 2, msg.formattedCreateTime);
        _setTextSafe(sheet, currentRow, 3, senderNickname);
        _setTextSafe(sheet, currentRow, 4, senderWxid);
        _setTextSafe(sheet, currentRow, 5, senderRemark);
        _setTextSafe(sheet, currentRow, 6, senderRole);
        _setTextSafe(sheet, currentRow, 7, msg.typeDescription);
        _setTextSafe(sheet, currentRow, 8, exportContent);
        currentRow++;

        // 每 500 条报告一次进度
        if ((i + 1) % 500 == 0 || i == messages.length - 1) {
          onProgress?.call(i + 1, totalMessages, '处理消息数据...');
          await Future.delayed(Duration.zero);
        }
      }

      // 自动调整列宽（Syncfusion 使用 1-based 索引）
      sheet.getRangeByIndex(1, 1).columnWidth = 8; // 序号
      sheet.getRangeByIndex(1, 2).columnWidth = 20; // 时间
      sheet.getRangeByIndex(1, 3).columnWidth = 20; // 发送者昵称
      sheet.getRangeByIndex(1, 4).columnWidth = 25; // 发送者微信ID
      sheet.getRangeByIndex(1, 5).columnWidth = 20; // 发送者备注
      sheet.getRangeByIndex(1, 6).columnWidth = 18; // 发送者身份
      sheet.getRangeByIndex(1, 7).columnWidth = 12; // 消息类型
      sheet.getRangeByIndex(1, 8).columnWidth = 50; // 内容

      if (avatars.isNotEmpty) {
        final avatarSheet = workbook.worksheets.addWithName('头像索引');
        _setTextSafe(avatarSheet, 1, 1, '头像ID');
        _setTextSafe(avatarSheet, 1, 2, '显示名称');
        _setTextSafe(avatarSheet, 1, 3, 'Base64');
        int avatarRow = 2;
        avatars.forEach((key, meta) {
          _setTextSafe(avatarSheet, avatarRow, 1, key);
          _setTextSafe(avatarSheet, avatarRow, 2, meta['displayName'] ?? key);
          _setTextSafe(avatarSheet, avatarRow, 3, meta['base64'] ?? '');
          avatarRow++;
        });
        avatarSheet.getRangeByIndex(1, 1).columnWidth = 18;
        avatarSheet.getRangeByIndex(1, 2).columnWidth = 24;
        avatarSheet.getRangeByIndex(1, 3).columnWidth = 80;
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) {
          workbook.dispose();
          return false;
        }
        filePath = outputFile;
      }

      // 保存工作簿为字节流
      onProgress?.call(totalMessages, totalMessages, '保存工作簿...');
      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return await _writeBytesInBackground(filePath, Uint8List.fromList(bytes));
    } catch (e) {
      workbook.dispose();
      return false;
    }
  }

  /// 导出聊天记录为 PostgreSQL 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToPostgreSQL(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    MediaExportOptions? mediaOptions,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      if (trimmedAccountWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedAccountWxid);
      }
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernameSet.add(currentAccountWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      // 获取所有发送者的详细信息（nickname、remark）
      final senderContactInfos = <String, Map<String, String>>{};
      for (final username in senderUsernames) {
        senderContactInfos[username] = await _getContactInfo(username);
      }

      // 获取当前账户的联系人信息（用于"我"发送的消息）
      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      final sanitizedAccountWxid = currentAccountWxid;
      if (sanitizedAccountWxid.isNotEmpty) {
        senderContactInfos[sanitizedAccountWxid] = currentAccountInfo;
      }
      final rawAccountWxidTrimmed = rawAccountWxid.trim();
      if (rawAccountWxidTrimmed.isNotEmpty) {
        senderContactInfos[rawAccountWxidTrimmed] = currentAccountInfo;
      }

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;
      if (mediaHelper != null) {
        onProgress?.call(0, totalMessages, '处理媒体资源...');
        await mediaHelper.prepareForMessages(
          messages,
          onProgress: (done, total, _) {
            if (total <= 0) return;
            final ratio = done / total;
            final current = (totalMessages * 0.2 * ratio).round();
            onProgress?.call(current, totalMessages, '处理媒体资源...');
          },
        );
      }

      onProgress?.call(0, totalMessages, '生成 SQL...');
      final buffer = StringBuffer();

      // Add DDL
      buffer.writeln(
        'DROP TABLE IF EXISTS "public"."echotrace"; CREATE TABLE "public"."echotrace" ("id" int4 NOT NULL GENERATED BY DEFAULT AS IDENTITY ( INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1 ), "date" date, "time" time(6), "is_send" bool, "content" text COLLATE "pg_catalog"."default", "send_name" varchar(255) COLLATE "pg_catalog"."default", "timestamp" timestamp(6),   CONSTRAINT "echotrace_pkey" PRIMARY KEY ("id") );',
      );
      buffer.writeln();
      buffer.writeln('ALTER TABLE "public"."echotrace" OWNER TO "postgres";');
      buffer.writeln();

      // Add INSERTs
      if (messages.isNotEmpty) {
        buffer.writeln(
          'INSERT INTO "public"."echotrace" ("date", "time", "is_send", "content", "send_name", "timestamp") VALUES',
        );

        for (int i = 0; i < messages.length; i++) {
          final msg = messages[i];

          // 确定发送者信息
          String senderRole;
          String senderNickname;

          if (msg.isSend == 1) {
            senderRole = '我';
            senderNickname = myDisplayName;
          } else if (session.isGroup && msg.senderUsername != null) {
            senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
            final info = senderContactInfos[msg.senderUsername] ?? {};
            senderNickname = _resolvePreferredName(info, fallback: senderRole);
          } else {
            senderRole = session.displayName ?? session.username;
            senderNickname = _resolvePreferredName(
              contactInfo,
              fallback: senderRole,
            );
          }

          final dt = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
          final dateStr =
              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          final timeStr =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
          final isSendBool = msg.isSend == 1 ? 'true' : 'false';
          final mediaItem = mediaHelper == null
              ? null
              : await mediaHelper.exportForMessage(msg);
          final exportContent = _resolveExportContent(msg, mediaItem);
          final contentEscaped = exportContent.replaceAll("'", "''");
          final sendNameEscaped = senderNickname.replaceAll("'", "''");
          final timestampStr = '$dateStr $timeStr';

          buffer.write(
            "('$dateStr', '$timeStr', $isSendBool, '$contentEscaped', '$sendNameEscaped', '$timestampStr')",
          );

          if (i < messages.length - 1) {
            buffer.writeln(',');
          } else {
            buffer.writeln(';');
          }

          // 每 500 条报告一次进度
          if ((i + 1) % 500 == 0 || i == messages.length - 1) {
            onProgress?.call(i + 1, totalMessages, '生成 SQL...');
            await Future.delayed(Duration.zero);
          }
        }
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.sql';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;

        filePath = outputFile;
      }

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return await _writeStringInBackground(filePath, buffer.toString());
    } catch (e) {
      return false;
    }
  }

  /// 流式导出聊天记录为 JSON 格式
  Future<bool> exportToJsonStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      final senderUsernames = <String>{
        if (trimmedMyWxid.isNotEmpty) trimmedMyWxid,
      };
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernames.add(myWxid);
      }

      final senderDisplayNames = <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.json';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      final sessionData = {
        'wxid': _sanitizeUsername(session.username),
        'nickname':
            contactInfo['nickname'] ?? session.displayName ?? session.username,
        'remark': _getRemarkOrAlias(contactInfo),
        'displayName': session.displayName ?? session.username,
        'type': session.typeDescription,
        'lastTimestamp': session.lastTimestamp,
        'messageCount': totalMessages,
      };
      final exportTime = DateTime.now().toIso8601String();

      sink.writeln('{');
      sink.writeln('  "session": ${jsonEncode(sessionData)},');
      sink.write('  "messages": [');

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;

      var isFirst = true;
      var processed = 0;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          for (final msg in batch) {
            final mediaItem = mediaHelper == null
                ? null
                : await mediaHelper.exportForMessage(msg);
            final item = _buildJsonMessageItem(
              msg: msg,
              session: session,
              contactInfo: contactInfo,
              myContactInfo: myContactInfo,
              senderDisplayNames: senderDisplayNames,
              rawMyWxid: rawMyWxid,
              myDisplayName: myDisplayName,
              myWxid: myWxid,
              exportAvatars: exportAvatars,
              mediaItem: mediaItem,
            );
            final encoded = jsonEncode(item);
            if (!isFirst) {
              sink!.write(',');
            }
            sink!.write('\n    ');
            sink.write(encoded);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '处理消息数据...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      var avatars = <String, Map<String, String>>{};
      if (exportAvatars) {
        onProgress?.call(totalMessages, totalMessages, '构建头像索引...');
        avatars = await _buildAvatarIndexFromUsernames(
          session: session,
          senderUsernames: senderUsernames,
          contactInfo: contactInfo,
          senderDisplayNames: senderDisplayNames,
          rawMyWxid: rawMyWxid,
          myDisplayName: myDisplayName,
        );
      }
      final groupMembers = session.isGroup
          ? await _getGroupMemberExportData(session.username)
          : null;

      sink.write('\n  ],\n');
      if (exportAvatars) {
        sink.writeln('  "avatars": ${jsonEncode(avatars)},');
      }
      if (groupMembers != null) {
        sink.writeln('  "groupMembers": ${jsonEncode(groupMembers)},');
      }
      if (mediaOptions != null && mediaOptions.enabled) {
        sink.writeln('  "mediaBase": "${mediaOptions.mediaDirName}",');
      }
      sink.writeln('  "exportTime": "$exportTime"');
      sink.writeln('}');

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      await sink.flush();
      return true;
    } catch (e, stack) {
      await logger.error(
        'ChatExportService',
        'exportToJsonStream 失败: $e\n$stack',
      );
      return false;
    } finally {
      await sink?.close();
    }
  }

  /// 流式导出聊天记录为 HTML 格式
  Future<bool> exportToHtmlStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      final senderUsernames = <String>{
        if (trimmedMyWxid.isNotEmpty) trimmedMyWxid,
      };
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernames.add(myWxid);
      }

      final senderDisplayNames = <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.html';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      final exportTime = DateTime.now().toString().split('.')[0];
      sink.write(
        _buildHtmlHeaderStream(
          session: session,
          contactInfo: contactInfo,
          totalMessages: totalMessages,
          exportTime: exportTime,
        ),
      );

      var isFirst = true;
      var processed = 0;
      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;

      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          for (final msg in batch) {
            final mediaItem = mediaHelper == null
                ? null
                : await mediaHelper.exportForMessage(msg);
            final item = _buildHtmlMessageData(
              msg: msg,
              session: session,
              senderDisplayNames: senderDisplayNames,
              myWxid: myWxid,
              contactInfo: contactInfo,
              myDisplayName: myDisplayName,
              exportAvatars: exportAvatars,
              mediaItem: mediaItem,
            );
            final encoded = jsonEncode(item);
            if (!isFirst) {
              sink!.write(',');
            }
            sink!.write('\n    ');
            sink.write(encoded);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '处理消息数据...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      var avatars = <String, Map<String, String>>{};
      if (exportAvatars) {
        onProgress?.call(totalMessages, totalMessages, '构建头像索引...');
        avatars = await _buildAvatarIndexFromUsernames(
          session: session,
          senderUsernames: senderUsernames,
          contactInfo: contactInfo,
          senderDisplayNames: senderDisplayNames,
          rawMyWxid: rawMyWxid,
          myDisplayName: myDisplayName,
        );
      }

      sink.write('\n  ];\n');
      sink.write(_buildHtmlFooterStream(avatars));

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      await sink.flush();
      return true;
    } catch (e, stack) {
      await logger.error(
        'ChatExportService',
        'exportToHtmlStream 失败: $e\n$stack',
      );
      return false;
    } finally {
      await sink?.close();
    }
  }

  /// 流式导出聊天记录为 Excel 格式
  Future<bool> exportToExcelStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
    bool exportAvatars = true,
    MediaExportOptions? mediaOptions,
  }) async {
    final Workbook workbook = Workbook();
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备工作簿...');

      final contactInfo = await _getContactInfo(session.username);

      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '聊天记录';
      } else {
        sheet = workbook.worksheets.addWithName('聊天记录');
      }
      int currentRow = 1;

      _setTextSafe(sheet, currentRow, 1, '会话信息');
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '微信ID');
      _setTextSafe(sheet, currentRow, 2, _sanitizeUsername(session.username));
      _setTextSafe(sheet, currentRow, 3, '昵称');
      _setTextSafe(sheet, currentRow, 4, contactInfo['nickname'] ?? '');
      _setTextSafe(sheet, currentRow, 5, '备注');
      _setTextSafe(sheet, currentRow, 6, _getRemarkOrAlias(contactInfo));
      currentRow++;
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '时间');
      _setTextSafe(sheet, currentRow, 3, '发送者昵称');
      _setTextSafe(sheet, currentRow, 4, '发送者微信ID');
      _setTextSafe(sheet, currentRow, 5, '发送者备注');
      _setTextSafe(sheet, currentRow, 6, '发送者身份');
      _setTextSafe(sheet, currentRow, 7, '消息类型');
      _setTextSafe(sheet, currentRow, 8, '内容');
      currentRow++;

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      final senderUsernames = <String>{
        if (trimmedAccountWxid.isNotEmpty) trimmedAccountWxid,
      };
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernames.add(currentAccountWxid);
      }

      final senderDisplayNames = <String, String>{};

      final senderContactInfos = <String, Map<String, String>>{};

      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      if (currentAccountWxid.isNotEmpty) {
        senderContactInfos[currentAccountWxid] = currentAccountInfo;
      }
      if (trimmedAccountWxid.isNotEmpty) {
        senderContactInfos[trimmedAccountWxid] = currentAccountInfo;
      }

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;

      var index = 0;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          await _ensureSenderContactInfos(newUsernames, senderContactInfos);
          for (final msg in batch) {
            index += 1;
            String senderRole;
            String senderWxid;
            String senderNickname;
            String senderRemark;

            if (msg.isSend == 1) {
              senderRole = '我';
              senderWxid = currentAccountWxid;
              senderNickname = myDisplayName;
              senderRemark = _getRemarkOrAlias(currentAccountInfo);
            } else if (session.isGroup && msg.senderUsername != null) {
              senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
              senderWxid = _sanitizeUsername(msg.senderUsername ?? '');
              final info = senderContactInfos[msg.senderUsername] ?? {};
              senderNickname = _resolvePreferredName(
                info,
                fallback: senderRole,
              );
              senderRemark = _getRemarkOrAlias(info);
            } else {
              senderRole = session.displayName ?? session.username;
              senderWxid = _sanitizeUsername(session.username);
              senderNickname = _resolvePreferredName(
                contactInfo,
                fallback: senderRole,
              );
              senderRemark = _getRemarkOrAlias(contactInfo);
            }

            senderWxid = _sanitizeUsername(senderWxid);

            final mediaItem = mediaHelper == null
                ? null
                : await mediaHelper.exportForMessage(msg);
            final exportContent = _resolveExportContent(msg, mediaItem);

            sheet.getRangeByIndex(currentRow, 1).setNumber(index.toDouble());
            _setTextSafe(sheet, currentRow, 2, msg.formattedCreateTime);
            _setTextSafe(sheet, currentRow, 3, senderNickname);
            _setTextSafe(sheet, currentRow, 4, senderWxid);
            _setTextSafe(sheet, currentRow, 5, senderRemark);
            _setTextSafe(sheet, currentRow, 6, senderRole);
            _setTextSafe(sheet, currentRow, 7, msg.typeDescription);
            _setTextSafe(sheet, currentRow, 8, exportContent);
            currentRow++;
          }

          if (index % 500 == 0) {
            onProgress?.call(index, totalMessages, '处理消息数据...');
          }
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );
      onProgress?.call(index, totalMessages, '处理消息数据...');

      final avatars = exportAvatars
          ? await _buildAvatarIndexFromUsernames(
              session: session,
              senderUsernames: senderUsernames,
              contactInfo: contactInfo,
              senderDisplayNames: senderDisplayNames,
              rawMyWxid: rawAccountWxid,
              myDisplayName: myDisplayName,
            )
          : <String, Map<String, String>>{};

      sheet.getRangeByIndex(1, 1).columnWidth = 8;
      sheet.getRangeByIndex(1, 2).columnWidth = 20;
      sheet.getRangeByIndex(1, 3).columnWidth = 20;
      sheet.getRangeByIndex(1, 4).columnWidth = 25;
      sheet.getRangeByIndex(1, 5).columnWidth = 20;
      sheet.getRangeByIndex(1, 6).columnWidth = 18;
      sheet.getRangeByIndex(1, 7).columnWidth = 12;
      sheet.getRangeByIndex(1, 8).columnWidth = 50;

      if (avatars.isNotEmpty) {
        final avatarSheet = workbook.worksheets.addWithName('头像索引');
        _setTextSafe(avatarSheet, 1, 1, '头像ID');
        _setTextSafe(avatarSheet, 1, 2, '显示名称');
        _setTextSafe(avatarSheet, 1, 3, 'Base64');
        int avatarRow = 2;
        avatars.forEach((key, meta) {
          _setTextSafe(avatarSheet, avatarRow, 1, key);
          _setTextSafe(avatarSheet, avatarRow, 2, meta['displayName'] ?? key);
          _setTextSafe(avatarSheet, avatarRow, 3, meta['base64'] ?? '');
          avatarRow++;
        });
        avatarSheet.getRangeByIndex(1, 1).columnWidth = 18;
        avatarSheet.getRangeByIndex(1, 2).columnWidth = 24;
        avatarSheet.getRangeByIndex(1, 3).columnWidth = 80;
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) {
          workbook.dispose();
          return false;
        }
        filePath = outputFile;
      }

      onProgress?.call(index, totalMessages, '保存工作簿...');
      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      onProgress?.call(index, totalMessages, '写入文件...');
      return await _writeBytesInBackground(filePath, Uint8List.fromList(bytes));
    } catch (e, stack) {
      workbook.dispose();
      await logger.error(
        'ChatExportService',
        'exportToExcelStream 失败: $e\n$stack',
      );
      return false;
    }
  }

  /// 流式导出聊天记录为 PostgreSQL 格式
  Future<bool> exportToPostgreSQLStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
    MediaExportOptions? mediaOptions,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      final senderUsernames = <String>{
        if (trimmedAccountWxid.isNotEmpty) trimmedAccountWxid,
      };
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernames.add(currentAccountWxid);
      }

      final senderDisplayNames = <String, String>{};

      final senderContactInfos = <String, Map<String, String>>{};

      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      if (currentAccountWxid.isNotEmpty) {
        senderContactInfos[currentAccountWxid] = currentAccountInfo;
      }
      if (trimmedAccountWxid.isNotEmpty) {
        senderContactInfos[trimmedAccountWxid] = currentAccountInfo;
      }

      final mediaHelper = (mediaOptions != null && mediaOptions.enabled)
          ? _MediaExportHelper(_databaseService, mediaOptions)
          : null;

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.sql';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      sink.writeln(
        'DROP TABLE IF EXISTS "public"."echotrace"; CREATE TABLE "public"."echotrace" ("id" int4 NOT NULL GENERATED BY DEFAULT AS IDENTITY ( INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1 ), "date" date, "time" time(6), "is_send" bool, "content" text COLLATE "pg_catalog"."default", "send_name" varchar(255) COLLATE "pg_catalog"."default", "timestamp" timestamp(6),   CONSTRAINT "echotrace_pkey" PRIMARY KEY ("id") );',
      );
      sink.writeln();
      sink.writeln('ALTER TABLE "public"."echotrace" OWNER TO "postgres";');
      sink.writeln();

      if (totalMessages > 0) {
        sink.writeln(
          'INSERT INTO "public"."echotrace" ("date", "time", "is_send", "content", "send_name", "timestamp") VALUES',
        );
      }

      var processed = 0;
      var isFirst = true;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          await _ensureSenderContactInfos(newUsernames, senderContactInfos);
          for (final msg in batch) {
            String senderRole;
            String senderNickname;

            if (msg.isSend == 1) {
              senderRole = '我';
              senderNickname = myDisplayName;
            } else if (session.isGroup && msg.senderUsername != null) {
              senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
              final info = senderContactInfos[msg.senderUsername] ?? {};
              senderNickname = _resolvePreferredName(
                info,
                fallback: senderRole,
              );
            } else {
              senderRole = session.displayName ?? session.username;
              senderNickname = _resolvePreferredName(
                contactInfo,
                fallback: senderRole,
              );
            }

            final dt = DateTime.fromMillisecondsSinceEpoch(
              msg.createTime * 1000,
            );
            final dateStr =
                '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
            final timeStr =
                '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
            final isSendBool = msg.isSend == 1 ? 'true' : 'false';
            final mediaItem = mediaHelper == null
                ? null
                : await mediaHelper.exportForMessage(msg);
            final exportContent = _resolveExportContent(msg, mediaItem);
            final contentEscaped = exportContent.replaceAll("'", "''");
            final sendNameEscaped = senderNickname.replaceAll("'", "''");
            final timestampStr = '$dateStr $timeStr';

            final line =
                "('$dateStr', '$timeStr', $isSendBool, '$contentEscaped', '$sendNameEscaped', '$timestampStr')";
            if (!isFirst) {
              sink!.writeln(',');
            }
            sink!.write(line);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '生成 SQL...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      if (totalMessages > 0) {
        sink.writeln(';');
      }

      await sink.flush();
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return true;
    } catch (e, stack) {
      await logger.error(
        'ChatExportService',
        'exportToPostgreSQLStream 失败: $e\n$stack',
      );
      return false;
    } finally {
      await sink?.close();
    }
  }

  String _generateHtmlFromData({
    required ChatSession session,
    required List<Map<String, dynamic>> messagesData,
    required Map<String, String> contactInfo,
    required Map<String, Map<String, String>> avatarIndex,
    required String? mediaBase,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="UTF-8">');
    buffer.writeln(
      '  <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    );
    buffer.writeln(
      '  <title>${_escapeHtml(session.displayName ?? session.username)} - 聊天记录</title>',
    );
    buffer.writeln('  <style>');
    buffer.writeln(_getHtmlStyles());
    buffer.writeln('  </style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('  <div class="container">');
    buffer.writeln('    <div class="header">');
    buffer.writeln('      <div class="header-main">');
    buffer.writeln(
      '        <h1>${_escapeHtml(session.displayName ?? session.username)}</h1>',
    );

    final nickname = contactInfo['nickname'] ?? '';
    final remark = _getRemarkOrAlias(contactInfo);
    final sanitizedSessionWxid = _sanitizeUsername(session.username);
    final hasDetails =
        nickname.isNotEmpty ||
        remark.isNotEmpty ||
        sanitizedSessionWxid.isNotEmpty;

    if (hasDetails) {
      buffer.writeln(
        '        <button class="info-menu-btn" id="info-menu-btn" type="button" title="查看详细信息">',
      );
      buffer.writeln(
        '          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">',
      );
      buffer.writeln('            <circle cx="12" cy="12" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="5" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="19" r="1"></circle>');
      buffer.writeln('          </svg>');
      buffer.writeln('        </button>');
      buffer.writeln('      </div>');
      buffer.writeln('      <div class="info-menu" id="info-menu">');
      buffer.writeln('        <div class="info-menu-content">');
      if (sanitizedSessionWxid.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">微信ID</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(sanitizedSessionWxid)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (nickname.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">昵称</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(nickname)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (remark.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">备注</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(remark)}</span>',
        );
        buffer.writeln('          </div>');
      }
      buffer.writeln('        </div>');
      buffer.writeln('      </div>');
    } else {
      buffer.writeln('      </div>');
    }

    buffer.writeln('      <div class="info">');
    buffer.writeln('        <span>${session.typeDescription}</span>');
    buffer.writeln('        <span>共 ${messagesData.length} 条消息</span>');
    if (mediaBase != null) {
      buffer.writeln('        <span>媒体目录: $mediaBase</span>');
    }
    buffer.writeln(
      '        <span>导出时间: ${DateTime.now().toString().split('.')[0]}</span>',
    );
    buffer.writeln('      </div>');
    buffer.writeln('    </div>');
    buffer.writeln('    <div class="messages" id="messages-container">');
    buffer.writeln('      <div class="loading">正在加载消息...</div>');
    buffer.writeln('    </div>');
    buffer.writeln(
      '    <div class="scroll-to-bottom" id="scroll-to-bottom" title="回到底部">↓</div>',
    );
    buffer.writeln('  </div>');
    buffer.writeln('  <script>');
    buffer.writeln('    const messagesData = ${jsonEncode(messagesData)};');
    buffer.writeln('    const avatarIndex = ${jsonEncode(avatarIndex)};');
    buffer.writeln('    const INITIAL_BATCH = 100; // 首次加载最新100条');
    buffer.writeln('    const BATCH_SIZE = 200; // 后续每批200条');
    buffer.writeln('    let loadedStart = messagesData.length; // 从末尾开始加载');
    buffer.writeln('    let isLoading = false;');
    buffer.writeln('    let allLoaded = false;');
    buffer.writeln('    ');
    buffer.writeln('    const TIME_GAP_SECONDS = 300;');
    buffer.writeln('    let lastShownTimestamp = null;');
    buffer.writeln('    function shouldShowTime(ts) {');
    buffer.writeln('      if (lastShownTimestamp === null) {');
    buffer.writeln('        lastShownTimestamp = ts;');
    buffer.writeln('        return true;');
    buffer.writeln('      }');
    buffer.writeln(
      '      if (Math.abs(ts - lastShownTimestamp) >= TIME_GAP_SECONDS) {',
    );
    buffer.writeln('        lastShownTimestamp = ts;');
    buffer.writeln('        return true;');
    buffer.writeln('      }');
    buffer.writeln('      return false;');
    buffer.writeln('    }');
    buffer.writeln(
      '    function createMessageElement(msg, showDate, showTime) {',
    );
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      if (showDate || showTime) {');
    buffer.writeln(
      '        const dateDivider = document.createElement("div");',
    );
    buffer.writeln('        dateDivider.className = "date-divider";');
    buffer.writeln(
      '        dateDivider.textContent = showDate ? msg.date : msg.time;',
    );
    buffer.writeln('        fragment.appendChild(dateDivider);');
    buffer.writeln('      }');
    buffer.writeln('      const messageEl = document.createElement("div");');
    buffer.writeln(
      '      messageEl.className = `message-item \${msg.isSend ? "sent" : "received"}`;',
    );
    buffer.writeln(
      '      const avatarHtml = msg.avatarKey && avatarIndex[msg.avatarKey] ?',
    );
    buffer.writeln(
      '        `<div class="avatar"><img src="data:image/png;base64,\${avatarIndex[msg.avatarKey].base64}" alt="\${avatarIndex[msg.avatarKey].displayName}"/></div>` :',
    );
    buffer.writeln('        `<div class="avatar placeholder"></div>`;');
    buffer.writeln(
      '      const bubbleClass = msg.isMedia ? "message-bubble media" : "message-bubble";',
    );
    buffer.writeln(
      '      messageEl.innerHTML = `<div class="message-row">\${avatarHtml}<div class="\${bubbleClass}"><div class="content">\${msg.content}</div></div></div>`;',
    );
    buffer.writeln(
      '      messageEl.setAttribute("data-time", msg.timeTooltip || msg.time);',
    );
    buffer.writeln('      fragment.appendChild(messageEl);');
    buffer.writeln('      return fragment;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function renderMessages(start, end, toTop = true) {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      let lastDate = null;');
    buffer.writeln('      for (let i = start; i < end; i++) {');
    buffer.writeln('        const msg = messagesData[i];');
    buffer.writeln('        const showDate = msg.date !== lastDate;');
    buffer.writeln('        const showTime = shouldShowTime(msg.timestamp);');
    buffer.writeln('        lastDate = msg.date;');
    buffer.writeln(
      '        fragment.appendChild(createMessageElement(msg, showDate, showTime));',
    );
    buffer.writeln('      }');
    buffer.writeln('      if (toTop) {');
    buffer.writeln(
      '        container.insertBefore(fragment, container.firstChild);',
    );
    buffer.writeln('      } else {');
    buffer.writeln('        container.appendChild(fragment);');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadInitialMessages() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      container.innerHTML = "";');
    buffer.writeln(
      '      const start = Math.max(0, messagesData.length - INITIAL_BATCH);',
    );
    buffer.writeln('      renderMessages(start, messagesData.length, false);');
    buffer.writeln('      loadedStart = start;');
    buffer.writeln('      updateScrollButton();');
    buffer.writeln('      scrollToBottom();');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadMoreMessages() {');
    buffer.writeln('      if (isLoading || allLoaded) return;');
    buffer.writeln('      isLoading = true;');
    buffer.writeln(
      '      const nextStart = Math.max(0, loadedStart - BATCH_SIZE);',
    );
    buffer.writeln('      if (nextStart === loadedStart) {');
    buffer.writeln('        allLoaded = true;');
    buffer.writeln('        isLoading = false;');
    buffer.writeln('        return;');
    buffer.writeln('      }');
    buffer.writeln(
      '      const oldScrollHeight = document.getElementById("messages-container").scrollHeight;',
    );
    buffer.writeln('      renderMessages(nextStart, loadedStart, true);');
    buffer.writeln(
      '      const newScrollHeight = document.getElementById("messages-container").scrollHeight;',
    );
    buffer.writeln(
      '      document.getElementById("messages-container").scrollTop = newScrollHeight - oldScrollHeight;',
    );
    buffer.writeln('      loadedStart = nextStart;');
    buffer.writeln('      isLoading = false;');
    buffer.writeln('      if (loadedStart === 0) {');
    buffer.writeln('        allLoaded = true;');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function scrollToBottom() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      container.scrollTop = container.scrollHeight;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function updateScrollButton() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln(
      '      const button = document.getElementById("scroll-to-bottom");',
    );
    buffer.writeln('      if (!container || !button) return;');
    buffer.writeln(
      '      const nearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 120;',
    );
    buffer.writeln(
      '      button.style.display = nearBottom ? "none" : "flex";',
    );
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln(
      '    document.getElementById("messages-container").addEventListener("scroll", () => {',
    );
    buffer.writeln(
      '      if (document.getElementById("messages-container").scrollTop === 0) {',
    );
    buffer.writeln('        loadMoreMessages();');
    buffer.writeln('      }');
    buffer.writeln('      updateScrollButton();');
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln(
      '    document.getElementById("scroll-to-bottom").addEventListener("click", scrollToBottom);',
    );
    buffer.writeln('    ');
    buffer.writeln('    if (document.getElementById("info-menu-btn")) {');
    buffer.writeln(
      '      document.getElementById("info-menu-btn").addEventListener("click", () => {',
    );
    buffer.writeln(
      '        document.getElementById("info-menu").classList.toggle("show");',
    );
    buffer.writeln('      });');
    buffer.writeln('      document.addEventListener("click", (event) => {');
    buffer.writeln(
      '        const menu = document.getElementById("info-menu");',
    );
    buffer.writeln(
      '        const btn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln('        if (!menu || !btn) return;');
    buffer.writeln(
      '        if (!menu.contains(event.target) && !btn.contains(event.target)) {',
    );
    buffer.writeln('          menu.classList.remove("show");');
    buffer.writeln('        }');
    buffer.writeln('      });');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    loadInitialMessages();');
    buffer.writeln('  </script>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }

  Set<String> _collectSenderUsernames(
    List<Message> batch,
    Set<String> senderUsernames,
    Map<String, String> senderDisplayNames,
  ) {
    final newUsernames = <String>{};
    for (final msg in batch) {
      final username = msg.senderUsername;
      if (username == null || username.trim().isEmpty) {
        continue;
      }
      senderUsernames.add(username);
      if (!senderDisplayNames.containsKey(username)) {
        newUsernames.add(username);
      }
    }
    return newUsernames;
  }

  Future<void> _ensureSenderDisplayNames(
    Set<String> newUsernames,
    Map<String, String> senderDisplayNames,
  ) async {
    if (newUsernames.isEmpty) return;
    try {
      final names = await _databaseService.getDisplayNames(
        newUsernames.toList(),
      );
      senderDisplayNames.addAll(names);
    } catch (_) {}
  }

  Future<void> _ensureSenderContactInfos(
    Set<String> newUsernames,
    Map<String, Map<String, String>> senderContactInfos,
  ) async {
    if (newUsernames.isEmpty) return;
    final futures = <Future<void>>[];
    for (final username in newUsernames) {
      if (senderContactInfos.containsKey(username)) continue;
      futures.add(
        _getContactInfo(username).then((info) {
          senderContactInfos[username] = info;
        }),
      );
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<Map<String, Map<String, String>>> _buildAvatarIndexFromUsernames({
    required ChatSession session,
    required Set<String> senderUsernames,
    required Map<String, String> contactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
  }) async {
    final targets = <String>{session.username, rawMyWxid, ...senderUsernames}
      ..removeWhere((u) => u.trim().isEmpty);

    if (targets.isEmpty) return {};

    final avatarUrls = await _databaseService.getAvatarUrls(targets.toList());
    if (avatarUrls.isEmpty) {
      return {};
    }

    final base64ByKey = <String, String>{};
    for (final entry in avatarUrls.entries) {
      final key = _sanitizeUsername(entry.key);
      if (key.isEmpty) continue;
      final encoded = await _loadAvatarBase64(entry.value);
      if (encoded != null && encoded.isNotEmpty) {
        base64ByKey[key] = encoded;
      }
    }

    if (base64ByKey.isEmpty) {
      return {};
    }

    final nameByKey = <String, String>{};
    void assignName(String username, String value) {
      final key = _sanitizeUsername(username);
      if (key.isEmpty || nameByKey.containsKey(key)) return;
      final trimmed = value.trim();
      nameByKey[key] = trimmed.isEmpty ? key : trimmed;
    }

    assignName(
      session.username,
      _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      ),
    );
    if (rawMyWxid.trim().isNotEmpty) {
      assignName(rawMyWxid, myDisplayName);
    }
    senderDisplayNames.forEach((username, display) {
      assignName(username, display);
    });
    base64ByKey.keys
        .where((key) => !nameByKey.containsKey(key))
        .forEach((key) => nameByKey[key] = key);

    final merged = <String, Map<String, String>>{};
    base64ByKey.forEach((key, value) {
      merged[key] = {'displayName': nameByKey[key] ?? key, 'base64': value};
    });

    return merged;
  }

  String _resolveExportContent(Message msg, _MediaExportItem? mediaItem) {
    if (mediaItem == null) return msg.displayContent;
    return mediaItem.relativePath;
  }

  String _formatHtmlContent(Message msg, _MediaExportItem? mediaItem) {
    if (mediaItem == null) return _escapeHtml(msg.displayContent);
    final path = _escapeHtml(mediaItem.relativePath);
    switch (mediaItem.kind) {
      case 'image':
        return '<img class="message-media image" src="$path" alt="图片" />';
      case 'emoji':
        return '<img class="message-media emoji" src="$path" alt="表情" />';
      case 'voice':
        return '<audio class="message-media voice" controls src="$path"></audio>';
      default:
        return msg.displayContent;
    }
  }

  Map<String, dynamic> _buildJsonMessageItem({
    required Message msg,
    required ChatSession session,
    required Map<String, String> contactInfo,
    required Map<String, String> myContactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
    required String myWxid,
    required bool exportAvatars,
    _MediaExportItem? mediaItem,
  }) {
    final isSend = msg.isSend == 1;
    final senderName = _resolveSenderDisplayName(
      msg: msg,
      session: session,
      isSend: isSend,
      contactInfo: contactInfo,
      myContactInfo: myContactInfo,
      senderDisplayNames: senderDisplayNames,
      myDisplayName: myDisplayName,
    );
    final senderWxid = _resolveSenderUsername(
      msg: msg,
      session: session,
      isSend: isSend,
      myWxid: myWxid,
    );
    final content = _resolveExportContent(msg, mediaItem);

    final item = <String, dynamic>{
      'localId': msg.localId,
      'createTime': msg.createTime,
      'formattedTime': msg.formattedCreateTime,
      'type': msg.typeDescription,
      'localType': msg.localType,
      'content': content,
      'isSend': msg.isSend,
      'senderUsername': senderWxid.isEmpty ? null : senderWxid,
      'senderDisplayName': senderName,
      'source': msg.source,
    };
    if (exportAvatars && senderWxid.isNotEmpty) {
      item['senderAvatarKey'] = senderWxid;
    }

    if (msg.localType == 47 && msg.emojiMd5 != null) {
      item['emojiMd5'] = msg.emojiMd5;
    }
    if (mediaItem != null) {
      item['mediaPath'] = mediaItem.relativePath;
    }

    return item;
  }

  Map<String, dynamic> _buildHtmlMessageData({
    required Message msg,
    required ChatSession session,
    required Map<String, String> senderDisplayNames,
    required String myWxid,
    required Map<String, String> contactInfo,
    required String myDisplayName,
    required bool exportAvatars,
    _MediaExportItem? mediaItem,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
    final isSend = msg.isSend == 1;

    String senderName = '';
    if (!isSend && session.isGroup && msg.senderUsername != null) {
      senderName = senderDisplayNames[msg.senderUsername] ?? '群成员';
    } else if (!isSend) {
      senderName = _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      );
    } else {
      senderName = myDisplayName;
    }
    final avatarKey = _resolveSenderUsername(
      msg: msg,
      session: session,
      isSend: isSend,
      myWxid: myWxid,
    );

    return {
      'date':
          '${msgDate.year}-${msgDate.month.toString().padLeft(2, '0')}-${msgDate.day.toString().padLeft(2, '0')}',
      'time':
          '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}:${msgDate.second.toString().padLeft(2, '0')}',
      'timeTooltip':
          '${msgDate.year}-${msgDate.month.toString().padLeft(2, '0')}-${msgDate.day.toString().padLeft(2, '0')} '
          '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}:${msgDate.second.toString().padLeft(2, '0')}',
      'isSend': isSend,
      'isMedia': mediaItem != null,
      'content': _formatHtmlContent(msg, mediaItem),
      'senderName': senderName,
      'timestamp': msg.createTime,
      'avatarKey': exportAvatars && avatarKey.isNotEmpty ? avatarKey : null,
    };
  }

  String _buildHtmlHeaderStream({
    required ChatSession session,
    required Map<String, String> contactInfo,
    required int totalMessages,
    required String exportTime,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="UTF-8">');
    buffer.writeln(
      '  <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    );
    buffer.writeln(
      '  <title>${_escapeHtml(session.displayName ?? session.username)} - 聊天记录</title>',
    );
    buffer.writeln('  <style>');
    buffer.writeln(_getHtmlStyles());
    buffer.writeln('  </style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('  <div class="container">');
    buffer.writeln('    <div class="header">');
    buffer.writeln('      <div class="header-main">');
    buffer.writeln(
      '        <h1>${_escapeHtml(session.displayName ?? session.username)}</h1>',
    );

    final nickname = contactInfo['nickname'] ?? '';
    final remark = _getRemarkOrAlias(contactInfo);
    final sanitizedSessionWxid = _sanitizeUsername(session.username);
    final hasDetails =
        nickname.isNotEmpty ||
        remark.isNotEmpty ||
        sanitizedSessionWxid.isNotEmpty;

    if (hasDetails) {
      buffer.writeln(
        '        <button class="info-menu-btn" id="info-menu-btn" type="button" title="查看详细信息">',
      );
      buffer.writeln(
        '          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">',
      );
      buffer.writeln('            <circle cx="12" cy="12" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="5" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="19" r="1"></circle>');
      buffer.writeln('          </svg>');
      buffer.writeln('        </button>');
      buffer.writeln('      </div>');
      buffer.writeln('      <div class="info-menu" id="info-menu">');
      buffer.writeln('        <div class="info-menu-content">');
      if (sanitizedSessionWxid.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">微信ID</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(sanitizedSessionWxid)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (nickname.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">昵称</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(nickname)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (remark.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">备注</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(remark)}</span>',
        );
        buffer.writeln('          </div>');
      }
      buffer.writeln('        </div>');
      buffer.writeln('      </div>');
    } else {
      buffer.writeln('      </div>');
    }

    buffer.writeln('      <div class="info">');
    buffer.writeln('        <span>${session.typeDescription}</span>');
    buffer.writeln('        <span>共 $totalMessages 条消息</span>');
    buffer.writeln('        <span>导出时间: $exportTime</span>');
    buffer.writeln('      </div>');
    buffer.writeln('    </div>');
    buffer.writeln('    <div class="messages" id="messages-container">');
    buffer.writeln('      <div class="loading">正在加载消息...</div>');
    buffer.writeln('    </div>');
    buffer.writeln(
      '    <div class="scroll-to-bottom" id="scroll-to-bottom" title="回到底部">↓</div>',
    );
    buffer.writeln('  </div>');
    buffer.writeln('  <script>');
    buffer.writeln('    const messagesData = [');
    return buffer.toString();
  }

  String _buildHtmlFooterStream(Map<String, Map<String, String>> avatarIndex) {
    final buffer = StringBuffer();
    buffer.writeln('    const avatarIndex = ${jsonEncode(avatarIndex)};');
    buffer.writeln('    const INITIAL_BATCH = 100; // 首次加载最新100条');
    buffer.writeln('    const BATCH_SIZE = 200; // 后续每批200条');
    buffer.writeln('    let loadedStart = messagesData.length; // 从末尾开始加载');
    buffer.writeln('    let isLoading = false;');
    buffer.writeln('    let allLoaded = false;');
    buffer.writeln('    ');
    buffer.writeln('    const TIME_GAP_SECONDS = 300;');
    buffer.writeln('    let lastShownTimestamp = null;');
    buffer.writeln('    function shouldShowTime(ts) {');
    buffer.writeln('      if (lastShownTimestamp === null) {');
    buffer.writeln('        lastShownTimestamp = ts;');
    buffer.writeln('        return true;');
    buffer.writeln('      }');
    buffer.writeln(
      '      if (Math.abs(ts - lastShownTimestamp) >= TIME_GAP_SECONDS) {',
    );
    buffer.writeln('        lastShownTimestamp = ts;');
    buffer.writeln('        return true;');
    buffer.writeln('      }');
    buffer.writeln('      return false;');
    buffer.writeln('    }');
    buffer.writeln(
      '    function createMessageElement(msg, showDate, showTime) {',
    );
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      if (showDate || showTime) {');
    buffer.writeln(
      '        const dateDivider = document.createElement("div");',
    );
    buffer.writeln('        dateDivider.className = "date-divider";');
    buffer.writeln(
      '        dateDivider.textContent = showDate ? msg.date : msg.time;',
    );
    buffer.writeln('        fragment.appendChild(dateDivider);');
    buffer.writeln('      }');
    buffer.writeln('      const messageEl = document.createElement("div");');
    buffer.writeln(
      '      messageEl.className = `message-item \${msg.isSend ? "sent" : "received"}`;',
    );
    buffer.writeln(
      '      const avatarHtml = msg.avatarKey && avatarIndex[msg.avatarKey] ?',
    );
    buffer.writeln(
      '        `<div class="avatar"><img src="data:image/png;base64,\${avatarIndex[msg.avatarKey].base64}" alt="\${avatarIndex[msg.avatarKey].displayName}"/></div>` :',
    );
    buffer.writeln('        `<div class="avatar placeholder"></div>`;');
    buffer.writeln(
      '      const bubbleClass = msg.isMedia ? "message-bubble media" : "message-bubble";',
    );
    buffer.writeln(
      '      messageEl.innerHTML = `<div class="message-row">\${avatarHtml}<div class="\${bubbleClass}"><div class="content">\${msg.content}</div></div></div>`;',
    );
    buffer.writeln(
      '      messageEl.setAttribute("data-time", msg.timeTooltip || msg.time);',
    );
    buffer.writeln('      fragment.appendChild(messageEl);');
    buffer.writeln('      return fragment;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function renderMessages(start, end, toTop = true) {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      let lastDate = null;');
    buffer.writeln('      for (let i = start; i < end; i++) {');
    buffer.writeln('        const msg = messagesData[i];');
    buffer.writeln('        const showDate = msg.date !== lastDate;');
    buffer.writeln('        const showTime = shouldShowTime(msg.timestamp);');
    buffer.writeln('        lastDate = msg.date;');
    buffer.writeln(
      '        fragment.appendChild(createMessageElement(msg, showDate, showTime));',
    );
    buffer.writeln('      }');
    buffer.writeln('      if (toTop) {');
    buffer.writeln(
      '        container.insertBefore(fragment, container.firstChild);',
    );
    buffer.writeln('      } else {');
    buffer.writeln('        container.appendChild(fragment);');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadInitialMessages() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      container.innerHTML = "";');
    buffer.writeln('      lastShownTimestamp = null;');
    buffer.writeln(
      '      const start = Math.max(0, messagesData.length - INITIAL_BATCH);',
    );
    buffer.writeln('      renderMessages(start, messagesData.length, false);');
    buffer.writeln('      loadedStart = start;');
    buffer.writeln('      if (start === 0) allLoaded = true;');
    buffer.writeln(
      '      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");',
    );
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln('        scrollToBottomBtn.classList.remove("visible");');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadMoreMessages() {');
    buffer.writeln('      if (isLoading || allLoaded) return;');
    buffer.writeln('      isLoading = true;');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      const scrollHeightBefore = container.scrollHeight;');
    buffer.writeln(
      '      const newStart = Math.max(0, loadedStart - BATCH_SIZE);',
    );
    buffer.writeln('      renderMessages(newStart, loadedStart, true);');
    buffer.writeln('      loadedStart = newStart;');
    buffer.writeln('      if (newStart === 0) allLoaded = true;');
    buffer.writeln('      const scrollHeightAfter = container.scrollHeight;');
    buffer.writeln(
      '      container.scrollTop += scrollHeightAfter - scrollHeightBefore;',
    );
    buffer.writeln('      isLoading = false;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function toggleInfoMenu() {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln('      if (!menu) return;');
    buffer.writeln('      menu.classList.toggle("show");');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function handleScroll() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      if (container.scrollTop < 200 && !allLoaded) {');
    buffer.writeln('        loadMoreMessages();');
    buffer.writeln('      }');
    buffer.writeln(
      '      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");',
    );
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln(
      '        const isBottom = container.scrollHeight - container.scrollTop <= container.clientHeight + 100;',
    );
    buffer.writeln(
      '        scrollToBottomBtn.classList.toggle("visible", !isBottom);',
    );
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function scrollToBottom() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (!container) return;');
    buffer.writeln(
      '      container.scrollTo({ top: container.scrollHeight, behavior: "smooth" });',
    );
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    document.addEventListener("click", (e) => {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln(
      '      const btn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln(
      '      if (menu && btn && !menu.contains(e.target) && !btn.contains(e.target)) {',
    );
    buffer.writeln('        menu.classList.remove("show");');
    buffer.writeln('      }');
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln(
      '    const infoMenuBtn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln('    if (infoMenuBtn) {');
    buffer.writeln('      infoMenuBtn.addEventListener("click", (event) => {');
    buffer.writeln('        event.stopPropagation();');
    buffer.writeln('        toggleInfoMenu();');
    buffer.writeln('      });');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    window.addEventListener("DOMContentLoaded", () => {');
    buffer.writeln('      loadInitialMessages();');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      if (container) {');
    buffer.writeln(
      '        container.addEventListener("scroll", handleScroll);',
    );
    buffer.writeln('      }');
    buffer.writeln(
      '      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");',
    );
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln(
      '        scrollToBottomBtn.addEventListener("click", scrollToBottom);',
    );
    buffer.writeln('      }');
    buffer.writeln('    });');
    buffer.writeln('  </script>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }

  Future<Map<String, Map<String, String>>> _buildAvatarIndex({
    required ChatSession session,
    required List<Message> messages,
    required Map<String, String> contactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
  }) async {
    final targets = <String>{
      session.username,
      rawMyWxid,
      ...messages.map((m) => m.senderUsername).whereType<String>(),
    }..removeWhere((u) => u.trim().isEmpty);

    if (targets.isEmpty) return {};

    final avatarUrls = await _databaseService.getAvatarUrls(targets.toList());
    if (avatarUrls.isEmpty) {
      return {};
    }

    final base64ByKey = <String, String>{};
    for (final entry in avatarUrls.entries) {
      final key = _sanitizeUsername(entry.key);
      if (key.isEmpty) continue;
      final encoded = await _loadAvatarBase64(entry.value);
      if (encoded != null && encoded.isNotEmpty) {
        base64ByKey[key] = encoded;
      }
    }

    if (base64ByKey.isEmpty) {
      return {};
    }

    final nameByKey = <String, String>{};
    void assignName(String username, String value) {
      final key = _sanitizeUsername(username);
      if (key.isEmpty || nameByKey.containsKey(key)) return;
      final trimmed = value.trim();
      nameByKey[key] = trimmed.isEmpty ? key : trimmed;
    }

    assignName(
      session.username,
      _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      ),
    );
    if (rawMyWxid.trim().isNotEmpty) {
      assignName(rawMyWxid, myDisplayName);
    }
    senderDisplayNames.forEach((username, display) {
      assignName(username, display);
    });
    base64ByKey.keys
        .where((key) => !nameByKey.containsKey(key))
        .forEach((key) => nameByKey[key] = key);

    final merged = <String, Map<String, String>>{};
    base64ByKey.forEach((key, value) {
      merged[key] = {'displayName': nameByKey[key] ?? key, 'base64': value};
    });

    return merged;
  }

  Future<String?> _loadAvatarBase64(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    final cached = _avatarBase64CacheByUrl[trimmed];
    if (cached != null) return cached;

    if (trimmed.startsWith('data:')) {
      final parts = trimmed.split(',');
      if (parts.length >= 2) {
        final payload = parts.sublist(1).join(',');
        _avatarBase64CacheByUrl[trimmed] = payload;
        return payload;
      }
    }

    final resolvedPath = trimmed.startsWith('file://')
        ? PathUtils.fromUri(trimmed)
        : trimmed;
    try {
      final file = File(resolvedPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final encoded = base64Encode(bytes);
        _avatarBase64CacheByUrl[trimmed] = encoded;
        return encoded;
      }
    } catch (_) {}

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      HttpClient? client;
      try {
        final uri = Uri.parse(trimmed);
        client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 10));
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        if (response.statusCode == 200) {
          final builder = BytesBuilder();
          await for (final chunk in response) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.isNotEmpty) {
            final encoded = base64Encode(bytes);
            _avatarBase64CacheByUrl[trimmed] = encoded;
            return encoded;
          }
        }
      } catch (_) {
        // 忽略远程获取错误，继续返回空字符串
      } finally {
        client?.close(force: true);
      }
    }

    _avatarBase64CacheByUrl[trimmed] = '';
    return '';
  }

  Future<int> _safeGetMessageCount(String sessionId) async {
    try {
      return await _databaseService.getMessageCount(sessionId);
    } catch (_) {
      return 0;
    }
  }

  String _sanitizeForExcel(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }

    // XML 1.0 valid chars: #x9 | #xA | #xD | #x20-#xD7FF | #xE000-#xFFFD | #x10000-#x10FFFF
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 0x9 || rune == 0xA || rune == 0xD) {
        buffer.writeCharCode(rune);
        continue;
      }
      final inBasicPlane = rune >= 0x20 && rune <= 0xD7FF;
      final inSupplementary = rune >= 0xE000 && rune <= 0xFFFD;
      final inAstral = rune >= 0x10000 && rune <= 0x10FFFF;
      if (inBasicPlane || inSupplementary || inAstral) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  void _setTextSafe(Worksheet sheet, int row, int column, String? value) {
    sheet.getRangeByIndex(row, column).setText(_sanitizeForExcel(value));
  }

  Future<String> _buildMyDisplayName(
    String myWxid,
    Map<String, String> myContactInfo,
  ) async {
    final trimmedWxid = myWxid.trim();
    final sanitizedWxid = _sanitizeUsername(myWxid);
    final fallbackBase = sanitizedWxid.isNotEmpty
        ? sanitizedWxid
        : (trimmedWxid.isNotEmpty ? trimmedWxid : '我');
    final preferred = _resolvePreferredName(
      myContactInfo,
      fallback: fallbackBase,
    );

    if (preferred != fallbackBase || sanitizedWxid.isEmpty) {
      return preferred;
    }

    try {
      final candidates = <String>{trimmedWxid, sanitizedWxid}
        ..removeWhere((c) => c.isEmpty);

      if (candidates.isEmpty) {
        return preferred;
      }

      final names = await _databaseService.getDisplayNames(candidates.toList());
      for (final candidate in candidates) {
        final resolved = names[candidate];
        if (resolved != null && resolved.trim().isNotEmpty) {
          return resolved.trim();
        }
      }
    } catch (_) {}

    await _logMissingDisplayName(
      myWxid,
      isSelf: true,
      details: 'contact/userinfo/getDisplayNames 均未匹配到昵称/备注',
    );

    return preferred;
  }

  String _resolveSenderDisplayName({
    required Message msg,
    required ChatSession session,
    required bool isSend,
    required Map<String, String> contactInfo,
    required Map<String, String> myContactInfo,
    required Map<String, String> senderDisplayNames,
    required String myDisplayName,
  }) {
    if (isSend) {
      return myDisplayName;
    }

    if (session.isGroup) {
      final groupSender = msg.senderUsername;
      if (groupSender != null && groupSender.isNotEmpty) {
        final display = senderDisplayNames[groupSender];
        if (display != null && display.trim().isNotEmpty) {
          return display;
        }
      }
      return '群成员';
    }

    return _resolvePreferredName(
      contactInfo,
      fallback: session.displayName ?? session.username,
    );
  }

  String _resolveSenderUsername({
    required Message msg,
    required ChatSession session,
    required bool isSend,
    required String myWxid,
  }) {
    String candidate = '';

    if (isSend) {
      if (myWxid.isNotEmpty) {
        candidate = myWxid;
      } else if (msg.senderUsername != null && msg.senderUsername!.isNotEmpty) {
        candidate = msg.senderUsername!;
      } else {
        candidate = session.username;
      }
    } else if (session.isGroup) {
      candidate = msg.senderUsername?.isNotEmpty == true
          ? msg.senderUsername!
          : session.username;
    } else {
      candidate = session.username;
    }

    return _sanitizeUsername(candidate);
  }

  String _sanitizeUsername(String input) {
    final normalized = input.replaceAll(
      RegExp(r'[\u00A0\u2000-\u200B\u202F\u205F\u3000]'),
      ' ',
    );
    final trimmed = normalized.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAll(
      RegExp(r'[\s\u00A0\u2000-\u200B\u202F\u205F\u3000]+'),
      '_',
    );
  }

  String _resolvePreferredName(
    Map<String, String> info, {
    required String fallback,
  }) {
    final remark = info['remark'];
    if (_hasMeaningfulValue(remark)) {
      return remark!;
    }

    final nickname = info['nickname'];
    if (_hasMeaningfulValue(nickname)) {
      return nickname!;
    }

    final alias = info['alias'];
    if (_hasMeaningfulValue(alias)) {
      return alias!;
    }
    return fallback;
  }

  String _getRemarkOrAlias(Map<String, String> info) {
    final remark = info['remark'];
    if (_hasMeaningfulValue(remark)) {
      return remark!;
    }
    final nickname = info['nickname'];
    if (_hasMeaningfulValue(nickname)) {
      return nickname!;
    }
    final alias = info['alias'];
    if (_hasMeaningfulValue(alias)) {
      return alias!;
    }
    return '';
  }

  Future<bool> exportContactsToExcel({
    String? directoryPath,
    String? filePath,
    List<ContactRecord>? contacts,
    bool includeStrangers = false,
    bool includeChatroomParticipants = false,
  }) async {
    final Workbook workbook = Workbook();
    try {
      final contactList =
          contacts ??
          await _databaseService.getAllContacts(
            includeStrangers: includeStrangers,
            includeChatroomParticipants: includeChatroomParticipants,
          );

      if (contactList.isEmpty) {
        workbook.dispose();
        return false;
      }

      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '通讯录';
      } else {
        sheet = workbook.worksheets.addWithName('通讯录');
      }

      int currentRow = 1;
      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '昵称');
      _setTextSafe(sheet, currentRow, 3, '微信ID');
      _setTextSafe(sheet, currentRow, 4, '备注');
      _setTextSafe(sheet, currentRow, 5, '微信号');
      currentRow++;

      for (int i = 0; i < contactList.length; i++) {
        final record = contactList[i];
        final contact = record.contact;
        final nickname = contact.nickName.isNotEmpty
            ? contact.nickName
            : contact.displayName;
        sheet.getRangeByIndex(currentRow, 1).setNumber(i + 1);
        _setTextSafe(sheet, currentRow, 2, nickname);
        _setTextSafe(sheet, currentRow, 3, contact.username);
        _setTextSafe(sheet, currentRow, 4, contact.remark);
        _setTextSafe(sheet, currentRow, 5, contact.alias);
        currentRow++;
      }

      sheet.getRangeByIndex(1, 1).columnWidth = 8;
      sheet.getRangeByIndex(1, 2).columnWidth = 22;
      sheet.getRangeByIndex(1, 3).columnWidth = 26;
      sheet.getRangeByIndex(1, 4).columnWidth = 22;
      sheet.getRangeByIndex(1, 5).columnWidth = 18;

      String? resolvedFilePath = filePath;
      if (resolvedFilePath == null) {
        if (directoryPath != null && directoryPath.isNotEmpty) {
          final fileName = '通讯录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
          resolvedFilePath = PathUtils.join(directoryPath, fileName);
        } else {
          final suggestedName =
              '通讯录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
          final outputFile = await FilePicker.platform.saveFile(
            dialogTitle: '保存通讯录',
            fileName: suggestedName,
          );
          if (outputFile == null) {
            workbook.dispose();
            return false;
          }
          resolvedFilePath = outputFile;
        }
      }

      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeBytesInBackground(
        resolvedFilePath,
        Uint8List.fromList(bytes),
      );
    } catch (e) {
      workbook.dispose();
      return false;
    }
  }

  /// 获取 HTML 样式
  String _getHtmlStyles() {
    return '''
      * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
      }
      
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Helvetica Neue", Arial, sans-serif;
        background: linear-gradient(to bottom, #f7f8fa 0%, #e8eaf0 100%);
        color: #1a1a1a;
        line-height: 1.6;
        min-height: 100vh;
      }
      
      .container {
        max-width: 900px;
        margin: 0 auto;
        background: transparent;
        min-height: 100vh;
        padding: 20px;
      }
      
      .header {
        background: linear-gradient(135deg, #09c269 0%, #07b961 50%, #06ae56 100%);
        color: white;
        padding: 32px 28px;
        border-radius: 16px;
        text-align: center;
        box-shadow: 0 8px 24px rgba(7, 193, 96, 0.25), 0 4px 8px rgba(0, 0, 0, 0.08);
        margin-bottom: 24px;
        position: relative;
        overflow: hidden;
      }
      
      .header::before {
        content: '';
        position: absolute;
        top: -50%;
        right: -20%;
        width: 200px;
        height: 200px;
        background: rgba(255, 255, 255, 0.1);
        border-radius: 50%;
        filter: blur(40px);
      }
      
      .header::after {
        content: '';
        position: absolute;
        bottom: -30%;
        left: -10%;
        width: 150px;
        height: 150px;
        background: rgba(255, 255, 255, 0.08);
        border-radius: 50%;
        filter: blur(30px);
      }
      
      .header-main {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 12px;
        position: relative;
        z-index: 1;
        margin-bottom: 12px;
      }

      .header h1 {
        font-size: 26px;
        font-weight: 600;
        letter-spacing: 0.5px;
        margin: 0;
      }

      .info-menu-btn {
        background: rgba(255, 255, 255, 0.2);
        border: none;
        border-radius: 50%;
        width: 36px;
        height: 36px;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        transition: all 0.3s ease;
        color: white;
        backdrop-filter: blur(10px);
      }

      .info-menu-btn:hover {
        background: rgba(255, 255, 255, 0.3);
        transform: scale(1.05);
      }

      .info-menu-btn:active {
        transform: scale(0.95);
      }

      .info-menu {
        position: absolute;
        top: 100%;
        right: 20px;
        margin-top: 8px;
        background: white;
        border-radius: 12px;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.15);
        opacity: 0;
        visibility: hidden;
        transform: translateY(-10px);
        transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        z-index: 1000;
        min-width: 280px;
      }

      .info-menu.show {
        opacity: 1;
        visibility: visible;
        transform: translateY(0);
      }

      .info-menu-content {
        padding: 16px;
      }

      .info-item {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 12px;
        border-radius: 8px;
        transition: background 0.2s ease;
      }

      .info-item:hover {
        background: rgba(7, 193, 96, 0.05);
      }

      .info-item:not(:last-child) {
        border-bottom: 1px solid rgba(0, 0, 0, 0.05);
      }

      .info-label {
        font-size: 13px;
        font-weight: 600;
        color: #666;
        margin-right: 16px;
      }

      .info-value {
        font-size: 14px;
        color: #333;
        font-weight: 500;
        text-align: right;
        word-break: break-all;
      }
      
      .header .info {
        display: flex;
        justify-content: center;
        align-items: center;
        gap: 20px;
        font-size: 14px;
        opacity: 0.95;
        flex-wrap: wrap;
        position: relative;
        z-index: 1;
      }
      
      .header .info span {
        display: inline-flex;
        align-items: center;
        background: rgba(255, 255, 255, 0.15);
        padding: 6px 14px;
        border-radius: 20px;
        backdrop-filter: blur(10px);
        gap: 6px;
        transition: all 0.3s ease;
      }
      
      .header .info span:hover {
        background: rgba(255, 255, 255, 0.22);
        transform: translateY(-1px);
      }
      
      .header .info span::before {
        content: '';
        width: 4px;
        height: 4px;
        background: currentColor;
        border-radius: 50%;
        opacity: 0.8;
      }

      .messages {
        background: white;
        padding: 28px 24px;
        border-radius: 16px;
        box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
        min-height: 400px;
        max-height: calc(100vh - 200px);
        overflow-y: auto;
        position: relative;
      }
      
      .loading {
        text-align: center;
        padding: 40px;
        color: #999;
        font-size: 14px;
      }
      
      .scroll-to-bottom {
        position: fixed;
        bottom: 40px;
        right: 40px;
        width: 48px;
        height: 48px;
        background: linear-gradient(135deg, #09c269 0%, #07b961 100%);
        color: white;
        border-radius: 50%;
        display: none;
        align-items: center;
        justify-content: center;
        font-size: 24px;
        cursor: pointer;
        box-shadow: 0 4px 16px rgba(7, 193, 96, 0.35);
        transition: all 0.3s ease;
        z-index: 1000;
        user-select: none;
      }
      
      .scroll-to-bottom:hover {
        transform: translateY(-3px);
        box-shadow: 0 6px 24px rgba(7, 193, 96, 0.45);
      }
      
      .scroll-to-bottom:active {
        transform: translateY(-1px);
      }
      
      .date-separator {
        text-align: center;
        color: #8c8c8c;
        font-size: 13px;
        margin: 28px 0;
        padding: 8px 16px;
        display: inline-block;
        background: linear-gradient(135deg, rgba(0, 0, 0, 0.04) 0%, rgba(0, 0, 0, 0.06) 100%);
        border-radius: 20px;
        position: relative;
        left: 50%;
        transform: translateX(-50%);
        font-weight: 500;
        letter-spacing: 0.3px;
        backdrop-filter: blur(10px);
      }

      .date-divider {
        text-align: center;
        color: #8b8b8b;
        font-size: 12px;
        margin: 22px auto;
        padding: 6px 14px;
        display: inline-block;
        background: #f1f1f1;
        border-radius: 999px;
        font-weight: 500;
        letter-spacing: 0.2px;
        box-shadow: 0 1px 0 rgba(0, 0, 0, 0.05);
        position: relative;
        left: 50%;
        transform: translateX(-50%);
      }
      
      .message-item {
        margin-bottom: 20px;
        display: flex;
        flex-direction: column;
        position: relative;
        width: 100%;
        padding: 4px 0;
        animation: slideIn 0.4s cubic-bezier(0.34, 1.56, 0.64, 1);
      }

      .message-item::after {
        content: attr(data-time);
        position: absolute;
        top: -22px;
        max-width: 70%;
        padding: 4px 10px;
        border-radius: 12px;
        background: rgba(0, 0, 0, 0.65);
        color: #fff;
        font-size: 11px;
        opacity: 0;
        pointer-events: none;
        transform: translateY(4px);
        transition: opacity 0.2s ease, transform 0.2s ease;
        white-space: nowrap;
      }

      .message-item.sent::after {
        right: 46px;
      }

      .message-item.received::after {
        left: 46px;
      }

      .message-item:hover::after {
        opacity: 1;
        transform: translateY(0);
      }

      .avatar {
        width: 36px;
        height: 36px;
        border-radius: 50%;
        overflow: hidden;
        flex-shrink: 0;
        background: rgba(255, 255, 255, 0.6);
      }

      .avatar img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        display: block;
      }

      .avatar.placeholder {
        background: rgba(255, 255, 255, 0.45);
      }
      
      @keyframes slideIn {
        from {
          opacity: 0;
          transform: translateY(15px) scale(0.95);
        }
        to {
          opacity: 1;
          transform: translateY(0) scale(1);
        }
      }
      
      .message-item.sent {
        align-items: flex-end;
      }
      
      .message-item.received {
        align-items: flex-start;
      }

      .message-bubble.media {
        background: transparent;
        box-shadow: none;
        border: none;
        padding: 0;
        min-width: auto;
      }

      .message-bubble.media::after {
        display: none;
      }

      .message-bubble.media:hover {
        transform: none;
        box-shadow: none;
      }

      .message-row {
        display: flex;
        align-items: flex-end;
        gap: 10px;
        width: 100%;
      }

      .message-item.sent .message-row {
        flex-direction: row-reverse;
      }

      .message-item.sent .sender-name {
        text-align: right;
      }
      
      .sender-name {
        font-size: 13px;
        color: #666;
        margin-bottom: 8px;
        padding: 0 14px;
        font-weight: 500;
      }
      
      .message-bubble {
        max-width: 68%;
        min-width: 80px;
        padding: 12px 16px;
        position: relative;
        word-break: break-word;
        transition: transform 0.2s ease, box-shadow 0.2s ease;
      }
      
      .message-bubble:hover {
        transform: translateY(-2px);
      }
      
      .sent .message-bubble {
        background: linear-gradient(135deg, #a0f47c 0%, #95ec69 100%);
        color: #1a1a1a;
        border-radius: 18px 18px 4px 18px;
        box-shadow: 0 3px 12px rgba(149, 236, 105, 0.3), 0 1px 3px rgba(0, 0, 0, 0.1);
      }
      
      .sent .message-bubble:hover {
        box-shadow: 0 6px 20px rgba(149, 236, 105, 0.4), 0 2px 6px rgba(0, 0, 0, 0.12);
      }
      
      .sent .message-bubble::after {
        content: '';
        position: absolute;
        right: -7px;
        bottom: 8px;
        width: 0;
        height: 0;
        border-left: 8px solid #95ec69;
        border-top: 6px solid transparent;
        border-bottom: 6px solid transparent;
        filter: drop-shadow(2px 2px 2px rgba(0, 0, 0, 0.08));
      }
      
      .received .message-bubble {
        background: linear-gradient(135deg, #ffffff 0%, #fafafa 100%);
        color: #1a1a1a;
        border-radius: 18px 18px 18px 4px;
        box-shadow: 0 3px 12px rgba(0, 0, 0, 0.08), 0 1px 3px rgba(0, 0, 0, 0.06);
        border: 1px solid rgba(0, 0, 0, 0.04);
      }
      
      .received .message-bubble:hover {
        box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12), 0 2px 6px rgba(0, 0, 0, 0.08);
      }
      
      .received .message-bubble::after {
        content: '';
        position: absolute;
        left: -7px;
        bottom: 8px;
        width: 0;
        height: 0;
        border-right: 8px solid #ffffff;
        border-top: 6px solid transparent;
        border-bottom: 6px solid transparent;
        filter: drop-shadow(-2px 2px 2px rgba(0, 0, 0, 0.06));
      }

      .sent .message-bubble.media,
      .received .message-bubble.media {
        background: transparent;
        box-shadow: none;
        border: none;
      }

      .sent .message-bubble.media::after,
      .received .message-bubble.media::after {
        display: none;
      }
      
      .content {
        font-size: 15px;
        line-height: 1.6;
        word-wrap: break-word;
        white-space: pre-wrap;
        letter-spacing: 0.2px;
      }

      .message-media {
        max-width: 240px;
        border-radius: 12px;
        display: block;
      }

      .message-media.image {
        max-height: 240px;
        object-fit: cover;
      }

      .message-media.emoji {
        width: 120px;
        height: 120px;
        object-fit: contain;
      }

      .message-media.voice {
        width: 220px;
        height: 32px;
      }
      
      .time {
        font-size: 11px;
        margin-top: 8px;
        font-weight: 500;
        text-align: right;
        letter-spacing: 0.3px;
      }
      
      .sent .time {
        color: rgba(0, 0, 0, 0.45);
      }
      
      .received .time {
        color: rgba(0, 0, 0, 0.4);
      }
      
      @media print {
        body {
          background: white;
        }
        
        .container {
          padding: 0;
        }
        
        .header {
          box-shadow: none;
          border-radius: 0;
        }
        
        .messages {
          box-shadow: none;
          border-radius: 0;
          max-height: none;
          overflow: visible;
        }
        
        .message-item {
          page-break-inside: avoid;
          animation: none;
        }
        
        .message-bubble {
          box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1) !important;
        }
        
        .scroll-to-bottom {
          display: none !important;
        }
      }
      
      @media (max-width: 768px) {
        .container {
          padding: 12px;
          max-width: 100%;
        }
        
        .header {
          padding: 24px 20px;
          border-radius: 12px;
          margin-bottom: 16px;
        }
        
        .header h1 {
          font-size: 22px;
        }
        
        .messages {
          padding: 20px 16px;
          border-radius: 12px;
          max-height: calc(100vh - 160px);
        }
        
        .message-bubble {
          max-width: 80%;
        }
        
        .date-separator {
          font-size: 12px;
          padding: 6px 12px;
        }
        
        .scroll-to-bottom {
          bottom: 20px;
          right: 20px;
          width: 44px;
          height: 44px;
          font-size: 20px;
        }
      }
      
      @media (prefers-color-scheme: dark) {
        body {
          background: linear-gradient(to bottom, #1a1a1a 0%, #0f0f0f 100%);
        }
        
        .messages {
          background: #2a2a2a;
          box-shadow: 0 2px 12px rgba(0, 0, 0, 0.4);
        }
        
        .loading {
          color: #666;
        }
        
        .received .message-bubble {
          background: linear-gradient(135deg, #3a3a3a 0%, #333333 100%);
          color: #e8e8e8;
          border-color: rgba(255, 255, 255, 0.1);
        }
        
        .received .message-bubble::after {
          border-right-color: #3a3a3a;
        }
        
        .sender-name {
          color: #999;
        }
        
        .date-separator {
          color: #999;
          background: linear-gradient(135deg, rgba(255, 255, 255, 0.08) 0%, rgba(255, 255, 255, 0.12) 100%);
        }
        
        .sent .time,
        .received .time {
          color: rgba(255, 255, 255, 0.5);
        }
      }
    ''';
  }

  /// HTML 转义
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 获取联系人详细信息（nickname、remark）
  Future<Map<String, String>> _getContactInfo(String username) async {
    var result = <String, String>{};
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) {
        return result;
      }

      final contactFile = File(contactDbPath);
      if (!await contactFile.exists()) {
        return result;
      }

      final contactDb = await databaseFactoryFfi.openDatabase(contactDbPath);

      try {
        result = await _getContactInfoFromDb(
          contactDb,
          username,
          logMissing: false,
        );
        return result;
      } finally {
        await contactDb.close();
      }
    } catch (e) {
      // 查询失败时返回空map
    }

    if (result.isEmpty) {
      final isSelf = _isCurrentAccount(username);
      await _logMissingDisplayName(
        username,
        isSelf: isSelf,
        details: isSelf
            ? 'contact/stranger/userinfo 表无匹配记录'
            : 'contact/stranger 表无匹配记录',
      );
    }

    return result;
  }

  bool _isCurrentAccount(String username) {
    final myWxid = _databaseService.currentAccountWxid;
    if (myWxid == null) return false;
    final normalizedInput = _sanitizeUsername(username);
    final normalizedCurrent = _sanitizeUsername(myWxid);
    if (normalizedInput.isEmpty || normalizedCurrent.isEmpty) return false;
    return normalizedInput == normalizedCurrent;
  }

  Future<Map<String, String>> _getSelfInfoFromUserInfo(
    Database contactDb,
  ) async {
    final info = <String, String>{};
    try {
      final tableExists = await contactDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='userinfo' LIMIT 1",
      );
      if (tableExists.isEmpty) {
        return info;
      }

      final rows = await contactDb.query('userinfo');
      if (rows.isEmpty) {
        return info;
      }

      String? nickname;
      String? remark;
      String? alias;

      for (final row in rows) {
        final key = _extractUserInfoKey(row);
        final value = _extractUserInfoValue(row);
        if (value == null || value.isEmpty) continue;

        final normalizedValue = _normalizeDisplayField(value);
        if (!_hasMeaningfulValue(normalizedValue)) continue;

        final lowerKey = key?.toString().toLowerCase() ?? '';
        if (lowerKey.contains('remark') || lowerKey.contains('displayname')) {
          remark ??= normalizedValue;
        } else if (lowerKey.contains('alias')) {
          alias ??= normalizedValue;
        } else if (lowerKey.contains('nick') ||
            lowerKey.contains('name') ||
            lowerKey == '2') {
          nickname ??= normalizedValue;
        }

        if (nickname != null && (remark != null || alias != null)) {
          break;
        }
      }

      if (alias != null) {
        info['alias'] = alias;
      }
      if (remark != null) {
        info['remark'] = remark;
      }
      if (nickname != null) {
        info['nickname'] = nickname;
      }
    } catch (_) {}

    return info;
  }

  dynamic _extractUserInfoKey(Map<String, Object?> row) {
    for (final key in ['id', 'type', 'item', 'key']) {
      if (row.containsKey(key) && row[key] != null) {
        return row[key];
      }
    }
    return null;
  }

  String? _extractUserInfoValue(Map<String, Object?> row) {
    for (final key in ['value', 'Value', 'content', 'data']) {
      final v = row[key];
      if (v is String && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    return null;
  }

  Future<void> _logMissingDisplayName(
    String username, {
    required bool isSelf,
    required String details,
  }) async {
    final normalized = _sanitizeUsername(username);
    if (normalized.isEmpty) return;
    if (!_missingDisplayNameLog.add('$normalized|$isSelf')) {
      return;
    }

    final baseReason = isSelf
        ? '未在 contact/stranger/userinfo 表找到当前账号的昵称/备注，已回退为 wxid'
        : '未在 contact/stranger 表找到联系人显示名，已回退为 wxid';

    await logger.warning(
      'ChatExportService',
      '$baseReason: $normalized，原因: $details',
    );
  }

  bool _hasMeaningfulValue(String? value) {
    if (value == null) return false;
    if (value.isEmpty) return false;
    final stripped = value.replaceAll(RegExp(r'[ \t\r\n]'), '');
    return stripped.isNotEmpty;
  }

  String _normalizeDisplayField(String? value) {
    if (value == null) return '';
    return value
        .replaceAll(RegExp(r'^[ \t\r\n]+'), '')
        .replaceAll(RegExp(r'[ \t\r\n]+$'), '');
  }

  Future<List<Map<String, dynamic>>> _getGroupMemberExportData(
    String chatroomId,
  ) async {
    final results = <Map<String, dynamic>>[];
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) {
        return results;
      }

      final contactFile = File(contactDbPath);
      if (!await contactFile.exists()) {
        return results;
      }

      final contactDb = await databaseFactoryFfi.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );

      try {
        final memberRows = await _loadChatroomMemberRows(contactDb, chatroomId);
        if (memberRows.isEmpty) {
          return results;
        }

        final seen = <String>{};
        for (final row in memberRows) {
          final username = _normalizeDisplayField(row['username'] as String?);
          if (!_hasMeaningfulValue(username)) {
            continue;
          }
          if (!seen.add(username)) {
            continue;
          }

          final contactInfo = await _getContactInfoFromDb(
            contactDb,
            username,
            logMissing: false,
          );
          final remark = _normalizeDisplayField(contactInfo['remark']);
          final nickname = _normalizeDisplayField(contactInfo['nickname']);
          final alias = _normalizeDisplayField(contactInfo['alias']);
          final originalName = _hasMeaningfulValue(nickname)
              ? nickname
              : (_hasMeaningfulValue(alias) ? alias : username);

          results.add({
            'username': username,
            'remark': _hasMeaningfulValue(remark) ? remark : null,
            'originalName': originalName,
          });
        }
      } finally {
        await contactDb.close();
      }
    } catch (e) {
      // Ignore
    }
    return results;
  }

  Future<Map<String, String>> _getContactInfoFromDb(
    Database contactDb,
    String username, {
    required bool logMissing,
  }) async {
    final result = <String, String>{};

    final candidates = <String>{username.trim(), _sanitizeUsername(username)}
      ..removeWhere((c) => c.isEmpty);

    final tables = ['contact', 'stranger'];

    for (final table in tables) {
      for (final candidate in candidates) {
        final maps = await contactDb.query(
          table,
          columns: ['nick_name', 'remark', 'alias'],
          where: 'username = ?',
          whereArgs: [candidate],
          limit: 1,
        );

        if (maps.isNotEmpty) {
          final map = maps.first;
          final nickName = _normalizeDisplayField(map['nick_name'] as String?);
          final remark = _normalizeDisplayField(map['remark'] as String?);
          final alias = _normalizeDisplayField(map['alias'] as String?);

          if (_hasMeaningfulValue(remark)) {
            result['remark'] = remark;
          }

          if (_hasMeaningfulValue(alias)) {
            result['alias'] = alias;
          }

          if (_hasMeaningfulValue(nickName)) {
            result['nickname'] = nickName;
          }

          if (result.isNotEmpty) {
            return result;
          }
        }
      }
    }

    if (result.isEmpty && _isCurrentAccount(username)) {
      final selfInfo = await _getSelfInfoFromUserInfo(contactDb);
      if (selfInfo.isNotEmpty) {
        result.addAll(selfInfo);
        return result;
      }
    }

    if (result.isEmpty && logMissing) {
      final isSelf = _isCurrentAccount(username);
      await _logMissingDisplayName(
        username,
        isSelf: isSelf,
        details: isSelf
            ? 'contact/stranger/userinfo 表无匹配记录'
            : 'contact/stranger 表无匹配记录',
      );
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> _loadChatroomMemberRows(
    Database contactDb,
    String chatroomId,
  ) async {
    final tableRows = await contactDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    String? memberTable;
    for (final row in tableRows) {
      final name = row['name'] as String?;
      if (name == null) continue;
      final lower = name.toLowerCase();
      if (lower == 'chatroom_member') {
        memberTable = name;
        break;
      }
    }
    memberTable ??= tableRows.map((row) => row['name'] as String?).firstWhere((
      name,
    ) {
      final lower = name?.toLowerCase() ?? '';
      return lower == 'chatroommembers' ||
          lower == 'chatroom_members' ||
          lower.contains('chatroommember');
    }, orElse: () => null);

    if (memberTable == null) {
      return [];
    }

    final tableInfo = await contactDb.rawQuery(
      "PRAGMA table_info('$memberTable')",
    );
    final columns = <String>[];
    final columnTypes = <String, String>{};
    for (final row in tableInfo) {
      final name = row['name'] as String?;
      if (name == null) continue;
      columns.add(name);
      final type = row['type'] as String?;
      if (type != null) {
        columnTypes[name] = type;
      }
    }

    String? pickColumn(List<String> candidates) {
      for (final candidate in candidates) {
        final lowerCandidate = candidate.toLowerCase();
        for (final column in columns) {
          if (column.toLowerCase() == lowerCandidate) {
            return column;
          }
        }
      }
      return null;
    }

    final usernameColumn = pickColumn(['username', 'user_name', 'usrname']);
    final memberIdColumn = pickColumn(['member_id', 'memberid']);
    final roomColumn = pickColumn([
      'room_id',
      'chatroomid',
      'roomid',
      'chatroom_id',
    ]);
    final displayColumn = pickColumn([
      'display_name',
      'displayname',
      'nickname',
      'nick_name',
      'room_nickname',
      'roomnick',
      'room_nick_name',
    ]);

    if (roomColumn == null) {
      return [];
    }

    if (usernameColumn == null && memberIdColumn == null) {
      return [];
    }

    final roomIdRows = await contactDb.rawQuery(
      'SELECT rowid FROM name2id WHERE username = ? LIMIT 1',
      [chatroomId],
    );
    final roomId = roomIdRows.isNotEmpty
        ? roomIdRows.first['rowid'] as int?
        : null;

    final roomType = columnTypes[roomColumn];
    final roomIsText = _isTextColumnType(roomType);
    final roomValues = <Object?>[];
    if (roomIsText) {
      roomValues.add(chatroomId);
      if (roomId != null) {
        roomValues.add(roomId);
      }
    } else {
      if (roomId != null) {
        roomValues.add(roomId);
      }
      roomValues.add(chatroomId);
    }

    final rows = <Map<String, dynamic>>[];
    for (final roomValue in roomValues) {
      if (roomValue == null) continue;
      final query = _buildChatroomMemberQuery(
        memberTable: memberTable,
        usernameColumn: usernameColumn,
        memberIdColumn: memberIdColumn,
        roomColumn: roomColumn,
        displayColumn: displayColumn,
      );
      final fetched = await contactDb.rawQuery(query, [roomValue]);
      if (fetched.isNotEmpty) {
        rows.addAll(fetched);
        break;
      }
    }

    return rows;
  }

  String _buildChatroomMemberQuery({
    required String memberTable,
    required String? usernameColumn,
    required String? memberIdColumn,
    required String roomColumn,
    required String? displayColumn,
  }) {
    final buffer = StringBuffer('SELECT ');
    if (usernameColumn != null) {
      buffer.write('"$usernameColumn" AS username');
    } else {
      buffer.write('n.username AS username');
    }

    // 不再导出群昵称，仅保留原始名称与备注信息。

    if (usernameColumn != null) {
      buffer.write(' FROM "$memberTable"');
    } else {
      buffer.write(
        ' FROM "$memberTable" m JOIN name2id n '
        'ON m."$memberIdColumn" = n.rowid',
      );
    }

    if (usernameColumn != null) {
      buffer.write(' WHERE "$roomColumn" = ?');
    } else {
      buffer.write(' WHERE m."$roomColumn" = ?');
    }

    return buffer.toString();
  }

  bool _isTextColumnType(String? type) {
    final lower = type?.toLowerCase() ?? '';
    return lower.contains('char') ||
        lower.contains('text') ||
        lower.contains('clob');
  }
}
