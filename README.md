# connectly_chat

Embeddable AI chat widget for Flutter apps, talking to a Connectly `Chatting App`
(the Standalone SDK channel) - AI-first, with optional handoff to a human agent.
This is a **package**, not a standalone app: add it to an existing Flutter project
and drop `ConnectlyChatWidget` in wherever you want a chat screen.

## Install

```bash
flutter pub add connectly_chat
```

(Coming soon to pub.dev.) Until then, add it straight from GitHub in your app's `pubspec.yaml`:

```yaml
dependencies:
  connectly_chat:
    git:
      url: https://github.com/WOW-DIT/connectly_chat_flutter.git
```

or, if you vendor the source directly into your app's repo:

```yaml
dependencies:
  connectly_chat:
    path: ../connectly_chat_flutter
```

Then:

```bash
flutter pub get
```

### Platform setup (required)

**Android** (`android/app/src/main/AndroidManifest.xml`), inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<!-- Only if you enable voice recording -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

**iOS** (`ios/Runner/Info.plist`), only if you enable voice recording:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used to record voice messages in chat.</string>
```

The package can't inject these into your app's manifest/plist itself - that's a
constraint of how Flutter packages work, not something `connectly_chat` can
paper over. See `example/` for a working reference of both files.

## Configure (once, at build time - not a settings screen)

The connection details (`public_key`, API host, WebSocket host) are meant to be
baked into the app binary, never shown as editable text fields. Call
`ConnectlyChat.configure(...)` exactly once, before `runApp()`:

```dart
import 'package:connectly_chat/connectly_chat.dart';
import 'package:flutter/material.dart';

void main() {
  ConnectlyChat.configure(ConnectlyChatConfig.fromEnvironment());
  runApp(const MyApp());
}
```

`ConnectlyChatConfig.fromEnvironment()` reads three compile-time constants via
`--dart-define`, so you pass them at build/run time and they get compiled into
the binary - never stored, never editable at runtime:

```bash
flutter run \
  --dart-define=CONNECTLY_PUBLIC_KEY=pk_xxxxxxxxxxxxxxxx \
  --dart-define=CONNECTLY_API_BASE_URL=https://your-site.com \
  --dart-define=CONNECTLY_WS_URL=https://your-site.com
```

Use the exact same three `--dart-define` flags on `flutter build apk` /
`flutter build ipa` for a release build. If your CI has a secrets mechanism,
inject these as build args from there rather than committing them to a script.

Alternatively, construct `ConnectlyChatConfig(...)` directly if you'd rather
source these values from your own build-flavor setup - just make sure it's
still resolved once at build/init time, not read from user input.

`public_key` is a **publishable** identifier (same trust model as a Stripe
publishable key) - it's meant to be embedded in a shipped app. It is not a
secret and does not need to be protected as one. See "Abuse considerations" below.

## Use it

```dart
import 'package:connectly_chat/connectly_chat.dart';
import 'package:flutter/material.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ConnectlyChatWidget(
          title: 'Support',
          onClose: () => Navigator.pop(context),
        ),
      ),
    );
  }
}
```

Push it like any other screen:

```dart
Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
```

See `example/lib/main.dart` for a complete runnable app.

### Identified (logged-in) visitors

By default every visitor is an anonymous guest. To attach a real identity
(so a human agent sees who they're talking to, and so the same person's
history follows them across devices), pass `identifyToken`:

```dart
ConnectlyChatWidget(identifyToken: myBackendIssuedToken)
```

`identifyToken` must come from **your own backend** - see
[`IDENTIFY_TOKEN.md`](IDENTIFY_TOKEN.md) for exactly how to generate it and
why it can't be generated on-device.

## Customize

### Colors, background, bubble shape

```dart
ConnectlyChatWidget(
  theme: const ConnectlyChatTheme(
    primaryColor: Color(0xFF4F46E5),
    headerBackgroundColor: Color(0xFF4F46E5),
    backgroundColor: Color(0xFFF3F4F6),
    // backgroundImage: DecorationImage(image: AssetImage('assets/bg.png'), fit: BoxFit.cover),
    visitorBubbleColor: Color(0xFF4F46E5),
    otherBubbleColor: Color(0xFFF1F1F4),
    visitorTextColor: Colors.white,
    otherTextColor: Colors.black87,
    bubbleBorderRadius: BorderRadius.all(Radius.circular(16)),
  ),
)
```

### Attachments, voice notes, behavior

```dart
ConnectlyChatWidget(
  options: const ConnectlyChatOptions(
    enableAttachments: true,
    enableVoiceRecording: true,
    allowedFileExtensions: ['png', 'jpg', 'jpeg', 'pdf'],
    maxFileSizeBytes: 10 * 1024 * 1024,
    maxRecordingDuration: Duration(minutes: 2),
    enableTypingIndicator: true,
    enableTalkToHuman: true,
    welcomeMessage: 'Hi! How can we help you today?',
    messageCharacterLimit: 2000,
  ),
)
```

Every field on `ConnectlyChatOptions` and `ConnectlyChatTheme` is optional with
a sensible default - pass only what you want to change.

### Full list of `ConnectlyChatOptions` fields

| Field | Default | Purpose |
|---|---|---|
| `enableAttachments` | `true` | Show the file-attachment button |
| `enableVoiceRecording` | `true` | Show the voice-note button |
| `allowedFileExtensions` | png/jpg/jpeg/gif/webp/pdf/doc/docx/txt | Extensions selectable in the file picker |
| `maxFileSizeBytes` | 10 MB | Client-side size check before upload |
| `maxRecordingDuration` | 2 min | Auto-stops a voice recording at this length |
| `enableTypingIndicator` | `true` | Show/receive the animated typing dots |
| `typingThrottle` | 2s | Minimum gap between outgoing typing pings |
| `enableSounds` | `true` | Reserved for a notification sound (wire up your own asset via a fork/PR if needed) |
| `enableTalkToHuman` | `true` | Show the handoff button |
| `welcomeMessage` | "Hi! How can..." | First line shown in an empty conversation; `null` to hide |
| `inputPlaceholder` / `talkToHumanLabel` / `connectingLabel` / `onlineLabel` / `waitingForAgentLabel` / `agentConnectedLabel` | English defaults | All user-facing strings - override for localization |
| `messageCharacterLimit` | 2000 | `0` disables the limit |

## Architecture notes

- Transport is Socket.IO (`socket_io_client`), matching the server's
  `python-socketio` backend - not a custom WebSocket protocol.
- Guest identity (`visitor_id`) persists via `shared_preferences` so a returning
  guest resumes their conversation history across app restarts.
- Attachments and voice notes go over a plain REST upload
  (`connectly.chatting.api.send_attachment`), not the socket - the realtime
  channel only carries text messages/events. The resulting message (and any
  AI reply it triggers) arrives back over the socket like everything else.
- `ConnectlyChatClient` (the protocol layer) and `ConnectlyChatWidget` (the UI)
  are separate - use the client directly if you want to build fully custom UI.

## Abuse considerations

`public_key` is embedded in the shipped binary and can be extracted (there is
no equivalent of a browser's Origin header for native apps to restrict it by).
A stolen key lets someone else start guest conversations against your AI agent
- it does **not** grant access to other visitors' conversations, other
`Chatting App`s, or any privileged/admin action. The backend rate-limits
session creation per key. If this becomes a real problem, ask about adding
package-name/signing-certificate verification or Play Integrity/App Attest.

## What's not implemented yet

- Read receipts / delivered ticks
- Push notifications when the app is backgrounded (would need FCM/APNs wiring
  on top of this package - out of scope here)
- Persistent local message cache (history reloads from the server on each
  `ConnectlyChatWidget` mount; only the guest `visitor_id` itself persists)
