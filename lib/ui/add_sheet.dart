import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Save sheet: shows parsed URL + optional title hint, progress states
/// (fetching → AI → done), auto-closes on success with "View" action.
class AddSheet extends ConsumerStatefulWidget {
  final String? initialUrl;
  final String? initialNote;
  const AddSheet({super.key, this.initialUrl, this.initialNote});

  @override
  ConsumerState<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends ConsumerState<AddSheet> {
  late final TextEditingController _url;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    _note = TextEditingController(text: widget.initialNote ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saveState = ref.watch(saveControllerProvider);
    final saving = saveState.isLoading;
    final phase = ref.watch(savePhaseProvider);
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Save for later',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Link URL',
              hintText: 'https://…',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autofocus: widget.initialUrl == null,
            enabled: !saving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note / custom title (optional)',
              border: OutlineInputBorder(),
            ),
            enabled: !saving,
          ),
          if (saving) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text(_phaseLabel(phase), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bookmark_add),
              label: Text(saving ? _phaseLabel(phase) : 'Save'),
              onPressed: saving
                  ? null
                  : () async {
                      final ctrl = ref.read(saveControllerProvider.notifier);
                      final result = await ctrl.saveUrl(_url.text,
                          note: _note.text.trim().isEmpty ? null : _note.text.trim());
                      if (!context.mounted) return;
                      if (result.error != null && result.itemId == null) {
                        // Fatal: nothing saved, keep sheet open so user can fix.
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(result.error!)));
                      } else {
                        // Saved (possibly with AI warning, possibly duplicate).
                        // Hand the result to the inbox: it owns the snackbar
                        // (sheet context dies on pop — that was the sticky bug).
                        final itemId = result.itemId;
                        final msg = result.error ??
                            result.aiError ??
                            'Saved ✓ ${result.usedAi ? '(AI)' : '(offline rules)'}';
                        Navigator.pop(context);
                        if (itemId != null) {
                          ref.read(navigateToItemProvider.notifier).state = itemId;
                        }
                        ref.read(pendingSaveMessageProvider.notifier).state = msg;
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  String _phaseLabel(SavePhase phase) => switch (phase) {
        SavePhase.idle => 'Saving…',
        SavePhase.fetching => 'Fetching link details…',
        SavePhase.ai => 'AI categorizing…',
        SavePhase.saving => 'Saving…',
      };
}
