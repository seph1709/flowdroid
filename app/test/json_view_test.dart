import 'package:flowdroid/ui/theme.dart';
import 'package:flowdroid/ui/widgets/json_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  final items = [
    {
      'id': 7,
      'user': {'name': 'Ada', 'tags': ['a', 'b']},
    },
  ];

  Finder row(String text) => find.textContaining(text, findRichText: true);

  testWidgets('tree folds and unfolds, and picks a field as an expression', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(app(JsonView(items, items: true, onPick: (path, _) => picked.add(itemExpression(path)))));
    // Two levels inside each item are open; deeper branches are closed.
    expect(row('name  Ada'), findsOneWidget);
    expect(row('0  a'), findsNothing);

    await tester.tap(row('user  {2}'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(row('name  Ada'), findsNothing);
    await tester.tap(row('user  {2}'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(row('name  Ada'));
    expect(picked, [r'$json.user.name']);

    await tester.tap(find.byTooltip('Unfold all'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(row('1  b'), findsOneWidget);
  });

  testWidgets('switches to colored JSON text and opens the viewer with a table', (tester) async {
    await tester.pumpWidget(app(JsonView(items, items: true, title: 'Fetch')));
    await tester.tap(find.text('JSON'));
    await tester.pump();
    expect(find.textContaining('"user"', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Open viewer'));
    await tester.pumpAndSettle();
    expect(find.text('Fetch'), findsOneWidget);
    expect(find.text('Table'), findsOneWidget);
    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    expect(find.text('id'), findsOneWidget);
  });
}
