/// Connection settings for the Connectly chat backend.
///
/// These are meant to be baked in once at build time - never shown to the
/// end user as editable text fields, and never bundled with a hardcoded
/// secret (there is no secret here; `publicKey` is a publishable identifier,
/// safe to embed in a shipped app the same way it's safe to embed in a web page).
class ConnectlyChatConfig {
  /// The `Chatting App.public_key` from the Connectly Desk.
  final String publicKey;

  /// Base URL of the Frappe/Connectly backend, e.g. `https://your-site.com`.
  final String apiBaseUrl;

  /// Base URL where `chatting-ws-server` is reachable - usually the same as
  /// [apiBaseUrl] once it's behind the same reverse proxy.
  final String wsUrl;

  /// Socket.IO path - only change this if the server's `socketio_path` changes.
  final String socketPath;

  const ConnectlyChatConfig({
    required this.publicKey,
    required this.apiBaseUrl,
    required this.wsUrl,
    this.socketPath = '/connectly-socket/',
  });

  /// Reads the connection settings from compile-time constants passed via
  /// `--dart-define` at build/run time, e.g.:
  ///
  /// ```
  /// flutter build apk \
  ///   --dart-define=CONNECTLY_PUBLIC_KEY=pk_xxx \
  ///   --dart-define=CONNECTLY_API_BASE_URL=https://your-site.com \
  ///   --dart-define=CONNECTLY_WS_URL=https://your-site.com
  /// ```
  ///
  /// This is the recommended way to configure the SDK: the values are compiled
  /// into the binary, not stored in any user-editable settings screen.
  factory ConnectlyChatConfig.fromEnvironment() {
    const publicKey = String.fromEnvironment('CONNECTLY_PUBLIC_KEY');
    const apiBaseUrl = String.fromEnvironment('CONNECTLY_API_BASE_URL');
    const wsUrl = String.fromEnvironment('CONNECTLY_WS_URL');
    const socketPath = String.fromEnvironment(
      'CONNECTLY_SOCKET_PATH',
      defaultValue: '/connectly-socket/',
    );

    // A real check, not an assert: asserts are stripped from release/profile
    // builds, where a missing value otherwise surfaces much later as a cryptic
    // "No host specified in URI /api/method/..." network error.
    final missing = [
      if (publicKey.isEmpty) 'CONNECTLY_PUBLIC_KEY',
      if (apiBaseUrl.isEmpty) 'CONNECTLY_API_BASE_URL',
      if (wsUrl.isEmpty) 'CONNECTLY_WS_URL',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'connectly_chat: ${missing.join(', ')} not set. Pass them at build/run time, e.g. '
        'flutter run --dart-define=CONNECTLY_PUBLIC_KEY=pk_... '
        '--dart-define=CONNECTLY_API_BASE_URL=https://your-site '
        '--dart-define=CONNECTLY_WS_URL=https://your-site '
        '(running from the IDE? add them to its launch configuration).',
      );
    }

    return const ConnectlyChatConfig(
      publicKey: publicKey,
      apiBaseUrl: apiBaseUrl,
      wsUrl: wsUrl,
      socketPath: socketPath,
    );
  }
}

/// Call [ConnectlyChat.configure] exactly once (e.g. in `main()`, before
/// `runApp`) - every [ConnectlyChatWidget] afterwards picks it up automatically,
/// so nothing about the connection is ever exposed as a runtime-editable field.
class ConnectlyChat {
  ConnectlyChat._();

  static ConnectlyChatConfig? _config;

  static void configure(ConnectlyChatConfig config) {
    _config = config;
  }

  static bool get isConfigured => _config != null;

  static ConnectlyChatConfig get config {
    final c = _config;
    if (c == null) {
      throw StateError(
        'ConnectlyChat.configure() must be called once (e.g. in main()) before '
        'using ConnectlyChatWidget.',
      );
    }
    return c;
  }
}
