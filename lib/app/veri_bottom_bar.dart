// 停靠底栏的条目绘制组件（本项目自持实现）。
//
// 本文件最早抄写自 `bottom_bar_matu` 1.5.0 的 `BottomBarDoubleBullet`
// （MIT License, Copyright (c) 2021 Tuannvm），随后逐步替换：库的扫线圆弧、飞点与
// 图标摆动都已移除，现在只剩自有实现。
//
// 设计要点：
// - 选中态**完全由 [VeriBottomBar.selectedIndex] 驱动**（单一数据源），组件不自己记
//   选中项、也不延迟回调；父级改变下标即触发切换动效；
// - 反馈只有「图标与标签由灰渐变为强调色」，不旋转、不摆动、不扫线：根导航的位移
//   语义交给页面本身的横向滑动，底栏只负责标出「现在在哪一页」；
// - 图标 State 随元素树自然存活，父级普通重建不重置渐变动画。

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 底栏条目的未选中灰阶，集中在此处；改动会影响底栏观感。
const Color _kUnselectedGrey = veriNavigationUnselected;

@immutable
class VeriBottomBarItem {
  const VeriBottomBarItem({
    required this.iconData,
    this.itemKey,
    this.iconSize = 30,
    this.label,
    this.labelTextStyle,
  });

  final IconData iconData;

  /// 条目的稳定 key，供测试与无障碍按条目定位，不依赖等宽几何。
  ///
  /// 契约（见 `root_navigation.dart`）要求每个样式为条目产出 `<前缀>_nav_item_<下标>`。
  final Key? itemKey;

  final double iconSize;
  final String? label;
  final TextStyle? labelTextStyle;
}

/// 停靠底栏：整宽一行条目，每项是「常显文字 + 图标」。
///
/// 与上游库的差别是**选中状态完全由 [selectedIndex] 驱动**（单一数据源），组件不再
/// 自己记住选中项、也不再延迟回调。颜色默认跟随 `Theme.of(context).colorScheme.primary`，
/// 不会写死成品牌蓝。
class VeriBottomBar extends StatelessWidget {
  const VeriBottomBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    this.onSelect,
    this.height = 71,
    this.color,
    this.backgroundColor = Colors.transparent,
  });

  /// 切换动画的时间尺度。调用方以同一尺度驱动页面切换（页面是弹簧，没有固定
  /// 时长），两者才会同时起步、同时收住。
  static const Duration switchDuration = Duration(milliseconds: 250);

  final List<VeriBottomBarItem> items;
  final int selectedIndex;
  final ValueChanged<int>? onSelect;
  final double height;

  /// 选中项的主色。省略时取当前主题的 `colorScheme.primary`，这样用户切换动态色或
  /// 自定义主题色时底栏会一起跟随，不会被默认值锁成品牌蓝。
  final Color? color;

  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    assert(items.isNotEmpty, '底栏至少要有一个条目');
    assert(
      selectedIndex >= 0 && selectedIndex < items.length,
      'selectedIndex 越界',
    );
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: height,
      child: ColoredBox(
        color: backgroundColor,
        child: Row(
          children: <Widget>[
            for (var index = 0; index < items.length; index++)
              Expanded(
                key: items[index].itemKey,
                // MergeSemantics + selected：条目对 TalkBack 的语义是「一个已选中/未
                // 选中的按钮」，而不是只有名字和点击。缺少 selected 时读屏能念出标签，
                // 却无法告诉用户当前停在第几个 Tab。
                child: MergeSemantics(
                  child: Semantics(
                    selected: selectedIndex == index,
                    child: InkWell(
                      onTap: onSelect == null ? null : () => onSelect!(index),
                      // 底栏表面是不透明的，Material 的溅墨只会画在它下面、永远看不见；
                      // 关掉不可见的涟漪，选中反馈完全交给颜色渐变。
                      splashFactory: NoSplash.splashFactory,
                      highlightColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      child: IgnorePointer(
                        child: _VeriBottomBarIcon(
                          item: items[index],
                          color: accent,
                          selected: selectedIndex == index,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单个底栏条目：图标 + 常显文字。选中时图标与标签由灰渐变为强调色。
class _VeriBottomBarIcon extends StatefulWidget {
  const _VeriBottomBarIcon({
    required this.item,
    required this.color,
    required this.selected,
  });

  final VeriBottomBarItem item;
  final Color color;
  final bool selected;

  @override
  State<_VeriBottomBarIcon> createState() => _VeriBottomBarIconState();
}

class _VeriBottomBarIconState extends State<_VeriBottomBarIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: VeriBottomBar.switchDuration,
      value: widget.selected ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant _VeriBottomBarIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      if (widget.selected) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: double.infinity,
      child: Stack(
        children: <Widget>[
          // 标签固定在条底 5dp，图标区从条顶到条底 10dp。
          Positioned(bottom: 5, left: 0, right: 0, child: _labelWidget()),
          Positioned(
            bottom: widget.item.label != null ? 10 : 0,
            top: 0,
            left: 0,
            right: 0,
            child: _iconWidget(),
          ),
        ],
      ),
    );
  }

  Widget _iconWidget() {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 颜色在动画前半程就插值完，剩下的时间留给标签跟随。
        final color = Color.lerp(
          _kUnselectedGrey,
          widget.color,
          (_controller.value * 2).clamp(0.0, 1.0),
        )!;
        return Icon(
          widget.item.iconData,
          size: widget.item.iconSize,
          color: color,
        );
      },
    );
  }

  Widget _labelWidget() {
    final label = widget.item.label;
    if (label == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Text(
        label,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: (widget.item.labelTextStyle ?? const TextStyle()).copyWith(
          color: Color.lerp(
            _kUnselectedGrey,
            widget.color,
            (_controller.value * 2).clamp(0.0, 1.0),
          ),
        ),
      ),
    );
  }
}
