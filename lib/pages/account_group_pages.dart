part of 'assets_pages.dart';

class HiddenAccountsPage extends StatelessWidget {
  const HiddenAccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final accounts = controller.accounts
        .where((account) => account.hidden)
        .toList(growable: false);
    final balances = <Account, double>{
      for (final account in accounts)
        account: controller.accountBalance(account),
    };

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: AppLocalizations.of(context).hiddenAccountsTitle,
                showBack: true,
              ),
              const SizedBox(height: 10),
              if (accounts.isEmpty)
                VeriCard(
                  child: EmptyState(
                    icon: Icons.visibility_off_outlined,
                    title: AppLocalizations.of(
                      context,
                    ).hiddenAccountsEmptyTitle,
                    description: AppLocalizations.of(
                      context,
                    ).hiddenAccountsEmptyDesc,
                  ),
                )
              else
                AccountSectionCard(
                  title: AppLocalizations.of(context).hiddenAccountsTitle,
                  accounts: _sortedAccounts(accounts),
                  balances: balances,
                  onAccountTap: (account) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            AccountDetailPage(account: account),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个资金容器（银行卡／平台）详情：在这里查看和添加该容器里的资产项。
/// 容器本身仍复用 AccountGroup，不另存一份可重复计入的余额。
class AccountGroupDetailPage extends StatelessWidget {
  const AccountGroupDetailPage({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final group = controller.accountGroups
        .where((item) => item.id == groupId)
        .firstOrNull;
    final accounts = group == null
        ? const <Account>[]
        : _sortedAccounts(
            controller.accounts.where(
              (account) => account.groupId == groupId && !account.hidden,
            ),
          );
    final balances = <Account, double>{
      for (final account in accounts)
        account: controller.accountBalance(account),
    };

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: group?.name ?? l10n.assetsUngrouped,
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.add,
                    tooltip: l10n.accountAdd,
                    onPressed: () => _openAddAccount(context),
                  ),
                  if (group != null)
                    AnchoredMenuButton(
                      icon: Icons.more_horiz,
                      tooltip: l10n.accountGroupsTitle,
                      entries: _accountGroupMenuEntries(
                        context,
                        group: group,
                        accountCount: accounts.length,
                        onDeleted: () => Navigator.of(context).pop(),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (accounts.isEmpty)
                VeriCard(
                  child: EmptyState(
                    icon: Icons.account_balance_wallet_outlined,
                    title: l10n.assetsEmptyTitle,
                    description: l10n.assetsEmptyDesc,
                    action: FilledButton.icon(
                      onPressed: () => _openAddAccount(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.accountAdd),
                    ),
                  ),
                )
              else ...<Widget>[
                AccountSectionCard(
                  title: l10n.accountsCount(accounts.length),
                  accounts: accounts,
                  balances: balances,
                  nameOf: group == null
                      ? null
                      : (account) => assetNameInContainer(account, group.name),
                  totalText: _assetSectionTotalText(
                    accounts: accounts,
                    valuation: controller.accountBalancesInBase(
                      accounts: accounts.where(
                        (account) => account.includeInAssets,
                      ),
                    ),
                    baseCurrencyCode: controller.activeBook.baseCurrencyCode,
                  ),
                  onAccountTap: (account) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            AccountDetailPage(account: account),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _openAddAccount(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.accountAdd),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openAddAccount(BuildContext context) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => AddAccountPage(initialGroupId: groupId),
        ),
      ),
    );
  }
}

class AccountGroupsPage extends StatefulWidget {
  const AccountGroupsPage({super.key});

  @override
  State<AccountGroupsPage> createState() => _AccountGroupsPageState();
}

class _AccountGroupsPageState extends State<AccountGroupsPage> {
  bool _sorting = false;
  bool _savingOrder = false;
  List<AccountGroup> _draftGroups = <AccountGroup>[];
  List<String> _initialOrder = <String>[];

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final groups = _sorting ? _draftGroups : controller.accountGroups;
    final accounts = controller.accounts;

    return UnsavedChangesGuard(
      isDirty: _isOrderDirty,
      onSave: _saveOrder,
      onDiscard: _discardOrder,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: VeriHeader(
                    title: AppLocalizations.of(context).accountGroupsTitle,
                    showBack: true,
                    actions: <Widget>[
                      if (!_sorting)
                        HeaderAction(
                          icon: Icons.add,
                          tooltip: AppLocalizations.of(context).groupAdd,
                          onPressed: () => _showAccountGroupNameDialog(context),
                        ),
                      SortModeHeaderActions(
                        sorting: _sorting,
                        canSort: groups.length >= 2,
                        dirty: _isOrderDirty,
                        onStart: () => _startSorting(controller),
                        onCancel: _cancelSorting,
                        onSave: _saveOrderAndFinish,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: groups.isEmpty
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 86),
                          children: <Widget>[
                            VeriCard(
                              child: EmptyState(
                                icon: Icons.folder_open_outlined,
                                title: AppLocalizations.of(
                                  context,
                                ).groupsEmptyTitle,
                                description: AppLocalizations.of(
                                  context,
                                ).groupsEmptyDesc,
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 86),
                          children: <Widget>[
                            VeriCard(
                              padding: EdgeInsets.zero,
                              child: ReorderableListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                buildDefaultDragHandles: false,
                                itemCount: groups.length,
                                onReorderItem: _reorderDraft,
                                itemBuilder: (context, index) {
                                  final group = groups[index];
                                  final accountCount = accounts
                                      .where(
                                        (account) =>
                                            _effectiveGroupId(account) ==
                                            group.id,
                                      )
                                      .length;
                                  final Widget row;
                                  if (_sorting) {
                                    row = _AccountGroupManageRow(
                                      index: index,
                                      group: group,
                                      accountCount: accountCount,
                                      sorting: true,
                                    );
                                  } else {
                                    row = AnchoredMenuAnchor(
                                      entries: _accountGroupMenuEntries(
                                        context,
                                        group: group,
                                        accountCount: accountCount,
                                      ),
                                      semanticLabel: group.name,
                                      builder: (context, openMenu, menuOpen) =>
                                          _AccountGroupManageRow(
                                            index: index,
                                            group: group,
                                            accountCount: accountCount,
                                            sorting: false,
                                            // 点击整行进容器，三点才开操作菜单。
                                            onTap: () => unawaited(
                                              Navigator.of(context).push<void>(
                                                MaterialPageRoute<void>(
                                                  builder: (context) =>
                                                      AccountGroupDetailPage(
                                                        groupId: group.id,
                                                      ),
                                                ),
                                              ),
                                            ),
                                            onActions: openMenu,
                                          ),
                                    );
                                  }
                                  return Column(
                                    key: ValueKey(group.id),
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      row,
                                      if (index < groups.length - 1)
                                        const Divider(height: 1),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _isOrderDirty =>
      _sorting &&
      !listEquals(
        _draftGroups.map((group) => group.id).toList(),
        _initialOrder,
      );

  void _startSorting(VeriFinController controller) {
    setState(() {
      _sorting = true;
      _draftGroups = List<AccountGroup>.of(controller.accountGroups);
      _initialOrder = _draftGroups.map((group) => group.id).toList();
    });
  }

  void _reorderDraft(int oldIndex, int newIndex) {
    if (!_sorting ||
        oldIndex < 0 ||
        oldIndex >= _draftGroups.length ||
        newIndex < 0 ||
        newIndex > _draftGroups.length) {
      return;
    }
    setState(() {
      final moved = _draftGroups.removeAt(oldIndex);
      _draftGroups.insert(newIndex.clamp(0, _draftGroups.length), moved);
    });
  }

  Future<bool> _saveOrder() async {
    if (_savingOrder || !_isOrderDirty) {
      return !_isOrderDirty;
    }
    _savingOrder = true;
    final saved = await VeriFinScope.of(context).saveAccountGroupOrderDraft(
      _draftGroups.map((group) => group.id).toList(),
    );
    _savingOrder = false;
    return saved;
  }

  Future<void> _saveOrderAndFinish() async {
    if (await _saveOrder() && mounted) {
      setState(_discardOrder);
    }
  }

  void _discardOrder() {
    _sorting = false;
    _draftGroups = <AccountGroup>[];
    _initialOrder = <String>[];
  }

  Future<void> _cancelSorting() async {
    if (!_isOrderDirty) {
      setState(_discardOrder);
      return;
    }
    final decision = await showUnsavedChangesDialog(context: context);
    if (!mounted) {
      return;
    }
    switch (decision) {
      case EditorExitDecision.save:
        await _saveOrderAndFinish();
      case EditorExitDecision.discard:
        setState(_discardOrder);
      case EditorExitDecision.cancel:
        break;
    }
  }
}

/// 新增或重命名银行卡／平台。分组管理页与资产表单都会用到，统一放这里。
Future<void> _showAccountGroupNameDialog(
  BuildContext context, {
  String? groupId,
}) async {
  final controller = VeriFinScope.of(context);
  final matching = groupId == null
      ? const <AccountGroup>[]
      : controller.accountGroups.where((group) => group.id == groupId);
  final l10n = AppLocalizations.of(context);
  final name = await showTextInputDialog(
    context: context,
    title: groupId == null ? l10n.groupAdd : l10n.groupRenameTitle,
    label: l10n.groupNameLabel,
    initialValue: matching.isEmpty ? '' : matching.first.name,
  );
  if (!context.mounted || name == null) {
    return;
  }
  if (groupId == null) {
    await controller.addAccountGroup(name);
  } else {
    await controller.renameAccountGroup(groupId, name);
  }
}

List<AnchoredMenuEntry> _accountGroupMenuEntries(
  BuildContext context, {
  required AccountGroup group,
  required int accountCount,
  VoidCallback? onDeleted,
}) {
  final l10n = AppLocalizations.of(context);
  return <AnchoredMenuEntry>[
    AnchoredMenuItem(
      id: 'account_group_rename',
      icon: Icons.drive_file_rename_outline,
      title: l10n.commonRename,
      onPressed: () async =>
          _showAccountGroupNameDialog(context, groupId: group.id),
    ),
    const AnchoredMenuDivider(),
    AnchoredMenuItem(
      id: 'account_group_delete',
      icon: Icons.delete_outline,
      title: l10n.commonDelete,
      foregroundColor: Theme.of(context).colorScheme.error,
      onPressed: () async => _deleteAccountGroup(
        context,
        group: group,
        accountCount: accountCount,
        onDeleted: onDeleted,
      ),
    ),
  ];
}

Future<void> _deleteAccountGroup(
  BuildContext context, {
  required AccountGroup group,
  required int accountCount,
  VoidCallback? onDeleted,
}) async {
  final controller = VeriFinScope.of(context);
  final l10n = AppLocalizations.of(context);
  final confirmed = await showConfirmDialog(
    context,
    title: l10n.groupDeleteTitle,
    message: accountCount == 0
        ? l10n.groupDeleteMessage(group.name)
        : l10n.groupDeleteInUseMessage(group.name, accountCount),
    confirmLabel: l10n.commonDelete,
    destructive: true,
  );
  if (!context.mounted || !confirmed) {
    return;
  }
  if (await controller.deleteAccountGroup(group.id)) {
    onDeleted?.call();
  }
}

class _AccountGroupManageRow extends StatelessWidget {
  const _AccountGroupManageRow({
    required this.index,
    required this.group,
    required this.accountCount,
    required this.sorting,
    this.onTap,
    this.onActions,
  });

  final int index;
  final AccountGroup group;
  final int accountCount;
  final bool sorting;
  final VoidCallback? onTap;
  final VoidCallback? onActions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(veriRadiusSm),
        onTap: sorting ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.folder_outlined,
                size: 24,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.78),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      group.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      AppLocalizations.of(context).accountsCount(accountCount),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.48),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (sorting)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.drag_handle,
                      size: 18,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                )
              else
                IconButton(
                  // 行本身是「进入容器」，三点只是该行的操作菜单：两者分开命名，
                  // 也让无障碍读屏不再把两个入口都念成同一个名字。
                  tooltip: AppLocalizations.of(
                    context,
                  ).groupRowActions(group.name),
                  onPressed: onActions,
                  icon: const Icon(Icons.more_vert),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
