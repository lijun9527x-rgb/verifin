/// 账户域模型：账户类型（能力矩阵见 docs/dev/tech-decisions.md）、账户与分组。
library;

import '../../l10n/app_localizations.dart';
import '../account_icon_assets.dart';

import 'ledger_book.dart';
import 'currency.dart';

enum AccountType {
  onlinePayment,
  // 信用账户：花呗 / 白条等有额度、账单日、还款、但无实体卡号的信用类账户。
  // 放在网络支付与信用卡之间。能力矩阵见 docs/dev/tech-decisions.md「账户类型能力矩阵」。
  creditAccount,
  creditCard,
  debitCard,
  investment,
  cash;

  String label(AppLocalizations l10n) {
    switch (this) {
      case AccountType.onlinePayment:
        return l10n.accountTypeOnlinePayment;
      case AccountType.creditAccount:
        return l10n.accountTypeCreditAccount;
      case AccountType.creditCard:
        return l10n.accountTypeCreditCard;
      case AccountType.debitCard:
        return l10n.accountTypeDebitCard;
      case AccountType.investment:
        return l10n.accountTypeInvestment;
      case AccountType.cash:
        return l10n.accountTypeCash;
    }
  }

  String capabilityHint(AppLocalizations l10n) {
    if (supportsCardLast4 && supportsCredit) {
      return l10n.accountTypeCardCreditHint;
    }
    if (supportsCardLast4) {
      return l10n.accountTypeCardHint;
    }
    if (supportsCredit) {
      return l10n.accountTypeCreditHint;
    }
    return l10n.accountTypeBasicHint;
  }

  static AccountType fromStorage(String? value) {
    return AccountType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => AccountType.onlinePayment,
    );
  }

  /// 是否有实体卡号（完整卡号 + 后四位）：信用卡、储蓄卡。
  bool get supportsCardLast4 {
    return this == AccountType.creditCard || this == AccountType.debitCard;
  }

  /// 是否为信用类账户，支持额度 / 账单日 / 还款日 / 还款：信用卡、信用账户。
  bool get supportsCredit {
    return this == AccountType.creditCard || this == AccountType.creditAccount;
  }
}

/// 资产性质与账户能力分开；所属银行卡/平台复用 AccountGroup。
/// 枚举顺序即用户看到的类别顺序：先人民币存款与基金，再外币，最后兜底。
/// 存储用 `name`，调整顺序不影响已有数据。
enum AssetClass {
  demandDeposit,
  fixedDeposit,
  moneyMarketFund,
  bondFund,
  equityFund,
  foreignDemandDeposit,
  foreignFixedDeposit,
  other;

  static AssetClass fromStorage(String? value) => AssetClass.values.firstWhere(
    (item) => item.name == value,
    orElse: () => AssetClass.other,
  );

  /// 基金类资产填当前市值，不是累计投入本金，录入与核对时用「市值」措辞。
  bool get isFund =>
      this == AssetClass.moneyMarketFund ||
      this == AssetClass.bondFund ||
      this == AssetClass.equityFund;

  String label(AppLocalizations l10n) => switch (this) {
    AssetClass.demandDeposit => l10n.assetClassDemand,
    AssetClass.fixedDeposit => l10n.assetClassFixed,
    AssetClass.moneyMarketFund => l10n.assetClassMoneyMarket,
    AssetClass.bondFund => l10n.assetClassBond,
    AssetClass.equityFund => l10n.assetClassEquity,
    AssetClass.foreignDemandDeposit => l10n.assetClassForeignDemand,
    AssetClass.foreignFixedDeposit => l10n.assetClassForeignFixed,
    AssetClass.other => l10n.assetClassOther,
  };
}

class Account {
  const Account({
    required this.id,
    required this.bookId,
    required this.name,
    required this.type,
    required this.groupId,
    required this.initialBalance,
    required this.iconCode,
    required this.note,
    required this.includeInAssets,
    required this.hidden,
    this.assetClass = AssetClass.other,
    this.currencyCode = defaultCurrencyCode,
    this.cardLast4 = '',
    this.cardNumber = '',
    this.cardLast4Follows = true,
    this.baseValuation,
    this.creditLimit,
    this.statementDay,
    this.dueDay,
  });

  final String id;
  final String bookId;
  final String name;
  final AccountType type;
  final String? groupId;
  final double initialBalance;
  final String iconCode;
  final String note;
  final bool includeInAssets;
  final bool hidden;
  final AssetClass assetClass;
  final String currencyCode;
  final String cardLast4;

  /// 完整卡号（选填，仅信用卡/储蓄卡 supportsCardLast4）。列表/首页仍只展示后四位，
  /// 详情页可展示完整卡号并一键复制。
  final String cardNumber;

  /// 「后四位跟随完整卡号」开关，持久化（落库 + 进备份），忠实还原用户选择、不再靠反推。
  /// true：后四位自动取 cardNumber 末四位（`cardLast4Of`），编辑页只读；false：后四位可手填、
  /// 独立于完整卡号。新账户默认 true；仅信用卡/储蓄卡有意义。
  final bool cardLast4Follows;

  /// 外币资产手填的本位币金额（可空）。填了就按这个数计入资产汇总、容器小计
  /// 与净资产，不要求用户维护汇率、也不联网换算；非零外币余额未填则不显示完整总额。
  /// 这是**当前**金额，历史各月的填写值分别冻结在月度快照里，两者互不覆盖。
  final double? baseValuation;

  /// 信用额度上限（选填，仅信用卡/信用账户 supportsCredit）。设置后展示已用/可用额度。
  final double? creditLimit;

  /// 信用卡账单日（每月 1–28，可选）。花呗类用户可不设置。
  final int? statementDay;

  /// 信用卡还款日（每月 1–28，可选）。设置后展示还款提醒。
  final int? dueDay;

  Account copyWith({
    String? id,
    String? bookId,
    String? name,
    AccountType? type,
    String? groupId,
    double? initialBalance,
    String? iconCode,
    String? note,
    bool? includeInAssets,
    bool? hidden,
    AssetClass? assetClass,
    String? currencyCode,
    String? cardLast4,
    String? cardNumber,
    bool? cardLast4Follows,
    double? baseValuation,
    bool clearBaseValuation = false,
    double? creditLimit,
    bool clearCreditLimit = false,
    int? statementDay,
    bool clearStatementDay = false,
    int? dueDay,
    bool clearDueDay = false,
  }) {
    return Account(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      name: name ?? this.name,
      type: type ?? this.type,
      groupId: groupId ?? this.groupId,
      initialBalance: initialBalance ?? this.initialBalance,
      iconCode: iconCode ?? this.iconCode,
      note: note ?? this.note,
      includeInAssets: includeInAssets ?? this.includeInAssets,
      hidden: hidden ?? this.hidden,
      assetClass: assetClass ?? this.assetClass,
      currencyCode: currencyCode ?? this.currencyCode,
      cardLast4: cardLast4 ?? this.cardLast4,
      cardNumber: cardNumber ?? this.cardNumber,
      cardLast4Follows: cardLast4Follows ?? this.cardLast4Follows,
      baseValuation: clearBaseValuation
          ? null
          : baseValuation ?? this.baseValuation,
      creditLimit: clearCreditLimit ? null : creditLimit ?? this.creditLimit,
      statementDay: clearStatementDay
          ? null
          : statementDay ?? this.statementDay,
      dueDay: clearDueDay ? null : dueDay ?? this.dueDay,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'bookId': bookId,
      'name': name,
      'type': type.name,
      'groupId': groupId,
      'initialBalance': initialBalance,
      'iconCode': iconCode,
      'note': note,
      'includeInAssets': includeInAssets,
      'hidden': hidden,
      'assetClass': assetClass.name,
      'currencyCode': currencyCode,
      'cardLast4': cardLast4,
      'cardNumber': cardNumber,
      'cardLast4Follows': cardLast4Follows,
      if (baseValuation != null) 'baseValuation': baseValuation,
      if (creditLimit != null) 'creditLimit': creditLimit,
      if (statementDay != null) 'statementDay': statementDay,
      if (dueDay != null) 'dueDay': dueDay,
    };
  }

  static Account fromJson(Map<String, Object?> json) {
    return Account(
      id: json['id'] as String,
      bookId: json['bookId'] as String? ?? defaultLedgerBookId,
      name: json['name'] as String? ?? '未命名账户',
      type: AccountType.fromStorage(json['type'] as String?),
      groupId: json['groupId'] as String?,
      initialBalance: (json['initialBalance'] as num? ?? 0).toDouble(),
      iconCode: normalizeAccountIconCode(json['iconCode'] as String?),
      note: json['note'] as String? ?? '',
      includeInAssets: json['includeInAssets'] as bool? ?? true,
      hidden: json['hidden'] as bool? ?? false,
      assetClass: AssetClass.fromStorage(json['assetClass'] as String?),
      currencyCode: (json['currencyCode'] as String? ?? defaultCurrencyCode)
          .toUpperCase(),
      cardLast4: json['cardLast4'] as String? ?? '',
      cardNumber: json['cardNumber'] as String? ?? '',
      // 旧备份（无此字段）默认 false：保留其手填后四位、不因跟随把它冲成空。
      cardLast4Follows: json['cardLast4Follows'] as bool? ?? false,
      baseValuation: (json['baseValuation'] as num?)?.toDouble(),
      creditLimit: (json['creditLimit'] as num?)?.toDouble(),
      statementDay: (json['statementDay'] as num?)?.toInt(),
      dueDay: (json['dueDay'] as num?)?.toInt(),
    );
  }
}

/// 「未归类」分区的稳定标识：资产没有所属银行卡／平台时归入该分区。
/// 它不是真实的 [AccountGroup]，只表示「没有容器」，不写进分组表。
const String ungroupedAccountGroupId = 'ungrouped';

/// 新建资产默认用容器、类别和外币代码命名；同名资产加序号，不影响已有名称。
String defaultAssetName({
  required AppLocalizations l10n,
  required AssetClass assetClass,
  required String currencyCode,
  required String baseCurrencyCode,
  String? containerName,
  Iterable<String> existingNames = const [],
}) {
  final parts = <String>[
    if (containerName != null && containerName.trim().isNotEmpty)
      containerName.trim(),
    assetClass.label(l10n),
    if (currencyCode != baseCurrencyCode) currencyCode,
  ];
  final base = parts.join('·');
  final existing = existingNames.toSet();
  var candidate = base;
  var suffix = 2;
  while (existing.contains(candidate)) {
    candidate = '$base ($suffix)';
    suffix++;
  }
  return candidate;
}

/// 容器内省略重复的容器前缀，存储名称及其他页面显示保持完整。
String assetNameInContainer(Account account, String containerName) {
  final prefix = '$containerName·';
  return account.name.startsWith(prefix) && account.name.length > prefix.length
      ? account.name.substring(prefix.length)
      : account.name;
}

/// 手填本位币估值的字段标签：人民币账本说「对应人民币金额」，其他本位币按币种取名。
String baseCurrencyValuationLabel(
  AppLocalizations l10n,
  String baseCurrencyCode,
) => baseCurrencyCode == 'CNY'
    ? l10n.assetSnapshotManualValue
    : l10n.baseCurrencyAmountLabel(baseCurrencyCode);

/// 从完整卡号提取后四位（只取数字，末四位）。空号返回空串。
String cardLast4Of(String cardNumber) {
  final digits = cardNumber.replaceAll(RegExp(r'\D'), '');
  return digits.length > 4 ? digits.substring(digits.length - 4) : digits;
}

class AccountGroup {
  const AccountGroup({
    required this.id,
    required this.bookId,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String bookId;
  final String name;
  final int sortOrder;

  AccountGroup copyWith({
    String? id,
    String? bookId,
    String? name,
    int? sortOrder,
  }) {
    return AccountGroup(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'bookId': bookId,
      'name': name,
      'sortOrder': sortOrder,
    };
  }

  static AccountGroup fromJson(Map<String, Object?> json) {
    return AccountGroup(
      id: json['id'] as String,
      bookId: json['bookId'] as String? ?? defaultLedgerBookId,
      name: json['name'] as String? ?? '未命名分组',
      sortOrder: json['sortOrder'] as int? ?? 0,
    );
  }
}
