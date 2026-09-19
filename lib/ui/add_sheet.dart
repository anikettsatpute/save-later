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
          FilledButton.icon(
            icon: saving
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bookmark_add),
            label: Text(saving ? _phaseLabel(phase) : 'Save'),
            onPressed: saving
                ? null
                : () async {
                    final ctrl = ref.read(saveControllerProvider.notifier);
                    // Capture everything needed for the post-save snackbar
                    // BEFORE popping: after pop, this context is dead and
                    // ScaffoldMessenger/View silently do nothing.
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(context);
                    final result = await ctrl.saveUrl(_url.text,
                        note: _note.text.trim().isEmpty ? null : _note.text.trim());
                    if (result.error != null && result.itemId == null) {
                      // Fatal: nothing saved, keep sheet open so user can fix.
                      messenger.showSnackBar(SnackBar(content: Text(result.error!)));
                    } else {
                      // Saved (possibly with AI warning, possibly duplicate).
                      // Close first, then show the snackbar from the parent.
                      navigator.pop();
                      final msg = result.error ??
                          result.aiError ??
                          'Saved ✓ ${result.usedAi ? '(AI)' : '(offline rules)'}';
                      messenger.showSnackBar(SnackBar(
                        content: Text(msg),
                        duration: const Duration(seconds: 8),
                        action: result.itemId != null
                            ? SnackBarAction(
                                label: 'View',
                                onPressed: () => ref
                                    .read(navigateToItemProvider.notifier)
                                    .state = result.itemId,
                              )
                            : null,
                      ));
                    }
                  },
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
