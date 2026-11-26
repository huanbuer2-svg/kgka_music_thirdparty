import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../../services/playback_history_service.dart';
import '../../services/platform_preference.dart';
import '../design_tokens.dart';
import '../widgets/artwork.dart';
import '../widgets/platform_home_header.dart';
import '../widgets/song_artwork.dart';
import 'playback_history_page.dart';
import 'playlist_detail_page.dart';

/// 歌单页（底部「歌单」tab）。
///
/// 版式照着各家原生 App 的「音乐库」做：顶部平台徽标 + 头像，
/// 中间是我的歌单（喜欢 / 我创建的 / 收藏的），下面是最近播放。
class PlaylistHubPage extends StatefulWidget {
  const PlaylistHubPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    this.onOpenProfile,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  /// 右上角头像：切到「我的」。
  final VoidCallback? onOpenProfile;

  @override
  State<PlaylistHubPage> createState() => _PlaylistHubPageState();
}

class _PlaylistHubPageState extends State<PlaylistHubPage> {
  final PlaybackHistoryService _history = PlaybackHistoryService();
  List<Song> _recentSongs = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecent());
  }

  Future<void> _loadRecent() async {
    try {
      final songs = await _history.getHistory(limit: 5);
      if (!mounted) return;
      setState(() => _recentSongs = songs);
    } catch (error) {
      debugPrint('[KA Music][playlist-hub] 读取最近播放失败：$error');
    }
  }

  void _openPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackHistoryPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) {
        final liked = widget.auth.likedPlaylist;
        final created = widget.auth.createdPlaylists;
        final collected = widget.auth.collectedPlaylists;
        final platformLabel =
            PlatformPreference.labels[PlatformPreference.instance.platform] ??
                '音乐库';

        // 我的喜欢固定排第一，其余按创建顺序
        final entries = <_HubEntry>[
          if (liked != null)
            _HubEntry(
              playlist: liked,
              icon: Icons.favorite_rounded,
              color: const Color(0xFFFF5C7A),
            ),
          for (final item in created)
            _HubEntry(playlist: item, icon: Icons.queue_music_rounded),
          for (final item in collected.take(3))
            _HubEntry(playlist: item, icon: Icons.library_music_rounded),
        ];

        return RefreshIndicator(
          onRefresh: _loadRecent,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              18,
              MediaQuery.paddingOf(context).top + 10,
              18,
              140,
            ),
            children: [
              PlatformHomeHeader(
                platformKey: PlatformPreference.instance.platform,
                auth: widget.auth,
                subtitle: '音乐库 · $platformLabel 收藏与歌单',
                onTapAvatar: widget.onOpenProfile,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    '我的歌单',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${entries.length} 个',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (entries.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 26),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  child: Text(
                    '还没有歌单，登录后会自动同步',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.35,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            indent: 68,
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        _PlaylistTile(
                          entry: entries[i],
                          onTap: () => _openPlaylist(entries[i].playlist),
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Text(
                    '最近播放',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _openHistory,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('查看全部', style: TextStyle(fontSize: 12)),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 4),
              if (_recentSongs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '还没有播放记录',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (var i = 0; i < _recentSongs.length; i++)
                  _RecentSongRow(
                    song: _recentSongs[i],
                    onTap: () => widget.player.playSong(
                      _recentSongs[i],
                      queue: _recentSongs,
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _HubEntry {
  _HubEntry({
    required this.playlist,
    required this.icon,
    this.color,
  });

  final PlaylistSummary playlist;
  final IconData icon;
  final Color? color;
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.entry, required this.onTap});

  final _HubEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playlist = entry.playlist;
    final cover = playlist.coverUrl;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: entry.color?.withValues(alpha: 0.16) ??
                    scheme.primary.withValues(alpha: 0.12),
              ),
              clipBehavior: Clip.antiAlias,
              child: (cover != null && cover.isNotEmpty)
                  ? Artwork(url: cover, size: double.infinity)
                  : Icon(
                      entry.icon,
                      size: 22,
                      color: entry.color ?? scheme.primary,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    playlist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    playlist.songCount != null && playlist.songCount! > 0
                        ? '${playlist.songCount} 首'
                        : '空歌单',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _RecentSongRow extends StatelessWidget {
  const _RecentSongRow({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seconds = song.duration?.inSeconds;
    final timeText = seconds == null
        ? ''
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Row(
          children: [
            SongArtwork(song: song, size: 46),
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
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
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
            if (timeText.isNotEmpty)
              Text(
                timeText,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
