import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/custom_source/custom_source_manager.dart';
import 'package:kgka_music_hl/ui/pages/custom_source_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('管理页在没有任何音源时显示空状态', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomSourcePage()));
    await tester.pumpAndSettle();

    expect(find.text('第三方音源'), findsOneWidget);
    expect(find.text('还没有导入音源'), findsOneWidget);
    expect(find.text('从链接导入'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('粘贴脚本'), findsOneWidget);
  });

  testWidgets('四个策略都能切换', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomSourcePage()));
    await tester.pumpAndSettle();

    final manager = CustomSourceManager.instance;
    for (final mode in CustomSourceMode.values) {
      await tester.tap(find.text(mode.label));
      await tester.pumpAndSettle();
      expect(manager.mode, mode, reason: '点击「${mode.label}」后策略应生效');
    }
    // 复位，避免影响其他用例
    await manager.setMode(CustomSourceMode.auto);
  });

  testWidgets('导入对话框可以打开并取消', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomSourcePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('从链接导入'));
    await tester.pumpAndSettle();
    expect(find.text('从链接导入'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
