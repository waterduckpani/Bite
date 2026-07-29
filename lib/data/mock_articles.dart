import '../models/article.dart';
import 'palettes.dart';

typedef _A = Article;

final List<Article> mockArticles = [
  // -- Phase 14: link-out stories -------------------------------------------
  // Publisher-direct cards, the shape ingest-rss produces. Since Phase 15.1
  // EVERY card is one of these in behaviour: bodies are gone from the model,
  // and every story shows the persistent "Swipe up to read at {publisher}" cue
  // and opens the publisher's page. Bite is a referrer, not a replacement.
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
    aiSummaryHook: 'Three states ration irrigation water after weak monsoon',
    aiSummary:
        'Three states have ordered irrigation rationing after the monsoon delivered well below its usual rainfall, leaving reservoirs at their lowest level in eleven years. Officials said the limits will hold until the winter crop is sown. Farming groups have asked for compensation.',
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
    aiSummaryHook: 'Delta cities are redrawing their maps every quarter',
    aiSummary:
        'Planners in three of the largest delta cities now reissue elevation charts every quarter instead of every decade, because the ground moves faster than the paperwork behind it. The revisions have already pushed thousands of properties into flood categories carrying higher insurance costs and stricter building rules. City engineers say the quarterly cycle is not a temporary measure but the new baseline, and neighbouring authorities are preparing to adopt the same schedule within the year.',
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
    aiSummaryHook: 'The four-day week is turning into the default',
    aiSummary:
        'A pandemic-era experiment is now showing up in job postings as a baseline expectation rather than a perk. Recruiters say listings without it draw noticeably fewer applications in several sectors, and a handful of firms have quietly dropped the trial framing altogether.',
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
    aiSummaryHook: 'The smallest club in the league made the giants blink',
    aiSummary:
        'A fifty-year drought ended in extra time, with the league\'s smallest club beating a side whose wage bill is nine times its own. The winning goal came from a player signed on a free transfer in January. The club has already said it will not sell him this summer.',
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
    aiSummaryHook: 'Streaming has quietly rebuilt the thing it replaced',
    aiSummary:
        'Bundles, ad tiers and household password rules have reassembled most of what cable offered, at a comparable monthly cost. Subscribers are responding by cycling in and out of services around single releases, a pattern the industry now spends heavily to discourage.',
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
    aiSummaryHook: 'A weekend project is outrunning a billion-dollar lab',
    aiSummary:
        'A loose collective of researchers released a model built over a weekend that now matches far better-funded systems on several public benchmarks. The weights are open, so the result was reproduced within days. Labs that spent years on the same problem have not publicly responded.',
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
    aiSummaryHook: 'A ceasefire built on side letters and personal trust',
    aiSummary:
        'Negotiators describe an agreement resting on unpublished side letters and language vague enough for both sides to claim a win. Nobody involved expected the talks to survive the first week, and several delegates arrived with instructions to walk out. What kept them in the room was a narrow set of guarantees no signatory has been willing to describe publicly, and which may not outlast the officials who wrote them.',
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
    aiSummaryHook: 'The dullest chip in your kitchen is now leverage',
    aiSummary:
        'Commodity microcontrollers were an afterthought for forty years, until every industry that embeds one tried to buy them at the same time. Lead times that ran weeks now run quarters, and appliance makers are redesigning products around whichever part they can actually source.',
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
    aiSummaryHook: 'A one-shot cure arrives with a pricing crisis',
    aiSummary:
        'A single infusion ended a lifelong genetic disease in forty-one trial patients, the first outright cure of its kind to clear regulatory review. The clinical result is not in dispute; the bill is. Health systems built to spread costs across decades of treatment now face one payment large enough to distort an annual budget, and insurers, hospitals and the regulator that approved it are already arguing over who absorbs it first.',
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
    aiSummaryHook: 'One record deal forced every club to reprice its roster',
    aiSummary:
        'A transfer that broke the league\'s salary model sent every rival back to renegotiate what a squad is worth. The immediate effect was panic; the measured one is that attendance is up across the division, including at clubs that lost players in the reshuffle.',
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
    aiSummaryHook: 'A generated score picked up a real nomination',
    aiSummary:
        'An indie film scored entirely by a model trained on public-domain recordings has been nominated, forcing the academy to decide what authorship means when no performer was in the room. The credited composer is the person who wrote the prompts and edited the output. Rival nominees have asked for a separate category; the academy has so far declined, saying the rules were written around the work rather than the tools that made it.',
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
    aiSummaryHook: 'Passwords are dead on the sites you use most',
    aiSummary:
        'Passkeys are now the default on the hundred largest consumer sites, and password resets on them have fallen sharply. The long tail is untouched: millions of smaller logins still hinge on a string invented years ago and reused everywhere else.',
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
    aiSummaryHook: 'Freight demand finished a rail line diplomacy could not',
    aiSummary:
        'A route surveyed a century ago and abandoned twice is being built across three borders, on old maps and an agreement that was never formally ratified. Officials credit freight volumes rather than diplomacy: the shipping that already crosses the corridor made the case that decades of talks could not.',
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
    aiSummaryHook: 'A closed shipping lane gave biologists a control group',
    aiSummary:
        'When a shipping lane shut for two years, the reef beneath it recovered enough to surprise the researchers monitoring it. The closure handed marine biologists something field science almost never gets: an untouched comparison the size of a small sea, against which every other reef can now be read.',
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
    aiSummaryHook: 'Inquiry opened into simultaneous undersea cable faults',
    aiSummary:
        'Regulators have opened an inquiry after four operators reported faults on the same undersea route within a day, disrupting international traffic for several hours. The operators said repairs are under way. The regulator did not say whether it suspects deliberate damage.',
  ),
];
