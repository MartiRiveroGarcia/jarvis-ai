# Jarvis mobile

Native Flutter client for Jarvis, a voice-first personal AI assistant. Android-first;
the Dart code is kept portable so iOS can be added later (there is no iOS project yet).

## What works

- Register and log in (email plus a 15–128 character password; spaces allowed).
- Session restore at startup through `GET /api/auth/me`. If the server can't be
  reached, the app offers Retry instead of signing you out.
- The session token is kept in secure storage backed by the Android Keystore.
- Protected routing: signed-out users only see login and registration.
- Push-to-talk with Jarvis: hold the voice button, speak, release and hear the reply —
  see [Push-to-talk](#push-to-talk).
- Settings: email, member-since date, app version and sign out.
- Android system assistant: with Jarvis as the default digital assistant, long-press
  Power opens a push-to-talk panel over the current app or the lock screen — see
  [Android system assistant](#android-system-assistant).

A temporary, debug-only screen also sends text to the Jarvis assistant and shows its
reply — see [Developer text assistant](#developer-text-assistant-debug-only).

**Not implemented yet:** AI agents.

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

## Push-to-talk

The home screen is built around one voice button.

- **Hold** the button and speak: the status shows **Listening…** once the microphone is
  actually recording.
- **Release** to send: **Jarvis is thinking…**, then **Jarvis is speaking…** while the
  reply plays, then back to **Hold to talk**.
- **Pressing while Jarvis is speaking** stops the reply and starts a new recording.
- **Microphone permission** is requested on first use. If you release during the
  prompt, nothing is recorded. If access is refused, the app says so and records
  nothing.
- **Limits:** a recording shorter than 0.3 s is not sent ("Hold the button a little
  longer."); at 30 s it stops and is sent automatically.
- **Accessibility:** with TalkBack or a keyboard, double-tap (or Enter / Space) to start
  and again to send, or to interrupt a reply. The button is unavailable while Jarvis
  is thinking.
- **Leaving the app** while Jarvis is listening, thinking or speaking (switching apps,
  locking the phone, pulling down the notification shade) cancels the exchange: the
  recording is discarded and a late reply is not played.
- **Errors** are short fixed messages ("Jarvis didn't hear anything.", "Couldn't reach
  Jarvis. Check your connection and try again.", …), never status codes or server
  details. An expired session returns you to login.
- **Languages:** speak Catalan, Spanish, English or Simplified Chinese; there is no
  language setting in the app, because the backend identifies the language. Jarvis
  normally replies in Catalan, spoken with the `ca-ES-AlbaNeural` voice, so any
  foreign-language words you ask for (a translation, for example) may not sound
  natural.

How it works:

- The app records 16 kHz, 16-bit mono PCM **in memory**, wraps it as a WAV and sends it
  with the Jarvis session to `POST /api/voice/respond`. The reply is MP3 audio. On
  Android it is played from memory through audioplayers' byte source (verified on a
  Pixel); other platform backends may buffer audio internally.
- Jarvis does not create audio files of its own: recordings and replies are not saved,
  and application logs never contain audio, transcripts or replies.
- The voice request has its own **100-second** timeout, longer than the backend's
  combined speech and model limits.
- The recording, network and playback logic lives in a voice controller that does not
  depend on the button, so other triggers can reuse it later.

To try it on a physical phone, configure Microsoft Foundry and Azure AI Speech in the
backend (see [../backend/README.md](../backend/README.md#azure-ai-speech-optional)),
then follow the run steps in
[Try it on a physical Android phone](#try-it-on-a-physical-android-phone) and hold the
voice button on the home screen.

Verified end to end on a physical Android device against the local FastAPI backend,
Azure AI Speech and Microsoft Foundry.

## Android system assistant

Jarvis can be Android's default digital assistant. Choose it in Android Settings
(Default apps → Digital assistant app); then long-pressing Power opens Jarvis, as the
system assistant would.

- A **compact bottom panel** appears over the current app or the lock screen, on a
  translucent window. It contains only the push-to-talk button, its status and Close:
  no navigation, settings or account details.
- **Push-to-talk only:** nothing is recorded when the panel opens; hold the button to
  talk, exactly as in the app.
- **Microphone permission is never requested by the panel.** If it is missing, the
  panel shows "Open Jarvis to allow microphone access"; grant it once through the
  normal app.
- **Signed out**, the panel shows "Sign in to Jarvis to use the assistant"; if the
  backend can't be reached at startup, "Can't reach Jarvis" with Retry.
- **Leaving** — Back, a tap outside the panel, Close or the screen turning off — ends
  the session and cancels any recording, request or reply, as when the app leaves the
  foreground.
- **On a locked phone** the panel appears over the lock screen and voice works without
  unlocking; closing it returns to the lock screen, still locked.

How it works:

- A dedicated native `AssistantActivity` handles `ACTION_ASSIST`, which makes Jarvis
  eligible for `ROLE_ASSISTANT`. The launcher still opens the normal `MainActivity`.
- It runs its own Flutter engine with a separate Dart entrypoint
  (`lib/assistant_main.dart`). That entrypoint reaches none of the normal app's
  router, screens or settings; a test checks its import graph. The voice controller
  and push-to-talk widget are shared with the app.
- The activity shows over the lock screen only for a valid assistant invocation (the
  `ACTION_ASSIST` action while Jarvis holds the role). Any other launch ends at once.
  The setting is cleared when the session ends.
- There is deliberately no native ↔ Dart invocation channel in v0.3.0: nothing needs
  one until a feature reacts to how or where Jarvis was invoked.

Verified on a physical Pixel (Android 17): unlocked and truly locked voice exchanges,
dismissal while listening, thinking and speaking by each way of leaving, revoked and
restored microphone permission, and no change to the normal app. Android reports the
panel as drawn about 1.1–1.5 s after the assistant starts from cold, and 0.8–0.95 s when
Jarvis is already running.

## Developer text assistant (debug only)

A **temporary** screen for testing the assistant by text before speech exists. It
is developer scaffolding, not the Jarvis experience: it will be replaced by the voice
interaction flow.

- **Debug builds only.** Settings shows a **Developer** section with
  **Developer: ask Jarvis by text**. Profile and release builds have neither the
  entry nor the `/developer/text-assistant` route; navigating to it goes home.
- **One message at a time** (1–4000 characters after trimming, counted like the
  backend: an emoji is one character). Send is disabled while a request runs.
- **Latest reply only.** A new request replaces the previous reply or error. There is
  no history, nothing is saved, and leaving the screen discards its text and reply.
- Uses the signed-in Jarvis session (`Authorization: Bearer`) to call
  `POST /api/assistant/respond`. The app never receives Azure or Microsoft Foundry
  credentials or configuration; the backend handles the model.
- The assistant request has its own **35-second** timeout, so the backend's
  25-second model timeout can answer first. Other requests keep the 15-second default.
- Errors are shown as short messages ("Jarvis is busy. Try again shortly.", …), never
  status codes or server details. An expired session returns you to login.
- No microphone, recording or speech is involved.

### Try it on a physical Android phone

The backend needs Microsoft Foundry configured — see
[../backend/README.md](../backend/README.md#microsoft-foundry-optional). Without it,
the screen shows "Jarvis is not available."

1. Start the backend on your network (in `backend/`, with its virtual environment):

   ```bash
   python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```

2. Connect the phone (USB or wireless debugging) and check it is listed:

   ```bash
   adb devices
   flutter devices      # note the device id
   ```

3. Run the app on the phone, using your computer's LAN IP:

   ```bash
   flutter run -d <device-id> --dart-define=API_BASE_URL=http://<LAN-IP>:8000
   ```

4. Log in or register on the phone.
5. Open **Settings → Developer → Developer: ask Jarvis by text**.
6. Send a message and check that a reply appears.

Verified end to end on a physical Android device against the local FastAPI backend
and Microsoft Foundry deployment.

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
- The app holds no Azure or Microsoft Foundry credentials or configuration; it only
  talks to the Jarvis backend with the Jarvis session token.
- Assistant messages and replies are kept only in memory by the mobile developer
  screen and are not persisted by the app. Application logs do not record their
  content.
- The only permission added for voice is `RECORD_AUDIO`, requested on first use by
  the app; the system assistant panel only checks it and never asks.
  Jarvis keeps recordings and spoken replies only for one exchange and never saves,
  logs or intentionally writes them to files (Android playback is in memory). Voice
  activity stops when the app or the assistant panel leaves the foreground.
- The assistant panel can be shown over the lock screen, so it shows no account
  details and offers no account actions.
- The app version shown in Settings comes from `pubspec.yaml` via the Flutter build
  (`FLUTTER_BUILD_NAME`); it is build metadata, not configuration.

## Checks

```bash
flutter analyze
dart format --set-exit-if-changed .
flutter test
flutter build apk --debug
```
