import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';
import 'voice_note_player.dart';

class MessageBubble extends StatelessWidget {
  final ConnectlyMessage message;
  final ConnectlyChatTheme theme;

  /// Called when the visitor taps a message that failed to send.
  final VoidCallback? onRetry;

  const MessageBubble({super.key, required this.message, required this.theme, this.onRetry});

  bool get _failed => message.status == ConnectlyMessageStatus.failed;

  /// In-chat status line (agent joined/left) - centered, not a bubble.
  Widget _buildNotice() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.primaryColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.support_agent, size: 16, color: theme.primaryColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  message.content,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: theme.primaryColor, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (message.role == 'system') return _buildNotice();
    final isVisitor = message.isVisitor;
    final bubbleColor = isVisitor ? theme.visitorBubbleColor : theme.otherBubbleColor;
    final textColor = isVisitor ? theme.visitorTextColor : theme.otherTextColor;

    final bubble = Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
      decoration: BoxDecoration(
        color: _failed ? bubbleColor.withValues(alpha: 0.6) : bubbleColor,
        borderRadius: theme.bubbleBorderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(alignment: Alignment.centerLeft, widthFactor: 1, child: _buildContent(context, textColor)),
          const SizedBox(height: 2),
          _buildMeta(textColor),
        ],
      ),
    );

    return Align(
      alignment: isVisitor ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: isVisitor ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(onTap: _failed ? onRetry : null, child: bubble),
            if (_failed)
              GestureDetector(
                onTap: onRetry,
                child: const Padding(
                  padding: EdgeInsets.only(top: 3, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error, color: Colors.red, size: 14),
                      SizedBox(width: 4),
                      Text('Not sent. Tap to retry', style: TextStyle(color: Colors.red, fontSize: 12)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Time, plus the delivery tick on the visitor's own messages.
  Widget _buildMeta(Color textColor) {
    final metaColor = textColor.withValues(alpha: 0.7);
    final t = message.timestamp;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    final IconData? icon = switch (message.status) {
      ConnectlyMessageStatus.sending => Icons.access_time,
      ConnectlyMessageStatus.sent => Icons.done,
      ConnectlyMessageStatus.failed => Icons.error_outline,
      null => null,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(time, style: theme.timestampTextStyle ?? TextStyle(color: metaColor, fontSize: 11)),
        if (icon != null) ...[
          const SizedBox(width: 4),
          Icon(icon, size: 14, color: _failed ? Colors.red : metaColor),
        ],
      ],
    );
  }

  String? get _fileName {
    final path = message.localPath ?? message.fileUrl;
    if (path == null) return null;
    final segments = Uri.parse(path).pathSegments;
    return segments.isEmpty ? null : Uri.decodeComponent(segments.last);
  }

  static Future<void> _openDocument(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool opened = false;
    try {
      opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened) messenger?.showSnackBar(const SnackBar(content: Text('Could not open this file.')));
  }

  Widget _buildImage(Color textColor) {
    Widget broken(BuildContext _, Object _, StackTrace? _) => Icon(Icons.broken_image, color: textColor);
    if (message.localPath != null) {
      return Image.file(File(message.localPath!), fit: BoxFit.cover, errorBuilder: broken);
    }
    return Image.network(message.fileUrl!, fit: BoxFit.cover, errorBuilder: broken);
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    final textStyle = (theme.messageTextStyle ?? const TextStyle()).copyWith(color: textColor);
    final caption = message.content.isNotEmpty
        ? [const SizedBox(height: 6), Text(message.content, style: textStyle)]
        : const <Widget>[];

    switch (message.type) {
      case ConnectlyMessageType.image:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.localPath != null || message.fileUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: _buildImage(textColor),
                ),
              ),
            ...caption,
          ],
        );
      case ConnectlyMessageType.audio:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            VoiceNotePlayer(localPath: message.localPath, url: message.fileUrl, color: textColor),
            ...caption,
          ],
        );
      case ConnectlyMessageType.document:
        final url = message.fileUrl;
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, color: textColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message.content.isEmpty ? _fileName ?? 'Attachment' : message.content,
                style: url == null ? textStyle : textStyle.copyWith(decoration: TextDecoration.underline),
              ),
            ),
            if (url != null) ...[
              const SizedBox(width: 6),
              Icon(Icons.open_in_new, size: 16, color: textColor),
            ],
          ],
        );
        // Opens in the device's viewer/browser once uploaded (a failed one
        // has no URL - tapping it retries instead).
        if (url == null || _failed) return row;
        return InkWell(onTap: () => _openDocument(context, url), child: row);
      case ConnectlyMessageType.text:
        return Text(message.content, style: textStyle);
    }
  }
}
