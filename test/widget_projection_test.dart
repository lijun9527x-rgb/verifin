import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/widgets/widget_catalog.dart';
import 'package:verifin/app/widgets/widget_projection.dart';

final LedgerBook _book = LedgerBook(
  id: 'book',
  name: '个人',
  createdAt: DateTime(2026),
  isDefault: true,
);

Account _account({
  String id = 'cash',
  double initialBalance = 1000,
  String currencyCode = 'CNY',
  bool includeInAssets = true,
  bool hidden = false,
}) => Account(
  id: id,
  bookId: _book.id,
  name: id,
  type: AccountType.cash,
  groupId: null,
  initialBalance: initialBalance,
  iconCode: 'wallet',
  note: '',
  includeInAssets: includeInAssets,
  hidden: hidden,
  currencyCode: currencyCode,
);

LedgerEntry _expense({
  required String id,
  required double amount,
  required DateTime occurredAt,
  String accountId = 'cash',
  double refundedAmount = 0,
  bool excludedFromBudget = false,
  String currencyCode = 'CNY',
}) => LedgerEntry(
  id: id,
  bookId: _book.id,
  type: EntryType.expense,
  amount: amount,
  currencyCode: currencyCode,
  categoryId: 'dining',
  accountId: accountId,
  note: '',
  occurredAt: occurredAt,
  refundedAmount: refundedAmount,
  excludedFromBudget: excludedFromBudget,
);

WidgetBookSnapshot _snapshot({
  List<LedgerEntry> entries = const <LedgerEntry>[],
  List<Account>? accounts,
  List<ExchangeRate> rates = const <ExchangeRate>[],
  double budget = 0,
  DateWindow? budgetWindow,
  bool usesMultipleCurrencies = false,
}) => WidgetBookSnapshot(
  book: _book,
  entries: entries,
  accounts: accounts ?? <Account>[_account()],
  rates: rates,
  budgetWindow:
      budgetWindow ??
      DateWindow(start: DateTime(2026, 9), end: DateTime(2026, 9, 30)),
  budget: budget,
  usesMultipleCurrencies: usesMultipleCurrencies,
);

/// 单币种账本默认隐藏单位，所以金额就是纯数字。
String _money(num value, {bool withUnit = false}) => formatMoney(
  value,
  'CNY',
  display: withUnit ? MoneyCodeDisplay.symbol : MoneyCodeDisplay.none,
);

void main() {
  final now = DateTime(2026, 9, 12, 15);

  test('小组件当前净资产使用手填人民币，不将它回填历史曲线', () {
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(
        accounts: [
          _account(initialBalance: 1000),
          _account(
            id: 'usd',
            currencyCode: 'USD',
            initialBalance: 0,
          ).copyWith(baseValuation: 7100),
        ],
      ),
      now: now,
    );
    final netWorth = projection.templates[WidgetTemplate.netWorth]!;
    expect(netWorth.amount, _money(8100));
    expect(netWorth.points, isNull);
  });

  test('今日支出与曲线共用同一份逐日聚合，且与既有口径一致', () {
    final entries = <LedgerEntry>[
      _expense(id: 'today', amount: 37, occurredAt: DateTime(2026, 9, 12, 9)),
      _expense(
        id: 'today-refunded',
        amount: 50,
        occurredAt: DateTime(2026, 9, 12, 20),
        refundedAmount: 20,
      ),
      _expense(id: 'in-window', amount: 80, occurredAt: DateTime(2026, 8, 26)),
      _expense(
        id: 'out-of-window',
        amount: 999,
        occurredAt: DateTime(2026, 6, 1),
      ),
    ];
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(entries: entries),
      now: now,
    );
    final trend = projection.templates[WidgetTemplate.trend]!;
    final points = trend.points!;

    expect(projection.dateKey, '2026-09-12');
    expect(points.length, widgetChartDays);
    // 末点就是今天；窗口外的交易不进入曲线。
    expect(points.last, 67);
    expect(points.first, 0);
    expect(points.reduce((a, b) => a + b), 147);
    expect(
      projection.templates[WidgetTemplate.quickEntry]!.amount,
      _money(dayExpenseTotal(entries, now)),
    );
    expect(
      trend.amount,
      _money(
        sumByType(
          entriesInWindow(
            entries,
            DateWindow(
              start: addCalendarDays(dateOnly(now), -(widgetChartDays - 1)),
              end: dateOnly(now),
            ),
          ),
          EntryType.expense,
        ),
      ),
    );
  });

  test('预算模板走预算口径：排除「不计入预算」并给出使用率', () {
    final entries = <LedgerEntry>[
      _expense(id: 'a', amount: 37, occurredAt: DateTime(2026, 9, 3)),
      _expense(
        id: 'borrowed',
        amount: 500,
        occurredAt: DateTime(2026, 9, 4),
        excludedFromBudget: true,
      ),
      _expense(
        id: 'last-month',
        amount: 200,
        occurredAt: DateTime(2026, 8, 20),
      ),
    ];
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(entries: entries, budget: 100),
      now: now,
    );
    final budget = projection.templates[WidgetTemplate.budget]!;
    expect(budget.amount, _money(63));
    expect(budget.usage, closeTo(.37, 1e-9));
    expect(budget.points, isNull);

    final noBudget = buildWidgetBookProjection(
      snapshot: _snapshot(entries: entries),
      now: now,
    );
    expect(
      noBudget.templates[WidgetTemplate.budget]!.amount,
      widgetMissingAmount,
    );
    expect(noBudget.templates[WidgetTemplate.budget]!.usage, isNull);
  });

  test('净资产曲线按期初余额 + 逐日生效日推进，已到账退款在到账日入账', () {
    final entries = <LedgerEntry>[
      _expense(id: 'before', amount: 100, occurredAt: DateTime(2026, 8, 1)),
      _expense(id: 'today', amount: 37, occurredAt: DateTime(2026, 9, 12, 23)),
      LedgerEntry(
        id: 'pending-refund',
        bookId: _book.id,
        type: EntryType.refund,
        amount: 20,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 9, 10),
        refundOf: 'before',
      ),
      LedgerEntry(
        id: 'settled-refund',
        bookId: _book.id,
        type: EntryType.refund,
        amount: 20,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 9, 10),
        settledAt: DateTime(2026, 9, 12),
        refundOf: 'before',
      ),
    ];
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(entries: entries),
      now: now,
    );
    final points = projection.templates[WidgetTemplate.netWorth]!.points!;
    // 期初 1000 − 100（8/1）− 37（9/12 支出）+ 20（9/12 到账退款）= 883。
    expect(projection.templates[WidgetTemplate.netWorth]!.amount, _money(883));
    expect(points.length, widgetChartDays);
    expect(points.last, 883);
    // 待到账退款不动余额：到账日之前应当是 900。
    expect(points[points.length - 2], 900);
    expect(points.first, 900);
  });

  test('缺汇率时净资产不显示部分和，也不画曲线', () {
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(
        accounts: <Account>[
          _account(),
          _account(id: 'usd', initialBalance: 100, currencyCode: 'USD'),
        ],
      ),
      now: now,
    );
    final netWorth = projection.templates[WidgetTemplate.netWorth]!;
    expect(netWorth.amount, widgetMissingAmount);
    expect(netWorth.points, isNull);
  });

  test('不参与资产的账户不进净资产，但仍是合法的支出账户', () {
    final projection = buildWidgetBookProjection(
      snapshot: _snapshot(
        entries: <LedgerEntry>[
          _expense(id: 'a', amount: 30, occurredAt: DateTime(2026, 9, 12)),
        ],
        accounts: <Account>[
          _account(hidden: true),
          _account(id: 'visible', initialBalance: 0),
        ],
      ),
      now: now,
    );
    expect(projection.templates[WidgetTemplate.netWorth]!.amount, _money(0));
    expect(projection.templates[WidgetTemplate.quickEntry]!.amount, _money(30));
  });

  test('窗口跨月、跨年、月末都与日历日对齐', () {
    final marchFirst = buildWidgetBookProjection(
      snapshot: _snapshot(
        entries: <LedgerEntry>[
          _expense(
            id: 'edge-in',
            amount: 10,
            occurredAt: DateTime(2026, 1, 31),
          ),
          _expense(
            id: 'edge-out',
            amount: 99,
            occurredAt: DateTime(2026, 1, 30),
          ),
          _expense(id: 'today', amount: 5, occurredAt: DateTime(2026, 3, 1)),
        ],
      ),
      now: DateTime(2026, 3, 1, 8),
    );
    final marchPoints = marchFirst.templates[WidgetTemplate.trend]!.points!;
    expect(marchFirst.dateKey, '2026-03-01');
    expect(marchPoints.length, widgetChartDays);
    expect(marchPoints.first, 10);
    expect(marchPoints.last, 5);
    // 窗口合计 = 10 + 5，窗口外那笔不计入。
    expect(marchPoints.reduce((a, b) => a + b), 15);

    final january = buildWidgetBookProjection(
      snapshot: _snapshot(
        entries: <LedgerEntry>[
          _expense(id: 'dec', amount: 12, occurredAt: DateTime(2026, 12, 7)),
          _expense(
            id: 'too-old',
            amount: 88,
            occurredAt: DateTime(2026, 12, 6),
          ),
        ],
      ),
      now: DateTime(2027, 1, 5),
    );
    expect(january.dateKey, '2027-01-05');
    expect(january.templates[WidgetTemplate.trend]!.points!.first, 12);
  });

  test('金额单位按实例所属账本判定：多币种账本照常带单位', () {
    final single = buildWidgetBookProjection(
      snapshot: _snapshot(
        entries: <LedgerEntry>[
          _expense(id: 'a', amount: 37, occurredAt: DateTime(2026, 9, 12)),
        ],
      ),
      now: now,
    );
    final multi = buildWidgetBookProjection(
      snapshot: _snapshot(
        entries: <LedgerEntry>[
          _expense(id: 'a', amount: 37, occurredAt: DateTime(2026, 9, 12)),
        ],
        usesMultipleCurrencies: true,
      ),
      now: now,
    );
    expect(single.templates[WidgetTemplate.quickEntry]!.amount, _money(37));
    expect(
      multi.templates[WidgetTemplate.quickEntry]!.amount,
      _money(37, withUnit: true),
    );
  });
}
