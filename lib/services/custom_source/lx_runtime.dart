import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'lx_js_bootstrap.dart';
import 'lx_script.dart';

/// 音源脚本执行层的统一异常。
class LxRuntimeException implements Exception {
  LxRuntimeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次脚本加载的结果。
class LxLoadResult {
  const LxLoadResult({
    required this.sources,
    this.displayName,
    this.version,
    this.updateAlert,
    this.logs = const [],
  });

  final Map<String, LxSourceDecl> sources;

  /// 脚本 `inited` 事件里可能自带的名字（多数脚本没有，靠头部注释）。
  final String? displayName;
  final String? version;

  /// 脚本上报的更新提醒（`EVENT_NAMES.updateAlert`）。
  final Map<String, dynamic>? updateAlert;

  final List<String> logs;
}

/// 单个 lx-music 自定义音源脚本的运行时。
///
/// 一个实例只承载一个脚本：脚本文件普遍在顶层用 `const { EVENT_NAMES,
/// request, on, send } = globalThis.lx` 解构，同一 JS 上下文里重复执行会因
/// 重复声明 `const` 而直接语法报错，所以脚本之间必须隔离。
///
/// 执行模型：
/// 1. 先执行 [kLxBootstrapSource] 装好 `globalThis.lx` 宿主与本文件描述的消息协议；
/// 2. 再执行脚本自身代码，脚本会 `send(EVENT_NAMES.inited, ...)` 上报能力；
/// 3. 调 `musicUrl` 时把 payload 交给 `__lxHost.dispatch`，脚本内部
///    `lx.request` 触发的 HTTP 由 Dart 侧真实发起，完成后把响应写回 JS；
/// 4. Dart 侧每 20ms 调一次 `executePendingJob()` 并把结果取出
///    （flutter_js 的 `sendMessage` 是单向同步通道，无法把 Future 传回 JS，
///    轮询是它自己处理 Promise 的同款办法）。
class LxRuntime {
  LxRuntime({this.debugTag = ''});

  final String debugTag;

  JavascriptRuntime? _js;
  http.Client? _http;
  bool _ready = false;
  bool _disposed = false;
  int _callSeq = 0;

  final List<String> _logs = [];
  Map<String, LxSourceDecl>? _sources;
  Map<String, dynamic>? _updateAlert;
  Completer<void>? _initedCompleter;

  /// 引擎是否已就绪。
  bool get isReady => _ready && !_disposed;

  /// 最近一次加载得到的音源声明。
  Map<String, LxSourceDecl> get sources => _sources ?? const {};

  /// 脚本产生的日志（最多保留 [maxLogs] 条）。
  List<String> get logs => List.unmodifiable(_logs);

  static const int maxLogs = 200;

  /// 加载并初始化脚本。
  Future<LxLoadResult> load(
    String scriptCode, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    dispose();
    _disposed = false;
    _logs.clear();
    _sources = null;
    _updateAlert = null;
    _initedCompleter = Completer<void>();

    final js = getJavascriptRuntime(xhr: false);
    _js = js;
    // 只注册一个通道，靠消息体区分类型
    js.onMessage('lx', _handleJsMessage);

    final boot = js.evaluate(kLxBootstrapSource);
    if (boot.isError) {
      throw LxRuntimeException('JS 宿主初始化失败：${boot.stringResult}');
    }
    _ready = true;

    final evaluated = js.evaluate(scriptCode);
    if (evaluated.isError) {
      throw LxRuntimeException('脚本执行出错：${_cleanupError(evaluated.stringResult)}');
    }

    // 多数脚本同步发 inited；少数先做异步检查更新再发，这里留出等待窗口。
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (_sources != null) break;
      _pump();
      if (_sources != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final sources = _sources;
    if (sources == null) {
      throw LxRuntimeException(
        '脚本未上报音源信息（未收到 inited 事件，可能脚本与 lx-music 协议不兼容）',
      );
    }
    if (sources.isEmpty) {
      throw LxRuntimeException('脚本没有声明任何可用音源');
    }

    return LxLoadResult(
      sources: sources,
      version: null,
      updateAlert: _updateAlert,
      logs: List<String>.unmodifiable(_logs),
    );
  }

  /// 向脚本请求播放地址。
  ///
  /// [source] 是脚本声明的平台键（kg / wy / tx ...），[musicInfo] 采用
  /// lx-music 的字段约定（hash / songmid / name / singer / albumName ...）。
  Future<String> fetchMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final value = await _invoke(
      {
        'action': 'musicUrl',
        'source': source,
        'info': {'type': quality, 'musicInfo': musicInfo},
      },
      timeout: timeout,
    );
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is Map && value['url'] is String) {
      final url = value['url'] as String;
      if (url.trim().isNotEmpty) return url.trim();
    }
    throw LxRuntimeException('脚本未返回有效的播放地址');
  }

  /// 向脚本请求歌词（部分音源脚本支持，失败不影响播放）。
  Future<String?> fetchLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final value = await _invoke(
        {
          'action': 'lyric',
          'source': source,
          'info': {'musicInfo': musicInfo},
        },
        timeout: timeout,
      );
      if (value is Map) {
        final lyric = value['lyric'] ?? value['rawLrc'];
        if (lyric is String && lyric.trim().isNotEmpty) return lyric;
      }
      if (value is String && value.trim().isNotEmpty) return value;
    } catch (_) {
      // 不支持歌词的音源很常见，静默失败
    }
    return null;
  }

  Future<dynamic> _invoke(
    Map<String, dynamic> payload, {
    required Duration timeout,
  }) async {
    final js = _js;
    if (js == null || _disposed) {
      throw LxRuntimeException('音源脚本未初始化');
    }
    final callId = ++_callSeq;
    final dispatched = js.evaluate(
      '__lxHost.dispatch(${_jsStringLiteral(jsonEncode(payload))}, $callId)',
    );
    if (dispatched.isError) {
      throw LxRuntimeException(_cleanupError(dispatched.stringResult));
    }

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      _pump();
      final taken = js.evaluate('__lxHost.takeResult($callId)');
      if (taken.isError) {
        throw LxRuntimeException(_cleanupError(taken.stringResult));
      }
      final raw = taken.stringResult.trim();
      if (raw.isNotEmpty && raw != 'null' && raw != 'undefined') {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['ok'] == true) {
          return decoded['val'];
        }
        final message = decoded is Map ? '${decoded['err'] ?? '未知错误'}' : '$decoded';
        throw LxRuntimeException(message);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw LxRuntimeException('音源脚本响应超时（${timeout.inSeconds}s）');
  }

  void _pump() {
    final js = _js;
    if (js == null || _disposed) return;
    try {
      js.executePendingJob();
    } catch (error) {
      debugPrint('[custom-source $debugTag] pump failed: $error');
    }
  }

  /// 处理 JS 侧通过 `sendMessage('lx', json)` 发来的消息。
  ///
  /// 注意：此回调由 JS 同步调用，**绝不能**在这里做 evaluate（引擎重入会崩），
  /// 因此 HTTP 一律丢进事件队列异步处理。
  void _handleJsMessage(dynamic args) {
    if (args is! Map) return;
    final type = '${args['t'] ?? ''}';
    switch (type) {
      case 'log':
        _appendLog('${args['msg'] ?? ''}');
        break;
      case 'inited':
        _handleInited(args['data']);
        break;
      case 'updateAlert':
        final data = args['data'];
        if (data is Map) {
          _updateAlert = Map<String, dynamic>.from(data);
          _appendLog('脚本提示有新版本：${data['log'] ?? ''}');
        }
        break;
      case 'http':
        _handleHttpRequest(args);
        break;
      default:
        break;
    }
  }

  void _handleInited(dynamic data) {
    if (data is! Map) return;
    final rawSources = data['sources'];
    final parsed = <String, LxSourceDecl>{};
    if (rawSources is Map) {
      rawSources.forEach((key, value) {
        if (value is Map) {
          parsed['$key'] = LxSourceDecl.fromJson(
            '$key',
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    _sources = parsed;
    if (_initedCompleter?.isCompleted == false) {
      _initedCompleter?.complete();
    }
  }

  void _handleHttpRequest(Map args) {
    final id = args['id'];
    final url = '${args['url'] ?? ''}';
    final options = args['options'];
    if (url.isEmpty) {
      _resolveHttp(id, error: '空请求地址');
      return;
    }
    Future<void>(() async {
      try {
        final response = await _performHttp(
          url,
          options is Map ? Map<String, dynamic>.from(options) : const {},
        );
        _resolveHttp(id, response: response);
      } catch (error) {
        _resolveHttp(id, error: _cleanupError('$error'));
      }
    });
  }

  Future<Map<String, dynamic>> _performHttp(
    String url,
    Map<String, dynamic> options,
  ) async {
    final method = '${options['method'] ?? 'GET'}'.toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = options['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) => headers['$key'] = '$value');
    }
    final body = options['body'];

    final request = http.Request(method, Uri.parse(url));
    request.headers.addAll(headers);
    if (body != null && body.toString().isNotEmpty) {
      request.body = '$body';
    }
    final client = _http ??= http.Client();
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    final response = await http.Response.fromStream(streamed);
    // http 包在缺少 charset 时按 latin1 解码，中文 JSON 会乱码，这里强制 utf8
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      parsed = text;
    }
    _appendLog('HTTP $method ${response.statusCode} $url');
    return {
      'statusCode': response.statusCode,
      'headers': response.headers,
      'body': parsed,
      'raw': text,
      'bytes': response.bodyBytes.length,
    };
  }

  /// 把 HTTP 结果写回 JS，触发脚本里 `lx.request` 的回调。
  void _resolveHttp(
    dynamic id, {
    Map<String, dynamic>? response,
    String? error,
  }) {
    final js = _js;
    if (js == null || _disposed || id == null) return;
    final payload = error != null
        ? {'error': error}
        : {'response': response ?? const {}};
    try {
      js.evaluate(
        '__lxHost.httpResult($id, ${_jsStringLiteral(jsonEncode(payload))})',
      );
    } catch (evalError) {
      debugPrint('[custom-source $debugTag] http inject failed: $evalError');
    }
  }

  void _appendLog(String message) {
    final text = message.trim();
    if (text.isEmpty) return;
    _logs.add(text);
    if (_logs.length > maxLogs) {
      _logs.removeRange(0, _logs.length - maxLogs);
    }
    if (kDebugMode) {
      debugPrint('[custom-source $debugTag] $text');
    }
  }

  /// JS 抛出的错误常常带一长串栈，界面里只要第一行。
  String _cleanupError(String raw) {
    var text = raw.replaceFirst('ERROR: ', '').trim();
    final newline = text.indexOf('\n');
    if (newline > 0) text = text.substring(0, newline).trim();
    return text.isEmpty ? '未知脚本错误' : text;
  }

  /// 把 Dart 字符串安全地放进 JS 代码里当字面量。
  ///
  /// [jsonEncode] 能处理引号、反斜杠和换行，但不会转义 U+2028/U+2029
  /// （JS 里它们是行终止符，会导致语法错误），需要单独处理。
  String _jsStringLiteral(String value) {
    return jsonEncode(value)
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
  }

  void dispose() {
    _disposed = true;
    _ready = false;
    _sources = null;
    try {
      _js?.dispose();
    } catch (error) {
      debugPrint('[custom-source $debugTag] dispose failed: $error');
    }
    _js = null;
    try {
      _http?.close();
    } catch (_) {}
    _http = null;
    if (_initedCompleter?.isCompleted == false) {
      _initedCompleter?.complete();
    }
    _initedCompleter = null;
  }
}
