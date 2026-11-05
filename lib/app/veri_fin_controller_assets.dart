part of 'veri_fin_controller.dart';

extension AssetSnapshotOperations on VeriFinController {
  List<AssetMonthSnapshot> get assetSnapshots => List.unmodifiable(
    _assetSnapshots.where((snapshot) => snapshot.bookId == activeBook.id),
  );

  AssetMonthSnapshot? assetSnapshotFor(DateTime month) => assetSnapshots
      .where((s) => s.month.year == month.year && s.month.month == month.month)
      .firstOrNull;

  /// 历史月份截至月末，当前月份截至现在；不会虚构未来月份或自动保存历史快照。
  AssetMonthSnapshot buildAssetSnapshot(
    DateTime month, {
    Map<String, double> balances = const {},
    Map<String, double> baseBalances = const {},
    AssetMonthSnapshot? template,
  }) {
    final now = DateTime.now();
    final nextMonth = DateTime(month.year, month.month + 1);
    final cutoff = nextMonth.isBefore(now) ? nextMonth : now;
    final seed = template?.holdings ?? _assetSnapshotSeed(cutoff);
    return AssetMonthSnapshot(
      bookId: activeBook.id,
      month: month,
      recordedAt: now,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      holdings: seed.map((holding) {
        final balance = normalizeCurrencyAmount(
          balances[holding.accountId] ?? holding.balance,
          holding.currencyCode,
        );
        final isBase = holding.currencyCode == activeBook.baseCurrencyCode;
        final enteredBase =
            baseBalances[holding.accountId] ?? holding.baseBalance;
        return AssetHoldingSnapshot(
          accountId: holding.accountId,
          name: holding.name,
          bankName: holding.bankName,
          bankId: holding.bankId,
          assetClass: holding.assetClass,
          currencyCode: holding.currencyCode,
          balance: balance,
          rateToBase: isBase ? 1 : null,
          baseBalance: isBase
              ? balance
              : enteredBase != null
              ? normalizeCurrencyAmount(
                  enteredBase,
                  activeBook.baseCurrencyCode,
                )
              : balance == 0
              ? 0
              : null,
        );
      }).toList(),
    );
  }

  List<AssetHoldingSnapshot> _assetSnapshotSeed(DateTime cutoff) {
    final selected = {
      for (final account in accounts)
        if (account.includeInAssets && !account.hidden) account.id: account,
    };
    final balances = {
      for (final account in selected.values) account.id: account.initialBalance,
    };
    for (final entry in entries) {
      if (!accountEffectDate(entry).isBefore(cutoff)) continue;
      for (final id in [
        entry.accountId,
        if (entry.toAccountId != null && entry.toAccountId != entry.accountId)
          entry.toAccountId!,
      ]) {
        if (balances.containsKey(id)) {
          balances[id] = balances[id]! + accountDeltaForEntry(entry, id);
        }
      }
    }
    final bankNames = {for (final bank in accountGroups) bank.id: bank.name};
    return [
      for (final account in selected.values)
        AssetHoldingSnapshot(
          accountId: account.id,
          name: account.name,
          bankName: bankNames[account.groupId] ?? '',
          bankId: bankNames.containsKey(account.groupId)
              ? account.groupId!
              : '',
          assetClass: account.assetClass,
          currencyCode: account.currencyCode,
          balance: normalizeCurrencyAmount(
            balances[account.id]!,
            account.currencyCode,
          ),
          rateToBase: account.currencyCode == activeBook.baseCurrencyCode
              ? 1
              : null,
          baseBalance: null,
        ),
    ];
  }

  Future<bool> saveAssetSnapshot(AssetMonthSnapshot snapshot) {
    final result = _assetSnapshotSaveTail.then(
      (_) => _saveAssetSnapshot(snapshot),
    );
    _assetSnapshotSaveTail = result.then<void>((_) {});
    return result;
  }

  Future<bool> _saveAssetSnapshot(AssetMonthSnapshot snapshot) async {
    final now = DateTime.now();
    if (!validAssetSnapshot(snapshot, ledgerBooks) ||
        snapshot.bookId != activeBook.id ||
        snapshot.baseCurrencyCode != activeBook.baseCurrencyCode ||
        snapshot.month.isAfter(DateTime(now.year, now.month)) ||
        snapshot.holdings.map((h) => h.accountId).toSet().length !=
            snapshot.holdings.length ||
        snapshot.holdings.any(
          (h) =>
              !h.balance.isFinite ||
              (h.rateToBase != null && !isValidExchangeRate(h.rateToBase!)) ||
              (h.baseBalance != null && !h.baseBalance!.isFinite),
        )) {
      return false;
    }
    final next = <AssetMonthSnapshot>[
      for (final old in _assetSnapshots)
        if (old.id != snapshot.id) old,
      snapshot,
    ];
    if (!await _runTrackedWrite(() => _repository.saveAssetSnapshots(next))) {
      return false;
    }
    _assetSnapshots
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }
}
