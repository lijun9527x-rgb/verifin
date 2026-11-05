import 'package:verifin/pages/home_category_budget_panel.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/home_page.dart';
import 'package:verifin/pages/budget_pages.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  testWidgets('概览胶囊靠右对齐，不紧挨主金额', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const Key('home_primary_metrics')));
    final pill = tester.getRect(find.byKey(const Key('home_summary_pill')));
    expect(pill.right, closeTo(row.right, 0.5));
    expect(tester.takeException(), isNull);
  });
  testWidgets('首页保留指标方块，分类预算展示进度并可打开详情', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    final controller = await makeController();
    await controller.importTransactionsFromCsv(
      File('docs/fixtures/preview-transactions.csv').readAsStringSync(),
    );
    controller.setDefaultCategoryBudget('dining', 5000);
    controller.setThemePreference(ThemePreference.light);
    await controller.waitForPendingWrites();
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final overview = tester.getRect(find.byType(HomeTrendPanel));
    expect(overview.height, lessThanOrEqualTo(280));
    for (var i = 1; i <= 3; i++) {
      expect(find.byKey(Key('home_metric_$i')), findsOneWidget);
    }
    final transactions = find.byType(TransactionTile);
    expect(transactions, findsNWidgets(5));
    final navTop = tester.getRect(find.byKey(const Key('main_bottom_nav'))).top;
    expect(tester.getRect(transactions.last).bottom, lessThan(navTop));
    final budget = find.byType(HomeCategoryBudgetPanel);
    expect(
      find.descendant(of: budget, matching: find.text('餐饮')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: budget,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsOneWidget,
    );
    await tester.drag(firstVerticalScrollable(), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(budget);
    await tester.pumpAndSettle();
    expect(find.byType(HomeTrendPanel), findsNothing);
    expect(find.byType(BudgetOverviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
