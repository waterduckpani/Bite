import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../data/palettes.dart';
import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/pressable.dart';
import '../widgets/saved_tile.dart';
import 'reader_screen.dart';

/// Topic browser: a snapping "trending" carousel on top of a grid of
/// category tiles that morph open into their topic's list.
class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    // One representative story per topic, favouring the freshest mock data.
    final trending = [
      for (final c in Category.values)
        if (state.articlesIn(c).isNotEmpty) state.articlesIn(c).first,
    ];

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        key: const PageStorageKey('discover.scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Discover', style: display(size: 34, weight: 680)),
                  const SizedBox(height: 2),
                  Text(
                    'Browse every topic in the stack',
                    style: sans(size: 13, color: bite.muted),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _Entrance(
              index: 0,
              child: Padding(
                padding: const EdgeInsets.only(left: 24, bottom: 10),
                child: Text('TRENDING TODAY',
                    style: caps(size: 10.5, color: bite.muted)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _Entrance(
              index: 1,
              child: _TrendingCarousel(articles: trending),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(24, 24, 24,
                24 + kBiteTabBarReserved + MediaQuery.paddingOf(context).bottom),
            sliver: SliverGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45,
              children: [
                for (final (i, c) in Category.values.indexed)
                  _Entrance(
                    index: 2 + i,
                    child: _CategoryTile(
                      category: c,
                      count: state.articlesIn(c).length,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and drifts a child up into place, staggered by [index]. Replays on
/// each visit to the tab, which gives Discover its entrance. Collapses to
/// nothing under reduced motion.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 30 * widget.index), () {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (reducedMotion(context)) return widget.child;
    return AnimatedSlide(
      offset: _in ? Offset.zero : const Offset(0, 0.06),
      duration: BiteMotion.gentle,
      curve: BiteMotion.easeOut,
      child: AnimatedOpacity(
        opacity: _in ? 1 : 0,
        duration: BiteMotion.gentle,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Snapping horizontal carousel of one standout story per topic.
class _TrendingCarousel extends StatelessWidget {
  const _TrendingCarousel({required this.articles});

  final List<Article> articles;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 168,
      child: PageView.builder(
        key: const PageStorageKey('discover.trending'),
        controller: PageController(viewportFraction: 0.86),
        padEnds: false,
        itemCount: articles.length,
        itemBuilder: (context, i) {
          final article = articles[i];
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 24 : 6, right: 6),
            child: Pressable(
              onTap: () => ReaderScreen.open(context, article),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: article.palette.gradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(article.category.label.toUpperCase(),
                              style: caps(
                                  size: 9,
                                  color:
                                      Colors.white.withValues(alpha: 0.8))),
                          const SizedBox(height: 6),
                          Text(
                            article.headline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: display(
                                size: 18,
                                weight: 640,
                                height: 1.2,
                                color: Colors.white),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${article.source}  ·  ${article.timeAgo}',
                            style: sans(
                                size: 11,
                                color: Colors.white.withValues(alpha: 0.75)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A topic tile that morphs (container transform) into the topic's list.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.count});

  final Category category;
  final int count;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    // Live categories can be momentarily empty; fall back to the canonical
    // palette rather than sampling the (absent) first story.
    final articles = state.articlesIn(category);
    final palette = articles.isEmpty
        ? paletteFor(category).gradient
        : articles.first.palette.gradient;
    final reduced = reducedMotion(context);

    return OpenContainer(
      tappable: false,
      transitionDuration:
          reduced ? const Duration(milliseconds: 60) : BiteMotion.gentle,
      transitionType: ContainerTransitionType.fade,
      closedElevation: 0,
      openElevation: 0,
      closedColor: bite.card,
      middleColor: bite.paper,
      openColor: bite.paper,
      closedShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      openBuilder: (context, _) => _CategoryList(category: category),
      closedBuilder: (context, openContainer) => Pressable(
        onTap: openContainer,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(gradient: palette),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(category.label,
                  style: display(size: 21, weight: 640, color: Colors.white)),
              const SizedBox(height: 2),
              Text(
                '$count ${count == 1 ? 'story' : 'stories'}',
                style: sans(
                  size: 11.5,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final articles = AppScope.of(context).articlesIn(category);
    return Scaffold(
      appBar: AppBar(
        title: Text(category.label, style: display(size: 22, weight: 660)),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(24),
        itemCount: articles.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) => SavedTile(
          article: articles[i],
          onTap: () => ReaderScreen.open(context, articles[i]),
        ),
      ),
    );
  }
}
