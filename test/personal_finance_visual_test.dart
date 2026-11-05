import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/asset_monthly_page.dart';
import 'package:verifin/pages/budget_pages.dart';
import 'package:verifin/pages/home_category_budget_panel.dart';

import 'support/test_harness.dart';

const _qaDirectory = String.fromEnvironment('VISUAL_QA_DIR');
const _qaFont = String.fromEnvironment('VISUAL_QA_FONT');
const _qaIcons = String.fromEnvironment('VISUAL_QA_ICONS');

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_qaDirectory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(_qaDirectory).create(recursive: true);
    await File(
      '$_qaDirectory/$name.png',
    ).writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  useTestDatabases();
  setUpAll(() async {
    if (_qaFont.isEmpty) return;
    final loader = FontLoader('VisualQA')
      ..addFont(
        Future.value(ByteData.sublistView(await File(_qaFont).readAsBytes())),
      );
    await loader.load();
    if (_qaIcons.isNotEmpty) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(_qaIcons).readAsBytes()),
          ),
        );
      await icons.load();
    }
  });

  for (final width in [360.0, 393.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('个人财务页面 $width $brightness $language 无溢出', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 852);
          addTearDown(tester.view.reset);
          final controller = await makeController();
          await controller.addAccountGroup('招行卡');
          await controller.addAccountGroup('中行卡');
          final bank = controller.accountGroups
              .firstWhere((g) => g.name == '招行卡')
              .id;
          final foreignBank = controller.accountGroups
              .firstWhere((g) => g.name == '中行卡')
              .id;
          final data = [
            ('cash', '招行日常活期', AssetClass.demandDeposit, 12000.0, 'CNY'),
            ('fixed', '招行一年定期', AssetClass.fixedDeposit, 50000.0, 'CNY'),
            ('bond', '招行债券基金', AssetClass.bondFund, 30380.0, 'CNY'),
            ('usd', '中行美元活期', AssetClass.foreignDemandDeposit, 1000.0, 'USD'),
          ];
          for (final item in data) {
            await controller.addAccountDraft(
              Account(
                id: item.$1,
                bookId: 'default',
                name: item.$2,
                type: AccountType.debitCard,
                assetClass: item.$3,
                initialBalance: item.$4,
                currencyCode: item.$5,
                groupId: item.$5 == 'USD' ? foreignBank : bank,
                iconCode: 'wallet',
                note: '',
                includeInAssets: true,
                hidden: false,
              ),
            );
          }
          controller.setDefaultAccountId('cash');
          final now = DateTime.now();
          for (var offset = -2; offset <= 0; offset++) {
            await controller.saveAssetSnapshot(
              controller.buildAssetSnapshot(
                DateTime(now.year, now.month + offset),
                balances: {'cash': 12000 + offset * 500.0},
                baseBalances: {'usd': 7120 + offset * 20.0},
              ),
            );
          }
          var theme = buildVeriFinTheme(brightness);
          if (_qaFont.isNotEmpty) {
            theme = theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'VisualQA'),
            );
          }
          final captureKey = GlobalKey();
          Widget app(Widget child) => VeriFinScope(
            controller: controller,
            child: zhMaterialApp(
              theme: theme,
              home: Builder(
                builder: (context) => Localizations.override(
                  context: context,
                  locale: Locale(language),
                  child: RepaintBoundary(key: captureKey, child: child),
                ),
              ),
            ),
          );
          await tester.pumpWidget(app(const AssetMonthlyPage()));
          await tester.pumpAndSettle();
          if (width == 393 &&
              brightness == Brightness.light &&
              language == 'zh') {
            await _capture(tester, captureKey, 'monthly-assets-widget');
          }
          final l10n = AppLocalizations.of(
            tester.element(find.byType(AssetMonthlyPage)),
          );
          await tester.tap(find.text(l10n.assetViewBank));
          await tester.pumpAndSettle();
          expect(find.text('招行卡'), findsOneWidget);
          await tester.tap(find.text(l10n.assetViewAccount));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Switch));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          controller.setDefaultCategoryBudget('dining', 1800);
          controller.setDefaultCategoryBudget('transport', 500);
          await tester.pumpWidget(
            app(
              Scaffold(
                body: ListView(
                  children: [
                    HomeCategoryBudgetPanel(
                      month: now,
                      snapshots: computeCategoryBudgetSnapshots(
                        controller: controller,
                        month: now,
                        monthEntries: [],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (width == 393 &&
              brightness == Brightness.light &&
              language == 'zh') {
            await _capture(tester, captureKey, 'category-budgets-widget');
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
