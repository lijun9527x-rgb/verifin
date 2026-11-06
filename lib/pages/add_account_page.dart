part of 'assets_pages.dart';

/// 「新建银行卡／平台」哨兵：选中后先要求输入名称，再选中新建的容器。
const String _createAccountGroupOption = '__create_account_group__';

class AddAccountPage extends StatefulWidget {
  const AddAccountPage({super.key, this.initialGroupId});

  /// 从银行卡／平台详情进入时预选该容器，省去再选一次。
  final String? initialGroupId;

  @override
  State<AddAccountPage> createState() => _AddAccountPageState();
}

class _AddAccountPageState extends State<AddAccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _cardLast4Controller = TextEditingController();
  final _cardNumberController = TextEditingController();
  final _noteController = TextEditingController();
  AssetClass _assetClass = AssetClass.other;
  AccountType _type = AccountType.onlinePayment;
  String _iconCode = 'wallet';
  late String _groupId;
  String? _currencyCode;
  bool _iconManuallySelected = false;
  // 卡号、额度等能力按需展开：默认只录入「是什么资产、在哪、多少钱」。
  bool _advancedOpen = false;
  // 「后四位跟随完整卡号」开关，新账户默认打开。
  bool _cardLast4Follows = true;
  // 信用类账户的额度 / 账单日 / 还款日：新建时就能填，省去建完再去详情页补一次。
  // 初始余额同样走统一数字键盘（可为负），不再用系统键盘输入。
  double? _balance;
  // 外币资产按手填的人民币金额计入汇总，不要求维护汇率。
  double? _baseValuation;
  double? _creditLimit;
  int? _statementDay;
  int? _dueDay;
  bool _saved = false;
  final EditorExitController _exitController = EditorExitController();

  @override
  void initState() {
    super.initState();
    _groupId = widget.initialGroupId ?? ungroupedAccountGroupId;
    _nameController.addListener(_handleNameChanged);
    _cardLast4Controller.addListener(_handleDraftChanged);
    _cardNumberController.addListener(_handleDraftChanged);
    _noteController.addListener(_handleDraftChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currencyCode ??= VeriFinScope.of(context).activeBook.baseCurrencyCode;
  }

  @override
  void dispose() {
    _nameController.removeListener(_handleNameChanged);
    _cardLast4Controller.removeListener(_handleDraftChanged);
    _cardNumberController.removeListener(_handleDraftChanged);
    _noteController.removeListener(_handleDraftChanged);
    _nameController.dispose();
    _cardLast4Controller.dispose();
    _cardNumberController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final groups = controller.accountGroups;
    final currencyCode =
        _currencyCode ?? controller.activeBook.baseCurrencyCode;
    final currency = CurrencyCatalog.require(currencyCode);
    final l10n = AppLocalizations.of(context);
    // 基金填当前市值，其余填余额：同一字段按资产类别换措辞。
    final balanceLabel = _assetClass.isFund
        ? l10n.accountMarketValueLabel(currencyCode)
        : l10n.accountBalanceCurrencyLabel(currencyCode);

    return UnsavedChangesGuard(
      isDirty: _isDirty,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                children: <Widget>[
                  VeriHeader(
                    title: l10n.accountAdd,
                    showBack: true,
                    actions: <Widget>[
                      SaveHeaderAction(
                        onPressed: _isDirty ? _saveAndExit : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AccountAssetClassField(
                    value: _assetClass,
                    onChanged: (value) => setState(() => _assetClass = value),
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    key: const Key('add_account_group'),
                    label: l10n.accountGroupLabel,
                    value: _groupLabel(groups),
                    icon: Icons.account_balance_outlined,
                    onTap: () => _pickAccountGroup(groups),
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    key: const Key('account_currency_select_field'),
                    label: l10n.commonCurrency,
                    value:
                        '${currency.code} · ${currency.nameForLocale(Localizations.localeOf(context).toLanguageTag())}',
                    icon: Icons.currency_exchange,
                    onTap: _pickCurrency,
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    key: const Key('add_account_balance'),
                    label: balanceLabel,
                    value: _balance == null
                        ? l10n.notSet
                        : formatUserMoney(_balance!, currencyCode),
                    icon: Icons.account_balance_wallet_outlined,
                    onTap: _pickBalance,
                  ),
                  if (currencyCode !=
                      controller.activeBook.baseCurrencyCode) ...<Widget>[
                    const SizedBox(height: 10),
                    SelectField(
                      key: const Key('add_account_base_valuation'),
                      label: baseCurrencyValuationLabel(
                        l10n,
                        controller.activeBook.baseCurrencyCode,
                      ),
                      value: _baseValuation == null
                          ? l10n.notSet
                          : formatUserMoney(
                              _baseValuation!,
                              controller.activeBook.baseCurrencyCode,
                            ),
                      icon: Icons.payments_outlined,
                      onTap: _pickBaseValuation,
                    ),
                  ],
                  const SizedBox(height: 10),
                  SelectField(
                    key: const Key('account_icon_select_field'),
                    label: l10n.accountIconLabel,
                    value: iconLabelForCode(l10n, _iconCode),
                    leading: AccountIconBox(iconCode: _iconCode, size: 28),
                    onTap: _pickAccountIcon,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _noteController,
                    maxLines: 1,
                    decoration: InputDecoration(
                      labelText: l10n.accountNoteLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildAdvancedSection(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 账户类型只控制卡号、信用额度等能力，普通资产不必先做这个选择。
  Widget _buildAdvancedSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.72);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            key: const Key('add_account_advanced_toggle'),
            borderRadius: BorderRadius.circular(veriRadiusSm),
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  Icon(Icons.credit_card_outlined, size: 18, color: muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.accountAdvancedSection,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: muted,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _advancedOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.42),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_advancedOpen) ...<Widget>[
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('add_account_custom_name'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.accountCustomNameLabel,
                hintText: _defaultName(),
              ),
            ),
            const SizedBox(height: 10),
            AnchoredMenuChoice<AccountType>(
              key: const Key('add_account_type_choice'),
              values: AccountType.values,
              selected: _type,
              idOf: (value) => 'add_account_type_${value.name}',
              labelOf: (value) => value.label(AppLocalizations.of(context)),
              subtitleOf: (value) =>
                  value.capabilityHint(AppLocalizations.of(context)),
              onSelected: (value) => setState(() => _type = value),
              semanticLabel: l10n.accountTypePickerTitle,
              builder: (context, openMenu, menuOpen) => SelectField(
                label: l10n.accountTypeLabel,
                value: _type.label(l10n),
                icon: Icons.category_outlined,
                onTap: openMenu,
              ),
            ),
            if (_type.supportsCardLast4) ...<Widget>[
              const SizedBox(height: 10),
              CardNumberFields(
                numberController: _cardNumberController,
                last4Controller: _cardLast4Controller,
                follows: _cardLast4Follows,
                onFollowsChanged: (value) =>
                    setState(() => _cardLast4Follows = value),
              ),
            ],
            if (_type.supportsCredit) ...<Widget>[
              const SizedBox(height: 10),
              SelectField(
                key: const Key('add_account_credit_limit'),
                label: l10n.creditLimitLabel,
                value: _creditLimit == null
                    ? l10n.notSet
                    : formatUserMoney(
                        _creditLimit!,
                        _currencyCode ?? defaultCurrencyCode,
                      ),
                icon: Icons.speed_outlined,
                onTap: _pickCreditLimit,
              ),
              const SizedBox(height: 10),
              SelectField(
                key: const Key('add_account_statement_day'),
                label: l10n.statementDay,
                value: _statementDay == null
                    ? l10n.notSet
                    : l10n.monthlyDayLabel(_statementDay!),
                icon: Icons.event_repeat_outlined,
                onTap: () => _pickBillingDay(isDue: false),
              ),
              const SizedBox(height: 10),
              SelectField(
                key: const Key('add_account_due_day'),
                label: l10n.dueDay,
                value: _dueDay == null
                    ? l10n.notSet
                    : l10n.monthlyDayLabel(_dueDay!),
                icon: Icons.event_available_outlined,
                onTap: () => _pickBillingDay(isDue: true),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _pickAccountIcon() async {
    final selected = await showAccountIconSheet(
      context: context,
      selected: _iconCode,
    );
    if (selected != null) {
      setState(() {
        _iconCode = selected;
        _iconManuallySelected = true;
      });
    }
  }

  Future<void> _pickCurrency() async {
    var controller = VeriFinScope.of(context);
    if (controller.activeBook.currencySetupStatus ==
        CurrencySetupStatus.legacyUnconfirmed) {
      final confirmed = await confirmLegacyLedgerCurrency(
        context: context,
        book: controller.activeBook,
      );
      if (!mounted || !confirmed) return;
      controller = VeriFinScope.of(context);
      setState(() => _currencyCode = controller.activeBook.baseCurrencyCode);
    }
    final selected = await showCurrencyPickerSheet(
      context: context,
      title: AppLocalizations.of(context).selectAccountCurrency,
      selectedCode: _currencyCode,
      preferredCodes: controller.accounts.map(
        (account) => account.currencyCode,
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _currencyCode = selected.code;
        // 换回本位币后不再需要单独填写金额。
        if (selected.code == controller.activeBook.baseCurrencyCode) {
          _baseValuation = null;
        }
      });
    }
  }

  /// 外币资产的本位币金额：直接填数字，不输入汇率、不联网换算。
  Future<void> _pickBaseValuation() async {
    final baseCode = VeriFinScope.of(context).activeBook.baseCurrencyCode;
    final value = await showNumberPadSheet(
      context,
      title: baseCurrencyValuationLabel(AppLocalizations.of(context), baseCode),
      initialAmount: _baseValuation,
      allowNegative: true,
      allowZero: true,
      currencyCode: baseCode,
    );
    if (value == null || !mounted) {
      return;
    }
    setState(() => _baseValuation = value);
  }

  void _handleNameChanged() {
    if (!_iconManuallySelected) {
      final suggested = suggestedAccountIconCode(_nameController.text);
      if (suggested != null) {
        _iconCode = suggested;
      }
    }
    _handleDraftChanged();
  }

  void _handleDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickAccountGroup(List<AccountGroup> groups) async {
    final l10n = AppLocalizations.of(context);
    final values = <String>[
      ungroupedAccountGroupId,
      ...groups.map((group) => group.id),
      _createAccountGroupOption,
    ];
    final selected = await showOptionSheet<String>(
      context: context,
      title: l10n.accountGroupPickerTitle,
      values: values,
      selected: _groupId,
      labelOf: (value) => switch (value) {
        ungroupedAccountGroupId => l10n.assetsUngrouped,
        _createAccountGroupOption => l10n.groupAdd,
        _ => _groupName(groups, value),
      },
    );
    if (selected == null || !mounted) {
      return;
    }
    if (selected != _createAccountGroupOption) {
      setState(() => _groupId = selected);
      return;
    }
    final name = await showTextInputDialog(
      context: context,
      title: l10n.groupAdd,
      label: l10n.groupNameLabel,
    );
    if (name == null || !mounted) {
      return;
    }
    final controller = VeriFinScope.of(context);
    if (!await controller.addAccountGroup(name) || !mounted) {
      return;
    }
    // 新建的容器 sortOrder 最大，即 accountGroups 的最后一项。
    setState(() => _groupId = controller.accountGroups.last.id);
  }

  String _groupLabel(List<AccountGroup> groups) {
    if (_groupId == ungroupedAccountGroupId) {
      return AppLocalizations.of(context).assetsUngrouped;
    }
    return _groupName(groups, _groupId);
  }

  String _groupName(List<AccountGroup> groups, String groupId) {
    final matching = groups.where((group) => group.id == groupId);
    return matching.isEmpty
        ? AppLocalizations.of(context).assetsUngrouped
        : matching.first.name;
  }

  bool get _isDirty {
    final balanceChanged = _balance != null;
    return !_saved &&
        (_nameController.text.trim().isNotEmpty ||
            balanceChanged ||
            _baseValuation != null ||
            _assetClass != AssetClass.other ||
            _type != AccountType.onlinePayment ||
            _iconCode != 'wallet' ||
            _groupId != ungroupedAccountGroupId ||
            _currencyCode !=
                VeriFinScope.of(context).activeBook.baseCurrencyCode ||
            _noteController.text.trim().isNotEmpty ||
            (_type.supportsCardLast4 &&
                (_cardNumberController.text.trim().isNotEmpty ||
                    cardLast4Of(_cardLast4Controller.text).isNotEmpty ||
                    !_cardLast4Follows)) ||
            (_type.supportsCredit &&
                (_creditLimit != null ||
                    _statementDay != null ||
                    _dueDay != null)));
  }

  Future<void> _pickCreditLimit() async {
    final code = _currencyCode ?? defaultCurrencyCode;
    final value = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).creditLimitEditTitle,
      initialAmount: _creditLimit,
      allowZero: true,
      currencyCode: code,
      maxFractionDigits: CurrencyCatalog.require(code).minorUnit,
    );
    if (value == null || !mounted) {
      return;
    }
    setState(() => _creditLimit = value <= 0 ? null : value);
  }

  /// 初始余额：信用卡 / 贷款类账户本来就可能是负数，因此开放首位负号并允许 0。
  Future<void> _pickBalance() async {
    final code =
        _currencyCode ?? VeriFinScope.of(context).activeBook.baseCurrencyCode;
    final value = await showNumberPadSheet(
      context,
      title: _assetClass.isFund
          ? AppLocalizations.of(context).accountMarketValueLabel(code)
          : AppLocalizations.of(context).accountBalanceCurrencyLabel(code),
      initialAmount: _balance,
      allowNegative: true,
      allowZero: true,
      currencyCode: code,
    );
    if (value == null || !mounted) {
      return;
    }
    setState(() => _balance = value);
  }

  /// 选择账单日 / 还款日（1–28 或不设置）。
  Future<void> _pickBillingDay({required bool isDue}) async {
    const clearValue = 0;
    final current = (isDue ? _dueDay : _statementDay) ?? clearValue;
    final selected = await showOptionSheet<int>(
      context: context,
      title: isDue
          ? AppLocalizations.of(context).pickDueDay
          : AppLocalizations.of(context).pickStatementDay,
      values: <int>[clearValue, for (var day = 1; day <= 28; day++) day],
      selected: current,
      labelOf: (value) => value == clearValue
          ? AppLocalizations.of(context).clearOption
          : AppLocalizations.of(context).monthlyDayLabel(value),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      if (isDue) {
        _dueDay = selected == clearValue ? null : selected;
      } else {
        _statementDay = selected == clearValue ? null : selected;
      }
    });
  }

  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      setState(() => _saved = true);
      _exitController.exit();
    }
  }

  String _defaultName() {
    final controller = VeriFinScope.of(context);
    final group = controller.accountGroups
        .where((group) => group.id == _groupId)
        .firstOrNull;
    return defaultAssetName(
      l10n: AppLocalizations.of(context),
      assetClass: _assetClass,
      currencyCode: _currencyCode ?? controller.activeBook.baseCurrencyCode,
      baseCurrencyCode: controller.activeBook.baseCurrencyCode,
      containerName: group?.name,
      existingNames: controller.accounts.map((account) => account.name),
    );
  }

  Future<bool> _save() async {
    if (!_formKey.currentState!.validate()) {
      return false;
    }
    final controller = VeriFinScope.of(context);
    return controller.addAccountDraft(
      Account(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        bookId: controller.activeBook.id,
        name: _nameController.text.trim().isEmpty
            ? _defaultName()
            : _nameController.text.trim(),
        assetClass: _assetClass,
        type: _type,
        groupId: _groupId,
        initialBalance: _balance ?? 0,
        currencyCode: _currencyCode ?? controller.activeBook.baseCurrencyCode,
        baseValuation:
            _currencyCode == null ||
                _currencyCode == controller.activeBook.baseCurrencyCode
            ? null
            : _baseValuation,
        iconCode: _iconCode,
        note: _noteController.text.trim(),
        includeInAssets: true,
        hidden: false,
        cardLast4: _type.supportsCardLast4
            ? cardLast4Of(_cardLast4Controller.text)
            : '',
        cardNumber: _type.supportsCardLast4
            ? _cardNumberController.text.trim()
            : '',
        cardLast4Follows: _type.supportsCardLast4 ? _cardLast4Follows : true,
        creditLimit: _type.supportsCredit ? _creditLimit : null,
        statementDay: _type.supportsCredit ? _statementDay : null,
        dueDay: _type.supportsCredit ? _dueDay : null,
      ),
    );
  }
}
