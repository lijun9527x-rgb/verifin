import 'dart:async';

import 'package:flutter/material.dart';

import '../app/asset_snapshot_math.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

class AssetMonthlyPage extends StatefulWidget {
  const AssetMonthlyPage({super.key});
  @override
  State<AssetMonthlyPage> createState() => _AssetMonthlyPageState();
}

class _AssetMonthlyPageState extends State<AssetMonthlyPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  AssetComparisonGrouping _grouping = AssetComparisonGrouping.category;
  bool _native = false;

  List<DateTime> _months = [];
  List<AssetMonthSnapshot?> _snapshots = [];
  List<AssetComparisonRow> _rows = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  void _refresh() {
    final controller = VeriFinScope.of(context);
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    _months = [
      for (
        var offset = MediaQuery.sizeOf(context).width < 600 ? -1 : -2;
        offset <= 0;
        offset++
      )
        DateTime(_month.year, _month.month + offset),
    ];
    _snapshots = _months
        .map(
          (month) =>
              controller.assetSnapshotFor(month) ??
              (month == currentMonth
                  ? controller.buildAssetSnapshot(month)
                  : null),
        )
        .toList();
    _rows = assetComparisonRows(
      _snapshots,
      grouping: _grouping,
      baseCurrencyCode: controller.activeBook.baseCurrencyCode,
      nativeCurrency: _native,
    );
  }

  void _change(VoidCallback change) => setState(() {
    change();
    _refresh();
  });

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final months = _months;
    final snapshots = _snapshots;
    final previous = snapshots[snapshots.length - 2];
    final current = snapshots.last;
    final rows = _rows;
    String amount(double? value, String code) =>
        value == null ? '—' : formatUserMoney(value, code);
    String title(AssetComparisonGrouping group) => switch (group) {
      AssetComparisonGrouping.category => l10n.assetViewCategory,
      AssetComparisonGrouping.bank => l10n.assetViewBank,
      AssetComparisonGrouping.account => l10n.assetViewAccount,
    };
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              VeriHeader(title: l10n.assetMonthlyTitle, showBack: true),
              MonthSwitcher(
                label: l10n.yearMonth(_month),
                onLabelTap: () async {
                  final selected = await showMonthPickerSheet(
                    context: context,
                    selected: _month,
                    firstDate: DateTime(1970),
                  );
                  if (selected != null && mounted) {
                    _change(() => _month = selected);
                  }
                },
                onPrevious: () => _change(
                  () => _month = DateTime(_month.year, _month.month - 1),
                ),
                onNext: _month.isBefore(currentMonth)
                    ? () => _change(
                        () => _month = DateTime(_month.year, _month.month + 1),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              VeriSegmentedControl<AssetComparisonGrouping>(
                values: AssetComparisonGrouping.values,
                selected: _grouping,
                labelOf: title,
                onChanged: (value) => _change(() => _grouping = value),
              ),
              if (_grouping == AssetComparisonGrouping.account)
                Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.assetSnapshotNative),
                    value: _native,
                    onChanged: (value) => _change(() => _native = value),
                  ),
                ),
              const SizedBox(height: 12),
              Text(l10n.assetMonthlyDescription),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('asset_snapshot_edit'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => AssetSnapshotEditorPage(month: _month),
                  ),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: Text(l10n.assetSnapshotEdit),
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                EmptyState(
                  icon: Icons.account_balance_wallet_outlined,
                  title: l10n.assetSnapshotMissing,
                  description: l10n.assetSnapshotEmpty,
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      DataColumn(label: Text(l10n.assetSnapshotGroup)),
                      for (final month in months)
                        DataColumn(
                          numeric: true,
                          label: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.yearMonth(month)),
                              Text(
                                controller.assetSnapshotFor(month) != null
                                    ? l10n.assetSnapshotSavedState
                                    : month == currentMonth
                                    ? l10n.assetSnapshotDraft
                                    : l10n.assetSnapshotMissing,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      DataColumn(
                        numeric: true,
                        label: Text(l10n.assetSnapshotChange),
                      ),
                    ],
                    rows: [
                      for (final row in rows)
                        DataRow(
                          cells: [
                            DataCell(
                              Text(switch (_grouping) {
                                AssetComparisonGrouping.category =>
                                  row.holding.assetClass.label(l10n),
                                AssetComparisonGrouping.bank =>
                                  row.holding.bankName.isEmpty
                                      ? l10n.assetsUngrouped
                                      : row.holding.bankName,
                                AssetComparisonGrouping.account =>
                                  '${row.holding.name}\n${row.currencyCode}',
                              }),
                            ),
                            for (final value in row.values)
                              DataCell(Text(amount(value, row.currencyCode))),
                            DataCell(
                              Text(
                                row.change == null
                                    ? '—'
                                    : formatSignedUserMoney(
                                        row.change!,
                                        row.currencyCode,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      DataRow(
                        cells: [
                          DataCell(Text(l10n.assetSnapshotTotal)),
                          for (final snapshot in snapshots)
                            DataCell(
                              Text(
                                amount(
                                  snapshot?.totalInBase,
                                  controller.activeBook.baseCurrencyCode,
                                ),
                              ),
                            ),
                          DataCell(
                            Text(
                              previous?.totalInBase == null ||
                                      current?.totalInBase == null
                                  ? '—'
                                  : formatSignedUserMoney(
                                      current!.totalInBase! -
                                          previous!.totalInBase!,
                                      controller.activeBook.baseCurrencyCode,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                l10n.assetSnapshotRates,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AssetSnapshotEditorPage extends StatefulWidget {
  const AssetSnapshotEditorPage({super.key, required this.month});
  final DateTime month;
  @override
  State<AssetSnapshotEditorPage> createState() =>
      _AssetSnapshotEditorPageState();
}

class _AssetSnapshotEditorPageState extends State<AssetSnapshotEditorPage> {
  AssetMonthSnapshot? _template;
  final Map<String, double> _balances = {};
  final Map<String, double> _baseBalances = {};
  bool _saving = false;
  bool _dirty = false;
  final EditorExitController _exit = EditorExitController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = VeriFinScope.of(context);
    _template ??=
        controller.assetSnapshotFor(widget.month) ??
        controller.buildAssetSnapshot(widget.month);
  }

  Future<void> _balance(AssetHoldingSnapshot holding) async {
    final value = await showNumberPadSheet(
      context,
      title: holding.name,
      initialAmount: _balances[holding.accountId] ?? holding.balance,
      currencyCode: holding.currencyCode,
      allowZero: true,
      allowNegative: true,
    );
    if (!mounted || value == null) return;
    setState(() {
      _balances[holding.accountId] = value;
      _dirty = true;
    });
  }

  Future<void> _baseValue(AssetHoldingSnapshot holding) async {
    final code = _template!.baseCurrencyCode;
    final l10n = AppLocalizations.of(context);
    final value = await showNumberPadSheet(
      context,
      title: code == 'CNY'
          ? l10n.assetSnapshotManualValue
          : l10n.baseCurrencyAmountLabel(code),
      initialAmount: _baseBalances[holding.accountId] ?? holding.baseBalance,
      currencyCode: code,
      allowZero: true,
      allowNegative: true,
    );
    if (!mounted || value == null) return;
    setState(() {
      _baseBalances[holding.accountId] = value;
      _dirty = true;
    });
  }

  Future<bool> _save() async {
    if (_saving || _template!.holdings.isEmpty) return false;
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    if (controller.assetSnapshotFor(widget.month) != null) {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.assetSnapshotSave,
        message: l10n.assetSnapshotOverwrite,
      );
      if (!mounted || !confirmed) return false;
    }
    setState(() => _saving = true);
    final snapshot = controller.buildAssetSnapshot(
      widget.month,
      template: _template,
      balances: _balances,
      baseBalances: _baseBalances,
    );
    final saved = await controller.saveAssetSnapshot(snapshot);
    if (!mounted) return saved;
    setState(() {
      _saving = false;
      if (saved) _dirty = false;
    });
    if (saved) {
      unawaited(
        VeriFeedbackHost.of(
          context,
        ).showMessage(message: l10n.assetSnapshotSaved),
      );
    } else {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: l10n.entrySaveValidationFailed,
          tone: VeriFeedbackTone.error,
        ),
      );
    }
    return saved;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    final draft = controller.buildAssetSnapshot(
      widget.month,
      template: _template,
      balances: _balances,
      baseBalances: _baseBalances,
    );
    return UnsavedChangesGuard(
      isDirty: _dirty,
      onSave: _save,
      exitController: _exit,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              children: [
                VeriHeader(
                  title: l10n.assetSnapshotEdit,
                  subtitle: l10n.yearMonth(widget.month),
                  showBack: true,
                  actions: [
                    SaveHeaderAction(
                      onPressed: _saving || draft.holdings.isEmpty
                          ? null
                          : () async {
                              if (await _save() && mounted) _exit.exit();
                            },
                    ),
                  ],
                ),
                Text(l10n.assetSnapshotHelp),
                const SizedBox(height: 16),
                for (final holding in draft.holdings) ...[
                  SelectField(
                    label: '${holding.name} · ${holding.currencyCode}',
                    value: formatUserMoney(
                      holding.balance,
                      holding.currencyCode,
                    ),
                    icon: Icons.account_balance_wallet_outlined,
                    onTap: _saving ? null : () => _balance(holding),
                  ),
                  const SizedBox(height: 10),
                  if (holding.currencyCode != draft.baseCurrencyCode) ...[
                    SelectField(
                      label: draft.baseCurrencyCode == 'CNY'
                          ? l10n.assetSnapshotManualValue
                          : l10n.baseCurrencyAmountLabel(
                              draft.baseCurrencyCode,
                            ),
                      value: holding.baseBalance == null
                          ? l10n.notSet
                          : formatUserMoney(
                              holding.baseBalance!,
                              draft.baseCurrencyCode,
                            ),
                      icon: Icons.payments_outlined,
                      onTap: _saving ? null : () => _baseValue(holding),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
                if (draft.holdings.isEmpty) Text(l10n.assetSnapshotEmpty),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
