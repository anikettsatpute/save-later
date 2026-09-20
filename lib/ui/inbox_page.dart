import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';

import '../models/saved_item.dart';
import '../state/providers.dart';
import 'add_sheet.dart';
import 'detail_page.dart';
import 'login_page.dart';
import 'settings_page.dart';

/// v4 inbox (Raindrop-inspired): nav drawer (status + collections),
/// stats header, full-text search, view switcher (list/grid/headlines),
/// active-filter chips, rich cards. Delete only via ⋮ menu with confirm.
class InboxPage extends ConsumerWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(itemsProvider);
    final filter = ref.watch(filterProvider);
    final counts = ref.watch(countsProvider);
    final viewMode = ref.watch(viewModeProvider);
    ref.listen<String?>(navigateToItemProvider, (prev, next) {
      if (next == null || next == prev) return;
      Future.microtask(() {
        if (!context.mounted) return;
        final route = ModalRoute.of(context);
        if (route == null || !route.isCurrent) return;
        ref.read(navigateToItemProvider.notifier).state = null;
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => DetailPage(itemId: next, url: '')));
      });
    });
    // Post-save toast owned by the inbox scaffold: auto-dismisses in 4s,
    // and "View" navigates immediately (fixes the sticky white banner).
    ref.listen<String?>(pendingSaveMessageProvider, (prev, next) {
      if (next == null || next == prev) return;
      ref.read(pendingSaveMessageProvider.notifier).state = null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(next),
          duration: const Duration(seconds: 4),
        ));
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Save Later'),
        actions: [
          // View switcher (Raindrop per-collection layout, here global).
          PopupMenuButton<ViewMode>(
            icon: Icon(switch (viewMode) {
              ViewMode.list => Icons.view_list_outlined,
              ViewMode.grid => Icons.grid_view_outlined,
              ViewMode.headlines => Icons.view_headline_outlined,
            }),
            tooltip: 'View',
            onSelected: (v) => ref.read(viewModeProvider.notifier).state = v,
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: ViewMode.list,
                  child: Row(children: [Icon(Icons.view_list_outlined), SizedBox(width: 8), Text('List')])),
              PopupMenuItem(
                  value: ViewMode.grid,
                  child: Row(children: [Icon(Icons.grid_view_outlined), SizedBox(width: 8), Text('Grid')])),
              PopupMenuItem(
                  value: ViewMode.headlines,
                  child: Row(children: [Icon(Icons.view_headline_outlined), SizedBox(width: 8), Text('Headlines')])),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings & AI key',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      drawer: const _NavDrawer(),
      body: Column(
        children: [
          _StatsHeader(counts: counts, filter: filter, ref: ref),
          _SearchBar(filter: filter, ref: ref),
          _ActiveChips(filter: filter, ref: ref),
          Expanded(
            child: items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorState(
                message: '$e',
                onRetry: () {
                  ref.invalidate(itemsProvider);
                  ref.invalidate(countsProvider);
                },
              ),
              data: (list) => list.isEmpty
                  ? (filter.query.isNotEmpty ||
                          filter.category != null ||
                          filter.type != null ||
                          filter.collectionId != null ||
                          filter.aiOnly ||
                          filter.remindedOnly ||
                          filter.status == ItemStatus.archived
                      ? _NoResultsState(filter: filter, ref: ref)
                      : const _EmptyState())
                  : RefreshIndicator(
                      onRefresh: () async => ref.invalidate(itemsProvider),
                      child: _BodyList(items: list, viewMode: viewMode),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: FloatingActionButton(
              heroTag: 'filter',
              mini: true,
              tooltip: 'Filter & sort',
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const FilterSheet(),
              ),
              child: const Icon(Icons.tune_outlined),
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'add',
            icon: const Icon(Icons.add),
            label: const Text('Save link'),
            // Extended FAB already ≥48dp tall; keep label tappable.
            extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const AddSheet(),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyList extends StatelessWidget {
  final List<SavedItem> items;
  final ViewMode viewMode;
  const _BodyList({required this.items, required this.viewMode});

  @override
  Widget build(BuildContext context) {
    switch (viewMode) {
      case ViewMode.grid:
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.78,
          ),
          itemCount: items.length,
          itemBuilder: (_, i) => _GridCard(item: items[i]),
        );
      case ViewMode.headlines:
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => _HeadlineRow(item: items[i]),
        );
      case ViewMode.list:
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: items.length,
          itemBuilder: (_, i) => _ItemCard(item: items[i]),
        );
    }
  }
}

/// Raindrop-style drawer: status destinations + user collections + reminders.
class _NavDrawer extends ConsumerWidget {
  const _NavDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(filterProvider);
    final counts = ref.watch(countsProvider).maybeWhen(data: (v) => v, orElse: () => null);
    final collections = ref.watch(collectionsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <Collection>[],
        );
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('Save Later',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Your second brain', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            const AccountTile(),
            const Divider(),
            _dest(context, ref, filter, Icons.inbox_outlined, 'Inbox',
                counts == null ? null : counts.inbox,
                filter.status == ItemStatus.inbox && filter.collectionId == null,
                () => const InboxFilter()),
            _dest(context, ref, filter, Icons.check_outlined, 'Done',
                counts == null ? null : counts.done,
                filter.status == ItemStatus.done,
                () => const InboxFilter(status: ItemStatus.done)),
            _dest(context, ref, filter, Icons.archive_outlined, 'Archived', null,
                filter.status == ItemStatus.archived,
                () => const InboxFilter(status: ItemStatus.archived)),
            _dest(context, ref, filter, Icons.alarm_outlined, 'Reminders', null,
                filter.remindedOnly,
                () => const InboxFilter(remindedOnly: true, status: null)),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text('Collections (${collections.length})',
                      style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: 'New collection',
                    onPressed: () => _newCollection(context, ref),
                  ),
                ],
              ),
            ),
            if (collections.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('Group items beyond categories — e.g. Thesis, Trip.',
                    style: TextStyle(fontSize: 12)),
              ),
            ...collections.map((c) => FutureBuilder<int>(
                  future: ref.watch(dbProviderForRetry).collectionCount(c.id),
                  builder: (_, snap) => _dest(
                    context,
                    ref,
                    filter,
                    Icons.folder_outlined,
                    '${c.icon ?? ''} ${c.name}'.trim(),
                    snap.data,
                    filter.collectionId == c.id,
                    () => InboxFilter(collectionId: c.id, status: null),
                    onLongPress: () => _collectionMenu(context, ref, c),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _dest(BuildContext context, WidgetRef ref, InboxFilter filter, IconData icon,
      String label, int? count, bool selected, InboxFilter Function() next,
      {VoidCallback? onLongPress}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: count == null ? null : Text('$count'),
      selected: selected,
      onTap: () {
        ref.read(filterProvider.notifier).state = next();
        Navigator.pop(context);
      },
      onLongPress: onLongPress,
    );
  }

  Future<void> _newCollection(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New collection'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
                hintText: 'e.g. Thesis research', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty && context.mounted) {
      await ref.read(collectionsControllerProvider.notifier).create(ctrl.text.trim());
    }
  }

  Future<void> _collectionMenu(BuildContext context, WidgetRef ref, Collection c) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(c.name),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const Text('Open')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: const Text('Delete collection', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (action == 'open' && context.mounted) {
      ref.read(filterProvider.notifier).state =
          InboxFilter(collectionId: c.id, status: null);
      Navigator.pop(context);
    } else if (action == 'delete') {
      await ref.read(collectionsControllerProvider.notifier).remove(c.id);
    }
  }
}

class _StatsHeader extends StatelessWidget {
  final AsyncValue<ItemCounts> counts;
  final InboxFilter filter;
  final WidgetRef ref;
  const _StatsHeader({required this.counts, required this.filter, required this.ref});

  @override
  Widget build(BuildContext context) {
    final c = counts.maybeWhen(data: (v) => v, orElse: () => null);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              c == null
                  ? 'Your second brain'
                  : '${c.inbox} to go · ${c.done} done${c.unreadAi > 0 ? ' · ${c.unreadAi} need AI' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          SegmentedButton<ItemStatus?>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: ItemStatus.inbox, label: Text('Inbox')),
              ButtonSegment(value: ItemStatus.done, label: Text('Done')),
              ButtonSegment(value: null, label: Text('All')),
            ],
            selected: {filter.status},
            onSelectionChanged: (s) => ref.read(filterProvider.notifier).state =
                filter.copyWith(status: () => s.first),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final InboxFilter filter;
  final WidgetRef ref;
  const _SearchBar({required this.filter, required this.ref});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _ctrl;
  late String _lastExternal;

  @override
  void initState() {
    super.initState();
    _lastExternal = widget.filter.query;
    _ctrl = TextEditingController(text: _lastExternal);
  }

  @override
  void didUpdateWidget(covariant _SearchBar old) {
    super.didUpdateWidget(old);
    if (widget.filter.query != _lastExternal && widget.filter.query != _ctrl.text) {
      _lastExternal = widget.filter.query;
      _ctrl.text = _lastExternal;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final ref = widget.ref;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _ctrl,
        decoration: InputDecoration(
          hintText: filter.fullText
              ? 'Search titles, bodies, notes… (full-text)'
              : 'Search titles, tags…',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Full-text toggle (FTS5 over body/notes vs titles/tags).
              IconButton(
                icon: Icon(filter.fullText
                    ? Icons.manage_search
                    : Icons.title_outlined),
                tooltip: filter.fullText
                    ? 'Full-text: ON (bodies + notes)'
                    : 'Full-text: OFF (titles + tags)',
                onPressed: () => ref.read(filterProvider.notifier).state =
                    filter.copyWith(fullText: !filter.fullText),
              ),
              if (_ctrl.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _ctrl.clear();
                    _lastExternal = '';
                    ref.read(filterProvider.notifier).state =
                        filter.copyWith(query: '');
                  },
                )
              else if (filter.status == ItemStatus.archived)
                IconButton(
                  icon: const Icon(Icons.inbox_outlined),
                  tooltip: 'Back to inbox',
                  onPressed: () => ref.read(filterProvider.notifier).state =
                      filter.copyWith(status: () => ItemStatus.inbox),
                )
              else
                IconButton(
                  icon: const Icon(Icons.archive_outlined),
                  tooltip: 'View archived',
                  onPressed: () => ref.read(filterProvider.notifier).state =
                      filter.copyWith(status: () => ItemStatus.archived),
                ),
            ],
          ),
        ),
        onChanged: (q) {
          _lastExternal = q;
          ref.read(filterProvider.notifier).state = filter.copyWith(query: q);
        },
      ),
    );
  }
}

class _ActiveChips extends StatelessWidget {
  final InboxFilter filter;
  final WidgetRef ref;
  const _ActiveChips({required this.filter, required this.ref});

  bool get _hasAny =>
      filter.category != null ||
      filter.type != null ||
      filter.collectionId != null ||
      filter.aiOnly ||
      filter.remindedOnly ||
      filter.sort != SortMode.newest ||
      filter.status == ItemStatus.archived;

  @override
  Widget build(BuildContext context) {
    if (!_hasAny) return const SizedBox.shrink();
    final collections = ref.watch(collectionsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <Collection>[],
        );
    final chips = <Widget>[];
    if (filter.category != null) {
      chips.add(_chip(filter.category!.label,
          () => ref.read(filterProvider.notifier).state = filter.copyWith(category: () => null)));
    }
    if (filter.type != null) {
      chips.add(_chip('type: ${filter.type!.name}',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(type: () => null)));
    }
    if (filter.collectionId != null) {
      final name = collections
          .where((c) => c.id == filter.collectionId)
          .map((c) => c.name)
          .firstOrNull;
      chips.add(_chip('📁 ${name ?? 'collection'}',
          () => ref.read(filterProvider.notifier).state =
              filter.copyWith(collectionId: () => null)));
    }
    if (filter.aiOnly) {
      chips.add(_chip('AI only',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(aiOnly: false)));
    }
    if (filter.remindedOnly) {
      chips.add(_chip('⏰ reminders',
          () => ref.read(filterProvider.notifier).state =
              filter.copyWith(remindedOnly: false)));
    }
    if (filter.sort != SortMode.newest) {
      chips.add(_chip('sort: ${filter.sort.name}',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(sort: SortMode.newest)));
    }
    if (filter.status == ItemStatus.archived) {
      chips.add(_chip('archived',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(status: () => ItemStatus.inbox)));
    }
    chips.add(TextButton(
        onPressed: () => ref.read(filterProvider.notifier).state = const InboxFilter(),
        child: const Text('Clear all')));
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: chips
            .map((c) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2), child: c))
            .toList(),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onRemove) {
    return InputChip(label: Text(label), onDeleted: onRemove);
  }
}

/// Filter sheet with local draft + Apply (no reflow glitch).
class FilterSheet extends ConsumerStatefulWidget {
  const FilterSheet({super.key});

  @override
  ConsumerState<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<FilterSheet> {
  late ItemStatus? _status;
  late Category? _category;
  late ItemType? _type;
  late bool _aiOnly;
  late bool _remindedOnly;
  late SortMode _sort;
  late bool _dirty;

  @override
  void initState() {
    super.initState();
    final f = ref.read(filterProvider);
    _status = f.status;
    _category = f.category;
    _type = f.type;
    _aiOnly = f.aiOnly;
    _remindedOnly = f.remindedOnly;
    _sort = f.sort;
    _dirty = false;
  }

  void _markDirty() => setState(() => _dirty = true);

  @override
  Widget build(BuildContext context) {
    final counts =
        ref.watch(countsProvider).maybeWhen(data: (v) => v, orElse: () => null);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Filter & sort',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _status = ItemStatus.inbox;
                    _category = null;
                    _type = null;
                    _aiOnly = false;
                    _remindedOnly = false;
                    _sort = SortMode.newest;
                    _dirty = true;
                  }),
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Status'),
            Wrap(
              spacing: 8,
              children: [
                _opt(_status == ItemStatus.inbox, 'Inbox',
                    () { _status = ItemStatus.inbox; _markDirty(); }),
                _opt(_status == ItemStatus.done, 'Done',
                    () { _status = ItemStatus.done; _markDirty(); }),
                _opt(_status == ItemStatus.archived, 'Archived',
                    () { _status = ItemStatus.archived; _markDirty(); }),
                _opt(_status == null, 'All', () { _status = null; _markDirty(); }),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Category'),
            Wrap(
              spacing: 8,
              children: [
                _opt(_category == null, 'All', () { _category = null; _markDirty(); }),
                ...Category.values.map((c) => _opt(
                    _category == c,
                    counts == null ? c.label : '${c.label} · ${counts.perCategory[c] ?? 0}',
                    () { _category = c; _markDirty(); })),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Type'),
            Wrap(
              spacing: 8,
              children: [
                _opt(_type == null, 'All', () { _type = null; _markDirty(); }),
                ...ItemType.values
                    .map((t) => _opt(_type == t, t.name, () { _type = t; _markDirty(); })),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('AI categorized only'),
                const Spacer(),
                Switch(
                  value: _aiOnly,
                  onChanged: (v) => setState(() { _aiOnly = v; _dirty = true; }),
                ),
              ],
            ),
            Row(
              children: [
                const Text('With reminders only'),
                const Spacer(),
                Switch(
                  value: _remindedOnly,
                  onChanged: (v) => setState(() { _remindedOnly = v; _dirty = true; }),
                ),
              ],
            ),
            const Text('Sort'),
            Wrap(
              spacing: 8,
              children: [
                _opt(_sort == SortMode.newest, 'Newest',
                    () { _sort = SortMode.newest; _markDirty(); }),
                _opt(_sort == SortMode.oldest, 'Oldest',
                    () { _sort = SortMode.oldest; _markDirty(); }),
                _opt(_sort == SortMode.az, 'A–Z',
                    () { _sort = SortMode.az; _markDirty(); }),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _dirty
                    ? () {
                        final current = ref.read(filterProvider);
                        ref.read(filterProvider.notifier).state = InboxFilter(
                          status: _status,
                          category: _category,
                          type: _type,
                          collectionId: current.collectionId,
                          aiOnly: _aiOnly,
                          remindedOnly: _remindedOnly,
                          fullText: current.fullText,
                          sort: _sort,
                          query: current.query,
                        );
                        Navigator.pop(context);
                      }
                    : null,
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _opt(bool selected, String label, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

// ------------------------------------------------------------------- cards
String _sourceLine(SavedItem item) {
  final parts = <String>[];
  if (item.siteName?.isNotEmpty == true) {
    parts.add(item.siteName!);
  } else {
    parts.add(Uri.tryParse(item.url)?.host.replaceFirst('www.', '') ?? item.type.name);
  }
  if (item.subreddit != null) parts.add('r/${item.subreddit}');
  if (item.author?.isNotEmpty == true) parts.add('by ${item.author}');
  parts.add(timeago.format(item.createdAt));
  return parts.join(' · ');
}

Widget _aiDot(BuildContext context, SavedItem item) {
  final theme = Theme.of(context);
  return Tooltip(
    message: item.aiProcessed ? 'AI categorized' : 'Offline rules — add Gemini key for AI',
    child: Icon(
      item.aiProcessed ? Icons.auto_awesome : Icons.cloud_off_outlined,
      size: 14,
      color: item.aiProcessed ? theme.colorScheme.primary : theme.colorScheme.outline,
    ),
  );
}

Widget _reminderDot(SavedItem item) {
  if (item.remindAt == null) return const SizedBox.shrink();
  final overdue = item.remindAt!.isBefore(DateTime.now());
  return Tooltip(
    message: 'Reminder: ${item.remindAt}',
    child: Icon(Icons.alarm,
        size: 14, color: overdue ? Colors.red : Colors.orange),
  );
}

class _ItemCard extends ConsumerWidget {
  final SavedItem item;
  const _ItemCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey(item.id),
      background: Container(
          color: Colors.green,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          child: Icon(
              item.status == ItemStatus.done ? Icons.inbox_outlined : Icons.check,
              color: Colors.white)),
      secondaryBackground: Container(
          color: Colors.grey.shade600,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(Icons.archive_outlined, color: Colors.white)),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          await ref.read(saveControllerProvider.notifier).setStatus(
              item.id, item.status == ItemStatus.done ? ItemStatus.inbox : ItemStatus.done);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(item.status == ItemStatus.done ? 'Reopened' : 'Marked done'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => ref
                      .read(saveControllerProvider.notifier)
                      .setStatus(item.id, item.status),
                ),
              ),
            );
          }
        } else {
          await ref.read(saveControllerProvider.notifier).setStatus(item.id, ItemStatus.archived);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Archived'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => ref
                      .read(saveControllerProvider.notifier)
                      .setStatus(item.id, item.status),
                ),
              ),
            );
          }
        }
        return false;
      },
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => DetailPage(itemId: item.id, url: item.url))),
          onLongPress: () =>
              launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _thumb(item),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                          ),
                          _overflowMenu(context, ref, item),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(_sourceLine(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                      if (item.summary?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(item.summary!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall),
                      ],
                      if (item.userNote?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.edit_note_outlined, size: 12),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(item.userNote!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      fontStyle: FontStyle.italic)),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _badge(context, item.category.label, Icons.folder_outlined),
                          ..._signalBadges(context, item),
                          ...item.tags
                              .take(2)
                              .map((t) => Text('#$t', style: theme.textTheme.bodySmall)),
                          const Spacer(),
                          _reminderDot(item),
                          _aiDot(context, item),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grid tile (Raindrop grid/moodboard nod): thumbnail top, title + badges.
class _GridCard extends ConsumerWidget {
  final SavedItem item;
  const _GridCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => DetailPage(itemId: item.id, url: item.url))),
        onLongPress: () => _overflowAction(context, ref, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: SizedBox.expand(child: _thumb(item, w: double.infinity))),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                            item.siteName ??
                                Uri.tryParse(item.url)
                                    ?.host
                                    .replaceFirst('www.', '') ??
                                '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ),
                      _reminderDot(item),
                      _aiDot(context, item),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Headlines: text-only fast scan (Raindrop headlines view).
class _HeadlineRow extends ConsumerWidget {
  final SavedItem item;
  const _HeadlineRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('h-${item.id}'),
      background: Container(
          color: Colors.green,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          child: const Icon(Icons.check, color: Colors.white)),
      secondaryBackground: Container(
          color: Colors.grey.shade600,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(Icons.archive_outlined, color: Colors.white)),
      confirmDismiss: (dir) async {
        await ref.read(saveControllerProvider.notifier).setStatus(item.id,
            dir == DismissDirection.startToEnd ? ItemStatus.done : ItemStatus.archived);
        return false;
      },
      child: ListTile(
        dense: true,
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${item.category.label} · ${timeago.format(item.createdAt)}${item.userNote?.isNotEmpty == true ? ' · 📝' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [_reminderDot(item), _aiDot(context, item)],
        ),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => DetailPage(itemId: item.id, url: item.url))),
      ),
    );
  }
}

List<Widget> _signalBadges(BuildContext context, SavedItem item) {
  final out = <Widget>[];
  if (item.readingMinutes != null) {
    out.add(_badge(context, '${item.readingMinutes} min', Icons.schedule_outlined));
  }
  if (item.isVideo == true) {
    out.add(_badge(context, 'video', Icons.play_circle_outline));
  }
  if (item.redditScore != null && item.redditScore! > 0) {
    out.add(_badge(context, '▲ ${item.redditScore}', Icons.trending_up_outlined));
  }
  if (item.redditComments != null && item.redditComments! > 0) {
    out.add(_badge(context, '${item.redditComments} comments', Icons.forum_outlined));
  }
  return out;
}

Widget _badge(BuildContext context, String text, IconData icon) {
  final theme = Theme.of(context);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.labelSmall),
      ],
    ),
  );
}

Widget _thumb(SavedItem item, {double w = 96}) {
  if (item.thumbnailUrl == null) return _typeIcon(item, w: w);
  return Hero(
    tag: 'thumb-${item.id}',
    child: Image.network(
      item.thumbnailUrl!,
      width: w,
      height: 120,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _typeIcon(item, w: w),
    ),
  );
}

Widget _typeIcon(SavedItem item, {double w = 96}) {
  final icon = switch (item.type) {
    ItemType.youtube => Icons.play_circle_fill,
    ItemType.reddit => Icons.forum_outlined,
    ItemType.movie => Icons.movie_outlined,
    ItemType.x => Icons.alternate_email,
    ItemType.article || ItemType.generic => Icons.article_outlined,
    _ => Icons.link,
  };
  return Container(
    width: w,
    height: 120,
    color: Colors.grey.shade200,
    child: Icon(icon, size: 32, color: Colors.grey.shade600),
  );
}

Widget _overflowMenu(BuildContext context, WidgetRef ref, SavedItem item) {
  return PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert, size: 18),
    // Bigger tap area for thumbs (mobile UX: 18px icon was hard to hit).
    padding: const EdgeInsets.all(12),
    onSelected: (v) => _overflowAction(context, ref, item, preset: v),
    itemBuilder: (_) => [
      PopupMenuItem(
          value: 'done',
          child: Text(item.status == ItemStatus.done ? 'Reopen' : 'Mark done')),
      const PopupMenuItem(value: 'archive', child: Text('Archive')),
      const PopupMenuItem(
          value: 'delete', child: Text('Delete…', style: TextStyle(color: Colors.red))),
    ],
  );
}

Future<void> _overflowAction(BuildContext context, WidgetRef ref, SavedItem item,
    {String? preset}) async {
  final v = preset ??
      await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Item actions'),
          children: [
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'done'),
                child: Text(item.status == ItemStatus.done ? 'Reopen' : 'Mark done')),
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'archive'),
                child: const Text('Archive')),
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('Delete…', style: TextStyle(color: Colors.red))),
          ],
        ),
      );
  if (v == 'done') {
    await ref.read(saveControllerProvider.notifier).setStatus(
        item.id, item.status == ItemStatus.done ? ItemStatus.inbox : ItemStatus.done);
  } else if (v == 'archive') {
    await ref.read(saveControllerProvider.notifier).setStatus(item.id, ItemStatus.archived);
  } else if (v == 'delete' && context.mounted) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this item?'),
        content: Text('"${item.title}" will be permanently removed.',
            maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(saveControllerProvider.notifier).remove(item.id);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_add_outlined, size: 64),
            SizedBox(height: 16),
            Text('Nothing here yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
                'Share any YouTube video, Reddit post, article or movie link to this app — it will be categorized automatically.'),
          ],
        ),
      ),
    );
  }
}

/// Friendly error with retry (browser test: raw "Error: Bad state" scared users).
class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friendly = message.contains('databaseFactory')
        ? 'Storage is not ready on this device yet. Retry — your saves are safe.'
        : message.length > 160
            ? '${message.substring(0, 160)}…'
            : message;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            const Text('Something went wrong',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(friendly, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// Filtered search with zero hits: one-tap escape (browser test: users felt trapped).
class _NoResultsState extends StatelessWidget {
  final InboxFilter filter;
  final WidgetRef ref;
  const _NoResultsState({required this.filter, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_outlined, size: 56),
            const SizedBox(height: 16),
            const Text('No matches',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              filter.query.isNotEmpty
                  ? 'Nothing matches "${filter.query}". Try fewer words or turn off full-text.'
                  : 'Nothing matches these filters.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () =>
                  ref.read(filterProvider.notifier).state = const InboxFilter(),
              child: const Text('Clear search & filters'),
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
