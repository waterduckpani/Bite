import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'glass.dart';

class BiteTab {
  const BiteTab(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const _tabs = [
  BiteTab('Feed', Icons.style_outlined, Icons.style),
  BiteTab('Saved', Icons.bookmark_border, Icons.bookmark),
  BiteTab('Discover', Icons.explore_outlined, Icons.explore),
  BiteTab('Profile', Icons.person_outline, Icons.person),
];

/// Height of the tab bar's touch area, excluding its floating margins and the
/// bottom safe-area inset. Screens use this to pad scroll content so nothing
/// hides permanently behind the floating bar.
const double kBiteTabBarHeight = 58;

/// Vertical space the floating tab bar reserves at the bottom of a screen,
/// including its margin. The system inset is added on top by callers.
const double kBiteTabBarReserved = kBiteTabBarHeight + 20;

/// Floating glass tab bar shared by all main screens.
///
/// Rendered as a Liquid Glass capsule that content scrolls behind on iOS 26,
/// and as a solid paper capsule on other platforms.
class BiteTabBar extends StatelessWidget {
  const BiteTabBar({super.key, required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final reduced = reducedMotion(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: GlassSurface(
          borderRadius: 28,
          blur: 10,
          thickness: 18,
          child: SizedBox(
            height: kBiteTabBarHeight,
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onChanged(i);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedScale(
                            scale: i == index && !reduced ? 1.12 : 1.0,
                            duration: BiteMotion.standard,
                            curve: BiteMotion.spring,
                            child: Icon(
                              i == index ? _tabs[i].activeIcon : _tabs[i].icon,
                              size: 22,
                              color: i == index ? bite.ink : bite.muted,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _tabs[i].label,
                            style: sans(
                              size: 10,
                              weight: i == index
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: i == index ? bite.ink : bite.muted,
                              spacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
