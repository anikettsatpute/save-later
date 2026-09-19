import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';

import '../models/saved_item.dart';
import '../services/ai_service.dart';
import '../services/link_parser.dart';
import '../state/providers.dart';

/// Detail view: hero thumbnail, source line, signal badges, summary,
/// tags, AI status, actions + Ask-AI chat with the item in context.
/// Delete requires confirmation. Open prefers in-app browser.
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
    if (item == null) {
      // Item may be outside the current filter (e.g. opened via "View" after
      // saving while a category filter is active). Fall back to direct load.
      return _DirectDetail(itemId: itemId, fallbackUrl: url);
    }
    return _DetailBody(item: item);
  }
}

/// Loads the item directly from DB when it is not in the filtered list.
class _DirectDetail extends ConsumerStatefulWidget {
  final String itemId;
  final String fallbackUrl;
  const _DirectDetail({required this.itemId, required this.fallbackUrl});

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
    final db = container.read(dbProviderForRetry);
    try {
      final all = await db.list();
      return all.where((e) => e.id == widget.itemId).firstOrNull;
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

/// Shared scaffold pieces for both entry paths.
class _DetailBody extends ConsumerWidget {
  final SavedItem item;
  const _DetailBody({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
            onSelected: (s) =>
                ref.read(saveControllerProvider.notifier).setStatus(item.id, s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: ItemStatus.inbox, child: Text('Move to Inbox')),
              PopupMenuItem(value: ItemStatus.done, child: Text('Mark Done')),
              PopupMenuItem(value: ItemStatus.archived, child: Text('Archive')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (item.thumbnailUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(item.thumbnailUrl!,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
          const SizedBox(height: 12),
          Text(item.title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            _sourceLine(item),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                  avatar: const Icon(Icons.folder_outlined, size: 16),
                  label: Text(item.category.label)),
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
              Chip(
                avatar: Icon(
                    item.aiProcessed ? Icons.auto_awesome : Icons.cloud_off_outlined,
                    size: 16),
                label: Text(item.aiProcessed ? 'AI' : 'offline rules'),
              ),
            ],
          ),
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
          const SizedBox(height: 12),
          SelectableText(item.url, style: const TextStyle(color: Colors.blue)),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open link'),
            onPressed: () => _open(item, context),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Ask AI about this'),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => AskAiSheet(item: item),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.check),
            label: Text(item.status == ItemStatus.done ? 'Reopen' : 'Mark done'),
            onPressed: () {
              ref.read(saveControllerProvider.notifier).setStatus(item.id,
                  item.status == ItemStatus.done ? ItemStatus.inbox : ItemStatus.done);
              Navigator.pop(context);
            },
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

/// Bottom-sheet chat: ask questions about this item. AI gets title, summary,
/// excerpt + freshly fetched article body (when available) as context.
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
  String? _articleText;
  bool _ctxReady = false;

  @override
  void initState() {
    super.initState();
    _messages.add((
      mine: false,
      text: 'Ask me anything about "${widget.item.title}". I have its summary and page content in context.'
    ));
    _loadContext();
  }

  Future<void> _loadContext() async {
    try {
      final meta = await LinkParser.fetchMeta(widget.item.url);
      _articleText = meta.articleText ?? meta.description;
    } catch (_) {}
    if (mounted) setState(() => _ctxReady = true);
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
      final answer = await AiService().askAboutItem(
        item: widget.item,
        question: q,
        history: history,
        articleText: _articleText,
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
      builder: (_, ctrl) => Padding(
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
                  if (!_ctxReady)
                    const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  IconButton(
                      icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
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
                        hintText: 'e.g. Summarize the key points…',
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
