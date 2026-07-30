import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/saved_tile.dart';
import 'browser_screen.dart';

/// How the Saved list is ordered. "Saved" dates come from `saves.saved_at`
/// (see [AppState.savedAtOf]); everything else reads off the article.
enum SavedSort {
  recentlySaved('Recently saved', Icons.history),
  oldestSaved('Oldest saved', Icons.schedule),
  published('Story date', Icons.calendar_today),
  title('Title A–Z', Icons.sort_by_alpha),
  source('Source A–Z', Icons.apartment),
  category('Category', Icons.category_outlined);

  const SavedSort(this.label, this.icon);
  final String label;
  final IconData icon;
}

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // The tab subtree is rebuilt on every tab switch, so the query, sort and
  // filter are all mirrored into PageStorage to survive round-trips.
  late final TextEditingController _search;
  String _query = '';
  SavedSort _sort = SavedSort.recentlySaved;
  Category? _category;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final storage = PageStorage.of(context);
    final storedQuery =
        storage.readState(context, identifier: 'saved.query') as String?;
    if (storedQuery != null && storedQuery != _query) {
      _query = storedQuery;
      _search.text = storedQuery;
    }
    final storedSort =
        storage.readState(context, identifier: 'saved.sort') as SavedSort?;
    if (storedSort != null) _sort = storedSort;
    // Read unconditionally: null is a real value here ("All topics"), so a
    // `!= null` guard would make the filter impossible to clear across a tab
    // switch.
    _category =
        storage.readState(context, identifier: 'saved.category') as Category?;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    PageStorage.of(context)
        .writeState(context, value, identifier: 'saved.query');
  }

  void _setSort(SavedSort value) {
    setState(() => _sort = value);
    PageStorage.of(context)
        .writeState(context, value, identifier: 'saved.sort');
  }

  void _setCategory(Category? value) {
    setState(() => _category = value);
    PageStorage.of(context)
        .writeState(context, value, identifier: 'saved.category');
  }

  /// Search → category filter → sort. Kept in that order so the chip counts
  /// and the result count always describe the same list the user is looking at.
  List<Article> _visible(AppState state) {
    final q = _query.trim().toLowerCase();
    final results = state.saved
        .where((a) =>
            (_category == null || a.category == _category) &&
            (q.isEmpty ||
                a.headline.toLowerCase().contains(q) ||
                a.source.toLowerCase().contains(q) ||
                (a.aiSummaryHook?.toLowerCase().contains(q) ?? false)))
        .toList();

    // state.saved is already newest-save-first, so recentlySaved needs no work
    // and is the fallback whenever a comparator ties.
    switch (_sort) {
      case SavedSort.recentlySaved:
        break;
      case SavedSort.oldestSaved:
        results.sort((a, b) => _savedAt(state, a).compareTo(_savedAt(state, b)));
      case SavedSort.published:
        results.sort((a, b) =>
            (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0)));
      case SavedSort.title:
        results.sort((a, b) =>
            a.headline.toLowerCase().compareTo(b.headline.toLowerCase()));
      case SavedSort.source:
        results.sort(
            (a, b) => a.source.toLowerCase().compareTo(b.source.toLowerCase()));
      case SavedSort.category:
        results.sort((a, b) => a.category.index.compareTo(b.category.index));
    }
    return results;
  }

  /// Saves with no recorded timestamp (hydrated from a row written before
  /// saved_at was carried) sort to the end of "oldest first" rather than
  /// jumping to the top of it.
  DateTime _savedAt(AppState state, Article a) =>
      state.savedAtOf(a.id) ?? DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final results = _visible(state);
    final categories = state.savedCategories;
    final filtering = _category != null || _query.trim().isNotEmpty;

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved', style: display(size: 34, weight: 640)),
                const SizedBox(height: 2),
                Text(
                  _countLine(state.saved.length, results.length, filtering),
                  style: sans(size: 13, color: bite.muted),
                ),
                if (state.saved.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  GlassSearchField(
                    controller: _search,
                    hintText: 'Search saved stories',
                    onChanged: _onQueryChanged,
                  ),
                ],
              ],
            ),
          ),
          if (state.saved.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FilterBar(
              categories: categories,
              selected: _category,
              sort: _sort,
              onCategory: _setCategory,
              onSortTap: () => _pickSort(context),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: results.isEmpty
                ? _EmptySaved(
                    filtering: filtering,
                    onClear: filtering ? _clearFilters : null,
                  )
                : ListView.separated(
                    key: const PageStorageKey('saved.list'),
                    padding: EdgeInsets.fromLTRB(24, 4, 24,
                        24 + kBiteTabBarReserved + MediaQuery.paddingOf(context).bottom),
                    itemCount: results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final article = results[i];
                      return Dismissible(
                        key: ValueKey(article.id),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => _remove(state, article),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: bite.danger,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.delete_outline,
                              color: Colors.white),
                        ),
                        child: SavedTile(
                          article: article,
                          onTap: () => BrowserScreen.open(context, article),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _countLine(int total, int shown, bool filtering) {
    if (total == 0) return 'Nothing here yet';
    final stories = '$total ${total == 1 ? 'story' : 'stories'}';
    if (!filtering) return stories;
    return '$shown of $stories';
  }

  void _clearFilters() {
    _search.clear();
    _onQueryChanged('');
    _setCategory(null);
  }

  Future<void> _pickSort(BuildContext context) async {
    HapticFeedback.selectionClick();
    final bite = context.bite;
    final picked = await showModalBottomSheet<SavedSort>(
      context: context,
      backgroundColor: bite.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text('Sort by', style: display(size: 22, weight: 620)),
            ),
            for (final option in SavedSort.values)
              ListTile(
                leading: Icon(
                  option.icon,
                  size: 20,
                  color: option == _sort ? bite.accent : bite.muted,
                ),
                title: Text(
                  option.label,
                  style: sans(
                    size: 14.5,
                    weight:
                        option == _sort ? FontWeight.w600 : FontWeight.w400,
                    color: bite.ink,
                  ),
                ),
                trailing: option == _sort
                    ? Icon(Icons.check, size: 18, color: bite.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked != null) _setSort(picked);
  }

  void _remove(AppState state, Article article) {
    state.unsave(article);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Removed from Saved'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => state.save(article),
        ),
      ));
  }
}

/// Sort control + topic filters, on one horizontally scrolling rail so a
/// reader with all six topics saved doesn't get a wrapping block of chips
/// pushing the list off screen.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.categories,
    required this.selected,
    required this.sort,
    required this.onCategory,
    required this.onSortTap,
  });

  final List<Category> categories;
  final Category? selected;
  final SavedSort sort;
  final ValueChanged<Category?> onCategory;
  final VoidCallback onSortTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          _Chip(
            label: sort.label,
            icon: sort.icon,
            selected: false,
            trailing: Icons.expand_more,
            onTap: onSortTap,
          ),
          if (categories.length > 1) ...[
            const SizedBox(width: 14),
            const _Divider(),
            const SizedBox(width: 14),
            _Chip(
              label: 'All',
              selected: selected == null,
              onTap: () => onCategory(null),
            ),
            for (final c in categories) ...[
              const SizedBox(width: 8),
              _Chip(
                label: c.label,
                selected: selected == c,
                // Tapping the active topic clears it — the same affordance
                // both ways, so the filter can't strand the reader.
                onTap: () => onCategory(selected == c ? null : c),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(width: 0.75, height: 20, color: context.bite.border),
    );
  }
}

/// The one chip shape used by both the sort control and the topic filters.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final fg = selected ? bite.onAccent : bite.ink;
    return Pressable(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: EdgeInsets.only(
            left: icon == null ? 16 : 12, right: trailing == null ? 16 : 10),
        decoration: BoxDecoration(
          color: selected ? bite.accent : bite.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? bite.accent : bite.border,
            width: 0.75,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: selected ? fg : bite.muted),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: sans(size: 13.5, weight: FontWeight.w500, color: fg),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 2),
              Icon(trailing, size: 17, color: bite.muted),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptySaved extends StatelessWidget {
  const _EmptySaved({required this.filtering, this.onClear});

  final bool filtering;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filtering ? Icons.search_off : Icons.bookmark_border,
                size: 36, color: bite.faint),
            const SizedBox(height: 12),
            Text(
              filtering ? 'No matches' : 'Nothing saved yet',
              style: display(size: 22, weight: 600),
            ),
            const SizedBox(height: 6),
            Text(
              filtering
                  ? 'Nothing saved matches this search and topic.'
                  : 'Swipe down on a story in the feed\nto keep it for later.',
              textAlign: TextAlign.center,
              style: sans(color: bite.muted),
            ),
            if (onClear != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: onClear,
                child: Text(
                  'Clear filters',
                  style: sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: bite.accent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
