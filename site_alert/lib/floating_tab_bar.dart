import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'screens/notice_list_screen.dart' show contentMaxWidth;
import 'theme.dart';

class TabItem {
  const TabItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 화면 아래에 떠 있는 알약 모양 탭 바. 선택 표시는 탭을 바꾸면 늘어났다 줄어들며 미끄러져 이동함.
class FloatingTabBar extends StatefulWidget {
  const FloatingTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<TabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends State<FloatingTabBar>
    with SingleTickerProviderStateMixin {
  static const _barHeight = 64.0;
  static const _barPadding = 6.0;

  // 앞쪽 끝이 먼저 가고 뒤쪽 끝이 따라와서, 이동하는 동안 표시가 가로로 늘어났다 줄어듦
  static const _lead = Interval(0, 0.7, curve: Curves.easeOutCubic);
  static const _trail = Interval(0.3, 1, curve: Curves.easeInOutCubic);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: 1,
  );

  // 표시의 양 끝. 탭 칸 폭을 1로 본 위치 (n번째 탭 = n ~ n+1)
  late double _fromLeft = widget.selectedIndex.toDouble();
  late double _fromRight = widget.selectedIndex + 1.0;

  (double, double) _edges(int target) {
    final forward = target + 0.5 >= (_fromLeft + _fromRight) / 2;
    final t = _controller.value;
    return (
      lerpDouble(_fromLeft, target, (forward ? _trail : _lead).transform(t))!,
      lerpDouble(
        _fromRight,
        target + 1,
        (forward ? _lead : _trail).transform(t),
      )!,
    );
  }

  @override
  void didUpdateWidget(FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex) return;
    // 이동 중에 다른 탭을 누르면 지금 위치에서 새로 출발
    final (left, right) = _edges(oldWidget.selectedIndex);
    _fromLeft = left;
    _fromRight = right;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: contentMaxWidth),
          child: Material(
            color: AppColors.tabBand,
            // 띠와 화면 바탕의 밝기 차이가 작아서 옅은 테두리로 경계를 보탬
            shape: StadiumBorder(
              side: BorderSide(color: AppColors.navy.withValues(alpha: 0.12)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Container(
              height: _barHeight,
              padding: const EdgeInsets.all(_barPadding),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cell = constraints.maxWidth / widget.items.length;
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final (left, right) = _edges(widget.selectedIndex);
                      return Stack(
                        children: [
                          Positioned(
                            left: left * cell,
                            width: (right - left) * cell,
                            top: 0,
                            bottom: 0,
                            child: const DecoratedBox(
                              key: ValueKey('tab-indicator'),
                              decoration: ShapeDecoration(
                                shape: StadiumBorder(),
                                color: AppColors.navy,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              for (var i = 0; i < widget.items.length; i++)
                                Expanded(child: _tab(context, i, left, right)),
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int i, double left, double right) {
    final item = widget.items[i];
    final selected = i == widget.selectedIndex;
    // 표시가 이 칸을 덮은 만큼 표시 위의 글자색에 가까워짐
    final left0 = left > i ? left : i.toDouble();
    final right0 = right < i + 1 ? right : i + 1.0;
    final covered = (right0 - left0).clamp(0.0, 1.0);
    final color = Color.lerp(AppColors.mutedNavy, AppColors.card, covered)!;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        customBorder: const StadiumBorder(),
        overlayColor: WidgetStatePropertyAll(
          AppColors.navy.withValues(alpha: 0.08),
        ),
        onTap: () => widget.onSelected(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? item.selectedIcon : item.icon,
                size: 22,
                color: color,
              ),
              const SizedBox(height: 2),
              // 좁은 화면이나 큰 글자 설정에서도 잘리거나 옆 탭과 겹치지 않게 칸 폭에 맞춰 줄임
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  item.label,
                  maxLines: 1,
                  softWrap: false,
                  textScaler: MediaQuery.textScalerOf(context)
                      .clamp(maxScaleFactor: 1.3),
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
