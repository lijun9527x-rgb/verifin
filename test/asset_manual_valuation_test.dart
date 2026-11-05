import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/asset_snapshot_math.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

Account _usd({double balance = 1000, double? valuation}) => Account(
  id: 'usd',
  bookId: 'default',
  name: '美元活期',
  type: AccountType.debitCard,
  assetClass: AssetClass.foreignDemandDeposit,
  groupId: null,
  initialBalance: balance,
  currencyCode: 'USD',
  iconCode: 'wallet',
  note: '',
  includeInAssets: true,
  hidden: false,
  baseValuation: valuation,
);

void main() {
  useTestDatabases();

  test('手填人民币金额直接用于资产汇总，无需汇率', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 7100));

    final valuation = controller.accountBalancesInBase();
    expect(valuation.isComplete, isTrue);
    expect(valuation.amountsByAccountId['usd'], 7100);
    expect(valuation.missingCurrencyCodes, isEmpty);
    expect(valuation.staleAccountIds, isEmpty);
    // 手填金额只影响汇总口径，不改写原币余额，也不产生流水。
    expect(controller.accountBalance(controller.accounts.single), 1000);
    expect(controller.entries, isEmpty);
  });

  test('未填人民币金额时不使用已有汇率补算', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd());

    var valuation = controller.accountBalancesInBase(
      date: DateTime(2026, 1, 2),
    );
    expect(valuation.isComplete, isFalse);
    expect(valuation.missingCurrencyCodes, <String>{'USD'});

    expect(
      await controller.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: DateTime(2026, 1, 1),
        rateToBase: 7,
      ),
      isTrue,
    );
    valuation = controller.accountBalancesInBase(date: DateTime(2026, 1, 2));
    expect(valuation.isComplete, isFalse);
    expect(valuation.amountsByAccountId.containsKey('usd'), isFalse);
  });

  test('手填金额不参与汇率过期判断，也不会被旧汇率覆盖', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 7100));
    await controller.saveExchangeRateDraft(
      currencyCode: 'USD',
      effectiveDate: DateTime(2020),
      rateToBase: 7,
    );

    final valuation = controller.accountBalancesInBase();
    expect(valuation.staleAccountIds, isEmpty);
    expect(valuation.amountsByAccountId['usd'], 7100);
  });

  test('清除手填金额后等待重新填写，不回退汇率', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 7100));
    expect(
      await controller.saveAccountDraft(
        controller.accounts.single.copyWith(clearBaseValuation: true),
      ),
      isTrue,
    );
    await controller.saveExchangeRateDraft(
      currencyCode: 'USD',
      effectiveDate: DateTime(2026, 1, 1),
      rateToBase: 7,
    );

    expect(
      controller
          .accountBalancesInBase(date: DateTime(2026, 1, 2))
          .amountsByAccountId['usd'],
      isNull,
    );
  });

  test('手填金额随重启读取与备份往返保留', () async {
    final store = LocalKeyValueStore();
    final source = await makeController(store);
    await source.addAccountDraft(_usd(valuation: 7100));

    final reloaded = await makeController(store);
    expect(reloaded.accounts.single.baseValuation, 7100);

    final target = await makeController();
    await target.importDataJson(reloaded.exportDataJson());
    expect(target.accounts.single.baseValuation, 7100);
    expect(target.accountBalancesInBase().amountsByAccountId['usd'], 7100);
  });

  test('月度核对填写的当月金额不改写当前手填金额', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 7100));
    final month = DateTime(2026, 1);
    await controller.saveAssetSnapshot(
      controller.buildAssetSnapshot(month, baseBalances: {'usd': 6800}),
    );

    expect(controller.assetSnapshotFor(month)!.totalInBase, 6800);
    expect(controller.accounts.single.baseValuation, 7100);
    expect(controller.accountBalancesInBase().amountsByAccountId['usd'], 7100);
  });

  test('只填人民币金额、原币余额为0时仍计入资产', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(balance: 0, valuation: 7100));
    expect(controller.accountBalancesInBase().completeTotal, 7100);
    expect(controller.accountBalance(controller.accounts.single), 0);
    expect(controller.entries, isEmpty);
  });

  test('人民币金额可显式填写0，不改用汇率计算', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 0));
    expect(controller.accountBalancesInBase().completeTotal, 0);
    expect(controller.accounts.single.baseValuation, 0);
  });

  test('历史曲线取月度记录，缺失和未来留空，当前金额不回填历史', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_usd(valuation: 7100));
    final march = controller.buildAssetSnapshot(
      DateTime(2026, 3),
      baseBalances: {'usd': 6800},
    );
    final otherBook = AssetMonthSnapshot(
      bookId: 'other',
      month: DateTime(2026, 2),
      recordedAt: DateTime(2026, 2),
      baseCurrencyCode: 'CNY',
      holdings: march.holdings,
    );
    final series = assetMonthlyAmountSeries(
      snapshots: [march, otherBook],
      bookId: 'default',
      baseCurrencyCode: 'CNY',
      now: DateTime(2026, 6),
      currentTotal: 7100,
    );
    expect(series[1], isNull);
    expect(series[2], 6800);
    expect(series[4], isNull);
    expect(series[5], 7100);
    expect(series[6], isNull);
  });
}
