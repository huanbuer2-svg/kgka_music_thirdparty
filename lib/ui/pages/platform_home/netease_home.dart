import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../controllers/auth_controller.dart';
import '../../../controllers/player_controller.dart';
import '../../../models/music_models.dart';
import '../../design_tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/platform_home_header.dart';
import '../../widgets/song_action_sheets.dart';
import '../../widgets/song_artwork.dart';

/// 网易云首页 / 榜单的数据接口。
class NeteaseHomeApi {
  NeteaseHomeApi._();

  static final NeteaseHomeApi instance = NeteaseHomeApi._();

  static const String _base = 'https://wyy.music.api.hoilai.cn';

  http.Client? _client;

  http.Client get _http => _client ??= http.Client();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
  };

  /// 官方榜单目录（只取前几个主榜）。
  Future<List<NeteaseRankBrief>> topLists({int limit = 6}) async {
    final uri = Uri.parse('$_base/toplist');
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    final list = decoded['list'];
    if (list is! List) return const [];
    final ranks = <NeteaseRankBrief>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = item['id'];
      final name = '${item['name'] ?? ''}';
      if (id == null || name.isEmpty) continue;
      ranks.add(
        NeteaseRankBrief(
          id: '$id',
          title: name,
          description: '${item['updateFrequency'] ?? ''}',
          cover: '${item['coverImgUrl'] ?? ''}',
        ),
      );
      if (ranks.length >= limit) break;
    }
    return ranks;
  }

  /// 推荐歌单。
  Future<List<NeteasePlaylistBrief>> recommended({
    int limit = 6,
  }) async {
    final uri = Uri.parse('$_base/personalized')
        .replace(queryParameters: {'limit': '$limit'});
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    final list = decoded['result'];
    if (list is! List) return const [];
    final playlists = <NeteasePlaylistBrief>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id == null) continue;
      playlists.add(
        NeteasePlaylistBrief(
          id: '$id',
          title: '${item['name'] ?? ''}',
          cover: '${item['picUrl'] ?? ''}',
        ),
      );
    }
    return playlists;
  }

  /// 每日推荐（/recommend/songs 的 dailySongs，30 首）。
  Future<List<Song>> dailySongs() async {
    final uri = Uri.parse('$_base/recommend/songs');
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    final data = decoded['data'];
    if (data is! Map) return const [];
    final list = data['dailySongs'];
    if (list is! List) return const [];
    return _songsFromList(list);
  }

  List<Song> _songsFromList(List<dynamic> list) {
    final songs = <Song>[];
    for (final item in list) {
      if (item is! Map) continue;
      final idValue = item['id'];
      if (idValue == null) continue;
      final artists = item['ar'] ?? item['artists'];
      final artist = artists is List
          ? artists
              .whereType<Map>()
              .map((entry) => '${entry['name'] ?? ''}')
              .where((name) => name.isNotEmpty)
              .join(' / ')
          : '';
      final album = item['al'] ?? item['album'];
      var durationMs = 0;
      if (item['dt'] != null) {
        durationMs = (item['dt'] as num).toInt();
      } else if (item['duration'] != null) {
        durationMs = (item['duration'] as num).toInt();
      }
      songs.add(
        Song(
          id: '$idValue',
          title: '${item['name'] ?? '未知歌曲'}',
          artist: artist.isEmpty ? '未知艺人' : artist,
          hash: '',
          albumName: album is Map ? '${album['name'] ?? ''}' : null,
          coverUrl: album is Map && album['picUrl'] is String
              ? album['picUrl'] as String
              : null,
          duration: durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
          source: SongSource.netease,
        ),
      );
    }
    return songs;
  }

  /// 榜单/歌单里的曲目。
  Future<List<Song>> playlistTracks(String id) async {
    final uri = Uri.parse('$_base/playlist/detail')
        .replace(queryParameters: {'id': id});
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 25));
    final decoded = _decode(response);
    final playlist = decoded['playlist'];
    if (playlist is! Map) return const [];
    final tracks = playlist['tracks'];
    if (tracks is! List) return const [];
    final songs = <Song>[];
    for (final item in tracks) {
      if (item is! Map) continue;
      final idValue = item['id'];
      if (idValue == null) continue;
      final artists = item['ar'] ?? item['artists'];
      final artist = artists is List
          ? artists
              .whereType<Map>()
              .map((entry) => '${entry['name'] ?? ''}')
              .where((name) => name.isNotEmpty)
              .join(' / ')
          : '';
      final album = item['al'] ?? item['album'];
      var durationMs = 0;
      if (item['dt'] != null) {
        durationMs = (item['dt'] as num).toInt();
      } else if (item['duration'] != null) {
        durationMs = (item['duration'] as num).toInt();
      }
      songs.add(
        Song(
          id: '$idValue',
          title: '${item['name'] ?? '未知歌曲'}',
          artist: artist.isEmpty ? '未知艺人' : artist,
          hash: '',
          albumName: album is Map ? '${album['name'] ?? ''}' : null,
          coverUrl: album is Map && album['picUrl'] is String
              ? album['picUrl'] as String
              : null,
          duration: durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
          source: SongSource.netease,
        ),
      );
    }
    return songs;
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      throw Exception('网易云接口 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}

class NeteaseRankBrief {
  const NeteaseRankBrief({
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

class NeteasePlaylistBrief {
  const NeteasePlaylistBrief({
    required this.id,
    required this.title,
    required this.cover,
  });

  final String id;
  final String title;
  final String cover;
}

/// 网易云首页。
class NeteaseHomeView extends StatefulWidget {
  const NeteaseHomeView({
    super.key,
    required this.player,
    required this.auth,
    this.onSwitchPlatform,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onSwitchPlatform;

  @override
  State<NeteaseHomeView> createState() => _NeteaseHomeViewState();
}

class _NeteaseHomeViewState extends State<NeteaseHomeView> {
  List<NeteaseRankBrief> _ranks = const [];
  List<NeteasePlaylistBrief> _playlists = const [];
  List<Song> _hotSongs = const [];
  List<Song> _dailySongs = const [];
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
      final api = NeteaseHomeApi.instance;
      final results = await Future.wait([
        api.topLists(limit: 6),
        api.recommended(limit: 6),
        api.dailySongs(),
      ]);
      final ranks = results[0] as List<NeteaseRankBrief>;
      final playlists = results[1] as List<NeteasePlaylistBrief>;
      final daily = results[2] as List<Song>;
      final hot = ranks.isEmpty
          ? <Song>[]
          : await api.playlistTracks(ranks.first.id);
      if (!mounted) return;
      setState(() {
        _ranks = ranks;
        _playlists = playlists;
        _dailySongs = daily;
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

  Future<void> _playPlaylist(NeteasePlaylistBrief playlist) async {
    try {
      final songs = await NeteaseHomeApi.instance.playlistTracks(playlist.id);
      if (!mounted) return;
      if (songs.isEmpty) {
        setState(() => _error = '这个歌单没有可播放的歌曲');
        return;
      }
      await widget.player.playSong(songs.first, queue: songs);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          18, MediaQuery.paddingOf(context).top + 10, 18, 140),
        children: [
          PlatformHomeHeader(
            platformKey: 'netease',
            auth: widget.auth,
            subtitle: '网易云 · 推荐与榜单',
            onSwitchPlatform: widget.onSwitchPlatform,
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
          if (_dailySongs.isNotEmpty) ...[
            _DailyCard(
              songs: _dailySongs,
              onPlay: () => widget.player.playSong(
                _dailySongs.first,
                queue: _dailySongs,
              ),
            ),
            const SizedBox(height: 22),
          ],
          _sectionTitle(context, '推荐歌单', Icons.queue_music_rounded),
          const SizedBox(height: 12),
          SizedBox(
            height: 176,
            child: _loading && _playlists.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _playlists.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final item = _playlists[index];
                      return _CoverCard(
                        title: item.title,
                        cover: item.cover,
                        onTap: () => _playPlaylist(item),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, '排行榜', Icons.leaderboard_rounded),
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
                      return _CoverCard(
                        title: rank.title,
                        subtitle: rank.description,
                        cover: rank.cover,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NeteaseRankPage(
                              rank: rank,
                              player: widget.player,
                              auth: widget.auth,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, '热歌榜 · 实时', Icons.local_fire_department_rounded),
          const SizedBox(height: 8),
          if (_hotSongs.isEmpty && _loading)
            for (var i = 0; i < 6; i++)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(height: 44),
              )
          else
            for (var i = 0; i < _hotSongs.length && i < 20; i++)
              _RankSongRow(
                song: _hotSongs[i],
                index: i + 1,
                onTap: () => widget.player.playSong(
                  _hotSongs[i],
                  queue: _hotSongs,
                ),
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

  Widget _sectionTitle(BuildContext context, String text, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

/// 每日推荐大卡片（对齐原生 App 的入口样式）。
class _DailyCard extends StatelessWidget {
  const _DailyCard({required this.songs, required this.onPlay});

  final List<Song> songs;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = songs.first.coverUrl;
    return GestureDetector(
      onTap: onPlay,
      child: Container(
        height: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: scheme.primaryContainer.withValues(alpha: 0.55),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null && cover.isNotEmpty)
              Artwork(url: cover, size: double.infinity)
            else
              Container(color: scheme.primary.withValues(alpha: 0.3)),
            // 底部渐变压暗，保证文字可读
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '每日推荐',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '根据你的口味生成 · ${songs.length} 首',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 14,
              bottom: 16,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow_rounded,
                    size: 26, color: scheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.title,
    required this.cover,
    required this.onTap,
    this.subtitle,
  });

  final String title;
  final String cover;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 100,
              width: double.infinity,
              child: cover.isEmpty
                  ? Container(
                      color: scheme.primary.withValues(alpha: 0.25),
                      child: Icon(Icons.album_rounded,
                          size: 34, color: scheme.primary),
                    )
                  : Artwork(url: cover, size: double.infinity),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankSongRow extends StatelessWidget {
  const _RankSongRow({
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

/// 网易云榜单详情页。
class NeteaseRankPage extends StatefulWidget {
  const NeteaseRankPage({
    super.key,
    required this.rank,
    required this.player,
    required this.auth,
  });

  final NeteaseRankBrief rank;
  final PlayerController player;
  final AuthController auth;

  @override
  State<NeteaseRankPage> createState() => _NeteaseRankPageState();
}

class _NeteaseRankPageState extends State<NeteaseRankPage> {
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
          await NeteaseHomeApi.instance.playlistTracks(widget.rank.id);
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
                    return _RankSongRow(
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
