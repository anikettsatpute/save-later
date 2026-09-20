import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Set once in main() after Firebase.initializeApp(). False when Firebase
/// isn't configured yet (or on platforms Firestore doesn't support) — the
/// app then runs local-only and hides sign-in UI affordances.
final firebaseReadyProvider = StateProvider<bool>((_) => false);

final firebaseAuthProvider =
    Provider<FirebaseAuth>((_) => FirebaseAuth.instance);

/// Null = signed out (or Firebase not ready — callers check
/// [firebaseReadyProvider] first).
final authStateProvider = StreamProvider<User?>((ref) {
  // FirebaseAuth.instance throws when Firebase isn't initialized — never
  // touch it until main() confirms readiness (or on unsupported platforms).
  if (!supportsCloudSync) return Stream.value(null);
  if (!ref.watch(firebaseReadyProvider)) return Stream.value(null);
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

final authServiceProvider =
    Provider<AuthService>((ref) => AuthService(ref));

/// Firestore SDKs exist for Android / iOS / macOS / web only.
/// Linux + Windows desktop builds stay on the local store.
bool get supportsCloudSync {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// Google sign-in only. No passwords to manage.
/// On web this uses a Firebase popup; on mobile the native Google flow.
class AuthService {
  final Ref _ref;
  AuthService(this._ref);

  FirebaseAuth get _auth => _ref.read(firebaseAuthProvider);

  User? get currentUser => _auth.currentUser;

  /// Returns the credential, or null if the user cancelled the picker.
  Future<UserCredential?> signInWithGoogle() async {
    if (kIsWeb) {
      return _auth.signInWithPopup(GoogleAuthProvider());
    }
    // google_sign_in v6: classic constructor API, cancellation returns null.
    // serverClientId = the type-3 "Web client" OAuth id from
    // google-services.json. Without it, Firebase Auth rejects the idToken
    // with ApiException: 10 on some devices/configs.
    final googleUser = await GoogleSignIn(
      serverClientId:
          '833208594065-dai4s0u1cqlvrr0ekbcl8apehgrqau06.apps.googleusercontent.com',
    ).signIn();
    if (googleUser == null) return null;
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        await GoogleSignIn().signOut();
      } catch (_) {
        // Native sign-out is best-effort; Firebase sign-out is the source.
      }
    }
    await _auth.signOut();
  }
}
