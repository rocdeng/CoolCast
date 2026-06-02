import 'package:flutter_test/flutter_test.dart';

import 'package:coolcast/main.dart';

void main() {
  testWidgets('shows receiver home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const CoolCastApp());

    expect(find.text('网络连接'), findsOneWidget);
    expect(find.text('设备名称'), findsOneWidget);
    expect(find.text('正在等待投屏请求'), findsOneWidget);
    expect(find.text('DLNA / UPnP'), findsOneWidget);
  });
}
