import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../design_tokens.dart';
import '../widgets/artwork.dart';
import 'playlist_detail_page.dart';

/// 歌单页（底部「歌单」tab）。
///
/// 两块：我创建的歌单（含「我喜欢」）、我收藏的歌单。
/// 标题行可折叠，右侧留了新建 / 排序的位置。
class PlaylistHubPage extends StatefulWidget {
  const PlaylistHubPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  State<PlaylistHubPage> createState() => _PlaylistHubPageState();
}

class _PlaylistHubPageState extends State<PlaylistHubPage> {
  bool _createdExpanded = true;
  bool _collectedExpanded = true;

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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) {
        final liked = widget.auth.likedPlaylist;
        final created = widget.auth.createdPlaylists;
        final collected = widget.auth.collectedPlaylists;

        // 创建组：我喜欢排第一，避免和已建歌单重复
        final createdItems = <PlaylistSummary>[
          if (liked != null) liked,
          for (final item in created)
            if (liked == null || item.id != liked.id) item,
        ];

        return ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 18,
            16,
            140,
          ),
          children: [
            _GroupHeader(
              title: '我创建的歌单',
              count: createdItems.length,
              expanded: _createdExpanded,
              onToggle: () =>
                  setState(() => _createdExpanded = !_createdExpanded),
            ),
            if (_createdExpanded)
              _PlaylistGroup(
                items: createdItems,
                emptyHint: '还没有歌单',
                onTap: _openPlaylist,
                highlightFirst: liked != null,
              ),
            const SizedBox(height: 26),
            _GroupHeader(
              title: '我收藏的歌单',
              count: collected.length,
              expanded: _collectedExpanded,
              onToggle: () =>
                  setState(() => _collectedExpanded = !_collectedExpanded),
            ),
            if (_collectedExpanded)
              _PlaylistGroup(
                items: collected,
                emptyHint: '还没有收藏歌单',
                onTap: _openPlaylist,
              ),
          ],
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Text(
              title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({
    required this.items,
    required this.emptyHint,
    required this.onTap,
    this.highlightFirst = false,
  });

  final List<PlaylistSummary> items;
  final String emptyHint;
  final ValueChanged<PlaylistSummary> onTap;

  /// 第一项是「我喜欢」时用粉色心形图标。
  final bool highlightFirst;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Text(
          emptyHint,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 76,
                color: scheme.outlineVariant.withValues(alpha: 0.3),
              ),
            _PlaylistRow(
              playlist: items[i],
              isLiked: highlightFirst && i == 0,
              onTap: () => onTap(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onTap,
    this.isLiked = false,
  });

  final PlaylistSummary playlist;
  final VoidCallback onTap;
  final bool isLiked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = playlist.coverUrl;
    final count = playlist.songCount ?? 0;
    final hasCover = cover != null && cover.isNotEmpty;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: hasCover
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF6EC6FF), Color(0xFFB39DDB)],
                      ),
                color: hasCover ? scheme.surfaceContainerHighest : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: hasCover
                  ? Artwork(url: cover, size: double.infinity)
                  : Icon(
                      isLiked
                          ? Icons.favorite_rounded
                          : Icons.music_note_rounded,
                      size: 26,
                      color: Colors.white,
                    ),
            ),
            const SizedBox(width: 14),
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
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$count 首歌',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
