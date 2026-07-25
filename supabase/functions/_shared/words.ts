// Bite · Phase 14: the 80-word bite cap.
//
// Lives in its own module so the cap is a testable property of the code rather
// than something the prompt politely asks for. The summariser asks the model
// for <= SUMMARY_MAX_WORDS, retries once if it overshoots, and then applies
// truncateToWords unconditionally — so nothing over the cap can ever be
// written, whatever the model returns.

/// Hard ceiling on a bite. Enforced in code, not merely requested.
export const SUMMARY_MAX_WORDS = 80;

export function wordCount(text: string): number {
  return text.trim().split(/\s+/).filter((w) => w.length > 0).length;
}

/// Truncates to [max] words, preferring the last complete sentence so a capped
/// bite still reads as finished prose rather than a severed clause. Falls back
/// to a hard cut with an ellipsis when no sentence boundary sits late enough to
/// leave a real summary behind.
export function truncateToWords(text: string, max: number): string {
  const words = text.trim().split(/\s+/).filter((w) => w.length > 0);
  if (words.length <= max) return text.trim();
  const capped = words.slice(0, max).join(" ");
  const lastStop = Math.max(
    capped.lastIndexOf(". "),
    capped.lastIndexOf("! "),
    capped.lastIndexOf("? "),
  );
  if (lastStop > capped.length * 0.55) return capped.slice(0, lastStop + 1).trim();
  return `${capped.replace(/[,;:\-–—]+$/, "").trim()}…`;
}
