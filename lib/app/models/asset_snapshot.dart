/// 月度资产快照是独立的核对记录，不改写交易或账户余额。
library;

import 'account.dart';

class AssetHoldingSnapshot {
  const AssetHoldingSnapshot({
    required this.accountId,
    required this.name,
    required this.bankName,
    this.bankId = '',
    required this.assetClass,
    required this.currencyCode,
    required this.balance,
    required this.rateToBase,
    required this.baseBalance,
  });

  final String accountId;
  final String name;
  final String bankName;
  final String bankId;
  final AssetClass assetClass;
  final String currencyCode;
  final double balance;
  final double? rateToBase;
  final double? baseBalance;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'name': name,
    'bankName': bankName,
    'bankId': bankId,
    'assetClass': assetClass.name,
    'currencyCode': currencyCode,
    'balance': balance,
    'rateToBase': rateToBase,
    'baseBalance': baseBalance,
  };

  factory AssetHoldingSnapshot.fromJson(Map<String, Object?> json) {
    final balance = (json['balance'] as num).toDouble();
    final rate = (json['rateToBase'] as num?)?.toDouble();
    final base = (json['baseBalance'] as num?)?.toDouble();
    if (!balance.isFinite ||
        (rate != null && (!rate.isFinite || rate <= 0)) ||
        (base != null && !base.isFinite)) {
      throw const FormatException('Invalid asset snapshot amount');
    }
    return AssetHoldingSnapshot(
      accountId: json['accountId'] as String,
      name: json['name'] as String,
      bankName: json['bankName'] as String? ?? '',
      bankId: json['bankId'] as String? ?? '',
      assetClass: AssetClass.fromStorage(json['assetClass'] as String?),
      currencyCode: json['currencyCode'] as String,
      balance: balance,
      rateToBase: rate,
      baseBalance: base,
    );
  }
}

class AssetMonthSnapshot {
  AssetMonthSnapshot({
    required this.bookId,
    required DateTime month,
    required this.recordedAt,
    required this.baseCurrencyCode,
    required List<AssetHoldingSnapshot> holdings,
  }) : month = DateTime(month.year, month.month),
       holdings = List.unmodifiable(holdings);

  final String bookId;
  final DateTime month;
  final DateTime recordedAt;
  final String baseCurrencyCode;
  final List<AssetHoldingSnapshot> holdings;

  String get id => '$bookId:${month.year}-${month.month}';

  double? get totalInBase {
    if (holdings.any((holding) => holding.baseBalance == null)) return null;
    return holdings.fold<double>(0, (sum, h) => sum + h.baseBalance!);
  }

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'month': month.toIso8601String(),
    'recordedAt': recordedAt.toIso8601String(),
    'baseCurrencyCode': baseCurrencyCode,
    'holdings': holdings.map((h) => h.toJson()).toList(),
  };

  factory AssetMonthSnapshot.fromJson(Map<String, Object?> json) {
    final month = DateTime.parse(json['month'] as String);
    final holdings = (json['holdings'] as List)
        .map(
          (h) => AssetHoldingSnapshot.fromJson(
            Map<String, Object?>.from(h as Map),
          ),
        )
        .toList();
    if (holdings.map((h) => h.accountId).toSet().length != holdings.length) {
      throw const FormatException('Duplicate asset snapshot account');
    }
    return AssetMonthSnapshot(
      bookId: json['bookId'] as String,
      month: month,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
      baseCurrencyCode: json['baseCurrencyCode'] as String,
      holdings: holdings,
    );
  }
}
