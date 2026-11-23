import 'dart:convert';

/// lx-music 自定义音源脚本的元信息与来源声明模型。
///
/// 脚本格式与 lx-music-desktop 一致：文件头部用注释块声明 `@name`、`@version`
/// 等字段，运行时通过 `send(EVENT_NAMES.inited, { sources })` 上报自己支持
/// 哪些平台（kw / kg / tx / wy / mg ...）、每个平台支持哪些动作
/// （musicUrl / lyric / pic）和音质档位。
class LxSourceDecl {
  const LxSourceDecl({
    required this.key,
    required this.name,
    this.type = 'music',
    this.actions = const ['musicUrl'],
    this.qualitys = const [],
  });

  /// 平台键，如 `kg`、`wy`、`tx`。
  final String key;

  /// 平台展示名（脚本里通常直接填平台键）。
  final String name;

  /// `music` / `local` 等。
  final String type;

  /// 支持的动作，脚本未声明时按 `musicUrl` 处理。
  final List<String> actions;

  /// 支持的音质档位，如 `128k` / `320k` / `flac`。
  final List<String> qualitys;

  bool supports(String action) =>
      actions.isEmpty || actions.contains(action);

  /// 该平台是否可用于「取播放地址」。
  bool get canResolveUrl => type != 'local' && supports('musicUrl');

  /// 平台键的可读名称。
  String get displayLabel => lxSourceLabels[key] ?? (name.isEmpty ? key : name);

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'type': type,
    'actions': actions,
    'qualitys': qualitys,
  };

  factory LxSourceDecl.fromJson(String key, Map<String, dynamic> json) {
    return LxSourceDecl(
      key: key,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : key,
      type: (json['type'] as String?) ?? 'music',
      actions: (json['actions'] as List?)?.map((e) => '$e').toList() ??
          const ['musicUrl'],
      qualitys:
          (json['qualitys'] as List?)?.map((e) => '$e').toList() ?? const [],
    );
  }
}

/// lx-music 平台键 → 中文名。
const Map<String, String> lxSourceLabels = {
  'kg': '酷狗',
  'kw': '酷我',
  'tx': 'QQ音乐',
  'wy': '网易云',
  'mg': '咪咕',
  'local': '本地',
};

/// 一条已导入的自定义音源脚本。
class CustomSourceScript {
  CustomSourceScript({
    required this.id,
    required this.name,
    required this.code,
    this.version = '',
    this.author = '',
    this.description = '',
    this.repository = '',
    this.enabled = true,
    this.order = 0,
    this.importedAt,
    this.originUrl,
    this.sources = const {},
    this.loadError,
  });

  final String id;
  final String name;
  final String code;
  final String version;
  final String author;
  final String description;
  final String repository;
  final bool enabled;
  final int order;
  final DateTime? importedAt;

  /// 从网络 URL 导入时记录的来源地址，本地文件导入为空。
  final String? originUrl;

  /// 脚本上报的音源声明；加载失败时为空。
  final Map<String, LxSourceDecl> sources;

  /// 上一次加载失败的报错（成功为 null）。仅内存态，不持久化。
  final String? loadError;

  /// 脚本体积（字节），用于界面展示。
  int get sizeInBytes => utf8.encode(code).length;

  List<String> get sourceLabels => sources.keys
      .where((key) => sources[key]?.canResolveUrl == true)
      .map((key) => lxSourceLabels[key] ?? key)
      .toList();

  /// 是否可用于某个平台键。
  bool supportsKey(String key) => sources[key]?.canResolveUrl == true;

  CustomSourceScript copyWith({
    bool? enabled,
    int? order,
    Map<String, LxSourceDecl>? sources,
    String? loadError,
    bool clearLoadError = false,
  }) {
    return CustomSourceScript(
      id: id,
      name: name,
      code: code,
      version: version,
      author: author,
      description: description,
      repository: repository,
      enabled: enabled ?? this.enabled,
      order: order ?? this.order,
      importedAt: importedAt,
      originUrl: originUrl,
      sources: sources ?? this.sources,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'code': code,
    'version': version,
    'author': author,
    'description': description,
    'repository': repository,
    'enabled': enabled,
    'order': order,
    'importedAt': importedAt?.toIso8601String(),
    if (originUrl != null) 'originUrl': originUrl,
    'sources': sources.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory CustomSourceScript.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'];
    final sources = <String, LxSourceDecl>{};
    if (rawSources is Map) {
      rawSources.forEach((key, value) {
        if (value is Map) {
          sources['$key'] = LxSourceDecl.fromJson(
            '$key',
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    final importedAt = json['importedAt'];
    return CustomSourceScript(
      id: '${json['id']}',
      name: '${json['name'] ?? '未命名音源'}',
      code: '${json['code'] ?? ''}',
      version: '${json['version'] ?? ''}',
      author: '${json['author'] ?? ''}',
      description: '${json['description'] ?? ''}',
      repository: '${json['repository'] ?? ''}',
      enabled: json['enabled'] != false,
      order: (json['order'] as num?)?.toInt() ?? 0,
      importedAt: importedAt is String ? DateTime.tryParse(importedAt) : null,
      originUrl: json['originUrl'] as String?,
      sources: sources,
    );
  }
}

/// 脚本头部注释里的元信息。
class LxScriptMeta {
  const LxScriptMeta({
    this.name,
    this.version,
    this.author,
    this.description,
    this.repository,
  });

  final String? name;
  final String? version;
  final String? author;
  final String? description;
  final String? repository;

  /// 解析脚本头部 8KB 内的 `@key value` 注释。
  ///
  /// 兼容 `/*! * @name x */`、`// @name x`、`/** @name x */` 三种写法。
  static LxScriptMeta parse(String source) {
    final head = source.length > 8192 ? source.substring(0, 8192) : source;
    final values = <String, String>{};
    final pattern = RegExp(
      r'^[\s/*!#-]*@(name|version|author|description|repository|homepage)\s+(.*)$',
      multiLine: true,
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(head)) {
      final key = match.group(1)!.toLowerCase();
      var value = match.group(2)!.trim();
      // 去掉行尾注释闭合符
      value = value.replaceAll(RegExp(r'\s*\*/\s*$'), '').trim();
      if (value.isNotEmpty && !values.containsKey(key)) {
        values[key] = value;
      }
    }
    return LxScriptMeta(
      name: values['name'],
      version: values['version'],
      author: values['author'],
      description: values['description'],
      repository: values['repository'] ?? values['homepage'],
    );
  }
}

/// 第三方音源单独的音质档位。
///
/// 脚本声明的 `qualitys` 用的是 lx-music 的字符串（`flac24bit` / `hires` /
/// `atmos` / `master` …），和官方接口的 128/320/flac 不是一套体系，
/// 所以单独给一份用户偏好，不必跟着官方音质走。
enum ThirdPartyQuality {
  bit24('flac24bit', '24位', '24BIT'),
  hiRes('hires', 'Hi-Res', 'HI-RES'),
  atmos('atmos', 'Atmos', 'ATMOS'),
  atmosPlus('atmos_plus', 'Atmos+', 'ATMOS+'),
  master('master', 'Master', 'MASTER');

  const ThirdPartyQuality(this.lxValue, this.label, this.badge);

  /// 写进脚本 `info.type` 的值。
  final String lxValue;
  final String label;
  final String badge;

  static ThirdPartyQuality? fromLxValue(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final quality in ThirdPartyQuality.values) {
      if (quality.lxValue == value) return quality;
    }
    return null;
  }
}

/// App 音质设置 → 候选的 lx 脚本音质档位（从高到低）。
List<String> lxQualityPreference(String appQuality) {
  switch (appQuality) {
    case 'master':
      return const ['master', 'hires', 'flac24bit', 'flac', '320k', '128k'];
    case 'hires':
      return const ['hires', 'flac24bit', 'flac', '320k', '128k'];
    case 'flac':
      return const ['flac', 'flac24bit', 'hires', '320k', '128k'];
    case '320':
      return const ['320k', '320', '128k'];
    default:
      return const ['128k', '320k', 'flac'];
  }
}

/// 在脚本声明的音质里挑一个最合适的档位。
///
/// [preferred] 是用户在「第三方音源音质」里单独选的档位，只要脚本支持就优先用；
/// 否则退回按 App 音质推导的偏好链。
String pickLxQuality(
  List<String> declared,
  String appQuality, {
  String? preferred,
}) {
  if (declared.isEmpty) {
    return preferred ?? lxQualityPreference(appQuality).first;
  }
  if (preferred != null &&
      preferred.isNotEmpty &&
      declared.contains(preferred)) {
    return preferred;
  }
  for (final candidate in lxQualityPreference(appQuality)) {
    if (declared.contains(candidate)) return candidate;
  }
  return declared.first;
}
