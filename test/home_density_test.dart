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
  testWidgets('首页保留指标方块，分类预算行编辑本期额度、入口打开详情', (tester) async {
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

    // 再加一个有预算的分类，用来验证行主体打开的是该行自己的分类，而不是首项。
    controller.setDefaultCategoryBudget('transport', 800);
    await tester.pumpAndSettle();

    await tester.drag(firstVerticalScrollable(), const Offset(0, -240));
    await tester.pumpAndSettle();

    // 分类行主体直接编辑该分类在当前预算键月的额度：标题写明分类与口径。
    Future<void> openRowBudget(String label) async {
      final row = find.descendant(of: budget, matching: find.text(label));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    Future<void> cancelNumberPad() async {
      Navigator.of(
        tester.element(find.byKey(const Key('number_pad_display'))),
      ).pop();
      await tester.pumpAndSettle();
    }

    // 餐饮行：打开的是餐饮自己的本期额度，写入当前预算键月的单期覆盖。
    final keyMonth = controller.budgetKeyMonthFor(DateTime.now());
    await openRowBudget('餐饮');
    expect(find.text('设置餐饮本月预算'), findsOneWidget);
    expect(find.byType(BudgetOverviewPage), findsNothing);
    await tester.tap(find.byKey(const Key('number_key_C')));
    for (final key in <String>['9', '00']) {
      await tester.tap(find.byKey(Key('number_key_$key')));
    }
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    expect(controller.categoryBudget(keyMonth, 'dining'), 900);
    expect(controller.categoryBudgetIsOverride(keyMonth, 'dining'), isTrue);
    // 只改这一行：默认预算与其它分类的本期预算都不动。
    expect(controller.defaultCategoryBudget('dining'), 5000);
    expect(controller.categoryBudget(keyMonth, 'transport'), 800);
    expect(controller.categoryBudgetIsOverride(keyMonth, 'transport'), isFalse);

    // 交通行：标题切换到该行自己的分类，取消不写入。
    await openRowBudget('交通');
    expect(find.text('设置交通本月预算'), findsOneWidget);
    expect(find.byType(BudgetOverviewPage), findsNothing);
    await cancelNumberPad();
    expect(controller.categoryBudget(keyMonth, 'transport'), 800);
    expect(controller.categoryBudgetIsOverride(keyMonth, 'transport'), isFalse);
    expect(controller.categoryBudget(keyMonth, 'dining'), 900);
    expect(find.byType(BudgetOverviewPage), findsNothing);

    // 标题入口仍进预算总览。
    await tester.tap(find.descendant(of: budget, matching: find.text('分类预算')));
    await tester.pumpAndSettle();
    expect(find.byType(HomeTrendPanel), findsNothing);
    expect(find.byType(BudgetOverviewPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(BudgetOverviewPage))).pop();
    await tester.pumpAndSettle();

    // 月份入口同样进预算总览（卡片标题行唯一的 TextButton）。
    final monthEntry = find.descendant(
      of: budget,
      matching: find.byType(TextButton),
    );
    expect(monthEntry, findsOneWidget);
    await tester.tap(monthEntry);
    await tester.pumpAndSettle();
    expect(find.byType(BudgetOverviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
