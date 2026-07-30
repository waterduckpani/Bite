import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
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
  BiteTab('Tracked', Icons.track_changes_outlined, Icons.track_changes),
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
  const BiteTabBar(
      {super.key,
      required this.index,
      required this.onChanged,
      this.itemKeys});

  /// The selected tab, or any out-of-range value for "none selected" (the
  /// walkthrough's tour starts with nothing chosen).
  final int index;

  final ValueChanged<int> onChanged;

  /// Optional per-tab keys, so a caller can measure where a tab actually sits.
  ///
  /// The Phase 17 walkthrough spotlights one tab at a time on the REAL tab
  /// bar, and a spotlight has to be cut out of the real geometry: guessing it
  /// from "five equal columns" would drift the moment the bar's padding or the
  /// safe-area inset changed. Ignored (and unmeasured) when null, which is
  /// every live use.
  final List<GlobalKey>? itemKeys;

  /// How many tabs the bar has, for callers that walk them.
  static int get tabCount => _tabs.length;

  /// The tab labels, in bar order.
  static List<String> get tabLabels => [for (final t in _tabs) t.label];

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final reduced = reducedMotion(context);
    final unread = AppScope.of(context).trackerUnreadCount;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: GlassSurface(
          child: SizedBox(
            height: kBiteTabBarHeight,
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    key: itemKeys != null && i < itemKeys!.length
                        ? itemKeys![i]
                        : null,
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
                            child: _TabIcon(
                              icon: i == index
                                  ? _tabs[i].activeIcon
                                  : _tabs[i].icon,
                              color: i == index ? bite.ink : bite.muted,
                              // Unread developments badge (Tracked tab only).
                              badge: _tabs[i].label == 'Tracked' ? unread : 0,
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

/// A tab icon with an optional unread-count badge pinned to its top-right.
class _TabIcon extends StatelessWidget {
  const _TabIcon({required this.icon, required this.color, this.badge = 0});

  final IconData icon;
  final Color color;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final icon0 = Icon(icon, size: 22, color: color);
    if (badge <= 0) return icon0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon0,
        Positioned(
          top: -5,
          right: -8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: bite.accent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: bite.paper, width: 1.5),
            ),
            child: Text(
              badge > 9 ? '9+' : '$badge',
              textAlign: TextAlign.center,
              style: sans(
                size: 9,
                weight: FontWeight.w700,
                height: 1.2,
                color: bite.onAccent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
