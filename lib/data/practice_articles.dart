import '../models/article.dart';
import 'palettes.dart';

typedef _A = Article;

/// The walkthrough's sandboxed deck (Phase 17).
///
/// Kept OUT of [mockArticles] on purpose. These never enter the article pool,
/// are never upserted, never carry a swipe event, and can never be saved,
/// tracked or ranked: the walkthrough reads this list directly and writes
/// nothing anywhere. The `practice-` id prefix makes that visible in a database
/// dump too, so a stray row would be obvious rather than plausible.
///
/// They still carry a real hook and a real 50-80 word bite, because the
/// practice deck has to feel identical to the live one. A card with placeholder
/// text would teach the gesture and misteach the product.
const List<Article> practiceArticles = [
  _A(
    id: 'practice-1',
    headline: 'City transit board approves late-night service on four lines',
    source: 'The Practice Post',
    author: 'The Practice Post',
    category: Category.world,
    imageUrl: '',
    snippet:
        'Trains will run until two in the morning on weekends from the spring timetable.',
    timeAgo: '1h ago',
    url: 'https://example.com/practice/transit',
    readMinutes: 3,
    palette: navyPalette,
    aiSummaryHook: 'Four lines are getting late-night trains',
    aiSummary:
        'The transit board voted to extend weekend service to two in the morning on four lines, starting with the spring timetable. Drivers pushed for the change for three years and will be paid a night rate for the extra shifts. The board says fares will not rise to cover it, and that a sixth line is under review for later in the year.',
  ),
  _A(
    id: 'practice-2',
    headline: 'A small lab keeps beating the big ones at protein folding',
    source: 'The Practice Post',
    author: 'The Practice Post',
    category: Category.science,
    imageUrl: '',
    snippet:
        'Nine people, one borrowed cluster, and a benchmark the field cannot ignore.',
    timeAgo: '3h ago',
    url: 'https://example.com/practice/folding',
    readMinutes: 4,
    palette: plumPalette,
    aiSummaryHook: 'Nine people keep outrunning the well-funded labs',
    aiSummary:
        'A nine-person lab has topped the folding benchmark for the third year running, using a borrowed cluster and a method it publishes in full. Larger groups with far bigger budgets have not matched it. The lead researcher says the advantage is not the model but the training data, which the team spent two years cleaning by hand before anything was trained on it.',
  ),
  _A(
    id: 'practice-3',
    headline: 'Second-division club sells out its season before the fixtures land',
    source: 'The Practice Post',
    author: 'The Practice Post',
    category: Category.sports,
    imageUrl: '',
    snippet:
        'Fans bought every seat for a season whose opponents were still unknown.',
    timeAgo: '5h ago',
    url: 'https://example.com/practice/season',
    readMinutes: 2,
    palette: rustPalette,
    aiSummaryHook: 'A whole season sold out before anyone knew the fixtures',
    aiSummary:
        'Every seat for next season went in under a week, before the fixture list was published. The club credits a members scheme that caps prices for anyone who renews three years running. It has now closed the waiting list at eleven thousand names and is weighing a stand extension it had shelved twice before.',
  ),
  _A(
    id: 'practice-4',
    headline: 'Regulators ask the biggest grocers to publish shrink rates',
    source: 'The Practice Post',
    author: 'The Practice Post',
    category: Category.business,
    imageUrl: '',
    snippet:
        'The figure has been treated as commercially sensitive for two decades.',
    timeAgo: '7h ago',
    url: 'https://example.com/practice/shrink',
    readMinutes: 3,
    palette: olivePalette,
    aiSummaryHook: 'Grocers may have to publish a number they have long hidden',
    aiSummary:
        'A draft rule would force the ten largest grocery chains to publish how much stock they write off each quarter, a figure treated as commercially sensitive for twenty years. Suppliers back the change and say it would settle long arguments about who pays for waste. The chains have until autumn to respond, and two have already signalled they will.',
  ),
  _A(
    id: 'practice-5',
    headline: 'The repair shop that fixes what manufacturers will not',
    source: 'The Practice Post',
    author: 'The Practice Post',
    category: Category.tech,
    imageUrl: '',
    snippet:
        'A back-room workshop keeps a decade of discontinued hardware running.',
    timeAgo: '9h ago',
    url: 'https://example.com/practice/repair',
    readMinutes: 4,
    palette: tealPalette,
    aiSummaryHook: 'One workshop keeps a decade of dead hardware alive',
    aiSummary:
        'A two-person workshop repairs devices whose makers stopped supplying parts years ago, machining replacements from scans it now publishes for free. Its waiting list runs to four months. New right-to-repair rules would require makers to supply those parts themselves, which the owners say would put them out of this line of work, and that they would consider it a good outcome.',
  ),
];
