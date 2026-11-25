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
  Future<String?> resolveUrl(Song song, {String quality = '320k'}) async {
    if (song.id.isEmpty) return null;
    final uri = Uri.parse(_base).replace(
      queryParameters: {
        'source': 'qs',
        'name': song.title,
        'singer': song.artist,
        'songmid': song.id,
        'quality': quality,
      },
    );
    final response = await _http.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('汽水取地址失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw Exception('汽水取地址返回格式异常');
    final code = decoded['code'];
    if (code != null && code != 200) {
      throw Exception('汽水取地址失败：${decoded['msg'] ?? code}');
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
    debugPrint('[KA Music][qishui] ${song.title} → ${data['quality'] ?? quality}');
    return url;
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}
