import '../models/article.dart';
import 'palettes.dart';

// Shared filler paragraphs so every article reads like a real story
// without bloating the mock data.
const _fillA =
    'Interviews with more than a dozen people close to the matter suggest the shift has been building for years, hiding in plain sight inside quarterly reports and conference-hall small talk. What changed is not the underlying facts but the willingness to say them out loud.';
const _fillB =
    'The second-order effects are harder to price. Analysts who once treated the sector as a rounding error now publish weekly notes on it, and the vocabulary has migrated from trade journals into boardrooms and group chats alike.';
const _fillC =
    'Skeptics remain, and their arguments are not frivolous. History is littered with confident projections that aged poorly, and the incentives to overstate momentum are obvious to anyone who has watched a hype cycle crest and collapse.';
const _fillD =
    'Still, the people doing the actual work describe something quieter than a revolution: a long accumulation of small decisions, each defensible on its own, that together add up to a different world than the one we planned for.';

typedef _A = Article;

final List<Article> mockArticles = [
  // -- Phase 14: link-out stories -------------------------------------------
  // Publisher-direct cards, the shape ingest-rss produces. hasFullText is
  // false, so these route to the in-app browser and the card shows the
  // persistent "Swipe up to read at {publisher}" cue instead of the "Read in
  // Bite" pill. They carry NO body: Bite is a referrer, not a replacement, and
  // a publisher's article is never rendered natively.
  //
  // Bundled so the keyless mock build still exercises the link-out card in
  // both themes — without one, the Phase 14 UI is unreachable without a
  // deployed backend and an enabled publisher.
  const _A(
    id: 'a16',
    headline: 'Monsoon shortfall pushes three states to ration irrigation water',
    source: 'Deccan Herald',
    author: 'Deccan Herald',
    category: Category.world,
    imageUrl: '',
    snippet:
        'Reservoir levels are the lowest in eleven years, and the rationing order runs until the winter crop is sown.',
    timeAgo: '3h ago',
    url: 'https://www.deccanherald.com/india/monsoon-shortfall-irrigation',
    readMinutes: 3,
    palette: rustPalette,
    provider: ArticleProvider.rss,
    hasFullText: false,
    aiSummaryHook: 'Three states ration irrigation water after weak monsoon',
    aiSummary:
        'Three states have ordered irrigation rationing after the monsoon delivered well below its usual rainfall, leaving reservoirs at their lowest level in eleven years. Officials said the limits will hold until the winter crop is sown. Farming groups have asked for compensation.',
    body: [],
  ),
  const _A(
    id: 'a01',
    headline: 'The quiet chip war reshaping who controls the future of AI',
    source: 'The Signal',
    author: 'Priya Raman',
    category: Category.tech,
    imageUrl: '',
    snippet:
        'Export rules, secretive fabs, and a scramble for packaging capacity are redrawing the map of computing power.',
    timeAgo: '2h ago',
    url: 'https://thesignal.example/chip-war',
    readMinutes: 6,
    palette: tealPalette,
    aiSummaryHook: 'A quiet chip war is redrawing who controls AI',
    aiSummary:
        'Export rules, secretive fabs, and a scramble for advanced packaging capacity are shifting computing power toward a handful of little-known companies. The fight plays out in cleanrooms and customs offices rather than courtrooms, and its knock-on effects are only starting to be priced in.',
    body: [
      'The most consequential technology fight of the decade is not happening on app stores or in courtrooms. It is happening in cleanrooms, customs offices, and the procurement spreadsheets of a handful of companies most people have never heard of.',
      _fillA,
      _fillB,
      _fillD,
    ],
  ),
  const _A(
    id: 'a02',
    headline: 'Coastal cities race to redraw their maps as the water keeps rising',
    source: 'Atlas',
    author: 'Maya Okonkwo',
    category: Category.world,
    imageUrl: '',
    snippet:
        'Planners in three of the largest delta cities have begun issuing revised elevation charts every quarter rather than every decade.',
    timeAgo: '4h ago',
    url: 'https://atlas.example/coastal-maps',
    readMinutes: 8,
    palette: navyPalette,
    body: [
      'The maps that governed these coastlines for a century are quietly being retired. In three of the largest delta cities, planners have begun issuing revised elevation charts every quarter rather than every decade — an admission that the ground beneath millions of people is no longer a fixed thing.',
      'We stopped designing for the storm we remember and started designing for the one the models keep promising, one engineer said, standing on a berm that did not exist eighteen months ago.',
      _fillC,
      _fillD,
    ],
  ),
  const _A(
    id: 'a03',
    headline: 'The four-day week is quietly becoming the default',
    source: 'Ledger',
    author: 'Tom Vasquez',
    category: Category.business,
    imageUrl: '',
    snippet:
        'What began as a pandemic-era experiment is showing up in job postings as a baseline expectation, not a perk.',
    timeAgo: '3h ago',
    url: 'https://ledger.example/four-day-week',
    readMinutes: 5,
    palette: olivePalette,
    body: [
      'Nobody announced it. There was no legislation, no landmark court case. But scan the hiring pages of mid-size firms this quarter and a pattern emerges: the four-day week has stopped being a talking point and started being a line item.',
      _fillA,
      _fillB,
      _fillC,
    ],
  ),
  const _A(
    id: 'a04',
    headline: "A planet that shouldn't exist orbits a dead star",
    source: 'Orbit',
    author: 'Dr. Lena Fischer',
    category: Category.science,
    imageUrl: '',
    snippet:
        'The gas giant survived its sun\'s violent collapse — and is forcing a rewrite of planetary endgame models.',
    timeAgo: '6h ago',
    url: 'https://orbit.example/dead-star-planet',
    readMinutes: 7,
    palette: plumPalette,
    aiSummaryHook: 'A planet that should not exist orbits a dead star',
    aiSummary:
        'Astronomers have found a gas giant circling a stellar remnant, where models said no planet could survive its star\'s collapse. Its presence challenges assumptions about what becomes of planetary systems after a star dies, hinting that some worlds endure in places long ruled out.',
    body: [
      'By every model on the books, the planet should be a wisp of vapor. Instead it hangs there, intact and improbable, circling the collapsed remnant of the star that should have devoured it.',
      _fillA,
      _fillC,
      _fillD,
    ],
  ),
  const _A(
    id: 'a05',
    headline: 'An underdog season ends the only way it could — in extra time',
    source: 'Baseline',
    author: 'Marcus Cole',
    category: Category.sports,
    imageUrl: '',
    snippet:
        'The smallest club in the league carried a fifty-year drought into the final, then made the giants blink.',
    timeAgo: '1h ago',
    url: 'https://baseline.example/underdog-final',
    readMinutes: 4,
    palette: rustPalette,
    body: [
      'The stadium had seen champions crowned before, but never like this: a club whose entire payroll costs less than the opposition\'s bench, holding its shape deep into extra time while the noise made the cameras shake.',
      _fillA,
      _fillD,
      _fillB,
    ],
  ),
  const _A(
    id: 'a06',
    headline: 'Streaming\'s next act looks a lot like cable, and viewers noticed',
    source: 'Marquee',
    author: 'Dana Whitfield',
    category: Category.entertainment,
    imageUrl: '',
    snippet:
        'Bundles, ads, and password rules have recreated the thing streaming promised to kill. The rebellion is already forming.',
    timeAgo: '5h ago',
    url: 'https://marquee.example/streaming-cable',
    readMinutes: 6,
    palette: plumPalette,
    body: [
      'Ten years ago the pitch was simple: pay for what you want, watch it anywhere, cancel anytime. This week, the average household needs four subscriptions, an ad tier, and a shared calendar to follow one prestige drama.',
      _fillB,
      _fillC,
      _fillD,
    ],
  ),
  const _A(
    id: 'a07',
    headline: 'The open-source model that outran a billion-dollar lab',
    source: 'The Signal',
    author: 'Jonas Beck',
    category: Category.tech,
    imageUrl: '',
    snippet:
        'A loose collective of researchers shipped a model over a weekend that benchmarks are still catching up to.',
    timeAgo: '8h ago',
    url: 'https://thesignal.example/open-source-model',
    readMinutes: 5,
    palette: navyPalette,
    body: [
      'The release notes were two paragraphs long and contained one typo. The weights landed on a public server on a Friday night, and by Monday morning the leaderboard maintainers were rechecking their own math.',
      _fillA,
      _fillB,
      _fillC,
    ],
  ),
  const _A(
    id: 'a08',
    headline: 'A ceasefire drawn in pencil: inside the talks nobody expected to hold',
    source: 'Atlas',
    author: 'Samir Haddad',
    category: Category.world,
    imageUrl: '',
    snippet:
        'Negotiators describe a deal held together by side letters, personal trust, and deliberately vague language.',
    timeAgo: '30m ago',
    url: 'https://atlas.example/pencil-ceasefire',
    readMinutes: 9,
    palette: rustPalette,
    body: [
      'The agreement that stopped the shelling runs to eleven pages, and the parts that matter most are the ones written to mean two different things at once.',
      _fillA,
      _fillC,
      _fillD,
    ],
  ),
  const _A(
    id: 'a09',
    headline: 'The chip in your coffee maker is now a supply-chain weapon',
    source: 'Ledger',
    author: 'Grace Lin',
    category: Category.business,
    imageUrl: '',
    snippet:
        'Commodity microcontrollers were boring for forty years. Then everyone tried to buy them at once.',
    timeAgo: '7h ago',
    url: 'https://ledger.example/commodity-chips',
    readMinutes: 6,
    palette: tealPalette,
    body: [
      'It is the least glamorous chip in the building: no branding, no keynote, a part number instead of a name. It is also, this quarter, the reason three assembly lines on two continents are standing still.',
      _fillB,
      _fillA,
      _fillD,
    ],
  ),
  const _A(
    id: 'a10',
    headline: 'Gene therapy just got its first outright cure — and a pricing crisis',
    source: 'Orbit',
    author: 'Dr. Amara Osei',
    category: Category.science,
    imageUrl: '',
    snippet:
        'A single infusion ended a lifelong disease for 41 trial patients. Paying for it may break the system that approved it.',
    timeAgo: '12h ago',
    url: 'https://orbit.example/gene-cure',
    readMinutes: 8,
    palette: olivePalette,
    body: [
      'The word "cure" appears exactly once in the trial paper, hedged by three qualifiers. The patients use it more freely.',
      _fillA,
      _fillC,
      _fillB,
    ],
  ),
  const _A(
    id: 'a11',
    headline: 'The transfer that broke the salary model may have saved the league',
    source: 'Baseline',
    author: 'Ivy Nakamura',
    category: Category.sports,
    imageUrl: '',
    snippet:
        'One record-shattering deal forced every club to renegotiate what a roster is worth — and attendance is up everywhere.',
    timeAgo: '9h ago',
    url: 'https://baseline.example/record-transfer',
    readMinutes: 5,
    palette: navyPalette,
    body: [
      'When the fee leaked, the first reaction across the league was laughter. The second was a flurry of emergency board meetings.',
      _fillB,
      _fillD,
      _fillC,
    ],
  ),
  const _A(
    id: 'a12',
    headline: 'The soundtrack was generated. The Grammy nomination is real.',
    source: 'Marquee',
    author: 'Leo Antoine',
    category: Category.entertainment,
    imageUrl: '',
    snippet:
        'An indie film scored entirely by a model trained on public-domain recordings is forcing the academy to define authorship.',
    timeAgo: '1d ago',
    url: 'https://marquee.example/generated-score',
    readMinutes: 7,
    palette: tealPalette,
    body: [
      'The composer credit reads like a legal settlement, because it is one. Four names, two asterisks, and a footnote that will be argued about for years.',
      _fillC,
      _fillA,
      _fillD,
    ],
  ),
  const _A(
    id: 'a13',
    headline: 'Passkeys finally killed the password — for the top hundred sites, anyway',
    source: 'The Signal',
    author: 'Rosa Delgado',
    category: Category.tech,
    imageUrl: '',
    snippet:
        'The long tail is another story: millions of logins still hinge on a string you invented in 2011.',
    timeAgo: '11h ago',
    url: 'https://thesignal.example/passkeys',
    readMinutes: 4,
    palette: rustPalette,
    body: [
      'The obituary has been written a dozen times, but this one might stick: as of this month, every one of the hundred most-visited sites on the internet accepts a passkey.',
      _fillB,
      _fillA,
      _fillC,
    ],
  ),
  const _A(
    id: 'a14',
    headline: 'A rail line across three borders, built on a handshake and old maps',
    source: 'Atlas',
    author: 'Elif Kaya',
    category: Category.world,
    imageUrl: '',
    snippet:
        'The route was surveyed a century ago and abandoned twice. This time, freight demand did what diplomacy could not.',
    timeAgo: '2d ago',
    url: 'https://atlas.example/three-border-rail',
    readMinutes: 7,
    palette: olivePalette,
    body: [
      'The surveyors\' notebooks from 1921 are still legible, and for long stretches the new line follows their pencil marks exactly. The politics took a hundred years to catch up to the geography.',
      _fillA,
      _fillD,
      _fillB,
    ],
  ),
  const _A(
    id: 'a15',
    headline: 'The reef that came back: an accidental experiment in leaving things alone',
    source: 'Orbit',
    author: 'Noah Reyes',
    category: Category.science,
    imageUrl: '',
    snippet:
        'A shipping-lane closure gave marine biologists something they never get: a control group the size of a small sea.',
    timeAgo: '3d ago',
    url: 'https://orbit.example/reef-return',
    readMinutes: 6,
    palette: plumPalette,
    body: [
      'Nobody planned the experiment. A rerouted shipping lane simply left four hundred square kilometers of water quiet for three years, and the ocean did the rest.',
      _fillC,
      _fillB,
      _fillD,
    ],
  ),
  const _A(
    id: 'a17',
    headline: 'Regulators open inquiry into undersea cable outage',
    source: 'Al Jazeera',
    author: 'Al Jazeera',
    category: Category.tech,
    imageUrl: '',
    snippet:
        'Four operators reported simultaneous faults on a route that carries most of the region\'s international traffic.',
    timeAgo: '5h ago',
    url: 'https://www.aljazeera.com/news/undersea-cable-inquiry',
    readMinutes: 2,
    palette: tealPalette,
    provider: ArticleProvider.rss,
    hasFullText: false,
    aiSummaryHook: 'Inquiry opened into simultaneous undersea cable faults',
    aiSummary:
        'Regulators have opened an inquiry after four operators reported faults on the same undersea route within a day, disrupting international traffic for several hours. The operators said repairs are under way. The regulator did not say whether it suspects deliberate damage.',
    body: [],
  ),
];
