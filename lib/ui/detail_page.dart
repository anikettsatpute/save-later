import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/saved_item.dart';
import '../services/ai_service.dart';
import '../state/providers.dart';

/// Detail view v4 (Obsidian-inspired knowledge card):
/// hero, source line, chips, summary, excerpt, MY NOTE (markdown-lite),
/// highlights, collections, reminder, actions, Ask-AI.
class DetailPage extends ConsumerWidget {
  final String itemId;
  final String url;
  const DetailPage({super.key, required this.itemId, required this.url});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(itemsProvider);
    final item = itemsAsync.maybeWhen(
      data: (list) => list.where((e) => e.id == itemId).firstOrNull,
      orElse: () => null,
    );
    if (item == null) return _DirectDetail(itemId: itemId);
    return _DetailBody(item: item);
  }
}

class _DirectDetail extends ConsumerStatefulWidget {
  final String itemId;
  const _DirectDetail({required this.itemId});

  @override
  ConsumerState<_DirectDetail> createState() => _DirectDetailState();
}

class _DirectDetailState extends ConsumerState<_DirectDetail> {
  late final Future<SavedItem?> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<SavedItem?> _load() async {
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      return await container.read(dbProviderForRetry).getById(widget.itemId);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SavedItem?>(
      future: _f,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
              appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
        }
        final item = snap.data;
        if (item == null) {
          return Scaffold(
              appBar: AppBar(), body: const Center(child: Text('Item not found.')));
        }
        return _DetailBody(item: item);
      },
    );
  }
}

class _DetailBody extends ConsumerWidget {
  final SavedItem item;
  const _DetailBody({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final collectionsAsync = ref.watch(itemCollectionsProvider(item.id));
    final allCollections = ref.watch(collectionsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <Collection>[],
        );
    final myCollectionNames = collectionsAsync.maybeWhen(
      data: (ids) => ids
          .map((id) => allCollections
              .where((c) => c.id == id)
              .map((c) => c.name)
              .firstOrNull)
          .whereType<String>()
          .toList(),
      orElse: () => <String>[],
    );
    // Web: constrain to a readable column (mobile UI stretched full-width
    // looks broken on desktop — tiny hero, huge empty gutters).
    final recatting = ref.watch(recategorizingProvider).contains(item.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(item.category.label),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () => SharePlus.instance
                .share(ShareParams(text: '${item.title}\n${item.url}')),
          ),
          PopupMenuButton<ItemStatus>(
            onSelected: (s) async {
              await ref.read(saveControllerProvider.notifier).setStatus(item.id, s);
              if (s == ItemStatus.inbox && context.mounted) Navigator.pop(context);
            },
            itemBuilder: (_) => [
              if (item.status != ItemStatus.inbox)
                const PopupMenuItem(value: ItemStatus.inbox, child: Text('Move to Inbox')),
              if (item.status != ItemStatus.done)
                const PopupMenuItem(value: ItemStatus.done, child: Text('Mark Done')),
              if (item.status != ItemStatus.archived)
                const PopupMenuItem(value: ItemStatus.archived, child: Text('Archive')),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (item.thumbnailUrl != null)
            Hero(
              tag: 'thumb-${item.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(item.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const SizedBox.shrink()),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(item.title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(_sourceLine(item),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                  avatar: const Icon(Icons.folder_outlined, size: 16),
                  label: Text(item.category.label)),
              if ((item.aiSubcategory ?? '').isNotEmpty)
                Chip(
                    avatar: const Icon(Icons.subdirectory_arrow_right_outlined,
                        size: 16),
                    label: Text(item.aiSubcategory!)),
              Chip(
                  avatar: Icon(_typeIcon(item.type), size: 16),
                  label: Text(_typeLabel(item))),
              if (item.readingMinutes != null)
                Chip(
                    avatar: const Icon(Icons.schedule_outlined, size: 16),
                    label: Text('~${item.readingMinutes} min read')),
              if (item.isVideo == true)
                const Chip(
                    avatar: Icon(Icons.play_circle_outline, size: 16),
                    label: Text('video')),
              if (item.redditScore != null)
                Chip(
                    avatar: const Icon(Icons.trending_up_outlined, size: 16),
                    label: Text('▲ ${item.redditScore}')),
              if (item.redditComments != null)
                Chip(
                    avatar: const Icon(Icons.forum_outlined, size: 16),
                    label: Text('${item.redditComments} comments')),
              ...item.tags.map((t) => Chip(label: Text('#$t'))),
              // AI-filed collection shown inline so the filing is visible
              // without opening the Collections card.
              ...myCollectionNames.map((n) => Chip(
                  avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: Text(n))),
              Chip(
                avatar: Icon(
                    item.aiProcessed ? Icons.auto_awesome : Icons.cloud_off_outlined,
                    size: 16),
                label: Text(item.aiProcessed
                    ? (item.aiConfidence != null
                        ? 'AI ${(item.aiConfidence! * 100).round()}%'
                        : 'AI')
                    : 'offline rules'),
              ),
            ],
          ),
          // ---- AI insight card: topic + key points ----
          if (item.aiProcessed &&
              ((item.aiTopic ?? '').isNotEmpty ||
                  item.aiKeyPoints.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 16),
                        const SizedBox(width: 6),
                        Text('AI insight',
                            style: theme.textTheme.titleSmall),
                      ],
                    ),
                    if ((item.aiTopic ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(item.aiTopic!,
                          style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600)),
                    ],
                    if (item.aiKeyPoints.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ...item.aiKeyPoints.map((k) => Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                const Text('•  '),
                                Expanded(child: Text(k)),
                              ],
                            ),
                          )),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (item.author != null) ...[
            const SizedBox(height: 8),
            Text('By ${item.author}', style: theme.textTheme.bodySmall),
          ],
          if (item.summary?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Text('Summary', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(item.summary!, style: theme.textTheme.bodyLarge),
          ],
          if (item.excerpt?.isNotEmpty == true && item.excerpt != item.summary) ...[
            const SizedBox(height: 12),
            Text('From the page', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(item.excerpt!,
                style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
          ],
          // ---- Obsidian-style personal note ----
          const SizedBox(height: 16),
          _NoteCard(item: item),
          // ---- Collections ----
          const SizedBox(height: 8),
          collectionsAsync.maybeWhen(
            data: (ids) => _CollectionsCard(item: item, selectedIds: ids),
            orElse: () => const SizedBox.shrink(),
          ),
          // ---- Reminder ----
          const SizedBox(height: 8),
          _ReminderCard(item: item),
          const SizedBox(height: 12),
          SelectableText(item.url, style: const TextStyle(color: Colors.blue)),
          const SizedBox(height: 24),
          // Primary action first, full-width ≥48dp (mobile UX: thumb reach).
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open link'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              onPressed: () => _open(item, context),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Ask AI about this'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => AskAiSheet(item: item),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // AI re-categorize: visible always, emphasized when the item is
          // still on offline rules (cloud_off icon + "Retry AI" label).
          SizedBox(
            width: double.infinity,
            child: recatting
                ? const OutlinedButton.icon(
                    icon: SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2)),
                    label: Text('AI categorizing…'),
                    onPressed: null,
                  )
                : item.aiProcessed
                    ? OutlinedButton.icon(
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('Re-categorize with AI'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48)),
                        onPressed: () async {
                          try {
                            final msg = await ref
                                .read(saveControllerProvider.notifier)
                                .recategorize(item.id);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(msg)));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'AI retry failed: ${'$e'.replaceFirst('Exception: ', '')}')));
                            }
                          }
                        },
                      )
                    : FilledButton.tonalIcon(
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Retry AI categorization'),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        onPressed: () async {
                          try {
                            final msg = await ref
                                .read(saveControllerProvider.notifier)
                                .recategorize(item.id);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(msg)));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'AI retry failed: ${'$e'.replaceFirst('Exception: ', '')}')));
                            }
                          }
                        },
                      ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: Icon(item.status == ItemStatus.archived
                  ? Icons.unarchive_outlined
                  : Icons.check),
              label: Text(switch (item.status) {
                ItemStatus.archived => 'Unarchive to inbox',
                ItemStatus.done => 'Reopen',
                ItemStatus.inbox => 'Mark done',
              }),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              onPressed: () {
                ref.read(saveControllerProvider.notifier).setStatus(item.id,
                    item.status == ItemStatus.inbox ? ItemStatus.done : ItemStatus.inbox);
                Navigator.pop(context);
              },
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text('Delete…', style: TextStyle(color: Colors.red)),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete this item?'),
                  content: Text('"${item.title}" will be permanently removed.',
                      maxLines: 3, overflow: TextOverflow.ellipsis),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(saveControllerProvider.notifier).remove(item.id);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
          ),
        ),
      ),
    );
  }

  String _sourceLine(SavedItem item) {
    final parts = <String>[];
    if (item.siteName?.isNotEmpty == true) {
      parts.add(item.siteName!);
    } else {
      parts.add(Uri.tryParse(item.url)?.host.replaceFirst('www.', '') ?? item.type.name);
    }
    if (item.subreddit != null) parts.add('r/${item.subreddit}');
    parts.add(timeago.format(item.createdAt));
    return parts.join(' · ');
  }

  String _typeLabel(SavedItem item) {
    if (item.type == ItemType.reddit && item.subreddit != null) {
      return 'reddit · r/${item.subreddit}';
    }
    return item.type.name;
  }

  IconData _typeIcon(ItemType t) => switch (t) {
        ItemType.youtube => Icons.play_circle_fill,
        ItemType.reddit => Icons.forum_outlined,
        ItemType.movie => Icons.movie_outlined,
        ItemType.x => Icons.alternate_email,
        ItemType.article || ItemType.generic => Icons.article_outlined,
        _ => Icons.link,
      };

  Future<void> _open(SavedItem item, BuildContext context) async {
    final uri = Uri.parse(item.url);
    if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return;
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }
}

/// Obsidian-style note: tap to edit, markdown-lite render (bold/italic/links
/// stripped to readable text), saved per item, fed to Ask-AI.
class _NoteCard extends ConsumerStatefulWidget {
  final SavedItem item;
  const _NoteCard({required this.item});

  @override
  ConsumerState<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends ConsumerState<_NoteCard> {
  bool _editing = false;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.item.userNote ?? '');
  }

  @override
  void didUpdateWidget(covariant _NoteCard old) {
    super.didUpdateWidget(old);
    if (!_editing && old.item.userNote != widget.item.userNote) {
      _ctrl.text = widget.item.userNote ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note_outlined, size: 18),
                const SizedBox(width: 6),
                Text('My note', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (!_editing)
                  TextButton(
                    onPressed: () => setState(() => _editing = true),
                    child: Text(widget.item.userNote?.isNotEmpty == true ? 'Edit' : 'Add'),
                  ),
              ],
            ),
            if (_editing) ...[
              TextField(
                controller: _ctrl,
                maxLines: 5,
                minLines: 2,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Why did you save this? Key takeaway? [[link]] ideas…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => setState(() {
                            _editing = false;
                            _ctrl.text = widget.item.userNote ?? '';
                          }),
                      child: const Text('Cancel')),
                  FilledButton(
                    onPressed: () async {
                      await ref
                          .read(saveControllerProvider.notifier)
                          .saveNote(widget.item.id, _ctrl.text);
                      if (mounted) setState(() => _editing = false);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ] else ...[
              if (widget.item.userNote?.isNotEmpty == true)
                SelectableText(widget.item.userNote!)
              else
                Text('No note yet — capture why this matters.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
      ),
    );
  }
}

class _CollectionsCard extends ConsumerWidget {
  final SavedItem item;
  final List<String> selectedIds;
  const _CollectionsCard({required this.item, required this.selectedIds});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(collectionsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <Collection>[],
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 6),
                Text('Collections', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New'),
                  onPressed: () => _newCollection(context, ref),
                ),
              ],
            ),
            if (all.isEmpty)
              Text('Group items beyond categories — e.g. Thesis, Trip, Watchlist.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline))
            else
              Wrap(
                spacing: 8,
                children: all.map((c) {
                  final sel = selectedIds.contains(c.id);
                  return FilterChip(
                    label: Text('${c.icon ?? '📁'} ${c.name}'),
                    selected: sel,
                    onSelected: (_) async {
                      final next = [...selectedIds];
                      if (sel) {
                        next.remove(c.id);
                      } else {
                        next.add(c.id);
                      }
                      await ref
                          .read(saveControllerProvider.notifier)
                          .setCollections(item.id, next);
                      ref.invalidate(itemCollectionsProvider(item.id));
                    },
                  );
                }).toList(),
              ),
          ],
        ),
      ),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      // New collection attaches to THIS item immediately (user expectation).
      final newId = await ref
          .read(collectionsControllerProvider.notifier)
          .create(ctrl.text.trim());
      await ref
          .read(saveControllerProvider.notifier)
          .setCollections(item.id, [...selectedIds, newId]);
      ref.invalidate(itemCollectionsProvider(item.id));
    }
  }
}

class _ReminderCard extends ConsumerWidget {
  final SavedItem item;
  const _ReminderCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final has = item.remindAt != null && item.remindAt!.isAfter(DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.alarm_outlined, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reminder', style: theme.textTheme.titleSmall),
                  Text(
                    has
                        ? DateFormat('EEE, MMM d · h:mm a').format(item.remindAt!)
                        : 'Nudge yourself to revisit this.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            if (has)
              TextButton(
                onPressed: () => ref
                    .read(saveControllerProvider.notifier)
                    .setReminder(item.id, null),
                child: const Text('Clear'),
              )
            else
              PopupMenuButton<DateTime>(
                tooltip: 'Set reminder',
                onSelected: (dt) => ref
                    .read(saveControllerProvider.notifier)
                    .setReminder(item.id, dt),
                itemBuilder: (_) {
                  final now = DateTime.now();
                  final tonight =
                      DateTime(now.year, now.month, now.day, 21, 0).isAfter(now)
                          ? DateTime(now.year, now.month, now.day, 21, 0)
                          : now.add(const Duration(hours: 2));
                  final tomorrow =
                      DateTime(now.year, now.month, now.day, 9, 0).add(const Duration(days: 1));
                  var weekend = DateTime(now.year, now.month, now.day, 10, 0);
                  while (weekend.weekday != DateTime.saturday ||
                      !weekend.isAfter(now)) {
                    weekend = weekend.add(const Duration(days: 1));
                  }
                  return [
                    PopupMenuItem(
                        value: now.add(const Duration(hours: 2)),
                        child: const Text('In 2 hours')),
                    PopupMenuItem(value: tonight, child: const Text('Tonight 9pm')),
                    PopupMenuItem(value: tomorrow, child: const Text('Tomorrow 9am')),
                    PopupMenuItem(value: weekend, child: const Text('This weekend')),
                  ];
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Set'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet chat: Ask-AI with note + stored body in context.
class AskAiSheet extends ConsumerStatefulWidget {
  final SavedItem item;
  const AskAiSheet({super.key, required this.item});

  @override
  ConsumerState<AskAiSheet> createState() => _AskAiSheetState();
}

class _AskAiSheetState extends ConsumerState<AskAiSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <({bool mine, String text})>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _messages.add((
      mine: false,
      text:
          'Ask me anything about "${widget.item.title}". I have its summary and your note in context.'
    ));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final q = _input.text.trim();
    if (q.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _messages.add((mine: true, text: q));
      _busy = true;
    });
    _jump();
    try {
      final history = <({String q, String a})>[];
      for (var i = 1; i < _messages.length - 1; i += 2) {
        if (i + 1 < _messages.length && _messages[i].mine && !_messages[i + 1].mine) {
          history.add((q: _messages[i].text, a: _messages[i + 1].text));
        }
      }
      // Fresh item (note may have changed) for context.
      final container = ProviderScope.containerOf(context, listen: false);
      final db = container.read(dbProviderForRetry);
      final fresh = await db.getById(widget.item.id) ?? widget.item;
      final answer = await AiService().askAboutItem(
        item: fresh,
        question: q,
        history: history,
        highlights: const [],
      );
      if (!mounted) return;
      setState(() => _messages.add((mine: false, text: answer)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add((mine: false, text: '⚠ $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _jump();
    }
  }

  void _jump() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, __) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Ask AI',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length + (_busy ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i >= _messages.length) {
                    return const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    );
                  }
                  final m = _messages[i];
                  return Align(
                    alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.8),
                      decoration: BoxDecoration(
                        color: m.mine
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SelectableText(m.text),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Quiz me on the key points…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    onPressed: _busy ? null : _send,
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// ------------------------------------------------------- small controllers
final highlightsProvider =
    FutureProvider.family<List<Highlight>, String>((ref, itemId) async {
  ref.watch(dataVersionProvider);
  return ref.watch(_highlightsDbProvider).highlights(itemId);
});

final _highlightsDbProvider = Provider<dynamic>((ref) => ref.watch(dbProviderForRetry));

final itemCollectionsProvider =
    FutureProvider.family<List<String>, String>((ref, itemId) async {
  ref.watch(dataVersionProvider);
  return ref.watch(_highlightsDbProvider).itemCollectionIds(itemId);
});

class HighlightsController extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;
  HighlightsController(this._ref) : super(const AsyncValue.data(null));

  Future<void> add(String itemId, String text, {String? note}) async {
    await _ref.read(dbProviderForRetry).addHighlight(Highlight(
          id: const Uuid().v4(),
          itemId: itemId,
          text: text,
          note: note,
          createdAt: DateTime.now(),
        ));
    bumpData(_ref);
    _ref.invalidate(highlightsProvider(itemId));
  }

  Future<void> remove(String highlightId, String itemId) async {
    await _ref.read(dbProviderForRetry).deleteHighlight(highlightId);
    bumpData(_ref);
    _ref.invalidate(highlightsProvider(itemId));
  }
}

final highlightsControllerProvider =
    StateNotifierProvider<HighlightsController, AsyncValue<void>>(
        (ref) => HighlightsController(ref));

class CollectionsController extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;
  CollectionsController(this._ref) : super(const AsyncValue.data(null));

  /// Creates a collection and returns its id (so callers can auto-attach).
  Future<String> create(String name, {String? icon}) async {
    final existing = await _ref.read(dbProviderForRetry).collections();
    final id = const Uuid().v4();
    await _ref.read(dbProviderForRetry).upsertCollection(Collection(
          id: id,
          name: name,
          icon: icon,
          sortOrder: existing.length,
          createdAt: DateTime.now(),
        ));
    bumpData(_ref);
    return id;
  }

  Future<void> remove(String id) async {
    await _ref.read(dbProviderForRetry).deleteCollection(id);
    bumpData(_ref);
  }
}

final collectionsControllerProvider =
    StateNotifierProvider<CollectionsController, AsyncValue<void>>(
        (ref) => CollectionsController(ref));
