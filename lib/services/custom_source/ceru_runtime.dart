import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'lx_runtime.dart' show LxRuntimeException;
import 'lx_script.dart';

/// 插件声明的一个平台（QQ / 网易云 / 汽水 …）。
class CeruProvider {
  const CeruProvider({
    required this.id,
    required this.actions,
    this.name = '',
    this.qualities = const [],
  });

  factory CeruProvider.fromJson(
    Map<String, dynamic> json, {
    String name = '',
    List<String> qualities = const [],
  }) {
    final actions = json['actions'];
    return CeruProvider(
      id: '${json['id'] ?? ''}',
      actions: actions is List
          ? actions.map((item) => '$item').toList(growable: false)
          : const [],
      name: name,
      qualities: qualities,
    );
  }

  final String id;
  final List<String> actions;

  /// manifest 里声明的展示名（如「汽水音乐」）。
  final String name;

  /// manifest 里声明的音质档位。
  final List<String> qualities;

  bool get canSearch => actions.contains('search');
  bool get canResolve => actions.contains('resolve');
  bool get canLyrics => actions.contains('lyrics');

  String get label => name.isNotEmpty ? name : (lxSourceLabels[id] ?? id);
}

/// ceru 插件（manifestVersion 3）的元信息。
class CeruPluginInfo {
  const CeruPluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.configKeys,
    required this.providers,
    this.config = const {},
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;

  /// 需要用户填写的配置项（常见是 apiUrl / apiKey，指向插件作者的服务）。
  final List<String> configKeys;

  /// 插件 manifest 里自带的配置默认值（多数插件会把 apiUrl/apiKey 直接写在这里）。
  final Map<String, String> config;

  final List<CeruProvider> providers;

  List<String> get sourceLabels => providers
      .where((provider) => provider.canResolve)
      .map((provider) => provider.label)
      .toList(growable: false);
}

/// `ceru-js@1` 运行时。
///
/// 与 lx 音源的区别：这类插件是「模块化插件包」——脚本执行后只导出
/// `activate(ctx)`，真正的能力通过 `ctx.providers.register()` 注册，
/// 宿主再按协议（`music.search@1` / `music.resolve@1`）回调具体方法。
///
/// 引擎里注入三份 JS：crypto-js（摘要/AES）、pako（gzip 解压）、宿主垫片。
/// QuickJS 没有原生 crypto/zlib，只能带纯 JS 实现。
class CeruRuntime {
  CeruRuntime({this.debugTag = 'ceru'});

  final String debugTag;

  JavascriptRuntime? _js;
  http.Client? _http;
  bool _ready = false;
  bool _disposed = false;
  int _callSeq = 0;

  final List<String> _logs = [];
  CeruPluginInfo? _info;

  static const int maxLogs = 200;

  bool get isReady => _ready && !_disposed;

  CeruPluginInfo? get info => _info;

  List<String> get logs => List.unmodifiable(_logs);

  /// 载入插件并完成激活。
  ///
  /// [config] 是插件 `entry.share.configKeys` 里声明的配置项（如 apiUrl/apiKey），
  /// 缺省时按空串填，插件若强依赖会在激活阶段抛错，调用方据此提示用户去配置。
  Future<CeruPluginInfo> load({
    required String pluginCode,
    required String cryptoJs,
    required String pakoJs,
    required String shimJs,
    Map<String, String> config = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    dispose();
    _disposed = false;
    _logs.clear();
    _info = null;

    final js = getJavascriptRuntime(xhr: false);
    _js = js;
    js.onMessage('ceru', _handleJsMessage);

    // 顺序很重要：先注入库（它们靠 UMD 挂到全局），再注入垫片，最后插件。
    final libStopwatch = Stopwatch()..start();
    for (final entry in {
      'crypto-js': cryptoJs,
      'pako': pakoJs,
      'ceru-shim': shimJs,
    }.entries) {
      final result = js.evaluate(entry.value);
      if (result.isError) {
        throw LxRuntimeException(
          '${entry.key} 注入失败：${_cleanupError(result.stringResult)}',
        );
      }
    }
    debugPrint(
      '[custom-source $debugTag] 运行时注入完成 ${libStopwatch.elapsedMilliseconds}ms',
    );
    _ready = true;

    final loaded = js.evaluate('__ceru.load(${_jsStringLiteral(pluginCode)})');
    if (loaded.isError) {
      throw LxRuntimeException(
        '插件执行出错：${_cleanupError(loaded.stringResult)}',
      );
    }
    final manifestJson = _decode(loaded.stringResult);
    final manifest = manifestJson is Map ? Map<String, dynamic>.from(manifestJson) : <String, dynamic>{};
    final manifestMap = manifest['manifest'] is Map
        ? Map<String, dynamic>.from(manifest['manifest'] as Map)
        : <String, dynamic>{};
    final engines = manifestMap['engines'];
    if (engines is Map) {
      final logicRuntime = '${engines['logicRuntime'] ?? ''}';
      if (logicRuntime.isNotEmpty && !logicRuntime.startsWith('ceru-js')) {
        throw LxRuntimeException('不支持的插件运行时：$logicRuntime');
      }
    }

    final configKeys = _readConfigKeys(manifestMap);
    final configPayload = <String, String>{
      for (final key in configKeys) key: config[key] ?? '',
    };
    js.evaluate('__ceru.setConfig(${_jsStringLiteral(jsonEncode(configPayload))})');

    js.evaluate('__ceru.beginActivate()');
    final stopwatch = Stopwatch()..start();
    Map<String, dynamic>? status;
    while (stopwatch.elapsed < timeout) {
      _pump();
      final raw = js.evaluate('__ceru.activateStatus()').stringResult.trim();
      if (raw.isNotEmpty && raw != 'null') {
        final decoded = _decode(raw);
        if (decoded is Map) {
          status = Map<String, dynamic>.from(decoded);
          if (status['status'] != 'pending') break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    if (status == null) {
      throw LxRuntimeException('插件激活超时（${timeout.inSeconds}s）');
    }
    if (status['status'] == 'error') {
      throw LxRuntimeException('插件激活失败：${status['error'] ?? '未知错误'}');
    }
    if (status['status'] != 'ok') {
      throw LxRuntimeException('插件激活未完成');
    }

    // manifest.provides.providers 里才有展示名与音质档位，注册表里只有方法
    final declared = <String, Map<String, dynamic>>{};
    final provides = manifestMap['provides'];
    if (provides is Map) {
      final list = provides['providers'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            declared['${map['id']}'] = map;
          }
        }
      }
    }

    final providerList = status['providers'];
    final providers = <CeruProvider>[];
    if (providerList is List) {
      for (final item in providerList) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final extra = declared['${map['id']}'];
        providers.add(
          CeruProvider.fromJson(
            map,
            name: '${extra?['name'] ?? ''}',
            qualities: extra?['qualities'] is List
                ? (extra!['qualities'] as List).map((q) => '$q').toList()
                : const [],
          ),
        );
      }
    }
    if (providers.isEmpty) {
      throw LxRuntimeException('插件没有注册任何音源平台');
    }

    final manifestConfig = manifestMap['config'];
    final configDefaults = <String, String>{};
    if (manifestConfig is Map) {
      manifestConfig.forEach((key, value) {
        if (value != null) configDefaults['$key'] = '$value';
      });
    }

    _info = CeruPluginInfo(
      id: '${manifestMap['id'] ?? ''}',
      name: '${manifestMap['name'] ?? 'ceru 插件'}',
      version: '${manifestMap['version'] ?? ''}',
      description: '${manifestMap['description'] ?? ''}',
      author: '${manifestMap['author'] ?? ''}',
      configKeys: configKeys,
      providers: providers,
      config: configDefaults,
    );
    _appendLog(
      '【${_info!.name}】激活成功，平台：${providers.map((p) => p.label).join('/')}',
    );
    return _info!;
  }

  List<String> _readConfigKeys(Map<String, dynamic> manifest) {
    final entry = manifest['entry'];
    if (entry is! Map) return const [];
    final share = entry['share'];
    if (share is! Map) return const [];
    final keys = share['configKeys'];
    if (keys is! List) return const [];
    return keys.map((item) => '$item').toList(growable: false);
  }

  /// 搜索。返回插件原始的分页结果：`{items, nextCursor, totalEstimate}`。
  Future<Map<String, dynamic>> search(
    String providerId,
    String query, {
    String? cursor,
    int limit = 20,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final value = await _call(
      providerId,
      'search',
      [
        {
          'query': query,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
      ],
      timeout: timeout,
    );
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  /// 取播放地址。`resource` 是搜索结果里的 `ref`（或整条 item）。
  Future<String?> resolveUrl(
    String providerId,
    Map<String, dynamic> resource,
    String quality, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final value = await _call(
      providerId,
      'resolve',
      [resource, quality],
      timeout: timeout,
    );
    if (value is String && value.isNotEmpty) return value;
    if (value is Map) {
      final url = value['url'] ?? value['playUrl'] ?? value['src'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  /// 取歌词（`{lrc, translatedLrc}` 之类，按插件实际返回）。
  Future<Map<String, dynamic>?> lyrics(
    String providerId,
    Map<String, dynamic> resource, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final value = await _call(
      providerId,
      'lyrics',
      [resource],
      timeout: timeout,
    );
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<dynamic> _call(
    String providerId,
    String method,
    List<dynamic> args, {
    required Duration timeout,
  }) async {
    final js = _js;
    if (js == null || _disposed) {
      throw LxRuntimeException('插件运行时未初始化');
    }
    final callId = 'c${++_callSeq}';
    final started = js.evaluate(
      '__ceru.startCall('
      '${_jsStringLiteral(providerId)},'
      '${_jsStringLiteral(method)},'
      '${_jsStringLiteral(jsonEncode(args))},'
      '${_jsStringLiteral(callId)})',
    );
    if (started.isError) {
      throw LxRuntimeException(_cleanupError(started.stringResult));
    }

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      _pump();
      final taken = js.evaluate(
        '__ceru.takeResult(${_jsStringLiteral(callId)})',
      );
      if (taken.isError) {
        throw LxRuntimeException(_cleanupError(taken.stringResult));
      }
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
    } catch (error) {
      debugPrint('[custom-source $debugTag] pump failed: $error');
    }
  }

  /// JS 同步调用进来的消息，绝不能在这里 evaluate（引擎重入会崩）。
  void _handleJsMessage(dynamic args) {
    if (args is! Map) return;
    if (args['type'] != 'http') return;
    final id = args['id'];
    final url = '${args['url'] ?? ''}';
    if (url.isEmpty) {
      _deliverHttp(id, {'error': '空请求地址'});
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
        final text = utf8.decode(response.bodyBytes, allowMalformed: true);
        dynamic parsed;
        try {
          parsed = jsonDecode(text);
        } catch (_) {
          parsed = text;
        }
        _appendLog('HTTP $method ${response.statusCode} $url');
        _deliverHttp(id, {
          'status': response.statusCode,
          'headers': response.headers.map((k, v) => MapEntry(k.toLowerCase(), v)),
          'body': parsed,
          'text': text,
          'url': url,
        });
      } catch (error) {
        _deliverHttp(id, {'error': _cleanupError('$error')});
      }
    });
  }

  void _deliverHttp(dynamic id, Map<String, dynamic> payload) {
    final js = _js;
    if (js == null || _disposed || id == null) return;
    try {
      js.evaluate(
        '__ceru.deliverHttp(${_jsStringLiteral('$id')}, '
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
    if (_logs.length > maxLogs) _logs.removeAt(0);
    debugPrint('[custom-source $debugTag] $line');
  }

  String _jsStringLiteral(String value) {
    return jsonEncode(value)
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
  }

  String _cleanupError(String raw) {
    var text = raw.replaceFirst('ERROR: ', '').trim();
    final newline = text.indexOf('\n');
    if (newline > 0) text = text.substring(0, newline).trim();
    return text.isEmpty ? '未知脚本错误' : text;
  }

  void dispose() {
    _disposed = true;
    _ready = false;
    _info = null;
    try {
      _js?.dispose();
    } catch (_) {}
    _js = null;
    _http?.close();
    _http = null;
  }
}
