import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/custom_source/lx_runtime.dart';

/// JS 引擎是否可用。
///
/// flutter_js 在 Windows 上运行时才去 `DynamicLibrary.open('quickjs_c_bridge.dll')`，
/// 这个 DLL 在 `flutter build windows` 之后才会被拷到可执行文件旁边，
/// 因此纯 `flutter test` 环境里通常打不开——此时整组用例跳过，不影响 CI。
bool get _engineAvailable {
  if (!Platform.isWindows) {
    return Platform.environment['LKG_FORCE_JS_TEST'] == '1';
  }
  try {
    DynamicLibrary.open('quickjs_c_bridge.dll');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group(
    'JS 引擎端到端',
    () {
      late LxRuntime runtime;

      setUp(() {
        runtime = LxRuntime(debugTag: 'smoke');
      });

      tearDown(() {
        runtime.dispose();
      });

      test('加载脚本后能读到 inited 上报的音源声明', () async {
        final code = File('test/fixtures/lx_smoke.js').readAsStringSync();
        final result = await runtime.load(code);

        expect(result.sources.keys, contains('kg'));
        expect(result.sources['kg']!.qualitys, ['128k', '320k']);
        expect(result.sources['kg']!.canResolveUrl, isTrue);
      });

      test('musicUrl 请求能穿透到脚本并通过 lx.request 回调返回', () async {
        final code = File('test/fixtures/lx_smoke.js').readAsStringSync();
        await runtime.load(code);

        final url = await runtime.fetchMusicUrl(
          source: 'kg',
          quality: '320k',
          musicInfo: const {
            'hash': 'ABC123',
            'songmid': 'ABC123',
            'name': '测试',
            'singer': '歌手',
          },
        );

        expect(url, 'https://example.com/ABC123.mp3');
      });

      test('脚本没实现的 action 会被吞掉并返回 null（不影响播放）', () async {
        final code = File('test/fixtures/lx_smoke.js').readAsStringSync();
        await runtime.load(code);

        // 脚本对 lyric 直接 Promise.reject，fetchLyric 内部兜住并返回 null
        final lyric = await runtime.fetchLyric(
          source: 'kg',
          musicInfo: const {'hash': 'ABC123'},
        );
        expect(lyric, isNull);
        // 引擎仍然可用，后续请求不受影响
        expect(
          await runtime.fetchMusicUrl(
            source: 'kg',
            quality: '128k',
            musicInfo: const {'hash': 'ABC123'},
          ),
          'https://example.com/ABC123.mp3',
        );
      });
    },
    skip: _engineAvailable ? false : '当前环境没有 quickjs_c_bridge.dll，跳过引擎级用例',
  );
}
