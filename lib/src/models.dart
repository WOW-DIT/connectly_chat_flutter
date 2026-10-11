import 'package:mime/mime.dart';

enum ConnectlyMessageType { text, image, document, audio }

/// State of the realtime connection. `failed` means automatic reconnecting
/// gave up - call `ConnectlyChatClient.retry()` (the widget shows a button).
enum ConnectlyConnectionState { connecting, connected, reconnecting, failed }

/// Delivery state of a message the visitor sent. Null for incoming messages.
enum ConnectlyMessageStatus { sending, sent, failed }

ConnectlyMessageType typeFromString(String? value) {
  switch (value) {
    case 'image':
      return ConnectlyMessageType.image;
    case 'audio':
      return ConnectlyMessageType.audio;
    case 'document':
      return ConnectlyMessageType.document;
    default:
      return ConnectlyMessageType.text;
  }
}

/// A single chat message, from either side of the conversation.
///
/// [role] is the raw value the server sends - `"user"` for the visitor,
/// anything else (`"assistant"`, `"agent"`, a Frappe user id, ...) for the
/// other side. Use [isVisitor] rather than comparing [role] directly.
class ConnectlyMessage {
  /// Local identity, so a message can be found again to update its [status].
  final String id;
  final String role;
  final String content;
  final DateTime timestamp;
  final ConnectlyMessageType type;
  final String? fileUrl;

  /// The on-device file of an attachment the visitor sent - lets it show (and
  /// play) before/without the upload, and be retried if the upload failed.
  final String? localPath;

  final ConnectlyMessageStatus? status;

  ConnectlyMessage({
    String? id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.type = ConnectlyMessageType.text,
    this.fileUrl,
    this.localPath,
    this.status,
  }) : id = id ?? _nextId();

  static int _counter = 0;
  static String _nextId() => '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  bool get isVisitor => role == 'user';

  ConnectlyMessage copyWith({ConnectlyMessageStatus? status, String? fileUrl}) {
    return ConnectlyMessage(
      id: id,
      role: role,
      content: content,
      timestamp: timestamp,
      type: type,
      fileUrl: fileUrl ?? this.fileUrl,
      localPath: localPath,
      status: status ?? this.status,
    );
  }

  /// [baseUrl] turns the backend's site-relative file paths (`/files/x.png`)
  /// into absolute URLs - `Image.network` can't load a relative path on native.
  factory ConnectlyMessage.fromSocket(Map data, {String? baseUrl}) {
    return ConnectlyMessage(
      role: data['role']?.toString() ?? 'assistant',
      content: (data['content'] ?? data['text'] ?? '').toString(),
      timestamp: DateTime.now(),
      type: typeFromString(data['message_type']?.toString()),
      fileUrl: resolveFileUrl(data['file']?.toString(), baseUrl),
    );
  }
}

String? resolveFileUrl(String? file, String? baseUrl) {
  if (file == null || file.isEmpty) return null;
  final uri = Uri.parse(file);
  if (uri.hasScheme || baseUrl == null) return file;
  return Uri.parse(baseUrl).resolveUri(uri).toString();
}

/// Same image/audio/document split the server makes from the upload's MIME type.
ConnectlyMessageType typeForFile(String path) {
  final mime = lookupMimeType(path) ?? '';
  if (mime.startsWith('image/')) return ConnectlyMessageType.image;
  if (mime.startsWith('audio/')) return ConnectlyMessageType.audio;
  return ConnectlyMessageType.document;
}
