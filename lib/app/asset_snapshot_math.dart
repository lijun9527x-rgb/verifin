import 'dart:math' as math;

import 'models.dart';
import 'currency_catalog.dart';
import 'currency_math.dart';

/// 保存与备份恢复共用的快照校验，防止冻结金额与原币/汇率相互矛盾。
bool validAssetSnapshot(
  AssetMonthSnapshot snapshot,
  Iterable<LedgerBook> books,
) {
  final book = books.where((book) => book.id == snapshot.bookId).firstOrNull;
  if (book == null ||
      book.baseCurrencyCode != snapshot.baseCurrencyCode ||
      !CurrencyCatalog.isSupported(snapshot.baseCurrencyCode) ||
      snapshot.holdings.map((h) => h.accountId).toSet().length !=
          snapshot.holdings.length) {
    return false;
  }
  final currencyRates = <String, double?>{};
  for (final holding in snapshot.holdings) {
    if (holding.accountId.isEmpty ||
        !CurrencyCatalog.isSupported(holding.currencyCode) ||
        !holding.balance.isFinite ||
        !(holding.balance *
                math.pow(
                  10,
                  CurrencyCatalog.require(holding.currencyCode).minorUnit,
                ))
            .isFinite ||
        normalizeCurrencyAmount(holding.balance, holding.currencyCode) !=
            holding.balance) {
      return false;
    }
    final rate = holding.rateToBase;
    if (rate != null && !isValidExchangeRate(rate)) return false;
    if (currencyRates.containsKey(holding.currencyCode) &&
        currencyRates[holding.currencyCode] != rate) {
      return false;
    }
    currencyRates[holding.currencyCode] = rate;
    if (rate != null &&
        !(holding.balance *
                rate *
                math.pow(
                  10,
                  CurrencyCatalog.require(snapshot.baseCurrencyCode).minorUnit,
                ))
            .isFinite) {
      return false;
    }
    if (holding.currencyCode == snapshot.baseCurrencyCode && rate != 1) {
      return false;
    }
    final expected = holding.balance == 0
        ? 0.0
        : rate == null
        ? null
        : normalizeCurrencyAmount(
            holding.balance * rate,
            snapshot.baseCurrencyCode,
          );
    if (holding.baseBalance != expected) return false;
  }
  return true;
}

enum AssetComparisonGrouping { category, bank, account }

class AssetComparisonRow {
  const AssetComparisonRow({
    required this.key,
    required this.holding,
    required this.values,
    required this.currencyCode,
  });
  final String key;
  final AssetHoldingSnapshot holding;
  final List<double?> values;
  final String currencyCode;

  double? get change {
    if (values.length < 2) return null;
    final previous = values[values.length - 2];
    final current = values.last;
    return previous == null || current == null ? null : current - previous;
  }
}

/// 每月按该月冻结的类别/银行卡聚合；缺快照或缺汇率不伪装成零。
List<AssetComparisonRow> assetComparisonRows(
  List<AssetMonthSnapshot?> snapshots, {
  required AssetComparisonGrouping grouping,
  required String baseCurrencyCode,
  bool nativeCurrency = false,
}) {
  String keyFor(AssetHoldingSnapshot h) => switch (grouping) {
    AssetComparisonGrouping.category => h.assetClass.name,
    AssetComparisonGrouping.bank => h.bankId.isEmpty ? h.bankName : h.bankId,
    AssetComparisonGrouping.account => h.accountId,
  };
  final representatives = <String, AssetHoldingSnapshot>{};
  for (final snapshot in snapshots) {
    for (final holding in snapshot?.holdings ?? <AssetHoldingSnapshot>[]) {
      representatives[keyFor(holding)] = holding;
    }
  }
  return [
    for (final entry in representatives.entries)
      AssetComparisonRow(
        key: entry.key,
        holding: entry.value,
        currencyCode:
            nativeCurrency && grouping == AssetComparisonGrouping.account
            ? entry.value.currencyCode
            : baseCurrencyCode,
        values: snapshots.map((snapshot) {
          if (snapshot == null) return null;
          final matching = snapshot.holdings
              .where((h) => keyFor(h) == entry.key)
              .toList();
          if (matching.isEmpty) return 0.0;
          final useNative =
              nativeCurrency && grouping == AssetComparisonGrouping.account;
          if (useNative &&
              matching.any((h) => h.currencyCode != entry.value.currencyCode)) {
            return null;
          }
          if (!useNative && matching.any((h) => h.baseBalance == null)) {
            return null;
          }
          return matching.fold<double>(
            0,
            (sum, h) => sum + (useNative ? h.balance : h.baseBalance!),
          );
        }).toList(),
      ),
  ];
}
