import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../widgets/bite_tab_bar.dart';
import 'discover_screen.dart';
import 'feed_screen.dart';
import 'profile_screen.dart';
import 'saved_screen.dart';
import 'tracked_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Dev convenience: `--dart-define=BITE_INITIAL_TAB=2` boots into that tab.
  int _index = const int.fromEnvironment('BITE_INITIAL_TAB');

  // Tabs are rebuilt on each switch (fade-through swaps subtrees), so any
  // state worth keeping lives in AppState or PageStorage, not in the tab's
  // own State. Scroll offsets and the Saved search query use PageStorage.
  // Order must stay index-aligned with BiteTabBar's _tabs.
  static const _tabs = [
    FeedScreen(),
    SavedScreen(),
    TrackedScreen(),
    DiscoverScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final reduced = reducedMotion(context);
    return Scaffold(
      extendBody: true,
      body: PageTransitionSwitcher(
        duration: reduced ? Duration.zero : BiteMotion.standard,
        transitionBuilder: (child, animation, secondaryAnimation) =>
            FadeThroughTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          fillColor: Colors.transparent,
          child: child,
        ),
        child: KeyedSubtree(
          key: ValueKey<int>(_index),
          child: _tabs[_index],
        ),
      ),
      bottomNavigationBar: BiteTabBar(
        index: _index,
        onChanged: (i) {
          if (i != _index) setState(() => _index = i);
        },
      ),
    );
  }
}
