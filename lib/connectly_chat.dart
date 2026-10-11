/// Embeddable chat widget for the Connectly Standalone channel - AI-first,
/// with optional handoff to a human agent.
library;

export 'src/client.dart' show ConnectlyChatClient, ConnectlyChatException, ConnectlyRateLimitException;
export 'src/config.dart' show ConnectlyChat, ConnectlyChatConfig;
export 'src/models.dart' show ConnectlyConnectionState, ConnectlyMessage, ConnectlyMessageStatus, ConnectlyMessageType;
export 'src/options.dart' show ConnectlyChatOptions;
export 'src/theme.dart' show ConnectlyChatTheme;
export 'src/widgets/chat_widget.dart' show ConnectlyChatWidget;
