import 'package:connectly_chat/connectly_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromEnvironment without --dart-define fails clearly, in every build mode', () {
    expect(
      () => ConnectlyChatConfig.fromEnvironment(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('CONNECTLY_API_BASE_URL'))),
    );
  });
}
