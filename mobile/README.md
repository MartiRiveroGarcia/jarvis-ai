# Jarvis mobile

Native Flutter client for Jarvis, a voice-first personal AI assistant. Android-first;
the Dart code is kept portable so iOS can be added later (there is no iOS project yet).

## What works (Sprint 01)

- Register and log in (email plus a 15–128 character password; spaces allowed).
- Session restore at startup through `GET /api/auth/me`. If the server can't be
  reached, the app offers Retry instead of signing you out.
- The session token is kept in secure storage backed by the Android Keystore.
- Protected routing: signed-out users only see login and registration.
- Assistant home with a **visual-only** voice button.
- Settings: email, member-since date, app version and sign out.

**Not implemented yet:** real voice (no microphone access, recording, speech-to-text
or text-to-speech), Microsoft Foundry, AI agents and Android assistant integration.
The voice button only shows "Voice interaction is coming soon."

## Prerequisites

- Flutter stable, developed with **Flutter 3.47.6 / Dart 3.13.5**
- Android SDK with the API 36 platform, plus an emulator or an Android phone with
  developer options and device debugging enabled (USB or wireless)
- The Jarvis backend running locally — see [../backend/README.md](../backend/README.md)

```bash
cd mobile
flutter pub get
```

## Run against the local backend

**Android emulator.** Start the backend (`uvicorn app.main:app --reload` in
`backend/`), then:

```bash
flutter run      # uses http://10.0.2.2:8000, the emulator's alias for your computer
```

**Physical phone on the same Wi-Fi.** The backend must listen on your network, not
only on localhost:

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000                  # in backend/
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:8000  # your computer's LAN IP
```

If the phone can't connect, check that your firewall allows port 8000.

### `API_BASE_URL`

| Build                     | Example                                               |
| ------------------------- | ----------------------------------------------------- |
| Debug, emulator (default) | `http://10.0.2.2:8000`                                |
| Debug, phone on Wi-Fi     | `--dart-define=API_BASE_URL=http://192.168.1.20:8000` |
| Release                   | `--dart-define=API_BASE_URL=https://api.example.com`  |

- The URL is checked when the app starts; an invalid value stops it immediately.
- **Plain HTTP works only in debug builds.** Profile and release builds require
  `https://`, enforced both by the app and by Android's network security config.
- It is configuration, not a secret: values passed with `--dart-define` are compiled
  into the app and can be extracted from it.

## How sign-in works

- **Startup:** with no stored session you see Login. A locally expired session is
  removed without a network call; otherwise `GET /api/auth/me` decides. A 401 signs
  you out; a network or server error shows Retry and keeps the session.
- **Login** saves the session to secure storage before the app treats you as signed in.
- **Register** creates the account and logs in automatically. If that automatic login
  fails, you land on Login with your email filled in.
- **Sign out** asks for confirmation, attempts server revocation best-effort, and only
  treats the device as signed out once the local credential has been removed. If local
  removal fails, the app stays on a Retry screen.

## Security notes

- Only the session token and its expiry are stored on the device, in secure storage
  whose encryption key is backed by the Android Keystore — never the password or email.
- App data is excluded from Android backups and device-to-device transfers.
- The token is sent only as `Authorization: Bearer`, only to the configured base URL,
  and is never logged.
- The app version shown in Settings comes from `pubspec.yaml` via the Flutter build
  (`FLUTTER_BUILD_NAME`); it is build metadata, not configuration.

## Checks

```bash
flutter analyze
dart format --set-exit-if-changed .
flutter test
flutter build apk --debug
```
