import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/music_models.dart';
import 'ceru_runtime.dart';
import 'lx_runtime.dart';
import 'lx_script.dart';

/// 随安装包内置的音源脚本。
///
/// 首次启动自动导入并启用；用户手动删除后会记住，不会下次启动又塞回来。
class BuiltinCustomSource {
  const BuiltinCustomSource({
    required this.id,
    required this.asset,
    required this.displayName,
  });

  final String id;

  /// Flutter asset 路径。
  final String asset;

  /// 脚本头部没写名字时的兜底名称。
  final String displayName;

  /// 记录在脚本条目的 originUrl 上，用来判断「已经装过」。
  String get origin => 'builtin://$id';
}

/// 内置音源清单。只收录经过宿主自检（`tool/lx_host_check.cjs`）验证能跑通的脚本。
const List<BuiltinCustomSource> kBuiltinCustomSources = [
  BuiltinCustomSource(
    id: 'xinglan',
    asset: 'lib/assets/custom_sources/xinglan.js',
    displayName: '星澜音乐源',
  ),
];

/// 自定义音源在播放链路里的介入方式。
enum CustomSourceMode {
  /// 官方接口优先，取不到地址时自动换第三方音源。
  auto('自动'),

  /// 只用官方接口。
  official('官方'),

  /// 只用第三方音源。
  thirdParty('第三方');

  const CustomSourceMode(this.label);

  final String label;

  /// 兼容旧版本持久化过的 `off / fallback / prefer / only`。
  static CustomSourceMode fromName(String? name) {
    switch (name) {
      case 'official':
      case 'off':
        return official;
      case 'thirdParty':
      case 'only':
      case 'prefer':
        return thirdParty;
      default:
        return auto;
    }
  }
}

/// 一次成功的第三方音源解析结果。
class CustomSourceResolve {
  const CustomSourceResolve({
    required this.url,
    required this.scriptName,
    required this.sourceKey,
    required this.quality,
  });

  final String url;
  final String scriptName;
  final String sourceKey;
  final String quality;

  String get sourceLabel => lxSourceLabels[sourceKey] ?? sourceKey;
}

class _CacheEntry {
  _CacheEntry(this.resolve, this.createdAt);

  final CustomSourceResolve resolve;
  final DateTime createdAt;
}

/// 第三方音源（lx-music 自定义源脚本）管理器。
///
/// 职责：
/// - 脚本的导入 / 启用 / 排序 / 删除与本地持久化
/// - 按歌曲来源挑选合适的脚本并解析出播放地址（带内存缓存与多脚本降级）
/// - 向界面暴露运行日志
///
/// 全局单例，因为播放器（[PlayerController]）和设置页都要访问同一份状态。
class CustomSourceManager extends ChangeNotifier {
  CustomSourceManager._();

  static final CustomSourceManager instance = CustomSourceManager._();

  static const String _prefsKey = 'kgka_custom_sources_v1';
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 120;

  final List<CustomSourceScript> _scripts = [];
  final Map<String, LxRuntime> _runtimes = {};
  final Map<String, CeruRuntime> _ceruRuntimes = {};

  // ceru 运行时依赖的三份 JS，体积不小，读一次就缓存
  static String? _ceruCryptoJs;
  static String? _ceruPakoJs;
  static String? _ceruShimJs;

  /// 判断脚本是不是 manifestVersion 3 的 ceru 插件包。
  static bool detectCeruFormat(String code) {
    if (code.contains('exports.manifest')) return true;
    final head = code.length > 4000 ? code.substring(0, 4000) : code;
    return head.contains('manifestVersion') && head.contains('exports.');
  }

  /// 从插件 manifest 文本里取展示名（不启动 JS）。
  static String? _ceruManifestName(String code) {
    final match = RegExp(r'"name"\s*:\s*"([^"]{1,80})"').firstMatch(code);
    return match?.group(1);
  }

  /// 更新插件配置项（ceru 插件的 apiUrl / apiKey 之类），并重新探测。
  Future<void> setScriptConfig(String id, Map<String, String> config) async {
    final index = _scripts.indexWhere((script) => script.id == id);
    if (index < 0) return;
    _disposeRuntime(id);
    final updated = _scripts[index].copyWithConfig(config);
    _scripts[index] = updated;
    _cache.clear();
    final probed = await _probe(updated);
    _scripts[index] = probed;
    await _persist();
    notifyListeners();
  }

  static Future<void> _ensureCeruAssets() async {
    _ceruCryptoJs ??= await rootBundle.loadString(
      'lib/assets/custom_sources/ceru/crypto-js.js',
    );
    _ceruPakoJs ??= await rootBundle.loadString(
      'lib/assets/custom_sources/ceru/pako-inflate.min.js',
    );
    _ceruShimJs ??= await rootBundle.loadString(
      'lib/assets/custom_sources/ceru/ceru-shim.js',
    );
  }
  final Map<String, _CacheEntry> _cache = {};
  final List<String> _logLines = [];
  final http.Client _http = http.Client();

  CustomSourceMode _mode = CustomSourceMode.auto;

  /// 用户在「第三方音源音质」里单独选的档位。
  ThirdPartyQuality _quality = ThirdPartyQuality.master;

  /// 用户删掉的内置音源 id，用来避免下次启动又自动装回来。
  final Set<String> _removedBuiltins = {};

  /// 移动网络下自动降一档音质，避免用流量拉无损。
  bool _networkAwareQuality = false;

  /// 当前平台取不到地址时，去别的平台找同一首歌。
  bool _switchPlatformOnFailure = false;
  bool _initialized = false;

  List<CustomSourceScript> get scripts => List.unmodifiable(_scripts);

  CustomSourceMode get mode => _mode;

  ThirdPartyQuality get quality => _quality;

  bool get networkAwareQuality => _networkAwareQuality;

  bool get switchPlatformOnFailure => _switchPlatformOnFailure;

  bool get isInitialized => _initialized;

  /// 至少有一个启用中的脚本才认为功能可用。
  bool get hasEnabledScript =>
      _scripts.any((script) => script.enabled && script.sources.isNotEmpty);

  /// 是否应该在播放链路里介入。
  bool get isActive => _mode != CustomSourceMode.official && hasEnabledScript;

  /// 最近日志（新的在后）。
  List<String> get recentLogs => List.unmodifiable(_logLines);

  // ------------------------------------------------------------------ 初始化
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final modeName = decoded['mode'];
          _mode = CustomSourceMode.fromName(modeName as String?);
          _quality = ThirdPartyQuality.fromLxValue(decoded['quality'] as String?) ??
              ThirdPartyQuality.master;
          _networkAwareQuality = decoded['networkAwareQuality'] == true;
          _switchPlatformOnFailure = decoded['switchPlatformOnFailure'] == true;
          final removed = decoded['removedBuiltins'];
          if (removed is List) {
            _removedBuiltins.addAll(removed.whereType<String>());
          }
          final list = decoded['scripts'];
          if (list is List) {
            for (final item in list) {
              if (item is Map) {
                try {
                  _scripts.add(
                    CustomSourceScript.fromJson(Map<String, dynamic>.from(item)),
                  );
                } catch (error) {
                  debugPrint('[custom-source] 跳过损坏的脚本记录: $error');
                }
              }
            }
          }
        }
      }
    } catch (error) {
      debugPrint('[custom-source] 读取配置失败: $error');
    }
    _scripts.sort((a, b) => a.order.compareTo(b.order));
    notifyListeners();
    // 后台装内置音源，不阻塞启动
    unawaited(_installBuiltinSources());
  }

  /// 把随包内置的音源装进列表（已装过、或被用户删过就跳过）。
  Future<void> _installBuiltinSources() async {
    // 单测环境没有真实资产与 JS 引擎，跳过以免拖慢用例
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    var changed = false;
    for (final builtin in kBuiltinCustomSources) {
      if (_removedBuiltins.contains(builtin.id)) continue;
      if (_scripts.any((script) => script.originUrl == builtin.origin)) continue;
      try {
        final code = await rootBundle.loadString(builtin.asset);
        final meta = LxScriptMeta.parse(code);
        final draft = CustomSourceScript(
          id: 'builtin-${builtin.id}',
          name: meta.name ?? builtin.displayName,
          code: code,
          version: meta.version ?? '',
          author: meta.author ?? '',
          description: meta.description ?? '',
          repository: meta.repository ?? '',
          enabled: true,
          order: _scripts.length,
          importedAt: DateTime.now(),
          originUrl: builtin.origin,
        );
        final probed = await _probe(draft);
        _scripts.add(probed);
        changed = true;
        debugPrint('[KA Music][custom-source] 已内置音源 ${probed.name}');
      } catch (error) {
        debugPrint('[custom-source] 内置音源 ${builtin.id} 安装失败：$error');
      }
    }
    if (changed) {
      _scripts.sort((a, b) => a.order.compareTo(b.order));
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'mode': _mode.name,
        'quality': _quality.lxValue,
        'networkAwareQuality': _networkAwareQuality,
        'switchPlatformOnFailure': _switchPlatformOnFailure,
        'removedBuiltins': _removedBuiltins.toList(),
        'scripts': _scripts.map((script) => script.toJson()).toList(),
      });
      await prefs.setString(_prefsKey, payload);
    } catch (error) {
      debugPrint('[custom-source] 保存配置失败: $error');
    }
  }

  // -------------------------------------------------------------------- 导入
  /// 从脚本源码导入。会先试跑一次拿到音源声明，失败也保留脚本并记录原因。
  Future<CustomSourceScript> importFromText(
    String code, {
    String? originUrl,
    String? fallbackName,
  }) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw LxRuntimeException('脚本内容为空');
    }

    final meta = LxScriptMeta.parse(trimmed);
    final isCeru = detectCeruFormat(trimmed);
    final ceruName = isCeru ? _ceruManifestName(trimmed) : null;
    final name = (ceruName?.trim().isNotEmpty == true)
        ? ceruName!.trim()
        : (meta.name?.trim().isNotEmpty == true)
            ? meta.name!.trim()
            : (fallbackName?.trim().isNotEmpty == true
                ? fallbackName!.trim()
                : '未命名音源');

    // 同名脚本直接覆盖，避免用户重复导入后列表里出现一堆同名项
    final duplicated = _scripts.where((script) => script.name == name).toList();
    for (final old in duplicated) {
      _disposeRuntime(old.id);
      _scripts.remove(old);
    }

    final script = CustomSourceScript(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      code: trimmed,
      format: isCeru ? CustomSourceFormat.ceru : CustomSourceFormat.lx,
      version: meta.version ?? '',
      author: meta.author ?? '',
      description: meta.description ?? '',
      repository: meta.repository ?? '',
      enabled: true,
      order: _nextOrder(),
      importedAt: DateTime.now(),
      originUrl: originUrl,
    );

    final probed = await _probe(script);
    _scripts.add(probed);
    _scripts.sort((a, b) => a.order.compareTo(b.order));
    _cache.clear();
    await _persist();
    notifyListeners();
    return probed;
  }

  /// 从网络地址导入，自动把 GitHub / Gitee / GitLab 的网页链接换成 raw 链接。
  Future<CustomSourceScript> importFromUrl(String url) async {
    final normalized = normalizeScriptUrl(url.trim());
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme) {
      throw LxRuntimeException('链接格式不正确');
    }
    final response = await _http
        .get(uri, headers: const {'Accept': 'text/plain,*/*'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LxRuntimeException('下载失败：HTTP ${response.statusCode}');
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (!text.contains('lx') && !text.contains('EVENT_NAMES')) {
      throw LxRuntimeException('这个链接返回的内容不像 lx-music 音源脚本');
    }
    final segments = uri.pathSegments;
    final fallbackName = segments.isNotEmpty ? segments.last : null;
    return importFromText(
      text,
      originUrl: normalized,
      fallbackName: fallbackName,
    );
  }

  /// 用脚本的实际运行结果补齐 `sources`，失败时把原因记进 `loadError`。
  Future<CustomSourceScript> _probe(CustomSourceScript script) async {
    if (script.isCeru || detectCeruFormat(script.code)) {
      return _probeCeru(script);
    }
    final runtime = LxRuntime(debugTag: script.name);
    try {
      final result = await runtime.load(script.code);
      _runtimes[script.id] = runtime;
      _appendLog('【${script.name}】加载成功，支持 ${result.sources.keys.join('/')}');
      return script.copyWith(sources: result.sources, clearLoadError: true);
    } catch (error) {
      runtime.dispose();
      final message = error is LxRuntimeException ? error.message : '$error';
      _appendLog('【${script.name}】加载失败：$message');
      return script.copyWith(sources: const {}, loadError: message);
    }
  }

  /// 加载 ceru 插件包并把它注册的平台转换成通用音源声明。
  Future<CustomSourceScript> _probeCeru(CustomSourceScript script) async {
    CeruRuntime? runtime;
    try {
      await _ensureCeruAssets();
      runtime = CeruRuntime(debugTag: script.name);
      final info = await runtime.load(
        pluginCode: script.code,
        cryptoJs: _ceruCryptoJs!,
        pakoJs: _ceruPakoJs!,
        shimJs: _ceruShimJs!,
        config: script.config,
      );
      _disposeCeruRuntime(script.id);
      _ceruRuntimes[script.id] = runtime;

      final decls = <String, LxSourceDecl>{};
      for (final provider in info.providers) {
        if (!provider.canResolve) continue;
        decls[provider.id] = LxSourceDecl(
          key: provider.id,
          name: provider.label,
          actions: const ['musicUrl'],
          qualitys: provider.qualities,
        );
      }
      final names = decls.values.map((decl) => decl.displayLabel).join('/');
      _appendLog('【${script.name}】ceru 插件激活成功，平台：$names');
      return script.copyWith(
        sources: decls,
        clearLoadError: true,
        format: CustomSourceFormat.ceru,
        config: {
          for (final key in info.configKeys) key: script.config[key] ?? '',
        },
      );
    } catch (error) {
      runtime?.dispose();
      final raw = error is LxRuntimeException ? error.message : '$error';
      // 这类插件通常强依赖自建服务，缺配置时把话说清楚
      final message = raw.contains('Invalid URL')
          ? '需要先在音源设置里填写接口地址（apiUrl）'
          : raw;
      _appendLog('【${script.name}】加载失败：$message');
      return script.copyWith(
        sources: const {},
        loadError: message,
        format: CustomSourceFormat.ceru,
      );
    }
  }

  /// 重新加载某个脚本（界面上的「重试」）。
  Future<void> reload(String id) async {
    final index = _scripts.indexWhere((script) => script.id == id);
    if (index < 0) return;
    final current = _scripts[index];
    _disposeRuntime(id);
    final probed = await _probe(current.copyWith(enabled: current.enabled));
    _scripts[index] = probed;
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  // -------------------------------------------------------------------- 维护
  Future<void> setMode(CustomSourceMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> setNetworkAwareQuality(bool value) async {
    if (_networkAwareQuality == value) return;
    _networkAwareQuality = value;
    await _persist();
    notifyListeners();
  }

  Future<void> setSwitchPlatformOnFailure(bool value) async {
    if (_switchPlatformOnFailure == value) return;
    _switchPlatformOnFailure = value;
    await _persist();
    notifyListeners();
  }

  /// 切换第三方音源音质档位。
  Future<void> setQuality(ThirdPartyQuality quality) async {
    if (_quality == quality) return;
    _quality = quality;
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = _scripts.indexWhere((script) => script.id == id);
    if (index < 0) return;
    _scripts[index] = _scripts[index].copyWith(enabled: enabled);
    if (!enabled) _disposeRuntime(id);
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _disposeRuntime(id);
    for (final script in _scripts) {
      if (script.id == id && script.originUrl != null) {
        final origin = script.originUrl!;
        if (origin.startsWith('builtin://')) {
          _removedBuiltins.add(origin.substring('builtin://'.length));
        }
      }
    }
    _scripts.removeWhere((script) => script.id == id);
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  /// 拖动排序后重新编号，序号即优先级。
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _scripts.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _scripts.length) target = _scripts.length - 1;
    final moved = _scripts.removeAt(oldIndex);
    _scripts.insert(target, moved);
    for (var i = 0; i < _scripts.length; i++) {
      _scripts[i] = _scripts[i].copyWith(order: i);
    }
    _cache.clear();
    await _persist();
    notifyListeners();
  }

  int _nextOrder() {
    if (_scripts.isEmpty) return 0;
    return _scripts
            .map((script) => script.order)
            .reduce((a, b) => a > b ? a : b) +
        1;
  }

  void _disposeRuntime(String id) {
    _runtimes.remove(id)?.dispose();
    _ceruRuntimes.remove(id)?.dispose();
  }

  void _disposeCeruRuntime(String id) {
    _ceruRuntimes.remove(id)?.dispose();
  }

  // -------------------------------------------------------------------- 解析
  /// 歌曲对应到 lx-music 的平台键。
  static String? platformKeyOf(Song song) {
    switch (song.source) {
      case SongSource.kugou:
        return 'kg';
      case SongSource.netease:
        return 'wy';
      case SongSource.qq:
        return 'tx';
      case SongSource.qs:
        return 'qs';
      case SongSource.local:
        return null;
    }
  }

  /// 组装 lx-music 约定的 `musicInfo`。
  ///
  /// 脚本之间字段取用差异较大：酷狗系脚本读 `hash`，QQ/网易系读 `songmid`，
  /// 少数脚本（溯音）还会用 `name` + `singer` 反查，所以这里尽量填满。
  static Map<String, dynamic> buildMusicInfo(Song song, String platform) {
    final duration = song.duration;
    final interval = duration == null
        ? ''
        : '${duration.inMinutes.toString().padLeft(2, '0')}:'
              '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    final singer = song.artist;
    return {
      'songmid': platform == 'wy' ? song.id : (song.hash.isEmpty ? song.id : song.hash),
      'hash': song.hash,
      'id': song.id,
      'name': song.title,
      'singer': singer,
      'albumName': song.albumName ?? '',
      'album': song.albumName ?? '',
      'albumId': song.albumId ?? '',
      'interval': interval,
      'img': song.coverUrl ?? '',
      'source': platform,
    };
  }

  /// 为歌曲解析播放地址。
  ///
  /// 按脚本顺序依次尝试，第一个成功即返回；全部失败时抛出最后一个错误，
  /// 由调用方决定是否回退到官方接口。
  Future<CustomSourceResolve> resolve(
    Song song, {
    required String appQuality,
    ThirdPartyQuality? preferredQuality,
  }) async {
    final platform = platformKeyOf(song);
    if (platform == null) {
      throw LxRuntimeException('本地歌曲不需要第三方音源');
    }
    final candidates = _scripts
        .where((script) => script.enabled && script.sources.isNotEmpty)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    if (candidates.isEmpty) {
      throw LxRuntimeException('没有启用中的第三方音源');
    }

    final cacheKey = '$platform:${song.hash}:${song.id}:$appQuality';
    final cached = _cache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.createdAt) < _cacheTtl) {
      return cached.resolve;
    }

    final musicInfo = buildMusicInfo(song, platform);
    Object? lastError;
    for (final script in candidates) {
      final decl = script.sources[platform];
      if (decl == null || !decl.canResolveUrl) continue;
      final quality = pickLxQuality(
        decl.qualitys,
        appQuality,
        preferred: (preferredQuality ?? _quality).lxValue,
      );
      try {
        final String? url;
        if (script.isCeru) {
          url = await _resolveCeruUrl(script, song, platform, quality);
        } else {
          final runtime = await _runtimeFor(script);
          url = await runtime.fetchMusicUrl(
            source: platform,
            musicInfo: musicInfo,
            quality: quality,
          );
        }
        if (url == null || url.isEmpty) {
          throw LxRuntimeException('插件没有返回播放地址');
        }
        final resolve = CustomSourceResolve(
          url: url,
          scriptName: script.name,
          sourceKey: platform,
          quality: quality,
        );
        _remember(cacheKey, resolve);
        _appendLog('【${script.name}】${song.title} → ${decl.displayLabel} $quality 成功');
        return resolve;
      } catch (error) {
        lastError = error;
        _appendLog(
          '【${script.name}】${song.title} 解析失败：'
          '${error is LxRuntimeException ? error.message : error}',
        );
      }
    }

    throw LxRuntimeException(
      lastError?.toString() ?? '没有脚本支持 ${lxSourceLabels[platform] ?? platform} 音源',
    );
  }

  /// ceru 插件按「资源引用」解析，不是 lx 的 hash/musicInfo。
  Future<String?> _resolveCeruUrl(
    CustomSourceScript script,
    Song song,
    String platform,
    String quality,
  ) async {
    final runtime = _ceruRuntimes[script.id] ?? await _probeCeruRuntime(script);
    if (runtime == null) throw LxRuntimeException('插件未就绪');
    final pluginId = runtime.info?.id ?? '';
    final trackId = song.id.isNotEmpty ? song.id : song.hash;
    return runtime.resolveUrl(
      platform,
      {
        'pluginId': pluginId,
        'providerId': platform,
        'kind': 'track',
        'id': trackId,
        'scope': 'provider',
        // 顺带带上元信息，个别平台按名字匹配时用得上
        'title': song.title,
        'subtitle': song.artist,
      },
      quality,
    );
  }

  Future<CeruRuntime?> _probeCeruRuntime(CustomSourceScript script) async {
    try {
      await _ensureCeruAssets();
      final runtime = CeruRuntime(debugTag: script.name);
      await runtime.load(
        pluginCode: script.code,
        cryptoJs: _ceruCryptoJs!,
        pakoJs: _ceruPakoJs!,
        shimJs: _ceruShimJs!,
        config: script.config,
      );
      _ceruRuntimes[script.id] = runtime;
      return runtime;
    } catch (error) {
      _appendLog('【${script.name}】运行时初始化失败：$error');
      return null;
    }
  }

  Future<LxRuntime> _runtimeFor(CustomSourceScript script) async {
    final existing = _runtimes[script.id];
    if (existing != null && existing.isReady) return existing;
    existing?.dispose();
    final runtime = LxRuntime(debugTag: script.name);
    await runtime.load(script.code);
    _runtimes[script.id] = runtime;
    return runtime;
  }

  void _remember(String key, CustomSourceResolve resolve) {
    if (_cache.length >= _cacheLimit) {
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
    }
    _cache[key] = _CacheEntry(resolve, DateTime.now());
  }

  void _appendLog(String line) {
    final stamp = DateTime.now().toString().substring(11, 19);
    _logLines.add('$stamp $line');
    if (_logLines.length > 200) {
      _logLines.removeRange(0, _logLines.length - 200);
    }
  }

  void clearLogs() {
    _logLines.clear();
    notifyListeners();
  }

  /// 让播放器在切歌/改设置后能立刻丢掉旧地址。
  void invalidateCache() {
    _cache.clear();
  }

  /// 把 GitHub / Gitee / GitLab 的网页链接转成可直接下载的 raw 链接。
  static String normalizeScriptUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;

    // https://github.com/user/repo/blob/main/x.js
    if (host.endsWith('github.com') && segments.length >= 5 && segments[2] == 'blob') {
      final rest = segments.sublist(3).join('/');
      return 'https://raw.githubusercontent.com/${segments[0]}/${segments[1]}/$rest';
    }
    // https://gitee.com/user/repo/blob/main/x.js
    if (host.endsWith('gitee.com') && segments.length >= 5 && segments[2] == 'blob') {
      final rest = segments.sublist(3).join('/');
      return 'https://gitee.com/${segments[0]}/${segments[1]}/raw/$rest';
    }
    // https://gitlab.com/user/repo/-/blob/main/x.js
    // prefix 已经包含 GitLab 的 `-` 分隔段，直接拼 `raw` 才不会重复
    final blobIndex = segments.indexOf('blob');
    if (host.endsWith('gitlab.com') && blobIndex > 0) {
      final prefix = segments.sublist(0, blobIndex).join('/');
      final rest = segments.sublist(blobIndex + 1).join('/');
      return 'https://gitlab.com/$prefix/raw/$rest';
    }
    return url;
  }

  @override
  void dispose() {
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
    _http.close();
    super.dispose();
  }
}
