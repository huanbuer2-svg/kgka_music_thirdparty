import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../design_tokens.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/song_artwork.dart';

/// QQ 歌单内容页。
///
/// 走的是老 web 接口 `fcg_ucc_getcdinfo_byids_cp`（不需要签名），
/// 和歌单详情页那套分页/缓存逻辑对不上，所以单独做一个轻量页。
class QqPlaylistPage extends StatefulWidget {
  const QqPlaylistPage({
    super.key,
    required this.api,
    required this.player,
    required this.playlist,
  });

  final MusicApi api;
  final PlayerController player;
  final PlaylistSummary playlist;

  @override
  State<QqPlaylistPage> createState() => _QqPlaylistPageState();
}

class _QqPlaylistPageState extends State<QqPlaylistPage> {
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
      final songs = await widget.api.qqPlaylistSongs(widget.playlist.id);
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

  void _playAll() {
    if (_songs.isEmpty) return;
    widget.player.playSong(_songs.first, queue: _songs);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.playlist.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_songs.isNotEmpty)
            IconButton(
              tooltip: '播放全部',
              onPressed: _playAll,
              icon: const Icon(Icons.play_circle_outline_rounded),
            ),
        ],
      ),
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
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 120),
                  itemCount: _songs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
                        child: Row(
                          children: [
                            Text(
                              '${_songs.length} 首',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _playAll,
                              icon: const Icon(Icons.play_arrow_rounded,
                                  size: 18),
                              label: const Text('播放全部'),
                            ),
                          ],
                        ),
                      );
                    }
                    final song = _songs[index - 1];
                    return InkWell(
                      onTap: () => widget.player.playSong(
                        song,
                        queue: _songs,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
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
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
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
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                              onPressed: () => showSongActionSheet(
                                context: context,
                                song: song,
                                downloads: widget.player.downloadController,
                                actions: const [],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
