import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';

import 'support/test_harness.dart';

Account _account(String id) => Account(
  id: id,
  bookId: 'default',
  name: id,
  type: AccountType.debitCard,
  groupId: null,
  initialBalance: 1000,
  iconCode: 'wallet',
  note: '',
  includeInAssets: true,
  hidden: false,
);

LedgerEntry _entry(
  String id, {
  String accountId = 'other',
  EntryType type = EntryType.expense,
}) => LedgerEntry(
  id: id,
  bookId: 'default',
  type: type,
  amount: 10,
  categoryId: type == EntryType.income ? 'salary' : 'dining',
  accountId: accountId,
  note: '',
  occurredAt: DateTime(2026, 1, 5),
);

void main() {
  useTestDatabases();

  test('指定账户隐藏后拒绝新增支出，避免静默扣错账户', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('pay'));
    await controller.addAccountDraft(_account('other'));
    controller.setDefaultAccountId('pay');
    await controller.saveAccountDraft(_account('pay').copyWith(hidden: true));
    final result = await controller.saveEntryAggregateDraftResult(
      entry: _entry('blocked'),
      isNew: true,
    );
    expect(result, isA<EntrySaveValidationFailure>());
    expect(
      (result as EntrySaveValidationFailure).code,
      EntryValidationCode.invalidExpenseAccount,
    );
    expect(controller.entries, isEmpty);
  });

  test('手动和AI聚合新增支出统一扣款，编辑历史不迁移账户', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('pay'));
    await controller.addAccountDraft(_account('other'));
    controller.setDefaultAccountId('pay');
    expect(
      await controller.saveEntryAggregateDraft(
        entry: _entry('new'),
        isNew: true,
      ),
      isTrue,
    );
    expect(controller.entries.single.accountId, 'pay');
    expect(
      controller.accountBalance(
        controller.accounts.firstWhere((a) => a.id == 'pay'),
      ),
      990,
    );
    controller.setDefaultAccountId('other');
    expect(
      await controller.saveEntryAggregateDraft(
        entry: controller.entries.single.copyWith(note: 'edit'),
        isNew: false,
      ),
      isTrue,
    );
    expect(controller.entries.single.accountId, 'pay');
  });

  test('导入确认时统一支出账户，收入仍保留到账账户', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('pay'));
    await controller.addAccountDraft(_account('other'));
    controller.setDefaultAccountId('pay');
    expect(
      await controller.applyImportEntries(
        entries: [
          _entry('expense'),
          _entry('income', type: EntryType.income),
        ],
        candidateAccounts: [],
        candidateCategories: [],
      ),
      isTrue,
    );
    expect(
      controller.entries.firstWhere((e) => e.id == 'expense').accountId,
      'pay',
    );
    expect(
      controller.entries.firstWhere((e) => e.id == 'income').accountId,
      'other',
    );
  });

  test('外币支出使用冻结本位币金额扣人民币账户', () async {
    final controller = await makeController();
    await controller.addAccountDraft(_account('pay'));
    controller.setDefaultAccountId('pay');
    final entry = _entry('foreign', accountId: '').copyWith(
      currencyCode: 'USD',
      amount: 10,
      baseAmount: 71,
      clearAccountAmount: true,
    );
    expect(
      await controller.saveEntryAggregateDraft(entry: entry, isNew: true),
      isTrue,
    );
    expect(controller.entries.single.accountId, 'pay');
    expect(controller.entries.single.accountAmount, 71);
    expect(controller.entries.single.baseAmount, 71);
  });
}
