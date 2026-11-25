import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../controllers/auth_controller.dart';
import '../../../controllers/player_controller.dart';
import '../../../models/music_models.dart';
import '../../design_tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/song_action_sheets.dart';
import '../../widgets/song_artwork.dart';

class QqRankBrief {
  const QqRankBrief({
    required this.id,
    required this.title,
    required this.cover,
    this.updateFrequency = '',
  });

  final int id;
  final String title;
  final String cover;
  final String updateFrequency;
}

/// QQ 音乐首页 / 榜单接口。
///
/// 榜单详情只给 `songId`（数字），而第三方音源解析播放要 `songmid`（字符串），
/// 所以拿到列表后要并发调 `get_song_detail` 补一次 mid。
class QqHomeApi {
  QqHomeApi._();

  static final QqHomeApi instance = QqHomeApi._();

  static const String _endpoint = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
  };

  http.Client? _client;

  http.Client get _http => _client ??= http.Client();

  Future<Map<String, dynamic>> _call(Map<String, dynamic> req) async {
    final response = await _http
        .post(
          Uri.parse(_endpoint),
          headers: _headers,
          body: jsonEncode({
            'comm': {'ct': 24, 'cv': 0},
            'req': req,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('QQ 接口 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return {};
    final data = decoded['req'];
    if (data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    return {};
  }

  /// 榜单目录（取「巅峰榜」一组）。
  Future<List<QqRankBrief>> topLists({int limit = 6}) async {
    final data = await _call({
      'module': 'musicToplist.ToplistInfoServer',
      'method': 'GetAll',
      'param': {'offset': 0, 'num': 10, 'period': ''},
    });
    final groups = data['group'];
    final ranks = <QqRankBrief>[];
    if (groups is! List) return ranks;
    for (final group in groups) {
      if (group is! Map) continue;
      final list = group['toplist'];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['topId'];
        if (id is! num) continue;
        ranks.add(
          QqRankBrief(
            id: id.toInt(),
            title: '${item['title'] ?? ''}',
            cover: '${item['frontPicUrl'] ?? ''}',
            updateFrequency: '${item['updateFrequency'] ?? ''}',
          ),
        );
        if (ranks.length >= limit) return ranks;
      }
    }
    return ranks;
  }

  /// 榜单曲目。会把 `songId` 并发换成 `songmid` 填进 [Song.id]。
  Future<List<Song>> topListDetail(int topId, {int count = 20}) async {
    final data = await _call({
      'module': 'musicToplist.ToplistInfoServer',
      'method': 'GetDetail',
      'param': {'topId': topId, 'offset': 0, 'num': count, 'period': ''},
    });
    final inner = data['data'];
    if (inner is! Map) return const [];
    final list = inner['songInfoList'] ?? inner['song'];
    if (list is! List) return const [];

    final drafts = <({int songId, String title, String artist, String cover})>[];
    for (final item in list) {
      if (item is! Map) continue;
      final songId = item['songId'];
      if (songId is! num) continue;
      drafts.add((
        songId: songId.toInt(),
        title: '${item['title'] ?? '未知歌曲'}',
        artist: '${item['singerName'] ?? ''}',
        cover: '${item['cover'] ?? ''}',
      ));
    }

    // 并发补 songmid（不补的话第三方音源解析不了）
    final mids = await Future.wait(
      drafts.map((draft) => songMidOf(draft.songId)),
    );
    final songs = <Song>[];
    for (var i = 0; i < drafts.length; i++) {
      final mid = mids[i];
      if (mid == null || mid.isEmpty) continue;
      final draft = drafts[i];
      songs.add(
        Song(
          id: mid,
          title: draft.title,
          artist: draft.artist.isEmpty ? '未知艺人' : draft.artist,
          hash: '',
          coverUrl: draft.cover.isEmpty ? null : draft.cover,
          source: SongSource.qq,
        ),
      );
    }
    return songs;
  }

  /// 单曲 songId → songmid。
  Future<String?> songMidOf(int songId) async {
    try {
      final data = await _call({
        'module': 'music.pf_song_detail_svr',
        'method': 'get_song_detail',
        'param': {'song_id': songId},
      });
      final track = data['track_info'];
      if (track is Map) {
        final mid = track['mid'];
        if (mid is String && mid.isNotEmpty) return mid;
      }
    } catch (_) {
      // 个别歌曲查不到就跳过
    }
    return null;
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}

/// QQ 音乐首页。
class QqHomeView extends StatefulWidget {
  const QqHomeView({
    super.key,
    required this.player,
    required this.auth,
    this.onSwitchPlatform,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onSwitchPlatform;

  @override
  State<QqHomeView> createState() => _QqHomeViewState();
}

class _QqHomeViewState extends State<QqHomeView> {
  List<QqRankBrief> _ranks = const [];
  List<Song> _hotSongs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = QqHomeApi.instance;
      final ranks = await api.topLists(limit: 6);
      final hot = ranks.isEmpty
          ? <Song>[]
          : await api.topListDetail(ranks.first.id, count: 15);
      if (!mounted) return;
      setState(() {
        _ranks = ranks;
        _hotSongs = hot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 140),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      () {
                        final hour = DateTime.now().hour;
                        if (hour < 6) return '夜深了';
                        if (hour < 12) return '早上好';
                        if (hour < 18) return '下午好';
                        return '晚上好';
                      }(),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'QQ音乐 · 巅峰榜',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onSwitchPlatform != null)
                IconButton(
                  tooltip: '切换平台',
                  onPressed: widget.onSwitchPlatform,
                  icon: const Icon(Icons.swap_horiz_rounded),
                ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(Icons.leaderboard_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                '巅峰榜',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 168,
            child: _loading && _ranks.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _ranks.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final rank = _ranks[index];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => QqRankPage(
                              rank: rank,
                              player: widget.player,
                              auth: widget.auth,
                            ),
                          ),
                        ),
                        child: Container(
                          width: 132,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                            color: scheme.surfaceContainerHighest
                                .withValues(alpha: 0.55),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 100,
                                width: double.infinity,
                                child: rank.cover.isEmpty
                                    ? Container(
                                        color: scheme.primary
                                            .withValues(alpha: 0.25),
                                        child: Icon(Icons.bar_chart_rounded,
                                            size: 34, color: scheme.primary),
                                      )
                                    : Artwork(
                                        url: rank.cover,
                                        size: double.infinity,
                                      ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 8, 10, 10),
                                child: Text(
                                  rank.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Icon(Icons.local_fire_department_rounded,
                  size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                '热歌榜 · 实时',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (_loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _hotSongs.length; i++)
            _QqSongRow(
              song: _hotSongs[i],
              index: i + 1,
              onTap: () =>
                  widget.player.playSong(_hotSongs[i], queue: _hotSongs),
              onMore: () => showSongActionSheet(
                context: context,
                song: _hotSongs[i],
                downloads: widget.player.downloadController,
                actions: const [],
              ),
            ),
        ],
      ),
    );
  }
}

class _QqSongRow extends StatelessWidget {
  const _QqSongRow({
    required this.song,
    required this.index,
    required this.onTap,
    required this.onMore,
  });

  final Song song;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      onLongPress: onMore,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: index <= 3 ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SongArtwork(song: song, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '更多',
              icon: Icon(Icons.more_horiz_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

/// QQ 榜单详情页。
class QqRankPage extends StatefulWidget {
  const QqRankPage({
    super.key,
    required this.rank,
    required this.player,
    required this.auth,
  });

  final QqRankBrief rank;
  final PlayerController player;
  final AuthController auth;

  @override
  State<QqRankPage> createState() => _QqRankPageState();
}

class _QqRankPageState extends State<QqRankPage> {
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs =
          await QqHomeApi.instance.topListDetail(widget.rank.id, count: 30);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.rank.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '加载失败：$_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
                  itemCount: _songs.length,
                  itemBuilder: (context, index) {
                    final song = _songs[index];
                    return _QqSongRow(
                      song: song,
                      index: index + 1,
                      onTap: () => widget.player.playSong(song, queue: _songs),
                      onMore: () => showSongActionSheet(
                        context: context,
                        song: song,
                        downloads: widget.player.downloadController,
                        actions: const [],
                      ),
                    );
                  },
                ),
    );
  }
}
