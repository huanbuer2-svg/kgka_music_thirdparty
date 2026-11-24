import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/custom_source/custom_source_manager.dart';
import 'package:kgka_music_hl/services/custom_source/lx_script.dart';

const _sampleScript = '''
/*!
 * @name 示例音源[公益版]
 * @description QQ群 123456
 * @version v22
 * @author someone
 * @repository https://github.com/lxmusics/lx-music-api-server
 */

const { EVENT_NAMES, request, on, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: { kg: { name: 'kg', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] } } })
''';

void main() {
  group('脚本头部解析', () {
    test('读取 @name/@version/@author 等字段', () {
      final meta = LxScriptMeta.parse(_sampleScript);
      expect(meta.name, '示例音源[公益版]');
      expect(meta.version, 'v22');
      expect(meta.author, 'someone');
      expect(meta.description, 'QQ群 123456');
      expect(meta.repository, 'https://github.com/lxmusics/lx-music-api-server');
    });

    test('行注释写法同样可解析', () {
      final meta = LxScriptMeta.parse('// @name 落雪\n// @version 1.0.3\nvar a = 1;');
      expect(meta.name, '落雪');
      expect(meta.version, '1.0.3');
    });

    test('没有元信息时返回空字段', () {
      final meta = LxScriptMeta.parse('var a = 1;');
      expect(meta.name, isNull);
    });
  });

  group('音质档位选择', () {
    test('无损优先取 flac', () {
      expect(pickLxQuality(['128k', '320k', 'flac'], 'flac'), 'flac');
    });

    test('脚本不支持无损时降到 320k', () {
      expect(pickLxQuality(['128k', '320k'], 'flac'), '320k');
    });

    test('标准音质优先 128k', () {
      expect(pickLxQuality(['320k', '128k'], '128'), '128k');
    });

    test('脚本没声明音质时按 App 档位兜底', () {
      expect(pickLxQuality(const [], '320'), '320k');
    });
  });

  group('音源声明', () {
    test('local 类型不可用于取播放地址', () {
      const decl = LxSourceDecl(
        key: 'local',
        name: 'local',
        type: 'local',
        actions: ['musicUrl', 'lyric'],
      );
      expect(decl.canResolveUrl, isFalse);
      expect(decl.displayLabel, '本地');
    });

    test('普通平台可解析且带中文名', () {
      const decl = LxSourceDecl(key: 'kg', name: 'kg', qualitys: ['128k']);
      expect(decl.canResolveUrl, isTrue);
      expect(decl.displayLabel, '酷狗');
    });

    test('汽水音乐等小众平台也能显示中文名', () {
      const decl = LxSourceDecl(
        key: 'qs',
        name: 'qs',
        qualitys: ['128k', '320k', 'flac', 'spatial', 'hires'],
      );
      expect(decl.displayLabel, '汽水音乐');
      expect(decl.canResolveUrl, isTrue);
      expect(decl.qualitys, contains('spatial'));
    });

    test('空间音频档位能被识别', () {
      expect(
        ThirdPartyQuality.fromLxValue('spatial'),
        ThirdPartyQuality.spatial,
      );
      expect(ThirdPartyQuality.spatial.label, '空间音频');
    });

    test('JSON 往返保持字段', () {
      const decl = LxSourceDecl(
        key: 'wy',
        name: 'wy',
        actions: ['musicUrl'],
        qualitys: ['320k', 'flac'],
      );
      final restored = LxSourceDecl.fromJson('wy', decl.toJson());
      expect(restored.key, 'wy');
      expect(restored.qualitys, ['320k', 'flac']);
      expect(restored.canResolveUrl, isTrue);
    });
  });

  group('脚本持久化', () {
    test('toJson/fromJson 往返', () {
      final script = CustomSourceScript(
        id: '1',
        name: '示例音源',
        code: 'var a = 1;',
        version: 'v1',
        enabled: false,
        order: 3,
        importedAt: DateTime(2026, 1, 2, 3, 4, 5),
        originUrl: 'https://example.com/a.js',
        sources: const {
          'kg': LxSourceDecl(key: 'kg', name: 'kg', qualitys: ['128k']),
        },
      );
      final restored = CustomSourceScript.fromJson(script.toJson());
      expect(restored.name, '示例音源');
      expect(restored.enabled, isFalse);
      expect(restored.order, 3);
      expect(restored.originUrl, 'https://example.com/a.js');
      expect(restored.supportsKey('kg'), isTrue);
      expect(restored.supportsKey('wy'), isFalse);
      expect(restored.sourceLabels, ['酷狗']);
    });
  });

  group('链接规范化', () {
    test('GitHub blob 转 raw', () {
      expect(
        CustomSourceManager.normalizeScriptUrl(
          'https://github.com/user/repo/blob/main/src/a.js',
        ),
        'https://raw.githubusercontent.com/user/repo/main/src/a.js',
      );
    });

    test('Gitee blob 转 raw', () {
      expect(
        CustomSourceManager.normalizeScriptUrl(
          'https://gitee.com/user/repo/blob/master/a.js',
        ),
        'https://gitee.com/user/repo/raw/master/a.js',
      );
    });

    test('GitLab blob 转 raw', () {
      expect(
        CustomSourceManager.normalizeScriptUrl(
          'https://gitlab.com/group/repo/-/blob/main/a.js',
        ),
        'https://gitlab.com/group/repo/-/raw/main/a.js',
      );
    });

    test('本来就是 raw 链接时保持不变', () {
      const raw = 'https://raw.githubusercontent.com/u/r/main/a.js';
      expect(CustomSourceManager.normalizeScriptUrl(raw), raw);
    });
  });

  group('歌曲映射', () {
    final kugouSong = Song(
      id: '10086',
      title: '测试歌曲',
      artist: '测试歌手',
      hash: 'HASH123',
      albumName: '专辑A',
      albumId: '9',
      duration: const Duration(minutes: 3, seconds: 5),
    );

    test('酷狗歌曲映射到 kg 平台', () {
      expect(CustomSourceManager.platformKeyOf(kugouSong), 'kg');
      final info = CustomSourceManager.buildMusicInfo(kugouSong, 'kg');
      expect(info['hash'], 'HASH123');
      expect(info['songmid'], 'HASH123');
      expect(info['name'], '测试歌曲');
      expect(info['singer'], '测试歌手');
      expect(info['albumName'], '专辑A');
      expect(info['interval'], '03:05');
      expect(info['source'], 'kg');
    });

    test('网易云歌曲用 id 当 songmid', () {
      final neteaseSong = Song(
        id: '25706282',
        title: '网易云歌曲',
        artist: '歌手',
        hash: '',
        source: SongSource.netease,
      );
      expect(CustomSourceManager.platformKeyOf(neteaseSong), 'wy');
      final info = CustomSourceManager.buildMusicInfo(neteaseSong, 'wy');
      expect(info['songmid'], '25706282');
      expect(info['id'], '25706282');
    });

    test('本地歌曲没有平台键', () {
      final local = Song(
        id: '/tmp/a.mp3',
        title: '本地',
        artist: '未知',
        hash: '',
        source: SongSource.local,
      );
      expect(CustomSourceManager.platformKeyOf(local), isNull);
    });
  });
}
