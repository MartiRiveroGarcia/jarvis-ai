# Jarvis mobile

Native Flutter client for Jarvis, a voice-first personal AI assistant. Android-first;
shared code is kept portable so iOS can be added later.

**Status:** Sprint 01 in progress. The API client, configuration and secure token
storage exist; authentication screens and the assistant home screen are being added.

## Requirements

- Flutter stable (developed with Flutter 3.47 / Dart 3.13)
- Android SDK with an emulator or a physical device

## Run and check

```bash
flutter pub get
flutter run                 # on a connected device or emulator
flutter analyze
flutter test
```

## Connecting to the backend

The API base URL is set at build time with `--dart-define=API_BASE_URL=...` and is
validated when the app starts: an invalid value stops the app immediately.

| Target              | Command                                                                        |
| ------------------- | ------------------------------------------------------------------------------ |
| Android emulator    | `flutter run` (default `http://10.0.2.2:8000`, the emulator's alias for your computer) |
| Phone on your Wi-Fi | `flutter run --dart-define=API_BASE_URL=http://192.168.1.20:8000` (your computer's LAN IP) |
| Release build       | `flutter build apk --release --dart-define=API_BASE_URL=https://your-api.example` |

For a physical phone, start the backend so it listens on your network, not only on
localhost: `uvicorn app.main:app --host 0.0.0.0 --port 8000`.

- **Plain HTTP works only in debug builds.** Profile and release builds require
  `https://`: the app rejects `http://` at startup and Android's network security config
  blocks cleartext traffic (`android/app/src/main/res/xml/network_security_config.xml`;
  the debug-only override lives in `src/debug/`).
- **`API_BASE_URL` is configuration, not a secret.** Anything passed with
  `--dart-define` is compiled into the app and can be extracted from it. Never pass
  credentials or keys this way.

## Security notes

- The session token is stored with `flutter_secure_storage` (AES-GCM, key protected by
  the Android Keystore). Only the token and its expiry are stored: never the password
  or email.
- App data is excluded from Android backups and device-to-device transfers, so the
  token never leaves the device.
- The API client sends `Authorization: Bearer` only on authenticated calls, only to
  the configured base URL, and never logs requests, headers or tokens.
