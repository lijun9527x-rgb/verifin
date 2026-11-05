import 'package:anchored_menu/anchored_menu.dart';
import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/models.dart';
import '../l10n/app_localizations.dart';

/// 资产类别与账户能力、所属银行卡分开编辑。
class AccountAssetClassField extends StatelessWidget {
  const AccountAssetClassField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AssetClass value;
  final ValueChanged<AssetClass> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnchoredMenuChoice<AssetClass>(
      values: AssetClass.values,
      selected: value,
      idOf: (item) => 'asset_class_${item.name}',
      labelOf: (item) => item.label(l10n),
      onSelected: onChanged,
      semanticLabel: l10n.assetClassLabel,
      builder: (context, openMenu, menuOpen) => SelectField(
        label: l10n.assetClassLabel,
        value: value.label(l10n),
        icon: Icons.layers_outlined,
        onTap: openMenu,
      ),
    );
  }
}
