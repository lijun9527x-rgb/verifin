import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/asset_monthly_page.dart';
import 'package:verifin/pages/home_category_budget_panel.dart';
import 'package:verifin/pages/budget_pages.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('外币资产直接填写人民币估值，无需汇率', (tester) async {
    final controller = await makeController();
    await controller.addAccountDraft(
      const Account(
        id: 'usd',
        bookId: 'default',
        name: '美元活期',
        type: AccountType.debitCard,
        assetClass: AssetClass.foreignDemandDeposit,
        groupId: null,
        initialBalance: 1000,
        currencyCode: 'USD',
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );
    final now = DateTime.now();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: AssetSnapshotEditorPage(month: DateTime(now.year, now.month)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.currency_exchange), findsNothing);
    await tester.tap(find.text('对应人民币金额'));
    await tester.pumpAndSettle();
    for (final digit in ['7', '3', '1', '2', '.', '3', '4']) {
      await tester.tap(find.byKey(Key('number_key_$digit')));
    }
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    final holding = controller.assetSnapshots.single.holdings.single;
    expect(holding.balance, 1000);
    expect(holding.baseBalance, 7312.34);
    expect(holding.rateToBase, isNull);
  });

  testWidgets('首页保留零支出预算分类，点击进入预算管理', (tester) async {
    final controller = await makeController();
    final category = controller
        .categoriesForType(EntryType.expense)
        .firstWhere((c) => !c.isBalanceAdjust);
    controller.setDefaultCategoryBudget(category.id, 800);
    final now = DateTime.now();
    final snapshots = computeCategoryBudgetSnapshots(
      controller: controller,
      month: now,
      monthEntries: [],
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Scaffold(
            body: HomeCategoryBudgetPanel(month: now, snapshots: snapshots),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(category.label), findsOneWidget);
    expect(find.textContaining('800'), findsWidgets);
    expect(find.textContaining('支出 0'), findsOneWidget);
    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
    expect(find.byType(BudgetOverviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月度资产在窄屏切换维度、核对并保存快照', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    final controller = await makeController();
    await controller.addAccountDraft(
      const Account(
        id: 'bank',
        bookId: 'default',
        name: '测试日常活期',
        type: AccountType.debitCard,
        assetClass: AssetClass.demandDeposit,
        groupId: null,
        initialBalance: 1000,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AssetMonthlyPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('活期存款'), findsOneWidget);
    await tester.tap(find.text('账户明细'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试日常活期'), findsOneWidget);
    await tester.tap(find.byKey(const Key('asset_snapshot_edit')));
    await tester.pumpAndSettle();
    expect(find.byType(AssetSnapshotEditorPage), findsOneWidget);
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.assetSnapshots, hasLength(1));
    expect(controller.assetSnapshots.single.totalInBase, 1000);
    expect(find.byType(AssetSnapshotEditorPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
