import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/assets_pages.dart';

import 'support/test_harness.dart';

Account namedAsset(String name) => Account(
  id: 'asset',
  bookId: 'default',
  name: name,
  type: AccountType.debitCard,
  groupId: 'bank',
  initialBalance: 0,
  iconCode: 'wallet',
  note: '',
  includeInAssets: true,
  hidden: false,
);

void main() {
  useTestDatabases();
  final l10n = lookupAppLocalizations(const Locale('zh'));

  test('默认名称包括银行卡、资产类别与外币代码，本位币不重复显示', () {
    expect(
      defaultAssetName(
        l10n: l10n,
        assetClass: AssetClass.demandDeposit,
        currencyCode: 'CNY',
        baseCurrencyCode: 'CNY',
        containerName: '招行1234',
      ),
      '招行1234·活期存款',
    );
    expect(
      defaultAssetName(
        l10n: l10n,
        assetClass: AssetClass.foreignFixedDeposit,
        currencyCode: 'USD',
        baseCurrencyCode: 'CNY',
        containerName: '工行5678',
      ),
      '工行5678·外币定期·USD',
    );
    expect(
      defaultAssetName(
        l10n: l10n,
        assetClass: AssetClass.moneyMarketFund,
        currencyCode: 'CNY',
        baseCurrencyCode: 'CNY',
      ),
      '货币基金',
    );
  });

  test('同类资产自动加序号，银行卡内省略前缀，自定义名称保持原样', () {
    final name = defaultAssetName(
      l10n: l10n,
      assetClass: AssetClass.fixedDeposit,
      currencyCode: 'CNY',
      baseCurrencyCode: 'CNY',
      containerName: '招行',
      existingNames: ['招行·定期存款', '招行·定期存款 (2)'],
    );
    expect(name, '招行·定期存款 (3)');
    expect(assetNameInContainer(namedAsset(name), '招行'), '定期存款 (3)');
    expect(assetNameInContainer(namedAsset('三年定期'), '招行'), '三年定期');
    expect(assetNameInContainer(namedAsset('其他银行·定期存款'), '招行'), '其他银行·定期存款');
  });

  testWidgets('不填名称即可添加资产，保存后容器内显示类别短名称', (tester) async {
    final controller = await makeController();
    await controller.addAccountGroup('招行1234');
    final groupId = controller.accountGroups.last.id;
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: AddAccountPage(initialGroupId: groupId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add_account_custom_name')), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('资产类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('活期存款').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_account_balance')));
    await tester.pumpAndSettle();
    for (final key in ['1', '0', '0', '0']) {
      await tester.tap(find.byKey(Key('number_key_$key')));
    }
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.accounts.single.name, '招行1234·活期存款');
    expect(controller.accounts.single.initialBalance, 1000);
    expect(controller.accounts.single.groupId, groupId);
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: AccountGroupDetailPage(groupId: groupId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('活期存款', findRichText: true), findsOneWidget);
    expect(find.text('招行1234·活期存款', findRichText: true), findsNothing);
    expect(controller.accounts.single.name, '招行1234·活期存款');
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多设置可自定义名称，保存时保留用户输入', (tester) async {
    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AddAccountPage()),
      ),
    );
    await tester.pumpAndSettle();
    await setNewAssetName(tester, '三年定期');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.accounts.single.name, '三年定期');
    expect(tester.takeException(), isNull);
  });

  testWidgets('明确输入零余额也能保存自动命名资产', (tester) async {
    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AddAccountPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_account_balance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_key_0')));
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.accounts.single.name, '其他资产');
    expect(controller.accounts.single.initialBalance, 0);
  });
}
