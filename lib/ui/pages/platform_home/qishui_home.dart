import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/auth_controller.dart';
import '../../../controllers/player_controller.dart';
import '../../../models/music_models.dart';
import '../../../services/qishui_api.dart';
import '../../../services/platform_preference.dart';
import '../../design_tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/song_action_sheets.dart';
import '../../widgets/song_artwork.dart';

/// 汽水音乐首页。
///
/// 汽水没有公开的「每日推荐」接口，能拿到的是四个官方榜 + 榜内 50 首，
/// 所以首页以榜单为主：上面是榜单入口，下面是热歌榜的即时列表。
class QishuiHomeView extends StatefulWidget {
  const QishuiHomeView({
    super.key,
    required this.player,
    required this.auth,
    this.onSwitchPlatform,
  });

  final PlayerController player;
  final AuthController auth;

  /// 顶部切换平台入口（切回酷狗或其他平台）。
  final VoidCallback? onSwitchPlatform;

  @override
  State<QishuiHomeView> createState() => _QishuiHomeViewState();
}

class _QishuiHomeViewState extends State<QishuiHomeView> {
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
      final songs = await QishuiApi.instance.topListDetail(
        QishuiApi.topLists.first.id,
      );
      if (!mounted) return;
      setState(() {
        _hotSongs = songs;
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

  void _playFrom(int index) {
    if (index < 0 || index >= _hotSongs.length) return;
    widget.player.playSong(_hotSongs[index], queue: _hotSongs);
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
              Expanded(child: _Greeting(label: PlatformPreference.instance.label)),
              if (widget.onSwitchPlatform != null)
                IconButton(
                  tooltip: '切换平台',
                  onPressed: widget.onSwitchPlatform,
                  icon: const Icon(Icons.swap_horiz_rounded),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(Icons.leaderboard_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                '排行榜',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: QishuiApi.topLists.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final list = QishuiApi.topLists[index];
                return _TopListCard(
                  list: list,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QishuiRankPage(
                        topList: list,
                        player: widget.player,
                        auth: widget.auth,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 26),
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Text(
                    '加载失败：$_error',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          else if (_loading && _hotSongs.isEmpty)
            for (var i = 0; i < 6; i++)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(height: 44),
              )
          else
            for (var i = 0; i < _hotSongs.length && i < 20; i++)
              _SongRow(
                song: _hotSongs[i],
                index: i + 1,
                onTap: () => _playFrom(i),
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

class _Greeting extends StatelessWidget {
  const _Greeting({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final text = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$label · 榜单与热门',
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TopListCard extends StatelessWidget {
  const _TopListCard({required this.list, required this.onTap});

  final QishuiTopList list;
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
              height: 92,
              width: double.infinity,
              child: list.cover.isEmpty
                  ? Container(
                      color: scheme.primary.withValues(alpha: 0.25),
                      child: Icon(Icons.bar_chart_rounded,
                          size: 36, color: scheme.primary),
                    )
                  : Artwork(url: list.cover, size: double.infinity),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    list.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    list.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
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

/// 榜单详情页（50 首）。
class QishuiRankPage extends StatefulWidget {
  const QishuiRankPage({
    super.key,
    required this.topList,
    required this.player,
    required this.auth,
  });

  final QishuiTopList topList;
  final PlayerController player;
  final AuthController auth;

  @override
  State<QishuiRankPage> createState() => _QishuiRankPageState();
}

class _QishuiRankPageState extends State<QishuiRankPage> {
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
      final songs = await QishuiApi.instance.topListDetail(widget.topList.id);
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
      appBar: AppBar(title: Text(widget.topList.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.error, fontSize: 12)),
                      const SizedBox(height: 10),
                      OutlinedButton(
                          onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
                  itemCount: _songs.length,
                  itemBuilder: (context, index) {
                    final song = _songs[index];
                    return _SongRow(
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
