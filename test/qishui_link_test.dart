import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/custom_source/qishui_link.dart';

void main() {
  group('汽水链接解析', () {
    test('纯 ID 直接当 trackId', () async {
      final ref = await QishuiLinkParser.parse('7123456789012345678');
      expect(ref?.id, '7123456789012345678');
    });

    test('链接里带 track_id 参数', () async {
      final ref = await QishuiLinkParser.parse(
        'https://music.douyin.com/qishui/share/track?track_id=7123456789012345678',
      );
      expect(ref?.id, '7123456789012345678');
    });

    test('整段分享文案里提取链接', () async {
      final ref = await QishuiLinkParser.parse(
        '分享单曲「晴天」 https://music.douyin.com/qishui/share/track?trackId=abc123def456 来自汽水音乐',
      );
      expect(ref?.id, 'abc123def456');
    });

    test('路径末段的长数字当 ID', () async {
      final ref = await QishuiLinkParser.parse(
        'https://music.douyin.com/share/track/7123456789012345678',
      );
      expect(ref?.id, '7123456789012345678');
    });

    test('空内容返回 null', () async {
      expect(await QishuiLinkParser.parse('   '), isNull);
    });

    test('无关文本返回 null', () async {
      expect(await QishuiLinkParser.parse('这是一段普通文字'), isNull);
    });
  });
}
