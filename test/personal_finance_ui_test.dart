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
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
