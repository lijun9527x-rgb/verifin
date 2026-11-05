import '../l10n/app_localizations.dart';
import 'veri_fin_controller.dart';

/// 将交易聚合保存的校验错误码映射为用户可见文案。
///
/// 只把用户可操作的原因展开成具体文案；`invalidAmounts` 仍使用通用兜底，
/// 因为它的底层可能是多种金额/引用问题。内部 scope code 提示重新选择分类/标签。
String entrySaveValidationMessage(
  AppLocalizations l10n,
  EntryValidationCode code,
) {
  return switch (code) {
    EntryValidationCode.staleDraft => l10n.entrySaveStaleDraft,
    EntryValidationCode.invalidAmounts => l10n.entrySaveValidationFailed,
    EntryValidationCode.invalidExpenseAccount => l10n.expenseAccountInvalid,
    EntryValidationCode.invalidRefund => l10n.entrySaveInvalidRefund,
    EntryValidationCode.refundExceedsExpense =>
      l10n.entrySaveRefundExceedsExpense,
    EntryValidationCode.invalidAttachments => l10n.entrySaveInvalidAttachments,
    EntryValidationCode.invalidRememberedRate =>
      l10n.entrySaveInvalidRememberedRate,
    EntryValidationCode.categoryOutOfScope ||
    EntryValidationCode.tagOutOfScope => l10n.entrySaveInvalidScope,
  };
}
