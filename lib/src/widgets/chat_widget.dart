import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client.dart';
import '../config.dart';
import '../models.dart';
import '../options.dart';
import '../theme.dart';
import 'message_bubble.dart';
import 'typing_dots.dart';

/// A drop-in chat screen: connects using [ConnectlyChat.config] (set once via
/// `ConnectlyChat.configure(...)` in your `main()`), and renders the whole
/// conversation - text, attachments, voice notes, typing indicator, and the
/// "talk to a human" handoff flow.
///
/// Embed it directly, or push it as a page:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
///   body: SafeArea(child: ConnectlyChatWidget()),
/// )));
/// ```
class ConnectlyChatWidget extends StatefulWidget {
  final ConnectlyChatTheme theme;
  final ConnectlyChatOptions options;

  /// Pass a JWT your own backend signed with the app's secret_key to open an
  /// identified session. Leave null for an anonymous guest session.
  final String? identifyToken;

  /// Resume this conversation instead of starting a new one - pass the id
  /// [onChatStarted] gave you earlier. Null starts a new conversation.
  final String? chatId;

  /// Called once connected, with the conversation's id. Save it and pass it
  /// back as [chatId] next time to continue the same chat.
  final ValueChanged<String>? onChatStarted;

  /// A message arrived from the other side (AI or human agent) - live only,
  /// not the history loaded when resuming.
  final ValueChanged<ConnectlyMessage>? onMessageReceived;

  /// The visitor just sent a message (text, file or voice note), before it's
  /// delivered - [ConnectlyMessage.status] is `sending`. Also fires on retry.
  final ValueChanged<ConnectlyMessage>? onMessageSend;

  /// A sent message's delivery finished: `status` is `sent` or `failed`.
  /// Match it to [onMessageSend]'s message by [ConnectlyMessage.id].
  final ValueChanged<ConnectlyMessage>? onMessageStatusChanged;

  final String title;
  final VoidCallback? onClose;

  const ConnectlyChatWidget({
    super.key,
    this.theme = const ConnectlyChatTheme(),
    this.options = const ConnectlyChatOptions(),
    this.identifyToken,
    this.chatId,
    this.onChatStarted,
    this.onMessageReceived,
    this.onMessageSend,
    this.onMessageStatusChanged,
    this.title = 'Chat with us',
    this.onClose,
  });

  @override
  State<ConnectlyChatWidget> createState() => _ConnectlyChatWidgetState();
}

class _ConnectlyChatWidgetState extends State<ConnectlyChatWidget> with WidgetsBindingObserver {
  late final ConnectlyChatClient _client;
  final List<ConnectlyMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  late final List<StreamSubscription> _subs;

  bool _connecting = true;
  String? _connectError;
  bool _otherTyping = false;
  Timer? _typingHideTimer;
  DateTime? _lastTypingSentAt;
  bool _handoffPending = false;
  bool _handoffActive = false;
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Timer? _recordingTicker;
  bool _everReady = false;

  /// Ids of messages this screen sent - matched against history's ids on
  /// refresh, so each shows once whether or not the server has stored it yet.
  final Set<String> _sentHereIds = {};
  ConnectlyConnectionState _connection = ConnectlyConnectionState.connecting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = ConnectlyChatClient(ConnectlyChat.config);

    _subs = [
      _client.onReady.listen((chatId) {
        if (mounted) {
          setState(() {
            _connecting = false;
            // The server's word on who owns the chat - so "talk to a human"
            // stays hidden for a chat that's already live (also after resuming).
            final status = _client.handoffStatus;
            _handoffPending = status == 'Pending' || status == 'Assigned';
            _handoffActive = !_handoffPending && (_client.isLive || status == 'Accepted');
          });
        }
        widget.onChatStarted?.call(chatId);
        // First "ready": load the past only when resuming. Every later one is
        // a reconnect - reload so replies sent while offline aren't missing.
        if (_everReady || _resumedChatId != null) _refreshMessages();
        _rememberOpenChat(chatId);
        _everReady = true;
      }),
      _client.connectionChanges.listen((state) {
        if (mounted) setState(() => _connection = state);
      }),
      _client.messages.listen(_onMessage),
      _client.typing.listen((_) => _onTypingReceived()),
      _client.onHandoffRequested.listen((_) {
        if (mounted) setState(() => _handoffPending = true);
      }),
      _client.onHandoffAccepted.listen((_) => _setLive(true)),
      _client.onHandoffResolved.listen((_) => _setLive(false)),
      _client.onLiveChanged.listen(_setLive),
      _client.onError.listen((err) {
        if (mounted) setState(() => _connectError = err);
      }),
    ];

    _startConnect();
  }

  /// The chat to continue on first connect: the one the host passed, or the
  /// one this screen had open when the app was killed (see
  /// [ConnectlyChatOptions.resumeInterruptedChatWithin]).
  String? _resumedChatId;

  String get _openChatPrefsKey => 'connectly_open_chat_${ConnectlyChat.config.publicKey}';

  Future<String?> _interruptedChatId() async {
    final window = widget.options.resumeInterruptedChatWithin;
    if (window == Duration.zero) return null;
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_openChatPrefsKey);
      if (saved == null) return null;
      final sep = saved.indexOf('|');
      final at = DateTime.fromMillisecondsSinceEpoch(int.parse(saved.substring(0, sep)));
      return DateTime.now().difference(at) <= window ? saved.substring(sep + 1) : null;
    } catch (_) {
      return null;
    }
  }

  /// Marks [chatId] as open (with the time) - cleared again in [dispose]. If
  /// the OS kills the app first, dispose never runs and the mark survives.
  Future<void> _rememberOpenChat(String chatId) async {
    if (widget.options.resumeInterruptedChatWithin == Duration.zero) return;
    try {
      await (await SharedPreferences.getInstance())
          .setString(_openChatPrefsKey, '${DateTime.now().millisecondsSinceEpoch}|$chatId');
    } catch (_) {}
  }

  Future<void> _forgetOpenChat() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_openChatPrefsKey);
    } catch (_) {}
  }

  void _startConnect() {
    // Also runs from initState, where setState isn't allowed (nothing to clear yet).
    if (_connectError != null) setState(() => _connectError = null);
    // A retry stays on the client's current chat (connect() defaults to it);
    // only the first attempt decides between the host's/interrupted chat and a new one.
    _connectFirstTime().catchError((e) {
      if (mounted) setState(() => _connectError = e.toString());
    });
  }

  bool _firstConnectDone = false;

  Future<void> _connectFirstTime() async {
    if (!_firstConnectDone) {
      _firstConnectDone = true;
      _resumedChatId = widget.chatId ?? await _interruptedChatId();
    }
    // The chat the client is on, else the one being resumed - so a retry after
    // a failed first attempt doesn't fall back to starting a new chat.
    return _client.connect(identifyToken: widget.identifyToken, chatId: _client.chatId ?? _resumedChatId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS can drop the socket while the app is in the background - e.g.
    // while the file picker or camera is open. Reconnect on return.
    // Screen back on, picker/camera closed, switched back to the app: the socket
    // may be down - or look up while dead. Check, and reconnect if needed.
    if (state == AppLifecycleState.resumed) _client.ensureConnected();
    // Going to the background (gallery, file picker, home...) is when the OS
    // may kill the app - refresh the "open chat" mark so it's current then.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _client.pauseReconnecting();
      final chatId = _client.chatId;
      if (chatId != null) _rememberOpenChat(chatId);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _typingHideTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _recordingTicker?.cancel();
    _audioRecorder.dispose();
    _forgetOpenChat();
    _client.dispose();
    super.dispose();
  }

  void _onMessage(ConnectlyMessage msg) {
    // A human agent writing means they've taken over - even if the "accepted"
    // notice was missed, stop showing "connecting you with a human agent...".
    if (msg.role == 'agent' && !_handoffActive) _setLive(true);
    setState(() {
      _otherTyping = false;
      _typingHideTimer?.cancel();
      _messages.add(msg);
    });
    _scrollToBottom();
    widget.onMessageReceived?.call(msg);
  }

  void _onTypingReceived() {
    if (!widget.options.enableTypingIndicator) return;
    setState(() => _otherTyping = true);
    _typingHideTimer?.cancel();
    _typingHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _otherTyping = false);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleTextChanged(String _) {
    final now = DateTime.now();
    final last = _lastTypingSentAt;
    if (last == null || now.difference(last) > widget.options.typingThrottle) {
      _lastTypingSentAt = now;
      _client.sendTyping();
    }
  }

  /// Replaces the list with the server's copy of the chat, plus the messages
  /// sent from here that it doesn't have yet (sending, failed, or acked but
  /// still being processed). Matching is by id - the SDK sends its own id with
  /// each message and history returns it - so nothing shows twice.
  Future<void> _refreshMessages() async {
    try {
      final history = await _client.fetchHistory();
      if (!mounted) return;
      setState(() {
        final stored = history.map((m) => m.id).toSet();
        final notStoredYet = _messages.where((m) => _sentHereIds.contains(m.id) && !stored.contains(m.id));
        // Agent joined/left notices are local - keep them, in time order.
        final notices = _messages.where((m) => m.role == 'system');
        final merged = [...history, ...notStoredYet, ...notices]
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages
          ..clear()
          ..addAll(merged);
      });
      _scrollToBottom();
    } catch (e) {
      _showSnack('Could not load messages: $e');
    }
  }

  void _setStatus(ConnectlyMessage msg, ConnectlyMessageStatus status, {String? fileUrl}) {
    if (!mounted) return;
    final i = _messages.indexWhere((m) => m.id == msg.id);
    if (i == -1) return;
    final updated = _messages[i].copyWith(status: status, fileUrl: fileUrl);
    setState(() => _messages[i] = updated);
    if (status != ConnectlyMessageStatus.sending) widget.onMessageStatusChanged?.call(updated);
  }

  void _send() {
    final limit = widget.options.messageCharacterLimit;
    var text = _textController.text.trim();
    if (text.isEmpty) return;
    if (limit > 0 && text.length > limit) text = text.substring(0, limit);

    final msg = ConnectlyMessage(
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
      status: ConnectlyMessageStatus.sending,
    );
    _sentHereIds.add(msg.id);
    setState(() => _messages.add(msg));
    _textController.clear();
    _scrollToBottom();
    _deliver(msg);
  }

  /// Shows an attachment in the chat right away (from the local file), then
  /// uploads it; the bubble's tick/error reflects how that went.
  void _sendFile(String path) {
    final msg = ConnectlyMessage(
      role: 'user',
      content: '',
      timestamp: DateTime.now(),
      type: typeForFile(path),
      localPath: path,
      status: ConnectlyMessageStatus.sending,
    );
    _sentHereIds.add(msg.id);
    setState(() => _messages.add(msg));
    _scrollToBottom();
    _deliver(msg);
  }

  void _retry(ConnectlyMessage msg) {
    _setStatus(msg, ConnectlyMessageStatus.sending);
    _deliver(msg);
  }

  Future<void> _deliver(ConnectlyMessage msg) async {
    widget.onMessageSend?.call(msg.copyWith(status: ConnectlyMessageStatus.sending));
    if (msg.localPath == null) {
      try {
        await _client.sendMessage(msg.content, clientId: msg.id);
        _setStatus(msg, ConnectlyMessageStatus.sent);
      } catch (e) {
        _setStatus(msg, ConnectlyMessageStatus.failed);
        _explainSendFailure(e);
      }
      return;
    }

    // The server runs the AI before the upload request returns, so the request
    // being in flight is the "AI is thinking" window - show the typing dots for
    // it (the reply arriving over the socket hides them in [_onMessage]).
    final aiWillReply = !_handoffPending && !_handoffActive;
    if (aiWillReply && widget.options.enableTypingIndicator) {
      _typingHideTimer?.cancel();
      setState(() => _otherTyping = true);
      _scrollToBottom();
    }
    try {
      final url = await _client.sendAttachment(File(msg.localPath!), caption: msg.content, clientId: msg.id);
      _setStatus(msg, ConnectlyMessageStatus.sent, fileUrl: url);
    } catch (e) {
      _setStatus(msg, ConnectlyMessageStatus.failed);
      _explainSendFailure(e);
    } finally {
      if (mounted && aiWillReply) setState(() => _otherTyping = false);
    }
  }

  /// Called when the file picker closes. If Android dropped the socket while
  /// the app sat behind the picker, reconnect right away - the reconnect's
  /// "ready" reloads the conversation. Still connected: nothing was missed.
  void _refreshAfterPicker() {
    if (!mounted || !_everReady) return;
    _client.ensureConnected(); // only reconnects if the socket is down (or dead)
  }

  /// A failed bubble says "Not sent, tap to retry" - for the per-minute limit
  /// also say how long to wait.
  void _explainSendFailure(Object error) {
    if (error is ConnectlyRateLimitException) {
      _showSnack(widget.options.rateLimitedLabel.replaceAll('{seconds}', '${error.retryAfter.inSeconds}'));
    }
  }

  Future<void> _pickAttachment() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: widget.options.allowedFileExtensions,
      );
    } finally {
      // Picked or cancelled: the app sat behind the picker, so catch up now.
      _refreshAfterPicker();
    }
    if (files.isEmpty) return;
    final picked = files.first;
    if (picked.path == null) return;

    final fileSize = await picked.length();
    if (fileSize != null && fileSize > widget.options.maxFileSizeBytes) {
      _showSnack(
        'File too large (max ${(widget.options.maxFileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB)',
      );
      return;
    }

    _sendFile(picked.path!);
  }

  Duration get _recordingElapsed =>
      _recordingStartedAt == null ? Duration.zero : DateTime.now().difference(_recordingStartedAt!);

  Future<void> _startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      _showSnack('Microphone permission is required to record a voice message.');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/connectly_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(const RecordConfig(), path: path);
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _recordingStartedAt = DateTime.now();
    });
    // Drives the on-screen timer, and stops+sends at the length limit.
    _recordingTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_recordingElapsed >= widget.options.maxRecordingDuration) {
        _stopRecording(send: true);
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_isRecording) return;
    _recordingTicker?.cancel();
    _recordingTicker = null;
    final tooShort = _recordingElapsed < const Duration(milliseconds: 700);
    setState(() {
      _isRecording = false;
      _recordingStartedAt = null;
    });

    final path = await _audioRecorder.stop();
    if (path == null) return;
    if (!send || tooShort) {
      try {
        await File(path).delete();
      } catch (_) {/* temp file - ignore */}
      if (send && tooShort) _showSnack('Hold on a little longer to record a voice message.');
      return;
    }
    _sendFile(path);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Only after silent reconnecting gave up - a drop the app recovers from on
  /// its own (e.g. coming back from the file picker) shows nothing at all.
  Widget _buildConnectionBanner(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    return Material(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 18, color: Colors.red),
            const SizedBox(width: 10),
            Expanded(
              child: Text(options.connectionLostLabel, style: TextStyle(color: Colors.red.shade900, fontSize: 13)),
            ),
            TextButton(
              onPressed: _client.retry,
              style: TextButton.styleFrom(foregroundColor: theme.primaryColor),
              child: Text(options.retryLabel),
            ),
          ],
        ),
      ),
    );
  }

  void _setLive(bool live) {
    if (!mounted) return;
    final wasActive = _handoffActive;
    setState(() {
      _handoffPending = false;
      _handoffActive = live;
      if (live != wasActive) {
        _messages.add(ConnectlyMessage(
          role: 'system',
          content: live ? widget.options.agentConnectedLabel : widget.options.agentLeftLabel,
          timestamp: DateTime.now(),
        ));
      }
    });
    _scrollToBottom();
  }

  void _requestHuman() {
    setState(() => _handoffPending = true);
    _client.requestHuman();
    _scrollToBottom();
  }

  /// Sits just above the composer, inside the conversation: an invitation to
  /// reach a person while the AI is answering, then a waiting line once asked.
  /// Hidden while a human already owns the chat.
  Widget _buildHandoffBar(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    if (!options.enableTalkToHuman || _connecting || _handoffActive) return const SizedBox.shrink();

    if (_handoffPending) {
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.primaryColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.primaryColor.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: theme.primaryColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(options.waitingForAgentLabel, style: TextStyle(color: theme.primaryColor, fontSize: 13)),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Row(
        children: [
          Icon(Icons.support_agent, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(options.talkToHumanHint, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
          ),
          OutlinedButton(
            onPressed: _connection == ConnectlyConnectionState.connected ? _requestHuman : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.primaryColor,
              side: BorderSide(color: theme.primaryColor.withValues(alpha: 0.4)),
              shape: const StadiumBorder(),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Text(options.talkToHumanLabel),
          ),
        ],
      ),
    );
  }

  String _statusLabel() {
    final o = widget.options;
    if (_connecting) return o.connectingLabel;
    // Reconnecting stays silent (shown as usual); only giving up is visible.
    if (_connection == ConnectlyConnectionState.failed) return o.connectionLostLabel;
    if (_handoffActive) return o.agentConnectedLabel;
    if (_handoffPending) return o.waitingForAgentLabel;
    return o.onlineLabel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final options = widget.options;

    return Column(
      children: [
        _buildHeader(theme, options),
        if (_everReady && _connection == ConnectlyConnectionState.failed) _buildConnectionBanner(theme, options),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: theme.backgroundColor, image: theme.backgroundImage),
            child: _connectError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_connectError!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                            onPressed: _startConnect,
                          ),
                        ],
                      ),
                    ),
                  )
                : _connecting
                    ? const Center(child: CircularProgressIndicator())
                    : _buildMessageList(theme, options),
          ),
        ),
        _buildHandoffBar(theme, options),
        _buildComposer(theme, options),
      ],
    );
  }

  Widget _buildHeader(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.headerBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(color: theme.headerTextColor, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _statusLabel(),
                    style: TextStyle(color: theme.headerTextColor.withValues(alpha: 0.85), fontSize: 12),
                  ),
                ],
              ),
            ),
            if (widget.onClose != null)
              IconButton(icon: Icon(Icons.close, color: theme.headerTextColor), onPressed: widget.onClose),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    final showWelcome = _messages.isEmpty && options.welcomeMessage != null;

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        if (showWelcome)
          Align(
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                options.welcomeMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ),
        for (final m in _messages)
          MessageBubble(key: ValueKey(m.id), message: m, theme: theme, onRetry: () => _retry(m)),
        if (_otherTyping && options.enableTypingIndicator)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: theme.otherBubbleColor, borderRadius: theme.bubbleBorderRadius),
              child: const TypingDots(),
            ),
          ),
      ],
    );
  }

  Widget _buildComposer(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: _isRecording ? _buildRecordingBar(theme, options) : _buildInputBar(theme, options),
      ),
    );
  }

  Widget _buildInputBar(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    return Row(
      children: [
        if (options.enableAttachments)
          IconButton(icon: const Icon(Icons.attach_file), onPressed: _connecting ? null : _pickAttachment),
        if (options.enableVoiceRecording)
          IconButton(
            icon: const Icon(Icons.mic),
            tooltip: 'Record a voice message',
            onPressed: _connecting ? null : _startRecording,
          ),
        Expanded(
          child: TextField(
            controller: _textController,
            enabled: !_connecting,
            onChanged: _handleTextChanged,
            onSubmitted: (_) => _send(),
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              hintText: options.inputPlaceholder,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(Icons.send, color: theme.primaryColor),
          onPressed: _connecting ? null : _send,
        ),
      ],
    );
  }

  static String _formatDuration(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Replaces the input while recording: cancel, a live timer against the
  /// limit, and send - so it's obvious a recording is running and how long.
  Widget _buildRecordingBar(ConnectlyChatTheme theme, ConnectlyChatOptions options) {
    final elapsed = _recordingElapsed;
    final max = options.maxRecordingDuration;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Cancel recording',
          onPressed: () => _stopRecording(send: false),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                const _PulsingDot(),
                const SizedBox(width: 10),
                Text(
                  _formatDuration(elapsed),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recording… max ${_formatDuration(max)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(Icons.send, color: theme.primaryColor),
          tooltip: 'Send voice message',
          onPressed: () => _stopRecording(send: true),
        ),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_controller),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
      ),
    );
  }
}
