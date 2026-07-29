import 'package:flutter/material.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/saved_tile.dart';
import 'browser_screen.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // The tab subtree is rebuilt on every tab switch, so the query is mirrored
  // into PageStorage to survive round-trips.
  late final TextEditingController _search;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stored = PageStorage.of(context)
        .readState(context, identifier: 'saved.query') as String?;
    if (stored != null && stored != _query) {
      _query = stored;
      _search.text = stored;
    }
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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final q = _query.trim().toLowerCase();
    final results = state.saved
        .where((a) =>
            q.isEmpty ||
            a.headline.toLowerCase().contains(q) ||
            a.source.toLowerCase().contains(q))
        .toList();

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
                  state.saved.isEmpty
                      ? 'Nothing here yet'
                      : '${state.saved.length} ${state.saved.length == 1 ? 'story' : 'stories'}',
                  style: sans(size: 13, color: bite.muted),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _search,
                  onChanged: _onQueryChanged,
                  style: sans(size: 14, color: bite.ink),
                  decoration: InputDecoration(
                    hintText: 'Search saved stories',
                    hintStyle: sans(size: 14, color: bite.faint),
                    prefixIcon:
                        Icon(Icons.search, size: 20, color: bite.faint),
                    filled: true,
                    fillColor: bite.card,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: bite.border, width: 0.75),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: bite.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: results.isEmpty
                ? _EmptySaved(searching: q.isNotEmpty)
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

class _EmptySaved extends StatelessWidget {
  const _EmptySaved({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(searching ? Icons.search_off : Icons.bookmark_border,
                size: 36, color: bite.faint),
            const SizedBox(height: 12),
            Text(
              searching ? 'No matches' : 'Nothing saved yet',
              style: display(size: 22, weight: 600),
            ),
            const SizedBox(height: 6),
            Text(
              searching
                  ? 'Try a different search.'
                  : 'Swipe right on a story in the feed\nto keep it for later.',
              textAlign: TextAlign.center,
              style: sans(color: bite.muted),
            ),
          ],
        ),
      ),
    );
  }
}
