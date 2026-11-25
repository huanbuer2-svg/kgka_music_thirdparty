import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'lx_runtime.dart' show LxRuntimeException;
import 'lx_script.dart';

/// MusicFree 插件的元信息。
class MusicFreeInfo {
  const MusicFreeInfo({
    required this.platform,
    required this.version,
    required this.author,
    required this.description,
    required this.srcUrl,
    required this.supportedSearchType,
    required this.hasSearch,
    required this.hasMediaSource,
    required this.hasLyric,
    required this.hasTopLists,
  });

  factory MusicFreeInfo.fromJson(Map<String, dynamic> json) {
    final types = json['supportedSearchType'];
    return MusicFreeInfo(
      platform: '${json['platform'] ?? ''}',
      version: '${json['version'] ?? ''}',
      author: '${json['author'] ?? ''}',
      description: '${json['description'] ?? ''}',
      srcUrl: '${json['srcUrl'] ?? ''}',
      supportedSearchType: types is List
          ? types.map((item) => '$item').toList(growable: false)
          : const ['music'],
      hasSearch: json['hasSearch'] == true,
      hasMediaSource: json['hasMediaSource'] == true,
      hasLyric: json['hasLyric'] == true,
      hasTopLists: json['hasTopLists'] == true,
    );
  }

  final String platform;
  final String version;
  final String author;
  final String description;
  final String srcUrl;
  final List<String> supportedSearchType;
  final bool hasSearch;
  final bool hasMediaSource;
  final bool hasLyric;
  final bool hasTopLists;

  /// 从平台展示名推断出通用的平台键（qs/kg/wy/tx/kw），
  /// 好和官方的 [platformKeyOf] 对齐。
  String get platformKey {
    final name = platform.toLowerCase();
    if (name.contains('汽水') || name.contains('qishui') || name.contains('soda')) {
      return 'qs';
    }
    if (name.contains('网易') || name.contains('netease') || name.contains('wy')) {
      return 'wy';
    }
    if (name.contains('qq') || name.contains('腾讯')) return 'tx';
    if (name.contains('酷狗') || name.contains('kugou') || name.contains('kg')) {
      return 'kg';
    }
    if (name.contains('酷我') || name.contains('kuwo') || name.contains('kw')) {
      return 'kw';
    }
    if (name.contains('咪咕') || name.contains('migu') || name.contains('mg')) {
      return 'mg';
    }
    return 'mf';
  }

  String get label => platform.isNotEmpty
      ? platform
      : (lxSourceLabels[platformKey] ?? 'MusicFree 插件');
}

/// 一条 MusicFree 搜索结果。
class MusicFreeTrack {
  const MusicFreeTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.artwork,
    required this.duration,
    required this.raw,
  });

  factory MusicFreeTrack.fromJson(Map<String, dynamic> json) {
    final raw = json['raw'];
    return MusicFreeTrack(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? '未知歌曲'}',
      artist: '${json['artist'] ?? ''}',
      album: '${json['album'] ?? ''}',
      artwork: '${json['artwork'] ?? ''}',
      duration: (json['duration'] is num)
          ? (json['duration'] as num).toInt()
          : 0,
      raw: raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
    );
  }

  final String id;
  final String title;
  final String artist;
  final String album;
  final String artwork;

  /// 秒（MusicFree 约定）；0 表示未知。
  final int duration;

  /// 插件原始条目，取播放地址时要原样回传。
  final Map<String, dynamic> raw;
}

/// MusicFree 插件运行时。
///
/// 与 lx / ceru 都不同：插件是 CommonJS 模块，执行后 `module.exports` 直接暴露
/// `search` / `getMediaSource` / `getTopLists`。QuickJS 缺 fetch 与 setTimeout，
/// 由 `musicfree-shim.js` 补齐并桥接 HTTP。
class MusicFreeRuntime {
  MusicFreeRuntime({this.debugTag = 'musicfree'});

  final String debugTag;

  JavascriptRuntime? _js;
  http.Client? _http;
  bool _ready = false;
  bool _disposed = false;
  int _callSeq = 0;

  final List<String> _logs = [];
  MusicFreeInfo? _info;

  /// 上次搜索/榜单拿到的原始条目，按 id 缓存，取播放地址时回传。
  final Map<String, Map<String, dynamic>> _itemCache = {};

  bool get isReady => _ready && !_disposed;

  MusicFreeInfo? get info => _info;

  List<String> get logs => List.unmodifiable(_logs);

  Future<MusicFreeInfo> load({
    required String pluginCode,
    required String shimJs,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    dispose();
    _disposed = false;
    _logs.clear();
    _itemCache.clear();

    final js = getJavascriptRuntime(xhr: false);
    _js = js;
    js.onMessage('musicfree', _handleJsMessage);

    final shimResult = js.evaluate(shimJs);
    if (shimResult.isError) {
      throw LxRuntimeException('MusicFree 垫片注入失败：${_cleanup(shimResult.stringResult)}');
    }
    _ready = true;

    final loaded = js.evaluate('__mf.load(${_jsStringLiteral(pluginCode)})');
    if (loaded.isError) {
      throw LxRuntimeException('插件执行出错：${_cleanup(loaded.stringResult)}');
    }
    final decoded = _decode(loaded.stringResult);
    if (decoded is! Map) throw LxRuntimeException('插件未导出模块');
    final info = MusicFreeInfo.fromJson(Map<String, dynamic>.from(decoded));
    if (!info.hasSearch && !info.hasMediaSource) {
      throw LxRuntimeException('插件既没有 search 也没有 getMediaSource');
    }
    _info = info;
    _appendLog('【${info.label}】MusicFree 插件加载成功');
    return info;
  }

  Future<List<MusicFreeTrack>> search(
    String keywords, {
    int page = 1,
    String type = 'music',
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final value = await _call(
      'search',
      [keywords, page, type],
      timeout: timeout,
    );
    return _extractTracks(value);
  }

  /// 榜单详情（汽水这类平台用它做首页）。
  Future<List<MusicFreeTrack>> topListDetail(
    Map<String, dynamic> topList, {
    int page = 1,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final value = await _call(
      'getTopListDetail',
      [topList, page],
      timeout: timeout,
    );
    return _extractTracks(value);
  }

  /// 榜单目录。
  Future<List<dynamic>> topLists({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final value = await _call('getTopLists', const [], timeout: timeout);
    return value is List ? value : const [];
  }

  /// 取播放地址。缓存里有原始条目就用它，否则用 [fallback] 拼一个最小条目
  /// （播放列表里的歌没经过搜索，只有 id 和标题）。
  Future<String?> mediaSourceById(
    String trackId,
    String quality, {
    Map<String, dynamic>? fallback,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final raw = _itemCache[trackId] ?? fallback;
    if (raw == null) throw LxRuntimeException('缺少歌曲原始信息，请重新搜索');
    final value = await _call(
      'getMediaSource',
      [raw, quality],
      timeout: timeout,
    );
    if (value is String && value.isNotEmpty) return value;
    if (value is Map) {
      final url = value['url'] ?? value['src'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  Future<Map<String, dynamic>?> lyrics(
    String trackId, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final raw = _itemCache[trackId];
    if (raw == null) return null;
    final value = await _call('getLyric', [raw], timeout: timeout);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  List<MusicFreeTrack> _extractTracks(dynamic value) {
    if (value is! Map) return const [];
    final items = value['items'];
    if (items is! List) return const [];
    final tracks = <MusicFreeTrack>[];
    for (final item in items) {
      if (item is! Map) continue;
      final track = MusicFreeTrack.fromJson(Map<String, dynamic>.from(item));
      if (track.id.isEmpty) continue;
      _itemCache[track.id] = track.raw;
      tracks.add(track);
    }
    return tracks;
  }

  Future<dynamic> _call(
    String method,
    List<dynamic> args, {
    required Duration timeout,
  }) async {
    final js = _js;
    if (js == null || _disposed) throw LxRuntimeException('插件运行时未初始化');
    final callId = 'c${++_callSeq}';
    final started = js.evaluate(
      '__mf.startCall('
      '${_jsStringLiteral(method)},'
      '${_jsStringLiteral(jsonEncode(args))},'
      '${_jsStringLiteral(callId)})',
    );
    if (started.isError) throw LxRuntimeException(_cleanup(started.stringResult));

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      _pump();
      final taken = js.evaluate('__mf.takeResult(${_jsStringLiteral(callId)})');
      if (taken.isError) throw LxRuntimeException(_cleanup(taken.stringResult));
      final raw = taken.stringResult.trim();
      if (raw.isNotEmpty && raw != 'null') {
        final decoded = _decode(raw);
        if (decoded is Map) {
          if (decoded['ok'] == true) return decoded['value'];
          throw LxRuntimeException('${decoded['error'] ?? '插件调用失败'}');
        }
        return decoded;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw LxRuntimeException('插件响应超时（${timeout.inSeconds}s）');
  }

  void _pump() {
    final js = _js;
    if (js == null || _disposed) return;
    try {
      js.executePendingJob();
      // 插件的超时/重试靠 setTimeout，QuickJS 没有，得靠宿主推进
      js.evaluate('__mf.pumpTimers()');
    } catch (error) {
      debugPrint('[custom-source $debugTag] pump failed: $error');
    }
  }

  void _handleJsMessage(dynamic args) {
    if (args is! Map) return;
    if (args['type'] != 'http') return;
    final id = args['id'];
    final url = '${args['url'] ?? ''}';
    if (url.isEmpty) {
      _deliver(id, {'error': '空请求地址'});
      return;
    }
    final headers = <String, String>{};
    final rawHeaders = args['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) => headers['$key'] = '$value');
    }
    final body = args['body'];
    final method = '${args['method'] ?? 'GET'}'.toUpperCase();

    Future<void>(() async {
      try {
        final request = http.Request(method, Uri.parse(url));
        request.headers.addAll(headers);
        if (body != null && '$body'.isNotEmpty) {
          request.body = body is String ? body : jsonEncode(body);
        }
        final client = _http ??= http.Client();
        final streamed = await client
            .send(request)
            .timeout(const Duration(seconds: 20));
        final response = await http.Response.fromStream(streamed);
        // MusicFree 插件常常自己判 status，这里如实回传
        final text = utf8.decode(response.bodyBytes, allowMalformed: true);
        dynamic parsed;
        try {
          parsed = jsonDecode(text);
        } catch (_) {
          parsed = text;
        }
        _deliver(id, {
          'status': response.statusCode,
          'headers': response.headers.map((k, v) => MapEntry(k.toLowerCase(), v)),
          'body': parsed,
          'text': text,
          'url': url,
        });
      } catch (error) {
        _deliver(id, {'error': _cleanup('$error')});
      }
    });
  }

  void _deliver(dynamic id, Map<String, dynamic> payload) {
    final js = _js;
    if (js == null || _disposed || id == null) return;
    try {
      js.evaluate(
        '__mf.deliverHttp(${_jsStringLiteral('$id')}, '
        '${_jsStringLiteral(jsonEncode(payload))})',
      );
    } catch (error) {
      debugPrint('[custom-source $debugTag] http inject failed: $error');
    }
  }

  dynamic _decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text == 'undefined') return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  void _appendLog(String line) {
    _logs.add(line);
    debugPrint('[custom-source $debugTag] $line');
  }

  String _jsStringLiteral(String value) {
    return jsonEncode(value)
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
  }

  String _cleanup(String raw) {
    var text = raw.replaceFirst('ERROR: ', '').trim();
    final newline = text.indexOf('\n');
    if (newline > 0) text = text.substring(0, newline).trim();
    return text.isEmpty ? '未知脚本错误' : text;
  }

  void dispose() {
    _disposed = true;
    _ready = false;
    _info = null;
    _itemCache.clear();
    try {
      _js?.dispose();
    } catch (_) {}
    _js = null;
    _http?.close();
    _http = null;
  }
}
