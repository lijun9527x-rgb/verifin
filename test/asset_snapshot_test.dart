import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/asset_snapshot_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';
import 'support/in_memory_ledger_repository.dart';

class _FailingSnapshotRepository extends InMemoryLedgerRepository {
  bool fail = false;
  @override
  Future<void> saveAssetSnapshots(List<AssetMonthSnapshot> snapshots) {
    if (fail) {
      return Future.error(StateError('simulated snapshot write failure'));
    }
    return super.saveAssetSnapshots(snapshots);
  }
}

Account _account(String id, {String currency = 'CNY', double balance = 1000}) =>
    Account(
      id: id,
      bookId: 'default',
      name: id,
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: balance,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: currency,
      assetClass: AssetClass.demandDeposit,
    );

void main() {
  useTestDatabases();

  test('银行卡改名按稳定分组标识对照，不伪装成资金转出转入', () {
    AssetMonthSnapshot snapshot(int month, String bankName, double balance) =>
        AssetMonthSnapshot(
          bookId: 'default',
          month: DateTime(2026, month),
          recordedAt: DateTime(2026, month, 28),
          baseCurrencyCode: 'CNY',
          holdings: [
            AssetHoldingSnapshot(
              accountId: 'bank',
              name: '活期',
              bankId: 'stable-bank',
              bankName: bankName,
              assetClass: AssetClass.demandDeposit,
              currencyCode: 'CNY',
              balance: balance,
              rateToBase: 1,
              baseBalance: balance,
            ),
          ],
        );
    final rows = assetComparisonRows(
      [snapshot(1, '银行卡', 100), snapshot(2, '工资卡', 120)],
      grouping: AssetComparisonGrouping.bank,
      baseCurrencyCode: 'CNY',
    );
    expect(rows, hasLength(1));
    expect(rows.single.values, [100, 120]);
    expect(rows.single.change, 20);
    expect(rows.single.holding.bankName, '工资卡');
  });

  test('快照写入失败保留旧内存与旧磁盘，并反馈失败', () async {
    final repo = _FailingSnapshotRepository();
    final controller = await createTestController(
      LocalKeyValueStore(),
      repository: repo,
    );
    var errors = 0;
    controller.onPersistError = (_) => errors++;
    final month = DateTime(2026, 1);
    final initial = controller.buildAssetSnapshot(month);
    expect(await controller.saveAssetSnapshot(initial), isTrue);
    repo.fail = true;
    expect(
      await controller.saveAssetSnapshot(
        controller.buildAssetSnapshot(DateTime(2026, 2)),
      ),
      isFalse,
    );
    expect(errors, 1);
    expect(controller.assetSnapshots, hasLength(1));
    expect(await repo.loadAssetSnapshots(), hasLength(1));
  });

  test('并发保存不同月份串行执行，不丢失另一个月份', () async {
    final controller = await makeController();
    final results = await Future.wait([
      controller.saveAssetSnapshot(
        controller.buildAssetSnapshot(DateTime(2026, 1)),
      ),
      controller.saveAssetSnapshot(
        controller.buildAssetSnapshot(DateTime(2026, 2)),
      ),
    ]);
    expect(results, [true, true]);
    expect(controller.assetSnapshots, hasLength(2));
  });

  test('篡改快照折算金额的备份在修改现有数据前被拒绝', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('bank'));
    final month = DateTime(2026, 1);
    await controller.saveAssetSnapshot(controller.buildAssetSnapshot(month));
    final backup = jsonDecode(controller.exportDataJson()) as Map;
    final data = backup['data'] as Map;
    final snapshots = data['assetSnapshots'] as List;
    final holdings = (snapshots.single as Map)['holdings'] as List;
    (holdings.single as Map)['baseBalance'] = 99;
    await expectLater(
      controller.importDataJson(jsonEncode(backup)),
      throwsFormatException,
    );
    expect(controller.assetSnapshotFor(month)!.totalInBase, 1000);
  });

  test('快照冻结原币余额、手填人民币估值与类别，重启和备份恢复不漂移', () async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final account = _account('usd', currency: 'USD');
    await controller.addAccountDraft(account);
    final month = DateTime(2026, 1);
    final snapshot = controller.buildAssetSnapshot(
      month,
      baseBalances: {'usd': 7100},
    );
    expect(snapshot.totalInBase, 7100);
    expect(await controller.saveAssetSnapshot(snapshot), isTrue);
    await controller.saveAccountDraft(
      account.copyWith(name: 'renamed', assetClass: AssetClass.equityFund),
    );
    final reloaded = await makeController(store);
    expect(reloaded.assetSnapshotFor(month)!.holdings.single.name, 'usd');
    expect(
      reloaded.assetSnapshotFor(month)!.holdings.single.assetClass,
      AssetClass.demandDeposit,
    );
    expect(reloaded.assetSnapshotFor(month)!.totalInBase, 7100);
    final target = await makeController();
    await target.importDataJson(reloaded.exportDataJson());
    expect(target.assetSnapshotFor(month)!.toJson(), snapshot.toJson());
  });

  test('核对余额只改快照，不产生收支；编辑单月不改历史', () async {
    final controller = await makeController();
    final account = _account('bank');
    await controller.addAccountDraft(account);
    await controller.saveAssetSnapshot(
      controller.buildAssetSnapshot(DateTime(2026, 1)),
    );
    final feb = controller.buildAssetSnapshot(
      DateTime(2026, 2),
      balances: {'bank': 1200},
    );
    expect(await controller.saveAssetSnapshot(feb), isTrue);
    expect(controller.assetSnapshotFor(DateTime(2026, 1))!.totalInBase, 1000);
    expect(controller.assetSnapshotFor(DateTime(2026, 2))!.totalInBase, 1200);
    expect(controller.accountBalance(account), 1000);
    expect(controller.entries, isEmpty);
  });

  test('未填人民币估值不显示不完整总额，零余额可为零', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('usd', currency: 'USD'));
    final missing = controller.buildAssetSnapshot(DateTime(2026, 1));
    expect(missing.totalInBase, isNull);
    final zero = controller.buildAssetSnapshot(
      DateTime(2026, 1),
      balances: {'usd': 0},
    );
    expect(zero.totalInBase, 0);
    final rows = assetComparisonRows(
      [null, missing, zero],
      grouping: AssetComparisonGrouping.category,
      baseCurrencyCode: 'CNY',
    );
    expect(rows.single.values, [null, null, 0]);
    expect(rows.single.change, isNull);
  });

  test('快照按账本隔离，账户删除保留历史，删除账本与重置清理快照', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('bank'));
    final month = DateTime(2026, 1);
    await controller.saveAssetSnapshot(controller.buildAssetSnapshot(month));
    await controller.deleteAccount('bank');
    expect(controller.assetSnapshotFor(month)!.holdings.single.name, 'bank');
    controller.addLedgerBook('other');
    final book = controller.activeBook;
    expect(controller.assetSnapshots, isEmpty);
    await controller.saveAssetSnapshot(controller.buildAssetSnapshot(month));
    await controller.deleteLedgerBook(book.id);
    expect(controller.assetSnapshots, hasLength(1));
    final payload = jsonDecode(controller.exportDataJson()) as Map;
    expect((payload['data'] as Map)['assetSnapshots'], hasLength(1));
    await controller.resetAllData();
    expect(controller.assetSnapshots, isEmpty);
  });

  test('旧备份没有快照时清空既有快照，未来月份拒绝保存', () async {
    final controller = await makeController();
    final now = DateTime.now();
    expect(
      await controller.saveAssetSnapshot(
        controller.buildAssetSnapshot(DateTime(now.year, now.month + 1)),
      ),
      isFalse,
    );
    await controller.saveAssetSnapshot(
      controller.buildAssetSnapshot(DateTime(2026, 1)),
    );
    final payload =
        jsonDecode(controller.exportDataJson()) as Map<String, dynamic>;
    (payload['data'] as Map).remove('assetSnapshots');
    await controller.importDataJson(jsonEncode(payload));
    expect(controller.assetSnapshots, isEmpty);
  });
}
