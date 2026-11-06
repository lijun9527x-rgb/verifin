import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/recurring.dart';
import 'package:verifin/app/trading_calendar.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/recurring_page.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

// 合成测试年历，不作为生产日历：额外关闭 1 月 1 日、2 日，模拟交易所休市。
TradingCalendarYear calendar(int year) => TradingCalendarYear(year, {
  for (
    var day = DateTime(year);
    day.year == year;
    day = DateTime(day.year, day.month, day.day + 1)
  )
    tradingDateKey(day):
        day.weekday <= DateTime.friday && !(day.month == 1 && day.day <= 2),
});

String monthResponse(Uri uri) {
  final month = DateTime.parse('${uri.queryParameters['month']}-01');
  final data = calendar(month.year);
  return jsonEncode({
    'data': [
      for (
        var day = 1;
        day <= DateTime(month.year, month.month + 1, 0).day;
        day++
      )
        {
          'jyrq': tradingDateKey(DateTime(month.year, month.month, day)),
          'jybz':
              data.days[tradingDateKey(DateTime(month.year, month.month, day))]!
              ? '1'
              : '0',
        },
    ],
  });
}

RecurringRule rule(DateTime start) => RecurringRule(
  id: 'investment',
  bookId: defaultLedgerBookId,
  type: EntryType.transfer,
  amount: 100,
  accountAmount: 100,
  toAccountAmount: 100,
  baseAmount: 0,
  categoryId: 'transfer',
  accountId: 'demand',
  toAccountId: 'fund',
  note: '',
  frequency: RecurringFrequency.aShareTradingDay,
  startDate: start,
  nextRunDate: start,
);

void main() {
  useTestDatabases();

  testWidgets('编辑器可选择交易日频率，默认从明天开始', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const RecurringRuleEditPage()),
      ),
    );
    await tester.ensureVisible(find.text('频率'));
    await tester.tap(find.text('频率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每个A股交易日'));
    await tester.pumpAndSettle();
    final today = shanghaiDate(DateTime.now());
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final context = tester.element(find.byType(RecurringRuleEditPage));
    final text = AppLocalizations.of(context).dateMonthDay(tomorrow);
    expect(find.text(text), findsOneWidget);
    expect(find.text('打开应用时补记；新规则默认从明天开始'), findsOneWidget);
  });

  test('年历只拉一次，串行并发请求共用缓存，跨年自动获取新年', () async {
    var calls = 0;
    final service = TradingCalendarService(
      fetchMonth: (uri) async {
        calls++;
        return monthResponse(uri);
      },
    );
    await Future.wait([
      service.ensureYears({2026}, DateTime(2026, 1, 1)),
      service.ensureYears({2026}, DateTime(2026, 1, 1)),
    ]);
    expect(calls, 12);
    expect(service.isTradingDay(DateTime(2026, 1, 2)), false);
    // 1 月 4 日即使是调休上班的星期日也不交易。
    expect(service.isTradingDay(DateTime(2026, 1, 4)), false);
    expect(service.isTradingDay(DateTime(2027, 1, 4)), isNull);
    await service.ensureYears({2026, 2027}, DateTime(2027, 1, 1));
    expect(calls, 24);
    expect(service.years, [2026, 2027]);
  });

  test('缓存重启可读，异常响应不覆盖旧年历，失败有节流', () async {
    final directory = await Directory.systemTemp.createTemp(
      'trading-calendar-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/calendar.json');
    final first = TradingCalendarService(
      cacheFile: file,
      fetchMonth: (uri) async => monthResponse(uri),
    );
    await first.ensureYears({2026}, DateTime(2026));
    var calls = 0;
    final errors = <String>[];
    final second = TradingCalendarService(
      cacheFile: file,
      onFailure: errors.add,
      fetchMonth: (_) async {
        calls++;
        return '{"data":null}';
      },
    );
    await second.load();
    expect(second.years, [2026]);
    await second.ensureYears({2026, 2027}, DateTime(2027));
    expect(second.years, [2026]);
    expect(calls, 12);
    await second.ensureYears({2027}, DateTime(2027));
    expect(calls, 12);
    expect(errors, isNotEmpty);
    await second.ensureYears({2026}, DateTime(2027), force: true);
    expect(second.isTradingDay(DateTime(2026, 1, 5)), true);
    await file.writeAsString('{"version":1,"years":[]}');
    await second.load();
    expect(second.years, [2026]);
  });

  test('北京时间、起始日期边界、未知日历停止补记', () {
    final service = TradingCalendarService(initialCalendars: [calendar(2026)]);
    final investment = rule(DateTime(2026, 1, 5));
    expect(
      dueDatesFor(
        investment,
        DateTime.utc(2026, 1, 4, 15, 59),
        isTradingDay: service.isTradingDay,
      ),
      isEmpty,
    );
    expect(
      dueDatesFor(
        investment,
        DateTime.utc(2026, 1, 4, 16),
        isTradingDay: service.isTradingDay,
      ),
      [DateTime(2026, 1, 5)],
    );
    expect(dueDatesFor(investment, DateTime(2026, 1, 10)), isEmpty);
    expect(
      dueDatesFor(
        investment.copyWith(nextRunDate: DateTime(2026)),
        DateTime(2026, 1, 5, 12),
        isTradingDay: service.isTradingDay,
      ),
      [DateTime(2026, 1, 5)],
    );
  });

  test('v21 升级仅添加规则回执，已有资产、手填人民币和快照原样保留', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('trading-upgrade-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/ledger.db';
    var database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: path,
    );
    var repository = SqliteLedgerRepository(database);
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
    );
    controller.addAccount(
      Account(
        id: 'foreign',
        bookId: controller.activeBook.id,
        name: '外币存款',
        type: AccountType.debitCard,
        groupId: null,
        initialBalance: 2000,
        currencyCode: 'USD',
        baseValuation: 14123.45,
        iconCode: 'cash',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );
    await controller.saveAssetSnapshot(
      controller.buildAssetSnapshot(DateTime(2025, 12)),
    );
    final beforeAccounts = await database.db.query('accounts');
    final beforeSnapshots = await database.db.query('asset_month_snapshots');
    controller.dispose();
    // 最新 schema 去掉本次唯一新增列，模拟已录入资产但尚无交易的 v21 数据库。
    await database.db.execute(
      'ALTER TABLE recurring_rules DROP COLUMN handled_dates',
    );
    await database.db.execute('PRAGMA user_version = 21');
    await database.close();
    database = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    repository = SqliteLedgerRepository(database);
    expect(await database.db.query('accounts'), beforeAccounts);
    expect(await database.db.query('asset_month_snapshots'), beforeSnapshots);
    expect(await repository.loadEntries(), isEmpty);
    await repository.saveRecurringRules([
      rule(DateTime(2026)).copyWith(handledDates: {'2026-01-05'}),
    ]);
    expect((await repository.loadRecurringRules()).single.handledDates, {
      '2026-01-05',
    });
    await database.close();
  });

  test('定投仅生成转账，保护期初资产和快照，跳过/删除/重启不重复', () async {
    final repository = InMemoryLedgerRepository();
    final store = LocalKeyValueStore();
    final service = TradingCalendarService(initialCalendars: [calendar(2026)]);
    final controller = await VeriFinController.create(
      store,
      repository: repository,
      tradingCalendar: service,
    );
    addTearDown(controller.dispose);
    for (final item in [('demand', 10000.0), ('fund', 5000.0)]) {
      controller.addAccount(
        Account(
          id: item.$1,
          bookId: controller.activeBook.id,
          name: item.$1,
          type: AccountType.investment,
          groupId: null,
          initialBalance: item.$2,
          iconCode: 'cash',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      );
    }
    final snapshot = controller.buildAssetSnapshot(DateTime(2025, 12));
    expect(await controller.saveAssetSnapshot(snapshot), true);
    final initialAssets = (await repository.loadAccounts())
        .map((a) => a.toJson())
        .toList();
    final initialSnapshots = (await repository.loadAssetSnapshots())
        .map((s) => s.toJson())
        .toList();
    final transfer = rule(DateTime(2026, 1, 5)).copyWith(
      categoryId: controller.categoriesForType(EntryType.transfer).first.id,
    );
    expect(
      await controller.saveRecurringRuleDraft(transfer, isNew: true),
      true,
    );
    expect(await controller.applyDueRecurring(DateTime(2026, 1, 4, 12)), 0);
    expect(controller.entries, isEmpty);
    final results = await Future.wait([
      controller.applyDueRecurring(DateTime(2026, 1, 5, 12)),
      controller.applyDueRecurring(DateTime(2026, 1, 5, 12)),
    ]);
    expect(results, [1, 0]);
    expect(
      controller.accountBalance(
        controller.accounts.singleWhere((a) => a.id == 'demand'),
      ),
      9900,
    );
    expect(
      controller.accountBalance(
        controller.accounts.singleWhere((a) => a.id == 'fund'),
      ),
      5100,
    );
    expect(
      await controller.skipNextTradingOccurrence(
        transfer.id,
        DateTime(2026, 1, 6),
      ),
      true,
    );
    expect(await controller.applyDueRecurring(DateTime(2026, 1, 7, 12)), 1);
    expect(controller.entries, hasLength(2));
    expect(await controller.deleteEntry(controller.entries.first.id), true);
    // 人为把游标回拨模拟旧草稿保存；回执仍阻止删除或跳过的日期重生。
    controller.updateRecurringRule(
      controller.recurringRules.single.copyWith(
        nextRunDate: transfer.startDate,
      ),
    );
    expect(await controller.applyDueRecurring(DateTime(2026, 1, 7, 12)), 0);
    expect(
      (await repository.loadAccounts()).map((a) => a.toJson()).toList(),
      initialAssets,
    );
    expect(
      (await repository.loadAssetSnapshots()).map((s) => s.toJson()).toList(),
      initialSnapshots,
    );
    final receipt = controller.recurringRules.single.handledDates;
    expect(receipt, {'2026-01-05', '2026-01-06', '2026-01-07'});
    expect(
      RecurringRule.fromJson(
        controller.recurringRules.single.toJson(),
      ).handledDates,
      receipt,
    );
    final restarted = await VeriFinController.create(
      store,
      repository: repository,
      tradingCalendar: service,
    );
    addTearDown(restarted.dispose);
    expect(await restarted.applyDueRecurring(DateTime(2026, 1, 7, 12)), 0);
    expect(restarted.recurringRules.single.handledDates, receipt);
  });
}
