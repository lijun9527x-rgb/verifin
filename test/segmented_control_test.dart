import 'dart:math' as math;

import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';

/// 分段控件子树里最大的旋转角（弧度）。
///
/// `Transform.rotate` 生成 `Matrix4.rotationZ`，第二行第一列即 sin(angle)；平移与缩放
/// 的那一项都是 0，因此这个值只反映旋转。断言它接近 0 就等于「文字没有转动」。
double _maxLabelRotation(WidgetTester tester) {
  var maxAngle = 0.0;
  final transforms = find.descendant(
    of: find.byType(VeriSegmentedControl<String>),
    matching: find.byType(Transform),
  );
  for (final element in transforms.evaluate()) {
    final matrix = (element.widget as Transform).transform;
    maxAngle = math.max(
      maxAngle,
      math.atan2(matrix.storage[1], matrix.storage[0]).abs(),
    );
  }
  return maxAngle;
}

void main() {
  /// 轨道的横向内边距与选项间隙，必须与 `VeriSegmentedControl` 内部取值一致。
  const trackPadding = 2.0;
  const trackSpacing = 2.0;

  /// 一个选项槽的宽度：可用宽度扣掉轨道内边距与选项间隙后按选项数均分。
  double slotWidth(double availableWidth, int count) =>
      (availableWidth - trackPadding * 2 - trackSpacing * (count - 1)) / count;

  /// 在宽度受限的容器里渲染（`ListView` 子项、拉伸的列等都是这种紧约束）。
  Future<void> pumpStretched(
    WidgetTester tester, {
    required int count,
    required double width,
  }) {
    final values = <String>[for (var i = 0; i < count; i++) '选项$i'];
    return tester.pumpWidget(
      MaterialApp(
        theme: buildVeriFinTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: VeriSegmentedControl<String>(
                values: values,
                selected: values.first,
                labelOf: (value) => value,
                onChanged: (_) {},
                semanticLabel: '测试分段',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpControl(
    WidgetTester tester, {
    required List<String> values,
    required String selected,
    required ValueChanged<String> onChanged,
    bool compact = false,
    Color? Function(String)? accentOf,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildVeriFinTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: VeriSegmentedControl<String>(
                values: values,
                selected: selected,
                labelOf: (value) => value,
                onChanged: onChanged,
                compact: compact,
                accentOf: accentOf,
                semanticLabel: '测试分段',
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('渲染全部选项并标出当前选中', (tester) async {
    await pumpControl(
      tester,
      values: const <String>['支出', '收入', '转账'],
      selected: '收入',
      onChanged: (_) {},
    );

    // 每个选项只渲染一份文字：标签固定在各自槽位里，选中底板是唯一的动效层。
    // 曾经用 `.rolling` 时选中项会被额外渲染一份到胶囊前景，这里断言不允许再出现。
    expect(find.text('支出'), findsOneWidget);
    expect(find.text('收入'), findsOneWidget);
    expect(find.text('转账'), findsOneWidget);
  });

  testWidgets('点击未选中项回调，点击当前项不回调', (tester) async {
    final tapped = <String>[];
    await pumpControl(
      tester,
      values: const <String>['支出', '收入'],
      selected: '支出',
      onChanged: tapped.add,
    );

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    expect(tapped, <String>['收入']);
  });

  // 回归：曾经用 `AnimatedToggleSwitch.rolling`，它按「移动距离 ÷ 胶囊半径」算旋转角，
  // 在宽控件里角度远超一圈，表现为「文字转一圈再移动」。切换过程中（不只是结束时）
  // 都不允许出现旋转。
  testWidgets('切换过程中标签文字不旋转', (tester) async {
    await pumpControl(
      tester,
      values: const <String>['支出', '收入', '转账'],
      selected: '支出',
      onChanged: (_) {},
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('转账'));
    await tester.pump();
    // 动画中段：只看 `pumpAndSettle` 后的终态会漏掉旋转。
    await tester.pump(const Duration(milliseconds: 130));
    expect(_maxLabelRotation(tester), lessThan(0.01));

    await tester.pumpAndSettle();
    expect(_maxLabelRotation(tester), lessThan(0.01));
  });

  testWidgets('提供整组与单项的无障碍语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpControl(
      tester,
      values: const <String>['支出', '收入'],
      selected: '收入',
      onChanged: (_) {},
    );

    // 第三方控件本身不带语义，包装层必须补上：整组标注当前值。
    final node = tester.getSemantics(find.bySemanticsLabel('测试分段'));
    expect(node.label, '测试分段');
    expect(node.value, '收入');
    handle.dispose();
  });

  testWidgets('选中项使用 accentOf 的强调色', (tester) async {
    await pumpControl(
      tester,
      values: const <String>['支出', '收入'],
      selected: '支出',
      onChanged: (_) {},
      accentOf: (value) => value == '支出' ? veriExpense : null,
    );
    await tester.pumpAndSettle();

    final colors = tester
        .widgetList<Text>(find.text('支出'))
        .map((text) => text.style?.color)
        .toList();
    expect(colors, contains(veriExpense));
  });

  testWidgets('紧凑档高度小于常规档', (tester) async {
    await pumpControl(
      tester,
      values: const <String>['日', '月'],
      selected: '日',
      onChanged: (_) {},
    );
    final regular = tester.getSize(find.byType(VeriSegmentedControl<String>));

    await pumpControl(
      tester,
      values: const <String>['日', '月'],
      selected: '日',
      onChanged: (_) {},
      compact: true,
    );
    final dense = tester.getSize(find.byType(VeriSegmentedControl<String>));

    expect(dense.height, lessThan(regular.height));
  });

  // 胶囊宽度必须等于**一个选项槽的宽度**。第三方控件只在「选项总宽超过可用宽度」
  // 时把胶囊一起等比缩小；可用宽度有富余时它把余量全摊进选项间隙，胶囊仍停在传入
  // 的固定宽度上。这里按槽位宽度传入，避免选项越少胶囊越窄。
  for (final count in <int>[2, 3, 4]) {
    testWidgets('$count 项时胶囊铺满一个选项槽', (tester) async {
      const controlWidth = 361.0;
      await pumpStretched(tester, count: count, width: controlWidth);

      final control = tester.widget<AnimatedToggleSwitch<String>>(
        find.byType(AnimatedToggleSwitch<String>),
      );
      expect(
        control.indicatorSize.width,
        closeTo(slotWidth(controlWidth, count), 0.01),
        reason: '$count 项时胶囊应等于槽宽，而不是固定宽度',
      );
      // 胶囊 + 选项间隙必须正好铺满轨道：这样每个槽位都被胶囊整除，不会出现
      // 「胶囊窄、槽位宽」的错位。
      final rendered = tester.getSize(
        find.byType(VeriSegmentedControl<String>),
      );
      expect(rendered.width, closeTo(controlWidth, 0.01));
      expect(
        control.indicatorSize.width * count + trackSpacing * (count - 1),
        closeTo(rendered.width - trackPadding * 2, 0.01),
      );
    });
  }

  testWidgets('宽度不受限时沿用原来的紧凑/常规固定宽度', (tester) async {
    // `Row` 里不加 `Expanded`：横向约束无限，此时没有「槽宽」可算，退回原值。
    // 覆盖这条是为了避免为修「太窄」把本来正常的场景一起改掉。
    Future<double> indicatorWidthOf({required bool compact}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVeriFinTheme(Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              height: 60,
              child: Row(
                children: <Widget>[
                  VeriSegmentedControl<String>(
                    values: const <String>['日', '月'],
                    selected: '日',
                    compact: compact,
                    labelOf: (value) => value,
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return tester
          .widget<AnimatedToggleSwitch<String>>(
            find.byType(AnimatedToggleSwitch<String>),
          )
          .indicatorSize
          .width;
    }

    expect(await indicatorWidthOf(compact: false), 92);
    expect(await indicatorWidthOf(compact: true), 58);
  });
}
