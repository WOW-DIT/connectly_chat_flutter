// Live test against the real backend - run with:
//   CONNECTLY_LIVE=1 flutter test test/reconnect_live_test.dart
import 'dart:async';
import 'dart:io';

import 'package:connectly_chat/connectly_chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final live = Platform.environment['CONNECTLY_LIVE'] == '1';

void main() {
  setUpAll(() {
    HttpOverrides.global = null; // flutter_test blocks real HTTP by default
    SharedPreferences.setMockInitialValues({});
  });

  test('reconnect after a dropped transport keeps the chat and history has every role', () async {
    final client = ConnectlyChatClient(const ConnectlyChatConfig(
      publicKey: 'pk_84cbb761ffe6b6bdcec3af6b4d972758',
      apiBaseUrl: 'https://connectly.wowdigital.sa',
      wsUrl: 'https://connectly.wowdigital.sa',
    ));
    final states = <ConnectlyConnectionState>[];
    client.connectionChanges.listen(states.add);
    final readies = <String>[];
    client.onReady.listen(readies.add);
    final replies = <ConnectlyMessage>[];
    client.messages.listen(replies.add);

    await client.connect();
    await _until(() => readies.isNotEmpty, 'first ready');
    final chatId = readies.first;

    await client.sendMessage('reconnect test', clientId: 'live-${DateTime.now().microsecondsSinceEpoch}');
    await _until(() => replies.isNotEmpty, 'AI reply');

    client.debugDropConnection();
    await _until(() => readies.length >= 2, 'ready after reconnect', seconds: 30);

    final history = await client.fetchHistory();
    // ignore: avoid_print
    print('states: $states\nchat: $chatId -> ${client.chatId}\n'
        'history: ${history.map((m) => '${m.role}:${m.content.length > 20 ? m.content.substring(0, 20) : m.content}').toList()}');

    // ignore: avoid_print
    print('isLive after ready: ${client.isLive} | handoff: ${client.handoffStatus}');
    expect(client.isLive, isFalse);
    expect(client.chatId, chatId);
    expect(history.where((m) => m.role == 'user'), isNotEmpty);
    expect(history.where((m) => m.role != 'user'), isNotEmpty, reason: 'AI/agent messages missing from history');
    client.dispose();
  }, skip: !live, timeout: const Timeout(Duration(minutes: 3)));

  _backgroundScenario();
  _wakeScenario();
}

void _backgroundScenario() {
  test('backgrounded drop: no attempts wasted, and sending text reconnects + delivers', () async {
    final client = ConnectlyChatClient(const ConnectlyChatConfig(
      publicKey: 'pk_84cbb761ffe6b6bdcec3af6b4d972758',
      apiBaseUrl: 'https://connectly.wowdigital.sa',
      wsUrl: 'https://connectly.wowdigital.sa',
    ));
    final states = <ConnectlyConnectionState>[];
    client.connectionChanges.listen(states.add);
    final readies = <String>[];
    client.onReady.listen(readies.add);
    final replies = <ConnectlyMessage>[];
    client.messages.listen(replies.add);

    await client.connect();
    await _until(() => readies.isNotEmpty, 'first ready');

    client.pauseReconnecting(); // app went behind the file picker
    client.debugDropConnection(); // ...and Android dropped the socket
    await Future<void>.delayed(const Duration(seconds: 8)); // longer than a whole retry round
    // ignore: avoid_print
    print('while backgrounded: ${client.connectionState} (attempts would have failed by now)');
    expect(client.connectionState, isNot(ConnectlyConnectionState.failed));

    // Back in the app: the visitor just types and sends - no Retry tap.
    await client.sendMessage('text after picker', clientId: 'bg-${DateTime.now().microsecondsSinceEpoch}');
    await _until(() => replies.isNotEmpty, 'AI reply to the text');
    // ignore: avoid_print
    print('states: $states\nsame chat: ${client.chatId == readies.first} | reply: ${replies.first.content.length > 20 ? replies.first.content.substring(0, 20) : replies.first.content}');
    expect(client.chatId, readies.first);
    client.dispose();
  }, skip: !live, timeout: const Timeout(Duration(minutes: 3)));
}

void _wakeScenario() {
  test('ensureConnected: alive -> no-op; down -> reconnects to the same chat', () async {
    final client = ConnectlyChatClient(const ConnectlyChatConfig(
      publicKey: 'pk_84cbb761ffe6b6bdcec3af6b4d972758',
      apiBaseUrl: 'https://connectly.wowdigital.sa',
      wsUrl: 'https://connectly.wowdigital.sa',
    ));
    final readies = <String>[];
    client.onReady.listen(readies.add);
    await client.connect();
    await _until(() => readies.isNotEmpty, 'first ready');

    final t = DateTime.now();
    await client.ensureConnected(); // screen back on, socket fine
    // ignore: avoid_print
    print('alive check: ${DateTime.now().difference(t).inMilliseconds}ms, readies=${readies.length}');
    expect(readies.length, 1);

    client.pauseReconnecting(); // screen off...
    client.debugDropConnection(); // ...connection gone
    await Future<void>.delayed(const Duration(seconds: 3));
    final t2 = DateTime.now();
    await client.ensureConnected(); // screen back on
    await _until(() => readies.length >= 2, 'ready after wake', seconds: 20);
    // ignore: avoid_print
    print('woke + reconnected in ${DateTime.now().difference(t2).inMilliseconds}ms, same chat: ${readies[1] == readies[0]}');
    expect(readies[1], readies[0]);
    client.dispose();
  }, skip: !live, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _until(bool Function() cond, String what, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
