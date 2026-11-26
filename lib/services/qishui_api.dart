import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/music_models.dart';

/// 汽水音乐（qs）的直连接口。
///
/// 汽水官方接口（`api.qishui.com` / `api5-lq.qishui.com`）需要抖音的
/// `x-gorgon` / `msToken` 签名与设备 cookie，客户端直连只会拿到 200 空响应。
/// 这里走第三方维护的聚合后端（星海），它替我们完成了签名与设备注册：
///
/// - 搜索 `GET /qs.php?action=search&keywords=&page=`
/// - 播放 `GET /?source=qs&name=&singer=&songmid=&quality=`
///
/// 播放返回的 `source_url` 还需要拼上 `key` 才能直接取流。
/// 汽水的官方榜单（汽水没有公开的榜单目录接口，这四个是固定入口）。
class QishuiTopList {
  const QishuiTopList({
    required this.id,
    required this.title,
    required this.description,
    required this.cover,
  });

  final String id;
  final String title;
  final String description;
  final String cover;
}

class QishuiApi {
  QishuiApi._();

  static final QishuiApi instance = QishuiApi._();

  static const String _base = 'https://yy1.zddyr.top/lx/api';

  static const Duration _timeout = Duration(seconds: 15);

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 四个官方榜（id 与汽水 App 内一致）。
  static const List<QishuiTopList> topLists = [
    QishuiTopList(
      id: '7036274230471712007',
      title: '热歌榜',
      description: '每周热度最高的 50 首',
      cover: 'https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/'
          'd0d8d48461a62748e84689cdf049b19a.png~tplv-b829550vbb-resize:960:960.png',
    ),
    QishuiTopList(
      id: '7060812597884869927',
      title: '新歌榜',
      description: '近期发行的热门新歌',
      cover: 'https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/'
          'f12f7eb5b54d0a3e7a4c0d2e3e1e2b6a.png~tplv-b829550vbb-resize:960:960.png',
    ),
    QishuiTopList(
      id: '7061475546400005410',
      title: '欧美榜',
      description: '热度最高的外文歌',
      cover: 'https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/'
          '3374755015aeb1f2e6e0c1a3f0e8b1c2.png~tplv-b829550vbb-resize:960:960.png',
    ),
    QishuiTopList(
      id: '7061475546400005411',
      title: '国风榜',
      description: '国风与古风热门单曲',
      cover: '',
    ),
  ];

  http.Client? _client;

  http.Client get _http => _client ??= http.Client();

  /// 搜索汽水曲库。
  Future<List<Song>> search(String keywords, {int page = 1}) async {
    final uri = Uri.parse('$_base/qs.php').replace(
      queryParameters: {
        'action': 'search',
        'keywords': keywords,
        'page': '$page',
      },
    );
    final response = await _http.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('汽水搜索失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw Exception('汽水搜索返回格式异常');
    final code = decoded['code'];
    if (code != null && code != 200) {
      throw Exception('汽水搜索失败：${decoded['msg'] ?? code}');
    }
    final list = decoded['list'];
    if (list is! List) return const [];

    final songs = <Song>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final rawDuration = item['duration'];
      final durationMs = rawDuration is num
          ? rawDuration.toInt()
          : int.tryParse('${rawDuration ?? ''}') ?? 0;
      final cover = item['cover'] ?? item['pic'];
      songs.add(
        Song(
          id: id,
          title: '${item['name'] ?? '未知歌曲'}',
          artist: '${item['artist'] ?? '未知艺人'}',
          hash: '',
          albumName: item['album'] is String ? item['album'] as String : null,
          coverUrl: cover is String && cover.isNotEmpty ? cover : null,
          duration: durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
          source: SongSource.qs,
        ),
      );
    }
    return songs;
  }

  /// 取播放地址。返回可直接给播放器的完整 URL（已拼上 key）。
  ///
  /// 应用的音质档位是酷狗那套（128/320/flac/hires/master），
  /// 汽水后端只认 128k/320k/flac，且高档位不一定每首歌都有，
  /// 所以这里按档位降级试，避免「点了没反应」。
  Future<String?> resolveUrl(Song song, {String quality = '320k'}) async {
    if (song.id.isEmpty) return null;
    for (final candidate in _qualityCandidates(quality)) {
      final url = await _requestUrl(song, candidate);
      if (url != null && url.isNotEmpty) {
        if (candidate != _normalizeQuality(quality)) {
          debugPrint('[KA Music][qishui] ${song.title} 降级到 $candidate');
        }
        return url;
      }
    }
    return null;
  }

  /// 档位降级链：首选 → 320k → 128k。
  static List<String> _qualityCandidates(String quality) {
    final preferred = _normalizeQuality(quality);
    switch (preferred) {
      case 'flac':
        return const ['flac', '320k', '128k'];
      case '320k':
        return const ['320k', '128k'];
      default:
        return const ['128k'];
    }
  }

  /// 把应用里的档位名映射成汽水后端认的值。
  static String _normalizeQuality(String quality) {
    final value = quality.toLowerCase();
    if (value.contains('flac') ||
        value == 'hires' ||
        value == 'master' ||
        value.contains('atmos')) {
      return 'flac';
    }
    if (value.startsWith('320')) return '320k';
    if (value.startsWith('128')) return '128k';
    return '320k';
  }

  Future<String?> _requestUrl(Song song, String quality) async {
    final uri = Uri.parse(_base).replace(
      queryParameters: {
        'source': 'qs',
        'name': song.title,
        'singer': song.artist,
        'songmid': song.id,
        'quality': quality,
      },
    );
    try {
      final response = await _http.get(uri, headers: _headers).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      final code = decoded['code'];
      if (code != null && code != 200) {
        debugPrint('[KA Music][qishui] $quality 取址失败：${decoded['msg'] ?? code}');
        return null;
      }
      final data = decoded['data'];
      if (data is! Map) return null;
      var url = data['source_url'] ?? data['url'];
      if (url is! String || url.isEmpty) return null;
      // 抖音流必须带 key 才能访问
      final key = data['key'];
      if (key is String && key.isNotEmpty && !url.contains('key=')) {
        url = '$url${url.contains('?') ? '&' : '?'}key=${Uri.encodeComponent(key)}';
      }
      // 抖音 CDN 会先 302 到一个带 x-redirect 的中转域名，
      // 部分播放器（尤其 iOS AVPlayer）对「302 + 无扩展名 URL」支持不好，
      // 这里先自己跟一次，把最终地址交给播放器。
      final resolved = await _resolveRedirect(url);
      debugPrint('[KA Music][qishui] ${song.title} → $quality'
          '${resolved != null && resolved != url ? '（已跟随重定向）' : ''}');
      return resolved ?? url;
    } catch (error) {
      debugPrint('[KA Music][qishui] $quality 异常：$error');
      return null;
    }
  }

  /// 跟随重定向拿最终地址。
  ///
  /// 注意不能用 `response.request.url` —— 那是**发起时的原始 URL**，
  /// 不是重定向后的目标（上一版就栽在这）。这里关掉自动重定向，
  /// 手动读 `Location` 逐跳解析，最多 3 跳。
  Future<String?> _resolveRedirect(String url) async {
    var current = url;
    final client = _client ??= http.Client();
    try {
      for (var hop = 0; hop < 3; hop++) {
        final request = http.Request('GET', Uri.parse(current))
          ..followRedirects = false
          ..headers['Range'] = 'bytes=0-0';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 12));
        // 立刻断开，别把音频拉下来
        unawaited(response.stream.drain<void>().catchError((_) {}));

        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          // 不再跳转：current 就是可直连的最终地址
          return hop == 0 ? null : current;
        }
        // Location 可能是相对路径
        current = Uri.parse(current).resolve(location.trim()).toString();
        debugPrint('[KA Music][qishui] 重定向 ${hop + 1} → '
            '${Uri.parse(current).host}');
      }
      return current;
    } catch (error) {
      debugPrint('[KA Music][qishui] 跟随重定向失败：$error');
      return null;
    }
  }

  /// 拉某个榜单的曲目（官方 charts 接口，不需要抖音签名）。
  Future<List<Song>> topListDetail(String chartId) async {
    final uri = Uri.parse('https://api.qishui.com/luna/pc/charts/$chartId')
        .replace(
          queryParameters: const {
            'aid': '386088',
            'device_platform': 'web',
            'channel': 'pc_web',
          },
        );
    final response = await _http.get(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'x-luna-background-type': 'foreground',
        'x-luna-is-background-req': '0',
        'x-luna-is-local-user': '1',
        'Referer': 'https://music.douyin.com/',
      },
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('汽水榜单失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return const [];
    final chart = decoded['chart'];
    if (chart is! Map) return const [];
    final ranks = chart['track_ranks'];
    if (ranks is! List) return const [];

    final songs = <Song>[];
    for (final entry in ranks) {
      if (entry is! Map) continue;
      final track = entry['track'];
      if (track is! Map) continue;
      final id = '${track['id'] ?? ''}';
      if (id.isEmpty) continue;
      final artists = track['artists'];
      final artist = artists is List
          ? artists
              .whereType<Map>()
              .map((item) => '${item['name'] ?? ''}')
              .where((name) => name.isNotEmpty)
              .join(' / ')
          : '';
      final album = track['album'];
      final covers = (album is Map && album['url_cover'] is Map)
          ? (album['url_cover']['urls'] as List?)
          : null;
      final rawDuration = track['duration'];
      var durationMs = rawDuration is num ? rawDuration.toInt() : 0;
      if (durationMs > 10000000) durationMs = durationMs ~/ 1000;
      songs.add(
        Song(
          id: id,
          title: '${track['name'] ?? '未知歌曲'}',
          artist: artist.isEmpty ? '未知艺人' : artist,
          hash: '',
          albumName: album is Map ? '${album['name'] ?? ''}' : null,
          coverUrl: (covers != null && covers.isNotEmpty)
              ? '${covers.first}'
              : null,
          duration: durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
          source: SongSource.qs,
        ),
      );
    }
    return songs;
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}
