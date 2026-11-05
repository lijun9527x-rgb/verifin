import '../amount_format.dart' as amount_format;
import '../currency_math.dart';
import '../ledger_math.dart';
import '../models.dart';
import 'widget_catalog.dart';

/// 单个账本的投影输入。读取其它账本不会切换活动账本，也不改写任何数据。
class WidgetBookSnapshot {
  const WidgetBookSnapshot({
    required this.book,
    required this.entries,
    required this.accounts,
    required this.rates,
    required this.budgetWindow,
    required this.budget,
    required this.usesMultipleCurrencies,
  });

  final LedgerBook book;
  final List<LedgerEntry> entries;
  final List<Account> accounts;
  final List<ExchangeRate> rates;
  final DateWindow budgetWindow;
  final double budget;

  /// 该账本自身是否涉及多币种，决定金额是否省略重复单位（**不读活动账本的闸门**）。
  final bool usesMultipleCurrencies;
}

/// 单个模板在一个账本上的数字。**不含任何文案**：桌面显示的文字全部来自
/// 原生 `strings.xml`，这里只传数值与格式化后的金额。
class WidgetTemplateProjection {
  const WidgetTemplateProjection({
    required this.amount,
    this.usage,
    this.points,
  });

  /// 已按该账本口径格式化的金额；无法计算时是缺失占位符（`—`）。
  final String amount;

  /// 预算使用率（`0`–`1`），仅 `budget` 模板。
  final double? usage;

  /// 曲线数据点，仅 `trend` / `netWorth` 模板；缺汇率等情况为 `null`（不画图）。
  final List<double>? points;

  Map<String, Object?> toJson() => <String, Object?>{
    'amount': amount,
    if (usage != null) 'usage': usage,
    if (points != null) 'points': points,
  };
}

/// 一个账本全部模板的投影结果，可直接编码进共享存储。
class WidgetBookProjection {
  const WidgetBookProjection({required this.dateKey, required this.templates});

  /// 投影日期（`yyyy-MM-dd`）：原生据此判断「今日支出」是否跨天过期。
  final String dateKey;

  final Map<WidgetTemplate, WidgetTemplateProjection> templates;
}

/// 无法计算时的占位符（与界面其它「缺失态」一致）。
const String widgetMissingAmount = '—';

/// 投影快照的结构版本；与原生 `widgetSnapshotVersion` 必须成对修改。
const int widgetSnapshotVersion = 2;

String widgetDateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// 「日」的廉价整数键（`yyyymmdd`）：只比较日历日时用它，避免每条交易都构造
/// `DateTime` 再走 [calendarDaysBetween]（那是 `=n` 次分配，实测是投影里最大的开销）。
int _dayKey(DateTime value) =>
    value.year * 10000 + value.month * 100 + value.day;

/// 把一个账本投影成桌面上要显示的数字。
///
/// 纯函数：所有口径复用 `ledger_math` / `currency_math` 的既有入口（预算取数走
/// [budgetExpenseTotal]、退款与多币种换算走既有实现），不在这里重写领域语义。
/// 窗口固定 [widgetChartDays] 个日历日并以 [now] 当天收尾。
///
/// 复杂度是 `O(交易数 + 账户数 × 天数)`：逐日支出/收入与账户余额增量都在一次遍历里
/// 聚合，净资产曲线按「期初余额 + 逐日前缀和」推进，不再按账户重复扫描全部交易。
WidgetBookProjection buildWidgetBookProjection({
  required WidgetBookSnapshot snapshot,
  required DateTime now,
}) {
  final today = dateOnly(now);
  final dates = List<DateTime>.generate(
    widgetChartDays,
    (index) => addCalendarDays(today, index - (widgetChartDays - 1)),
  );
  final windowStart = dates.first;
  final windowStartKey = _dayKey(windowStart);
  final dayIndex = <int, int>{
    for (var i = 0; i < widgetChartDays; i++) _dayKey(dates[i]): i,
  };
  final display = _amountDisplayFor(snapshot);
  String format(num value) =>
      formatMoney(value, snapshot.book.baseCurrencyCode, display: display);

  // 一次遍历得到逐日支出桶：曲线、窗口合计与「今日支出」都由它派生。
  final expenseByDay = List<double>.filled(widgetChartDays, 0);
  for (final entry in snapshot.entries) {
    if (entry.type != EntryType.expense) continue;
    final index = dayIndex[_dayKey(entry.occurredAt)];
    if (index == null) continue;
    expenseByDay[index] += statAmountForEntry(entry);
  }
  final windowExpense = expenseByDay.fold<double>(0, (sum, v) => sum + v);
  final todayExpense = expenseByDay.last;
  final budgetSpent = budgetExpenseTotal(
    entriesInWindow(snapshot.entries, snapshot.budgetWindow),
  );
  final hasBudget = snapshot.budget > 0;
  final netWorthSeries = _netWorthSeries(
    snapshot: snapshot,
    dates: dates,
    dayIndex: dayIndex,
    windowStartKey: windowStartKey,
  );
  final netWorthToday = netWorthSeries.last;
  final hasVisibleAccount = snapshot.accounts.any(
    (account) => account.includeInAssets && !account.hidden,
  );
  final netWorthPoints =
      hasVisibleAccount && netWorthSeries.every((value) => value != null)
      ? netWorthSeries.cast<double>()
      : null;

  return WidgetBookProjection(
    dateKey: widgetDateKey(now),
    templates: <WidgetTemplate, WidgetTemplateProjection>{
      WidgetTemplate.quickEntry: WidgetTemplateProjection(
        amount: format(todayExpense),
      ),
      WidgetTemplate.budget: WidgetTemplateProjection(
        amount: hasBudget
            ? format(snapshot.budget - budgetSpent)
            : widgetMissingAmount,
        usage: hasBudget ? budgetSpent / snapshot.budget : null,
      ),
      WidgetTemplate.trend: WidgetTemplateProjection(
        amount: format(windowExpense),
        points: expenseByDay,
      ),
      WidgetTemplate.netWorth: WidgetTemplateProjection(
        amount: netWorthToday == null
            ? widgetMissingAmount
            : format(netWorthToday),
        points: netWorthPoints,
      ),
    },
  );
}

/// 本位币账户按流水生成每日净资产；外币只使用最后一天的当前手填金额。
///
/// 每个可见账户先按生效日聚合增量、再逐日前缀求和，最后交给既有的
/// [convertAccountBalancesToBase] 汇总当前金额，保证与首页当前资产口径一致。
List<double?> _netWorthSeries({
  required WidgetBookSnapshot snapshot,
  required List<DateTime> dates,
  required Map<int, int> dayIndex,
  required int windowStartKey,
}) {
  final visible = snapshot.accounts
      .where((account) => account.includeInAssets && !account.hidden)
      .toList(growable: false);
  if (visible.isEmpty) {
    return List<double?>.filled(dates.length, 0);
  }
  final positionOf = <String, int>{
    for (var i = 0; i < visible.length; i++) visible[i].id: i,
  };
  final baseline = List<double>.generate(
    visible.length,
    (i) => visible[i].initialBalance,
  );
  final dailyDelta = List<List<double>>.generate(
    visible.length,
    (_) => List<double>.filled(dates.length, 0),
  );
  for (final entry in snapshot.entries) {
    // 待到账退款不动余额，直接跳过。
    if (entry.type == EntryType.refund && entry.settledAt == null) continue;
    final key = _dayKey(accountEffectDate(entry));
    final windowIndex = dayIndex[key];
    final beforeWindow = key < windowStartKey;
    // 窗口结束之后（含今天之后）才生效的交易不影响本窗口任何一天。
    if (windowIndex == null && !beforeWindow) continue;
    final primary = positionOf[entry.accountId];
    final toAccountId = entry.toAccountId;
    final secondary = toAccountId == null || toAccountId == entry.accountId
        ? null
        : positionOf[toAccountId];
    final positions = <int>[?primary, ?secondary];
    for (final position in positions) {
      final delta = accountDeltaForEntry(entry, visible[position].id);
      if (delta == 0) continue;
      if (windowIndex == null) {
        baseline[position] += delta;
      } else {
        dailyDelta[position][windowIndex] += delta;
      }
    }
  }

  final running = List<double>.of(baseline);
  // 常见情形（账本只有一个币种）直接求和：既省掉每天一次的换算，结果也完全一致——
  // 本位币账户不需要额外填写金额。
  final baseCurrencyCode = snapshot.book.baseCurrencyCode;
  final allBaseCurrency = visible.every(
    (account) => account.currencyCode == baseCurrencyCode,
  );
  final series = <double?>[];
  for (var day = 0; day < dates.length; day++) {
    for (var i = 0; i < visible.length; i++) {
      running[i] += dailyDelta[i][day];
    }
    if (allBaseCurrency) {
      series.add(running.fold<double>(0, (sum, value) => sum + value));
      continue;
    }
    // 外币只有当前手填金额，没有每日历史金额，不反推过去的资产曲线。
    if (day != dates.length - 1) {
      series.add(null);
      continue;
    }
    final converted = convertAccountBalancesToBase(
      accounts: visible,
      balanceOf: (account) => running[positionOf[account.id]!],
      bookId: snapshot.book.id,
      baseCurrencyCode: baseCurrencyCode,
      date: dates[day],
      rates: snapshot.rates,
    );
    series.add(converted.completeTotal);
  }
  return series;
}

/// 金额单位口径按**实例所属账本**判定：单币种账本 + 「单币种隐藏单位」时省略单位。
MoneyCodeDisplay _amountDisplayFor(WidgetBookSnapshot snapshot) =>
    amount_format.hideUnitInSingleCurrency && !snapshot.usesMultipleCurrencies
    ? MoneyCodeDisplay.none
    : amount_format.preferredMoneyCodeDisplay;
