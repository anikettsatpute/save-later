import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cloud_store.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../state/providers.dart';

/// Google sign-in. Optional — the app works offline / local without it.
/// Signing in syncs library content (items, collections, rules, highlights,
/// notes) to the user's private Firestore.
///
/// AI provider keys (Gemini / OpenRouter / Azure) NEVER sync — they stay in
/// secure storage / SharedPreferences on each device.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cred = await ref.read(authServiceProvider).signInWithGoogle();
      if (cred?.user == null) {
        // User cancelled the account picker.
        if (mounted) setState(() => _busy = false);
        return;
      }
      // First-login merge: union local + cloud by id, then hand over to the
      // auth gate (providers switch to the cloud store automatically).
      try {
        final dynamic local = ref.read(localStoreProvider);
        final cloud = FirestoreStore(uid: cred!.user!.uid);
        final msg = await SyncService.mergeFromWidget(
            local: local, cloud: cloud);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Signed in · synced ($msg)')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Signed in (sync will retry later): $e')));
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_sync_outlined, size: 56),
                const SizedBox(height: 16),
                const Text('Access saves anywhere',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with Google to sync your library between phone and web.\n\n'
                  'Your AI provider keys stay on this device and are never uploaded.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.login_outlined),
                    label: const Text('Sign in with Google'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                    onPressed: _busy ? null : _signIn,
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('Continue offline'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Drawer / settings account row. Shows sign-in when signed out, the Google
/// profile + sign-out when signed in, or a setup hint when Firebase isn't
/// configured yet (see FIREBASE_SETUP.md).
class AccountTile extends ConsumerWidget {
  const AccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(firebaseReadyProvider)) {
      return const ListTile(
        leading: Icon(Icons.cloud_off_outlined),
        title: Text('Cloud sync not configured'),
        subtitle: Text('One-time setup: see FIREBASE_SETUP.md'),
      );
    }
    final auth = ref.watch(authStateProvider);
    return auth.when(
      data: (user) {
        if (user == null) {
          return ListTile(
            leading: const Icon(Icons.login_outlined),
            title: const Text('Sign in to sync'),
            subtitle: const Text('Google · access saves on web + phone'),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const LoginPage())),
          );
        }
        final label = user.displayName?.isNotEmpty == true
            ? user.displayName!
            : (user.email ?? 'Signed in');
        return ListTile(
          leading: user.photoURL != null
              ? CircleAvatar(
                  backgroundImage: NetworkImage(user.photoURL!))
              : CircleAvatar(
                  child: Text(label.isNotEmpty
                      ? label[0].toUpperCase()
                      : '?')),
          title: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Synced to your private cloud'),
          trailing: IconButton(
            icon: const Icon(Icons.logout_outlined),
            tooltip: 'Sign out (library stays on this device)',
            onPressed: () async {
              await ref.read(authServiceProvider).signOut();
              ref.invalidate(itemsProvider);
              ref.invalidate(countsProvider);
              bumpData(ref);
            },
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// On-demand re-merge. Visible only when signed in.
class SyncNowButton extends ConsumerStatefulWidget {
  const SyncNowButton({super.key});

  @override
  ConsumerState<SyncNowButton> createState() => _SyncNowButtonState();
}

class _SyncNowButtonState extends ConsumerState<SyncNowButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(firebaseReadyProvider)) {
      return const SizedBox.shrink();
    }
    final user = ref.watch(authStateProvider).valueOrNull;
    if (user == null) return const SizedBox.shrink();
    return OutlinedButton.icon(
      icon: _busy
          ? const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.sync_outlined),
      label: Text(_busy ? 'Syncing…' : 'Sync now'),
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                final dynamic local = ref.read(localStoreProvider);
                final cloud = FirestoreStore(uid: user.uid);
                final msg = await SyncService.mergeFromWidget(
                    local: local, cloud: cloud);
                ref.invalidate(itemsProvider);
                ref.invalidate(countsProvider);
                bumpData(ref);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Sync complete ($msg)')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Sync failed: $e')));
                }
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
    );
  }
}
