import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Marks text on screen as written by a model rather than by the publisher.
///
/// WHY THIS EXISTS, since it is easy to mistake for decoration and delete.
///
/// A Bite card shows the publisher's name and lettermark beside a hook and a
/// summary that the publisher did not write — an LLM did, from their feed.
/// Without a label the reader has every reason to read those words as the
/// publisher's own. That is a misattribution in the ordinary sense, and it is
/// the mechanism by which a model's mistake ("charged with" compressed to
/// "convicted of") becomes a false statement about a real person appearing
/// under someone else's masthead.
///
/// It is also a legal obligation rather than a courtesy. EU AI Act Article
/// 50(4) requires text that is AI-generated and published to inform the public
/// on matters of public interest to be disclosed as such; the transparency
/// provisions applied from 2 August 2026. The exemption is for content under
/// human editorial review, and Bite has none — no person reads a bite before
/// it ships.
///
/// So: wherever a bite is rendered, this goes with it. The terms page already
/// says the summaries are generated; the terms page is not where the reader is
/// looking when they believe the BBC wrote something.
class AiSummaryTag extends StatelessWidget {
  const AiSummaryTag({super.key, this.compact = false});

  /// Drops the label to the initials alone, for rows too tight for two words.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Semantics(
      // Screen readers get the whole sentence, not the abbreviation — "A I"
      // read aloud beside a publisher name communicates nothing.
      label: 'This summary was written by AI, not by the publisher',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: bite.faint.withValues(alpha: 0.55), width: 0.75),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          compact ? 'AI' : 'AI SUMMARY',
          style: caps(size: 8.5, color: bite.muted),
        ),
      ),
    );
  }
}
