import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/currency_math.dart';
import '../app/ledger_math.dart';
import '../app/common_widgets.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'budget_pages.dart';
import 'sheets.dart';

class HomeCategoryBudgetPanel extends StatelessWidget {
  const HomeCategoryBudgetPanel({
    super.key,
    required this.month,
    required this.snapshots,
  });

  final DateTime month;
  final List<CategoryBudgetSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final byId = {
      for (final snapshot in snapshots) snapshot.category.id: snapshot,
    };
    final visible = controller
        .categoriesForType(EntryType.expense)
        .map((category) => byId[category.id])
        .whereType<CategoryBudgetSnapshot>()
        .where((snapshot) => snapshot.hasBudget)
        .toList();
    void openBudgets() => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BudgetOverviewPage(initialMonth: month),
      ),
    );
    return VeriCard(
      key: const Key('home_category_budgets'),
      onTap: openBudgets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: l10n.categoryBudgetTitle,
            trailingWidget: TextButton(
              onPressed: openBudgets,
              child: Text(l10n.yearMonth(month)),
            ),
          ),
          if (controller.defaultAccountId != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.credit_card, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${l10n.defaultAccountTitle}: ${controller.accounts.firstWhere((account) => account.id == controller.defaultAccountId).name}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (visible.isEmpty)
            EmptyState(
              icon: Icons.pie_chart_outline,
              title: l10n.categoryBudgetTitle,
              description: l10n.homeCategoryBudgetEmpty,
              action: TextButton(
                onPressed: openBudgets,
                child: Text(l10n.budgetSettingsTitle),
              ),
            ),
          for (final snapshot in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: InkWell(
                // 行主体直接编辑该分类在本期（首页所选键月）的额度；整卡的
                // 「查看全部」入口仍然进总览。
                onTap: () =>
                    unawaited(_editCategoryBudget(context, snapshot.category)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CategoryIconBox(
                          iconCode: snapshot.category.iconCode,
                          color: colorForType(context, EntryType.expense),
                          size: 30,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(snapshot.category.label)),
                        Text(
                          formatUserMoney(
                            snapshot.budget,
                            controller.activeBook.baseCurrencyCode,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: snapshot.progress,
                      color: snapshot.overBudget
                          ? veriSemantic(context, veriExpense)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${l10n.metricExpense} ${formatUserMoney(snapshot.spent, controller.activeBook.baseCurrencyCode)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            '${l10n.budgetRemaining} ${formatUserMoney(snapshot.remaining, controller.activeBook.baseCurrencyCode)}',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: snapshot.overBudget
                                      ? veriSemantic(context, veriExpense)
                                      : null,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 编辑该分类在 [month]（首页当前预算键月）的单期额度。
  ///
  /// 复用统一数字键盘，不另造金额编辑器；取消返回 null，不写入。
  Future<void> _editCategoryBudget(
    BuildContext context,
    Category category,
  ) async {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final scope = controller.budgetCycleIsCustom
        ? l10n.budgetOverrideScopePeriod
        : l10n.budgetOverrideScopeMonth;
    final amount = await showNumberPadSheet(
      context,
      title: l10n.budgetOverrideCategoryAmountTitle(category.label, scope),
      initialAmount: controller.categoryBudget(month, category.id),
      allowZero: true,
      currencyCode: controller.activeBook.baseCurrencyCode,
    );
    if (!context.mounted || amount == null) {
      return;
    }
    controller.setCategoryBudget(month, category.id, amount);
  }
}
