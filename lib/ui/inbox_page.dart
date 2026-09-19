import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';

import '../models/saved_item.dart';
import '../state/providers.dart';
import 'add_sheet.dart';
import 'detail_page.dart';
import 'settings_page.dart';

/// v3 inbox: stats header, search, filter sheet (status/category/type/AI/sort),
/// active-filter chips, rich cards. Delete ONLY via card menu or detail page
/// with confirmation — swipes are done/archive, never delete.
class InboxPage extends ConsumerWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(itemsProvider);
    final filter = ref.watch(filterProvider);
    final counts = ref.watch(countsProvider);
    // Consume "View" navigation requests from the save sheet.
    ref.listen<String?>(navigateToItemProvider, (prev, next) {
      if (next == null) return;
      Future.microtask(() {
        ref.read(navigateToItemProvider.notifier).state = null;
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => DetailPage(itemId: next, url: '')));
      });
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Save Later'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings & AI key',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatsHeader(counts: counts, filter: filter, ref: ref),
          _SearchBar(filter: filter, ref: ref),
          _ActiveChips(filter: filter, ref: ref),
          Expanded(
            child: items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (list) => list.isEmpty
                  ? const _EmptyState()
                  : RefreshIndicator(
                      onRefresh: () async => ref.invalidate(itemsProvider),
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: list.length,
                        itemBuilder: (_, i) => _ItemCard(item: list[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'filter',
            mini: true,
            tooltip: 'Filter & sort',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const FilterSheet(),
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'add',
            icon: const Icon(Icons.add),
            label: const Text('Save link'),
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

class _SearchBar extends StatelessWidget {
  final InboxFilter filter;
  final WidgetRef ref;
  const _SearchBar({required this.filter, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        decoration: InputDecoration(
          hintText: 'Search titles, summaries, tags…',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: filter.query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => ref.read(filterProvider.notifier).state =
                      filter.copyWith(query: ''),
                )
              : (filter.status == ItemStatus.archived
                  ? IconButton(
                      icon: const Icon(Icons.inbox_outlined),
                      tooltip: 'Back to inbox',
                      onPressed: () => ref.read(filterProvider.notifier).state =
                          filter.copyWith(status: () => ItemStatus.inbox),
                    )
                  : IconButton(
                      icon: const Icon(Icons.archive_outlined),
                      tooltip: 'View archived',
                      onPressed: () => ref.read(filterProvider.notifier).state =
                          filter.copyWith(status: () => ItemStatus.archived),
                    )),
        ),
        onChanged: (q) => ref.read(filterProvider.notifier).state =
            filter.copyWith(query: q),
      ),
    );
  }
}

/// Removable chips for every active filter (category/type/AI/sort/archived).
class _ActiveChips extends StatelessWidget {
  final InboxFilter filter;
  final WidgetRef ref;
  const _ActiveChips({required this.filter, required this.ref});

  bool get _hasAny =>
      filter.category != null ||
      filter.type != null ||
      filter.aiOnly ||
      filter.sort != SortMode.newest ||
      filter.status == ItemStatus.archived;

  @override
  Widget build(BuildContext context) {
    if (!_hasAny) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (filter.category != null) {
      chips.add(_chip(context, filter.category!.label,
          () => ref.read(filterProvider.notifier).state = filter.copyWith(category: () => null)));
    }
    if (filter.type != null) {
      chips.add(_chip(context, 'type: ${filter.type!.name}',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(type: () => null)));
    }
    if (filter.aiOnly) {
      chips.add(_chip(context, 'AI only',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(aiOnly: false)));
    }
    if (filter.sort != SortMode.newest) {
      chips.add(_chip(context, 'sort: ${filter.sort.name}',
          () => ref.read(filterProvider.notifier).state = filter.copyWith(sort: SortMode.newest)));
    }
    if (filter.status == ItemStatus.archived) {
      chips.add(_chip(context, 'archived',
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
        children: chips.map((c) => Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: c)).toList(),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, VoidCallback onRemove) {
    return InputChip(label: Text(label), onDeleted: onRemove);
  }
}

/// Bottom-sheet with status/category/type/AI/sort controls.
class FilterSheet extends ConsumerWidget {
  const FilterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(filterProvider);
    final counts = ref.watch(countsProvider).maybeWhen(data: (v) => v, orElse: () => null);
    return SafeArea(
      child: Padding(
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
                  onPressed: () {
                    ref.read(filterProvider.notifier).state =
                        InboxFilter(status: filter.status, query: filter.query);
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Status'),
            Wrap(
              spacing: 8,
              children: [
                _opt<ItemStatus?>(ref, filter.status == ItemStatus.inbox, 'Inbox',
                    () => filter.copyWith(status: () => ItemStatus.inbox)),
                _opt<ItemStatus?>(ref, filter.status == ItemStatus.done, 'Done',
                    () => filter.copyWith(status: () => ItemStatus.done)),
                _opt<ItemStatus?>(ref, filter.status == ItemStatus.archived, 'Archived',
                    () => filter.copyWith(status: () => ItemStatus.archived)),
                _opt<ItemStatus?>(ref, filter.status == null, 'All',
                    () => filter.copyWith(status: () => null)),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Category'),
            Wrap(
              spacing: 8,
              children: [
                _opt(ref, filter.category == null, 'All',
                    () => filter.copyWith(category: () => null)),
                ...Category.values.map((c) => _opt(
                    ref,
                    filter.category == c,
                    counts == null ? c.label : '${c.label} · ${counts.perCategory[c] ?? 0}',
                    () => filter.copyWith(category: () => c))),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Type'),
            Wrap(
              spacing: 8,
              children: [
                _opt(ref, filter.type == null, 'All',
                    () => filter.copyWith(type: () => null)),
                ...ItemType.values.map((t) =>
                    _opt(ref, filter.type == t, t.name, () => filter.copyWith(type: () => t))),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('AI categorized only'),
                const Spacer(),
                Switch(
                  value: filter.aiOnly,
                  onChanged: (v) => ref.read(filterProvider.notifier).state =
                      filter.copyWith(aiOnly: v),
                ),
              ],
            ),
            const Text('Sort'),
            Wrap(
              spacing: 8,
              children: [
                _opt(ref, filter.sort == SortMode.newest, 'Newest',
                    () => filter.copyWith(sort: SortMode.newest)),
                _opt(ref, filter.sort == SortMode.oldest, 'Oldest',
                    () => filter.copyWith(sort: SortMode.oldest)),
                _opt(ref, filter.sort == SortMode.az, 'A–Z',
                    () => filter.copyWith(sort: SortMode.az)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _opt<T>(WidgetRef ref, bool selected, String label, InboxFilter Function() next) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => ref.read(filterProvider.notifier).state = next(),
    );
  }
}

class _ItemCard extends ConsumerWidget {
  final SavedItem item;
  const _ItemCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey(item.id),
      // Right swipe = done/reopen. Left swipe = archive (never delete).
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
              _thumb(),
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
                          _overflowMenu(context, ref),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _sourceLine(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                      if (item.summary?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(item.summary!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _badge(context, item.category.label, Icons.folder_outlined),
                          ..._signalBadges(context),
                          ...item.tags
                              .take(2)
                              .map((t) => Text('#$t', style: theme.textTheme.bodySmall)),
                          const Spacer(),
                          _aiDot(context),
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

  /// Delete lives here behind a confirmation dialog — nowhere else.
  Widget _overflowMenu(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (v) async {
        if (v == 'done') {
          await ref.read(saveControllerProvider.notifier).setStatus(
              item.id, item.status == ItemStatus.done ? ItemStatus.inbox : ItemStatus.done);
        } else if (v == 'archive') {
          await ref.read(saveControllerProvider.notifier).setStatus(item.id, ItemStatus.archived);
        } else if (v == 'delete') {
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
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Deleted')));
            }
          }
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
            value: 'done',
            child: Text(item.status == ItemStatus.done ? 'Reopen' : 'Mark done')),
        const PopupMenuItem(value: 'archive', child: Text('Archive')),
        const PopupMenuItem(
            value: 'delete',
            child: Text('Delete…', style: TextStyle(color: Colors.red))),
      ],
    );
  }

  String _sourceLine() {
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

  List<Widget> _signalBadges(BuildContext context) {
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

  Widget _aiDot(BuildContext context) {
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

  Widget _thumb() {
    if (item.thumbnailUrl == null) return _typeIcon();
    return Image.network(
      item.thumbnailUrl!,
      width: 96,
      height: 120,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _typeIcon(),
    );
  }

  Widget _typeIcon() {
    final icon = switch (item.type) {
      ItemType.youtube => Icons.play_circle_fill,
      ItemType.reddit => Icons.forum_outlined,
      ItemType.movie => Icons.movie_outlined,
      ItemType.x => Icons.alternate_email,
      ItemType.article || ItemType.generic => Icons.article_outlined,
      _ => Icons.link,
    };
    return Container(
      width: 96,
      height: 120,
      color: Colors.grey.shade200,
      child: Icon(icon, size: 32, color: Colors.grey.shade600),
    );
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
