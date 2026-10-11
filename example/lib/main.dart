import 'package:connectly_chat/connectly_chat.dart';
import 'package:flutter/material.dart';

void main() {
  // Configure once, before runApp() - never as a runtime-editable settings
  // screen. In a real app these come from --dart-define at build time, e.g.:
  //
  //   flutter run \
  //     --dart-define=CONNECTLY_PUBLIC_KEY=pk_xxx \
  //     --dart-define=CONNECTLY_API_BASE_URL=https://your-site.com \
  //     --dart-define=CONNECTLY_WS_URL=https://your-site.com
  //
  // ConnectlyChatConfig.fromEnvironment() reads exactly those three values.
  ConnectlyChat.configure(ConnectlyChatConfig.fromEnvironment());

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Connectly Chat Example',
      home: Scaffold(
        appBar: AppBar(title: const Text('Connectly Chat Example')),
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatPage()),
            ),
            child: const Text('Open chat'),
          ),
        ),
      ),
    );
  }
}

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ConnectlyChatWidget(
          title: 'Support',
          onClose: () => Navigator.pop(context),
          // Customize freely - every field here is optional.
          theme: const ConnectlyChatTheme(
            primaryColor: Color(0xFF4F46E5),
            headerBackgroundColor: Color(0xFF4F46E5),
            visitorBubbleColor: Color(0xFF4F46E5),
            otherBubbleColor: Color(0xFFF1F1F4),
          ),
          options: const ConnectlyChatOptions(
            enableAttachments: true,
            enableVoiceRecording: true,
            allowedFileExtensions: ['png', 'jpg', 'jpeg', 'pdf'],
            enableTalkToHuman: true,
          ),
        ),
      ),
    );
  }
}
