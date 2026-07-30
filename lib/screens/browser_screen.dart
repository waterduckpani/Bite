import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/source_quality.dart';
import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/cover_art.dart';
import '../widgets/follow_story_button.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';

/// How EVERY story opens, since Phase 15.1: the publisher's own page.
///
/// There is no longer a second tier. Bite is a referrer, not a replacement,
/// so it shows the publisher's real page, unmodified — no reader mode, no ad
/// stripping, no script injection. Bite only wraps the page in its own
/// chrome: a source bar with a load-progress hairline on top, and a
/// Save / Follow / Share / open-externally action row below.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.article});

  final Article article;

  /// Opens [article] at the publisher. THE single entry point — the Phase 6
  /// full-text/link-out router is gone, so there is no branch here and no way
  /// for a card's cue to disagree with where the tap goes.
  static Future<void> open(BuildContext context, Article article) {
    return Navigator.of(context, rootNavigator: true)
        .push(articleRoute(BrowserScreen(article: article)));
  }

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _web;
  double _progress = 0;
  bool _loaded = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      // JavaScript stays unrestricted so the publisher's page — ads and
      // all — runs exactly as it would in Safari.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p / 100);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onWebResourceError: (e) {
          // Subframe failures (an ad, a tracker) are business as usual;
          // only a dead main frame counts as a failed page.
          if ((e.isForMainFrame ?? true) && !_loaded && mounted) {
            setState(() => _failed = true);
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.article.url));
  }

  /// Back steps through webview history first; dismisses only from the
  /// first page.
  Future<void> _back() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loaded = false;
      _progress = 0;
    });
    _web.loadRequest(Uri.parse(widget.article.url));
  }

  Future<void> _openExternally() =>
      launchUrl(Uri.parse(widget.article.url),
          mode: LaunchMode.externalApplication);

  /// Shares the story's ORIGINAL url — never a rewrapped or proxied one.
  void _share(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    SharePlus.instance.share(ShareParams(
      uri: Uri.parse(widget.article.url),
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final state = AppScope.of(context);
    final bite = context.bite;
    final saved = state.isSaved(article);
    final showOverlay = !_loaded || _failed;

    return Scaffold(
      backgroundColor: bite.paper,
      body: Column(
        children: [
          _SourceBar(
            article: article,
            progress: _failed ? 0 : _progress,
            onBack: _back,
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                WebViewWidget(controller: _web),
                // Hero landing pad doubling as the loading/error state: the
                // card's cover and headline fly up into it, then the real
                // page fades in over it once loaded.
                IgnorePointer(
                  ignoring: !showOverlay,
                  child: AnimatedOpacity(
                    opacity: showOverlay ? 1 : 0,
                    duration: BiteMotion.gentle,
                    curve: BiteMotion.easeOut,
                    child: _LoadingPane(
                      article: article,
                      active: showOverlay,
                      failed: _failed,
                      onRetry: _retry,
                      onOpenExternally: _openExternally,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: GlassSurface(
            borderRadius: 30,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Pressable(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: saved ? bite.ink : bite.accent,
                          foregroundColor: saved ? bite.paper : bite.onAccent,
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
                  FollowStoryButton(article: article),
                  const SizedBox(width: 12),
                  Builder(
                    builder: (buttonContext) => _CircleButton(
                      icon: Icons.ios_share,
                      tooltip: 'Share',
                      onTap: () => _share(buttonContext),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CircleButton(
                    icon: Icons.open_in_browser,
                    tooltip: 'Open in system browser',
                    onTap: _openExternally,
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

/// Top chrome: back-through-history control, favicon + source name, and a
/// hairline page-load progress bar along the bottom edge.
class _SourceBar extends StatelessWidget {
  const _SourceBar({
    required this.article,
    required this.progress,
    required this.onBack,
  });

  final Article article;
  final double progress;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final host = SourceQuality.domainOf(article.url);
    return Container(
      color: bite.paper,
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back, size: 22, color: bite.ink),
                  tooltip: 'Back',
                  onPressed: onBack,
                ),
                const SizedBox(width: 4),
                _Favicon(article: article),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        article.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: bite.ink),
                      ),
                      if (host.isNotEmpty)
                        Text(
                          host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(size: 11, color: bite.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Thin page-load progress line; slips away once the page lands.
          SizedBox(
            height: 2,
            child: AnimatedOpacity(
              opacity: progress > 0 && progress < 1 ? 1 : 0,
              duration: BiteMotion.standard,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: bite.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The outlet's favicon: provider-supplied icon, else a favicon service,
/// else a lettermark circle.
class _Favicon extends StatelessWidget {
  const _Favicon({required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final host = SourceQuality.domainOf(article.url);
    final url = article.sourceIconUrl.isNotEmpty
        ? article.sourceIconUrl
        : (host.isEmpty
            ? ''
            : 'https://www.google.com/s2/favicons?domain=$host&sz=64');

    final lettermark = Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bite.ink, shape: BoxShape.circle),
      child: Text(
        article.source[0].toUpperCase(),
        style: sans(
            size: 12, weight: FontWeight.w600, height: 1, color: bite.paper),
      ),
    );
    if (url.isEmpty) return lettermark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: 24,
        height: 24,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => lettermark,
      ),
    );
  }
}

/// Landing pad for the Hero flight and the loading / failure states. Shows
/// the story's cover and headline (which the card morphs into) with a quiet
/// progress note, or a calm error with escape hatches.
class _LoadingPane extends StatelessWidget {
  const _LoadingPane({
    required this.article,
    required this.active,
    required this.failed,
    required this.onRetry,
    required this.onOpenExternally,
  });

  final Article article;

  /// Whether this pane is still the visible layer. Once the page lands the
  /// pane stays MOUNTED (it holds the Hero landing pad) but fades to nothing —
  /// and a CircularProgressIndicator left in an invisible subtree keeps a
  /// ticker running for as long as the story is open. So the spinner is built
  /// only while it is actually doing something.
  final bool active;

  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      color: bite.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeroMode(
            enabled: !reducedMotion(context),
            child: SizedBox(
              height: 220,
              child: Hero(
                tag: article.coverHeroTag,
                child: CoverArt(article: article, showCredit: true),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HeroMode(
                  enabled: !reducedMotion(context),
                  child: Hero(
                    tag: article.headlineHeroTag,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Text(
                        article.headline,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: display(size: 24, weight: 560, height: 1.18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (failed) ...[
                  Text(
                    "This page didn't load.",
                    style: sans(
                        size: 14, weight: FontWeight.w600, color: bite.ink),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The story is still there — try again, or read it in '
                    'your browser.',
                    style: sans(size: 13, height: 1.5, color: bite.muted),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Pressable(
                        child: FilledButton.icon(
                          onPressed: onOpenExternally,
                          icon: const Icon(Icons.open_in_browser, size: 18),
                          label: const Text('Open in system browser'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onRetry,
                        child: Text('Try again',
                            style: sans(
                                size: 14,
                                weight: FontWeight.w600,
                                color: bite.accent)),
                      ),
                    ],
                  ),
                ] else if (active)
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.8, color: bite.accent),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Loading ${article.source}…',
                        style: sans(size: 13, color: bite.muted),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final button = Material(
      color: Colors.transparent,
      shape: CircleBorder(side: BorderSide(color: bite.border, width: 0.75)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 20, color: bite.ink),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
