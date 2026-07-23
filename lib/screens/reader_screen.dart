import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/category_chip.dart';
import '../widgets/cover_art.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/reader_cue.dart';
import 'browser_screen.dart';

/// Native reader for stories with licensed full text (Guardian, mock).
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.article});

  final Article article;

  /// Opens [article] the only way its license allows: full-text stories in
  /// this native reader, headline-only stories at the publisher's real page
  /// in the in-app browser. Both morph up out of the card.
  static Future<void> open(BuildContext context, Article article) {
    return Navigator.of(context, rootNavigator: true).push(
      articleRoute(article.hasFullText
          ? ReaderScreen(article: article)
          : BrowserScreen(article: article)),
    );
  }

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  Article get article => widget.article;

  /// Paragraphs to render. Articles arrive as metadata only (bodies are
  /// never persisted), so a Guardian body is fetched on demand through the
  /// guardian-body Edge Function — no news-API key ships in the client.
  /// Null while that fetch is in flight; a failure degrades to the
  /// open-in-browser state below, which needs no key either.
  List<String>? _body;
  bool _bodyFailed = false;
  bool _fetchStarted = false;

  @override
  void initState() {
    super.initState();
    if (article.body.isNotEmpty) {
      _body = article.body;
    } else if (article.provider != ArticleProvider.guardian) {
      _bodyFailed = true;
    }
    // Guardian bodies are fetched from didChangeDependencies — the fetch
    // goes through AppState, and AppScope can't be read during initState.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_body == null && !_bodyFailed && !_fetchStarted) {
      _fetchStarted = true;
      _fetchBody(AppScope.of(context));
    }
  }

  Future<void> _fetchBody(AppState state) async {
    try {
      final body = await state.fetchGuardianBody(article.id);
      if (!mounted) return;
      setState(() {
        if (body.isEmpty) {
          _bodyFailed = true;
        } else {
          _body = body;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _bodyFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final saved = state.isSaved(article);

    return Scaffold(
      backgroundColor: bite.paper,
      extendBody: true,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.zero,
            children: [
              SizedBox(
                height: 360,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    HeroMode(
                      enabled: !reducedMotion(context),
                      child: Hero(
                        tag: article.coverHeroTag,
                        child: CoverArt(article: article, showCredit: true),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      bottom: 18,
                      child: CategoryChip(label: article.category.label),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    24, 22, 24, 32 + 76 + MediaQuery.paddingOf(context).bottom),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HeroMode(
                      enabled: !reducedMotion(context),
                      child: Hero(
                        tag: article.headlineHeroTag,
                        child: Material(
                          type: MaterialType.transparency,
                          child: Text(article.headline,
                              style:
                                  display(size: 30, weight: 560, height: 1.1)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: bite.ink,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            article.author[0],
                            style: sans(
                              size: 14,
                              weight: FontWeight.w600,
                              height: 1,
                              color: bite.paper,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                article.author,
                                style: sans(
                                  size: 13,
                                  weight: FontWeight.w600,
                                  color: bite.ink,
                                ),
                              ),
                              Text(
                                '${article.source}  ·  ${article.timeAgo}  ·  ${article.readMinutes} min read',
                                style: sans(size: 12, color: bite.muted),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Cue matches the reader routing: this native screen is
                        // only reached for full-text stories, so "Read in Bite".
                        ReaderCue(article: article),
                      ],
                    ),
                    // The Bite summary sits above the full text — a standalone
                    // TL;DR while the body loads, and when there is no summary
                    // this block simply doesn't render.
                    if (article.hasSummary) ...[
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                        decoration: BoxDecoration(
                          color: bite.accent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: bite.accent.withValues(alpha: 0.18),
                            width: 0.75,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('THE BITE',
                                style: caps(size: 10, color: bite.accent)),
                            const SizedBox(height: 8),
                            Text(
                              article.aiSummary!,
                              style:
                                  display(size: 16.5, weight: 460, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 16),
                    if (_body == null && !_bodyFailed)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      )
                    else if (_bodyFailed) ...[
                      Text(
                        "Couldn't load this story right now.",
                        style: display(size: 17, weight: 460, height: 1.5),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                            articleRoute(BrowserScreen(article: article))),
                        icon: const Icon(Icons.public, size: 18),
                        label: Text('Read at ${article.source}'),
                      ),
                      const SizedBox(height: 18),
                    ],
                    for (final (i, paragraph)
                        in (_body ?? const <String>[]).indexed) ...[
                        if (i == 1)
                          // Pull-quote: a weighted sage callout set off by a
                          // hairline accent bar.
                          Container(
                            padding: const EdgeInsets.only(left: 16),
                            decoration: BoxDecoration(
                              border: Border(
                                left:
                                    BorderSide(color: bite.accent, width: 2.5),
                              ),
                            ),
                            child: Text(
                              paragraph,
                              style: display(
                                size: 19,
                                weight: 560,
                                height: 1.45,
                                color: bite.accent,
                                spacing: -0.2,
                              ),
                            ),
                          )
                        else
                          Text(
                            paragraph,
                            style: display(
                                size: 16.5, weight: 420, height: 1.62,
                                spacing: 0),
                          ),
                      const SizedBox(height: 18),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Full story at ${article.url}',
                      style: sans(size: 12, color: bite.faint),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Floating glass back button over the hero image.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 16,
            child: GlassSurface(
              borderRadius: 22,
              blur: 8,
              thickness: 14,
              tint: Colors.black.withValues(alpha: 0.18),
              solidColor: bite.ink,
              solidBorder: false,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).pop(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.arrow_back, size: 20, color: bite.paper),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: GlassSurface(
            borderRadius: 30,
            blur: 12,
            thickness: 18,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                children: [
                  _CircleButton(
                    icon: Icons.arrow_back,
                    outlined: true,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Pressable(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: saved ? bite.ink : bite.accent,
                          foregroundColor:
                              saved ? bite.paper : bite.onAccent,
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          state.toggleSaved(article);
                        },
                        icon: Icon(
                            saved ? Icons.bookmark : Icons.bookmark_border,
                            size: 20),
                        label: Text(saved ? 'Saved' : 'Save'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _FollowButton(article: article),
                  const SizedBox(width: 12),
                  Builder(
                    builder: (buttonContext) => _CircleButton(
                      icon: Icons.ios_share,
                      outlined: true,
                      onTap: () {
                        final box =
                            buttonContext.findRenderObject() as RenderBox?;
                        SharePlus.instance.share(ShareParams(
                          uri: Uri.parse(article.url),
                          sharePositionOrigin: box == null
                              ? null
                              : box.localToGlobal(Offset.zero) & box.size,
                        ));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Follow this story" affordance: a circular toggle that seeds a Phase 13
/// tracker from the article. Follow-only (unfollowing lives in tracker
/// management, behind a confirm, so history isn't lost by a stray tap) — once
/// following, it shows a filled accent state and a tap just reaffirms it.
class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final following = state.isFollowing(article.id);
    final atCap = state.trackers.length >= AppState.maxTrackers;

    return Material(
      color: following ? bite.accent : Colors.transparent,
      shape: following
          ? const CircleBorder()
          : CircleBorder(side: BorderSide(color: bite.border, width: 0.75)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          if (following) {
            HapticFeedback.selectionClick();
            _snack(context, 'Following this story');
            return;
          }
          if (atCap) {
            _snack(context,
                'You can follow up to ${AppState.maxTrackers} stories.');
            return;
          }
          HapticFeedback.mediumImpact();
          state.followStory(article);
          _snack(context, 'Following — new developments land in Tracked');
        },
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            following ? Icons.notifications_active : Icons.notifications_none,
            size: 20,
            color: following ? bite.onAccent : bite.ink,
          ),
        ),
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    final bite = context.bite;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message,
            style: sans(size: 13, weight: FontWeight.w500, color: bite.paper)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bite.ink,
        duration: const Duration(seconds: 2),
      ));
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.outlined = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Material(
      color: outlined ? Colors.transparent : bite.ink.withValues(alpha: 0.35),
      shape: outlined
          ? CircleBorder(side: BorderSide(color: bite.border, width: 0.75))
          : const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 20, color: outlined ? bite.ink : bite.paper),
        ),
      ),
    );
  }
}
