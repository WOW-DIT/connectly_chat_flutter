/// Feature toggles and behavior tuning for [ConnectlyChatWidget].
///
/// Everything here has a sensible default - pass only what you want to change.
class ConnectlyChatOptions {
  /// Show the attachment (file picker) button.
  final bool enableAttachments;

  /// Show the voice-recording button.
  final bool enableVoiceRecording;

  /// File extensions selectable via the attachment picker (without the dot).
  final List<String> allowedFileExtensions;

  /// Reject a picked file larger than this.
  final int maxFileSizeBytes;

  /// Maximum voice note duration.
  final Duration maxRecordingDuration;

  /// If the app was killed while the chat was open (Android often does this
  /// while the gallery/file picker is in front), reopening it within this
  /// long continues that chat instead of starting a new one. Closing the chat
  /// normally always ends it. [Duration.zero] turns this off.
  final Duration resumeInterruptedChatWithin;

  /// Show the animated "..." dots when the other side is typing.
  final bool enableTypingIndicator;

  /// How often [sendTyping] pings are actually sent while the visitor types
  /// (throttled locally - the widget calls this on every keystroke).
  final Duration typingThrottle;

  /// Play a sound when a new message arrives.
  final bool enableSounds;

  /// Show the "talk to a human" button.
  final bool enableTalkToHuman;

  /// Shown as the first message in an empty conversation.
  final String? welcomeMessage;

  final String inputPlaceholder;
  final String talkToHumanLabel;
  final String connectingLabel;
  final String onlineLabel;
  final String waitingForAgentLabel;
  final String agentConnectedLabel;

  /// Shown above the "talk to a human" button while the AI is answering.
  final String talkToHumanHint;

  /// In-chat notice when the agent hands the conversation back.
  final String agentLeftLabel;

  /// Shown (with [retryLabel]) only after silent reconnecting gave up.
  final String connectionLostLabel;

  /// Shown when a message was refused for exceeding the per-minute limit;
  /// `{seconds}` becomes the wait time.
  final String rateLimitedLabel;
  final String retryLabel;

  /// 0 disables the limit.
  final int messageCharacterLimit;

  const ConnectlyChatOptions({
    this.enableAttachments = true,
    this.enableVoiceRecording = true,
    this.allowedFileExtensions = const [
      'png', 'jpg', 'jpeg', 'gif', 'webp',
      'pdf', 'doc', 'docx', 'txt',
    ],
    this.maxFileSizeBytes = 10 * 1024 * 1024,
    this.maxRecordingDuration = const Duration(minutes: 2),
    this.enableTypingIndicator = true,
    this.typingThrottle = const Duration(seconds: 2),
    this.enableSounds = true,
    this.enableTalkToHuman = true,
    this.welcomeMessage = 'Hi! How can we help you today?',
    this.inputPlaceholder = 'Type a message...',
    this.talkToHumanLabel = 'Talk to a human',
    this.connectingLabel = 'Connecting...',
    this.onlineLabel = 'Online',
    this.waitingForAgentLabel = 'Connecting you with a human agent...',
    this.agentConnectedLabel = 'You are now chatting with a human agent',
    this.talkToHumanHint = 'Need a person?',
    this.agentLeftLabel = 'The agent has left the chat. Our assistant is back to help.',
    this.connectionLostLabel = 'Connection lost',
    this.rateLimitedLabel = "You're sending messages too fast. Try again in {seconds}s.",
    this.retryLabel = 'Retry',
    this.messageCharacterLimit = 2000,
    this.resumeInterruptedChatWithin = const Duration(minutes: 30),
  });
}
