# Cloud sync setup (one-time, ~15 min)

Login + web access runs on **Firebase Auth (Google) + Cloud Firestore**.
The app is offline-first: without this setup it just keeps working local-only.

## What syncs vs what stays on-device

| Synced to your private Firestore | Never leaves the device |
|---|---|
| Saved items, notes, highlights | Gemini / OpenRouter / Azure **API keys** |
| Collections, auto-tag rules | AI model choice |
| Reminders, statuses | — |

Firestore is scoped by `firestore.rules` to `users/{yourUid}/...` — only your
Google account can read/write it. The `apiKey` inside `firebase_options.dart`
is a **public identifier**, not a secret (same as any Firebase web app);
security comes from the rules above, not from hiding it.

## Steps

1. **Install tooling** (needs the Flutter SDK on PATH):
   ```bash
   flutter pub get
   dart pub global activate flutterfire_cli
   ```
2. **Create the Firebase project** at `console.firebase.google.com`
   (any name, e.g. `save-later`), no Analytics needed.
3. **Generate options** (select Android + iOS + Web when asked):
   ```bash
   flutterfire configure
   ```
   This replaces `lib/firebase_options.dart` with real values.
4. **Enable Google sign-in**: Console → Authentication → Sign-in method →
   enable **Google**. Add your support email.
5. **Create Firestore**: Console → Firestore Database → Create database →
   **Production mode** → pick the region closest to you.
6. **Deploy rules**: copy `firestore.rules` into Console → Firestore → Rules,
   or `firebase deploy --only firestore:rules`.
7. **Android**: download `google-services.json` (Project settings → Your apps →
   Android, package `com.savelater.save_later`) into `android/app/`.
   Get your debug SHA-1 and register it in the Firebase console or Google
   sign-in will fail on-device:
   ```bash
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
   ```
8. **iOS**: download `GoogleService-Info.plist`, add it via Xcode to
   `Runner/` (flutterfire prints the exact step).
9. **Web**: nothing extra — `flutter run -d chrome` works after step 3.
   (Web uses a Firebase popup for Google sign-in, so no client-id meta tag.)
10. **Verify**: sign in on phone → save a link → open the web app → sign in
    with the same Google account → the item is there.

## Platform notes

- **Linux / Windows desktop**: the Firestore SDK doesn't support them, so
  those builds stay local-only by design (`supportsCloudSync`).
- **macOS**: supported, needs the same plist step as iOS.
- `minSdk` is already 23 (Firebase Auth requirement).
- `google-services.json` / `GoogleService-Info.plist` are gitignored —
  each developer / CI adds their own.
