import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'config.dart';
import 'models.dart';

class ConnectlyChatException implements Exception {
  final String message;
  ConnectlyChatException(this.message);
  @override
  String toString() => 'ConnectlyChatException: $message';
}

/// The server refused a message because the visitor sent too many this minute
/// (15 by default). It wasn't processed - resend it after [retryAfter].
class ConnectlyRateLimitException extends ConnectlyChatException {
  final Duration retryAfter;
  ConnectlyRateLimitException(this.retryAfter)
      : super('Too many messages - try again in ${retryAfter.inSeconds}s');
}

Duration _retryAfterOf(Object? body) {
  final seconds = body is Map ? int.tryParse('${body['retry_after']}') : null;
  return Duration(seconds: seconds ?? 60);
}

/// Talks to the Connectly backend: exchanges the app's public key for a
/// session over REST, then opens the realtime connection and exposes
/// everything as streams. One instance per conversation - create it when the
/// chat UI opens, [dispose] it when the UI closes.
class ConnectlyChatClient {
  final ConnectlyChatConfig config;

  io.Socket? _socket;
  String? _sessionToken;
  String? _visitorId;
  String? chatId;

  final _messages = StreamController<ConnectlyMessage>.broadcast();
  final _typing = StreamController<void>.broadcast();
  final _ready = StreamController<String>.broadcast();
  final _handoffRequested = StreamController<String>.broadcast();
  final _handoffAccepted = StreamController<void>.broadcast();
  final _handoffResolved = StreamController<void>.broadcast();
  final _liveChanged = StreamController<bool>.broadcast();

  /// Whether a human agent owns the conversation right now - from "ready",
  /// then kept current by live/handoff events. Hide "talk to a human" while true.
  bool isLive = false;

  /// The open handoff request's state ("Pending", "Assigned", "Accepted") as of
  /// the last "ready", or null when there is none.
  String? handoffStatus;
  final _errors = StreamController<String>.broadcast();
  final _connection = StreamController<ConnectlyConnectionState>.broadcast();
  ConnectlyConnectionState _connectionState = ConnectlyConnectionState.connecting;

  String? _identifyToken;
  String? _deviceInfo;

  Stream<ConnectlyMessage> get messages => _messages.stream;
  Stream<void> get typing => _typing.stream;
  Stream<String> get onReady => _ready.stream;
  Stream<String> get onHandoffRequested => _handoffRequested.stream;
  Stream<void> get onHandoffAccepted => _handoffAccepted.stream;
  Stream<void> get onHandoffResolved => _handoffResolved.stream;

  /// The agent switched the chat to Live (true) or back to the AI (false).
  Stream<bool> get onLiveChanged => _liveChanged.stream;
  /// The first connection failing (no session could be created). Drops after
  /// that are reported on [connectionChanges] and retried automatically.
  Stream<String> get onError => _errors.stream;

  Stream<ConnectlyConnectionState> get connectionChanges => _connection.stream;
  ConnectlyConnectionState get connectionState => _connectionState;

  bool get isConnected => _socket?.connected ?? false;

  /// Tests only: drops the transport the way Android does when the app is
  /// backgrounded (e.g. while the file picker is open), without disposing.
  @visibleForTesting
  void debugDropConnection() => _socket?.io.engine?.close();

  ConnectlyChatClient(this.config);

  static const _visitorIdPrefsKey = 'connectly_visitor_id';

  Future<String?> _loadVisitorId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_visitorIdPrefsKey);
    } catch (_) {
      return null; // storage unavailable - guest just won't persist across restarts
    }
  }

  Future<void> _storeVisitorId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_visitorIdPrefsKey, id);
    } catch (_) {
      /* ignore */
    }
  }

  /// Creates/resumes a session and opens the realtime connection.
  ///
  /// Pass [identifyToken] only for identified (logged-in) visitors - a JWT
  /// *your own backend* signs with the app's secret_key. Omit it for guests.
  ///
  /// Pass [chatId] (a value [onReady] emitted earlier) to resume that
  /// conversation; omit it to start a new one. An id that doesn't belong to
  /// this visitor also starts a new one.
  ///
  /// Calling it again (e.g. a retry) stays on the chat this client is already
  /// on unless a different [chatId] is passed.
  Future<void> connect({String? identifyToken, String? deviceInfo, String? chatId}) async {
    _identifyToken = identifyToken;
    _deviceInfo = deviceInfo;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _socket?.dispose();
    _socket = null;
    _setConnection(ConnectlyConnectionState.connecting);
    try {
      await _createSession(chatId: chatId ?? this.chatId);
    } on ConnectlyChatException catch (e) {
      _errors.add(e.message);
      _setConnection(ConnectlyConnectionState.failed);
      rethrow;
    }

    _socket = io.io(
      '${config.wsUrl}/chatting',
      io.OptionBuilder()
          .setPath(config.socketPath)
          // io.io() otherwise caches sockets by URL, so reopening the chat could
          // pick up the previous (disposed) one, still holding the old token.
          .enableForceNew()
          // socket_io_client has no long-polling transport on native (dart:io):
          // listing "polling" still opens a WebSocket but tags it
          // `transport=polling`, which the server rejects. So WebSocket only -
          // any proxy in front must pass the Upgrade/Connection headers through.
          .setTransports(['websocket'])
          // Reconnection is driven by [_scheduleReconnect] instead, so each
          // attempt can refresh the session and the attempts can be capped.
          .disableReconnection()
          .setAuth({'token': _sessionToken})
          .build(),
    );

    _socket!.onDisconnect((_) => _onConnectionLost());
    _socket!.onConnectError((_) => _onConnectionLost());

    _socket!.on('ready', (data) {
      if (data is Map && data['chat_id'] != null) {
        // this.: connect()'s `chatId` parameter would otherwise shadow the
        // field, leaving it null - and every reconnect would start a new chat.
        this.chatId = data['chat_id'].toString();
        isLive = data['is_live'] == true;
        handoffStatus = data['handoff_status']?.toString();
        _reconnectAttempts = 0;
        _setConnection(ConnectlyConnectionState.connected);
        _ready.add(this.chatId!);
      }
    });

    _socket!.on('message', (data) {
      if (data is Map) {
        if (data['role'] == 'agent') {
          isLive = true; // an agent writing = they've taken over
          handoffStatus = 'Accepted';
        }
        _messages.add(ConnectlyMessage.fromSocket(data, baseUrl: config.apiBaseUrl));
      }
    });

    _socket!.on('typing', (_) => _typing.add(null));

    _socket!.on('handoff_requested', (data) {
      final handoff = data is Map ? (data['handoff']?.toString() ?? '') : '';
      _handoffRequested.add(handoff);
    });

    _socket!.on('handoff_accepted', (_) {
      isLive = true;
      handoffStatus = 'Accepted';
      _handoffAccepted.add(null);
    });
    _socket!.on('handoff_resolved', (_) {
      isLive = false;
      handoffStatus = null;
      _handoffResolved.add(null);
    });
    _socket!.on('live_changed', (data) {
      isLive = data is Map && data['is_live'] == true;
      if (!isLive) handoffStatus = null;
      _liveChanged.add(isLive);
    });

    _socket!.connect();
  }

  Future<void> _createSession({String? chatId}) async {
    if (Uri.tryParse(config.apiBaseUrl)?.hasAuthority != true) {
      throw ConnectlyChatException(
        'apiBaseUrl "${config.apiBaseUrl}" is not a full URL like https://your-site - '
        'check ConnectlyChatConfig (or the CONNECTLY_API_BASE_URL --dart-define).',
      );
    }
    _visitorId ??= await _loadVisitorId();

    final uri = Uri.parse('${config.apiBaseUrl}/api/method/connectly.chatting.api.create_session');
    late http.Response response;
    try {
      response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'public_key': config.publicKey,
          // Socket reconnects within this session keep the same chat either way.
          if (chatId != null) 'chat_id': chatId else 'new_chat': true,
          if (_visitorId != null) 'visitor_id': _visitorId,
          if (_identifyToken != null) 'identify_token': _identifyToken,
          if (_deviceInfo != null) 'device_info': _deviceInfo,
        }),
      );
    } catch (e) {
      throw ConnectlyChatException('Network error creating session: $e');
    }

    if (response.statusCode != 200) {
      throw ConnectlyChatException('Failed to create session (HTTP ${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final session = (decoded is Map && decoded['message'] != null ? decoded['message'] : decoded)
        as Map<String, dynamic>;

    _sessionToken = session['session_token'] as String;
    _visitorId = session['visitor_id'] as String;
    await _storeVisitorId(_visitorId!);
  }

  static const maxReconnectAttempts = 3;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _disposed = false;

  void _setConnection(ConnectlyConnectionState state) {
    if (_disposed || _connectionState == state) return;
    _connectionState = state;
    _connection.add(state);
  }

  /// The app is in the background (file picker, camera, home...). Android often
  /// blocks its network then, so reconnect attempts would only fail and use up
  /// the round - hold them until [reconnectIfNeeded] (called on return).
  bool _paused = false;

  void pauseReconnecting() {
    _paused = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _onConnectionLost() {
    if (_disposed || _reconnectTimer != null) return;
    if (_connectionState == ConnectlyConnectionState.failed) return;
    if (_paused) {
      _setConnection(ConnectlyConnectionState.reconnecting); // resumes on return
      return;
    }
    _scheduleReconnect();
  }

  /// Up to [maxReconnectAttempts] tries (right away, then 2s and 4s apart), then
  /// gives up with [ConnectlyConnectionState.failed] until [retry] /
  /// [reconnectIfNeeded] starts a new round. A successful "ready" resets the count.
  void _scheduleReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _setConnection(ConnectlyConnectionState.failed);
      return;
    }
    _setConnection(ConnectlyConnectionState.reconnecting);
    final delay = _reconnectAttempts == 0
        ? const Duration(milliseconds: 300)
        : Duration(seconds: 1 << _reconnectAttempts);
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () async {
      if (_disposed || _paused) return;
      try {
        // A fresh token for the same chat each time - the old one may have
        // expired while the app sat in the background (e.g. in the file picker).
        await _createSession(chatId: chatId);
        _reconnectTimer = null;
        _socket!
          ..auth = {'token': _sessionToken}
          ..connect(); // a refusal/failure comes back as connect_error -> next attempt
      } catch (_) {
        _reconnectTimer = null;
        _scheduleReconnect();
      }
    });
  }

  /// Manual retry after [ConnectlyConnectionState.failed] - starts a new round
  /// of [maxReconnectAttempts] attempts.
  void retry() {
    if (_disposed || _socket == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _connectionState = ConnectlyConnectionState.reconnecting;
    _scheduleReconnect();
  }

  /// Reconnect right away if the socket is down - when the app returns to the
  /// foreground, the file picker closes, or a message is sent. Always a fresh
  /// round of attempts, even after "failed": attempts made while the app was
  /// in the background may have failed only because Android blocked its network.
  void reconnectIfNeeded() {
    _paused = false;
    if (_disposed || _socket == null || isConnected) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _scheduleReconnect();
  }

  /// Call when the app comes back to the foreground (screen on, file picker or
  /// camera closed, switched back to the app). After the OS suspended the app a
  /// socket can look connected yet be dead - socket.io only notices after its
  /// ping timeout (up to ~45s), and meanwhile messages vanish. So ask the server;
  /// no answer within [timeout] -> drop it and reconnect now (whose "ready"
  /// reloads the conversation). A socket that's plainly down reconnects at once.
  Future<void> ensureConnected({Duration timeout = const Duration(seconds: 4)}) async {
    _paused = false;
    final socket = _socket;
    if (_disposed || socket == null) return;
    if (!socket.connected) {
      reconnectIfNeeded();
      return;
    }
    final answered = Completer<bool>();
    final timer = Timer(timeout, () {
      if (!answered.isCompleted) answered.complete(false);
    });
    socket.emitWithAck('heartbeat', {}, ack: ([dynamic _]) {
      timer.cancel();
      if (!answered.isCompleted) answered.complete(true);
    });
    if (await answered.future || _disposed || !identical(socket, _socket)) return;
    // Dead but "connected": close it - the disconnect starts a fresh reconnect round.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    if (_connectionState == ConnectlyConnectionState.failed) {
      _connectionState = ConnectlyConnectionState.reconnecting;
    }
    socket.io.engine?.close();
    if (!socket.connected) reconnectIfNeeded();
  }

  /// Completes once the server acknowledges it received the message (the
  /// "sent" tick); throws [ConnectlyChatException] if it doesn't within
  /// [ackTimeout]. While a reconnect is under way (e.g. the app just came back
  /// from the file picker) it waits for it instead of failing right away.
  ///
  /// [clientId] identifies the message across retries: the server ignores a
  /// second copy with the same id, and history returns it (as the message
  /// [ConnectlyMessage.id]) so a local message can be matched to its stored one.
  Future<void> sendMessage(
    String text, {
    String? clientId,
    Duration ackTimeout = const Duration(seconds: 15),
  }) async {
    if (_socket == null) throw ConnectlyChatException('Not connected');
    if (!_socket!.connected) {
      // Even after "failed": sending is a reason to try again, not to give up.
      reconnectIfNeeded();
      try {
        await connectionChanges
            .firstWhere((s) => s == ConnectlyConnectionState.connected || s == ConnectlyConnectionState.failed)
            .timeout(ackTimeout);
      } on TimeoutException {
        throw ConnectlyChatException('Not connected');
      } on StateError {
        throw ConnectlyChatException('Not connected'); // client disposed meanwhile
      }
      if (_socket?.connected != true) throw ConnectlyChatException('Not connected');
    }
    final socket = _socket!;

    final completer = Completer<void>();
    final timer = Timer(ackTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(ConnectlyChatException('Message not acknowledged by the server'));
      }
    });
    socket.emitWithAck('message', {'text': text, 'client_id': ?clientId}, ack: ([dynamic response]) {
      timer.cancel();
      if (completer.isCompleted) return;
      if (response is Map && response['ok'] == false) {
        completer.completeError(response['error'] == 'rate_limited'
            ? ConnectlyRateLimitException(_retryAfterOf(response))
            : ConnectlyChatException('Message rejected: ${response['error']}'));
      } else {
        completer.complete();
      }
    });
    return completer.future;
  }

  void sendTyping() {
    _socket?.emit('typing', {});
  }

  void requestHuman([String? reason]) {
    _socket?.emit('request_human', {'reason': reason});
  }

  /// The session's chat history, oldest first - [page] 1 is the most recent
  /// [pageSize] messages. Only returns this session's own chat.
  Future<List<ConnectlyMessage>> fetchHistory({int page = 1, int pageSize = 50}) async {
    if (_sessionToken == null) {
      throw ConnectlyChatException('Call connect() before fetchHistory().');
    }

    final uri = Uri.parse('${config.apiBaseUrl}/api/method/connectly.chatting.api.get_history');
    final response = await http.post(uri, body: {
      'session_token': _sessionToken!,
      'page': '$page',
      'page_size': '$pageSize',
    });
    if (response.statusCode != 200) {
      throw ConnectlyChatException('Failed to load history (HTTP ${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    final body = (decoded is Map && decoded['message'] != null ? decoded['message'] : decoded)
        as Map<String, dynamic>;
    final rows = (body['messages'] as List? ?? const []).cast<Map>();

    return rows.reversed.map((row) {
      final role = row['role']?.toString() ?? 'assistant';
      final type = typeFromString(row['type']?.toString());
      var text = (row['message_text'] ?? '').toString();
      // Caption-less uploads are stored with a "[image]"-style placeholder.
      if (type != ConnectlyMessageType.text && text == '[${type.name}]') text = '';
      final clientId = row['client_id']?.toString() ?? '';
      return ConnectlyMessage(
        // The SDK's own id when this message was sent from it - matches the
        // local copy - otherwise the server's.
        id: clientId.isNotEmpty ? clientId : row['name']?.toString(),
        role: role,
        content: text,
        // Sent with the site's UTC offset; show it in the device's time zone.
        timestamp: DateTime.tryParse(row['creation']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
        type: type,
        fileUrl: resolveFileUrl(row['file']?.toString(), config.apiBaseUrl),
        // Anything already in history reached the server.
        status: role == 'user' ? ConnectlyMessageStatus.sent : null,
      );
    }).toList();
  }

  /// Uploads a file or voice note. Goes over REST (not the socket), since the
  /// realtime channel only carries text - see `connectly.chatting.api.send_attachment`.
  ///
  /// Returns the uploaded file's URL. The AI's reply (if any) arrives on
  /// [messages]; failures throw rather than going to [onError], so a failed
  /// upload marks just that message, not the whole connection.
  /// [clientId] works as in [sendMessage].
  Future<String?> sendAttachment(File file, {String caption = '', String? clientId}) async {
    if (_sessionToken == null) {
      throw ConnectlyChatException('Call connect() before sendAttachment().');
    }

    // The server picks image/audio/document from the part's content type, and
    // `http` sends application/octet-stream unless told otherwise.
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';

    final uri = Uri.parse('${config.apiBaseUrl}/api/method/connectly.chatting.api.send_attachment');
    final request = http.MultipartRequest('POST', uri)
      ..fields['session_token'] = _sessionToken!
      ..fields['caption'] = caption
      ..fields.addAll({'client_id': ?clientId})
      ..files.add(await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: MediaType.parse(mimeType),
      ));

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 429) {
      Object? body;
      try {
        final decoded = jsonDecode(response.body);
        body = decoded is Map && decoded['message'] != null ? decoded['message'] : decoded;
      } catch (_) {}
      throw ConnectlyRateLimitException(_retryAfterOf(body));
    }
    if (response.statusCode != 200) {
      throw ConnectlyChatException('Failed to send attachment: ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final body = (decoded is Map && decoded['message'] != null ? decoded['message'] : decoded)
        as Map<String, dynamic>;

    if (body['success'] != true) {
      throw ConnectlyChatException('Attachment upload rejected: ${response.body}');
    }

    return resolveFileUrl(body['file']?.toString(), config.apiBaseUrl);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _socket?.dispose();
    _messages.close();
    _typing.close();
    _ready.close();
    _handoffRequested.close();
    _handoffAccepted.close();
    _handoffResolved.close();
    _liveChanged.close();
    _errors.close();
    _connection.close();
  }
}
