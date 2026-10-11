import 'package:flutter/material.dart';

/// Visual customization for [ConnectlyChatWidget] - colors, background, bubble
/// shape and header. Build one `const ConnectlyChatTheme(...)` per brand/host app.
class ConnectlyChatTheme {
  /// Send button, header background, and active states.
  final Color primaryColor;

  /// Chat area background color (ignored if [backgroundImage] is set).
  final Color backgroundColor;

  /// Optional background image behind the message list.
  final DecorationImage? backgroundImage;

  final Color visitorBubbleColor;
  final Color otherBubbleColor;
  final Color visitorTextColor;
  final Color otherTextColor;
  final BorderRadius bubbleBorderRadius;

  final Color headerBackgroundColor;
  final Color headerTextColor;

  final TextStyle? messageTextStyle;
  final TextStyle? timestampTextStyle;

  const ConnectlyChatTheme({
    this.primaryColor = const Color(0xFF4F46E5),
    this.backgroundColor = const Color(0xFFF3F4F6),
    this.backgroundImage,
    this.visitorBubbleColor = const Color(0xFF4F46E5),
    this.otherBubbleColor = const Color(0xFFF1F1F4),
    this.visitorTextColor = Colors.white,
    this.otherTextColor = Colors.black87,
    this.bubbleBorderRadius = const BorderRadius.all(Radius.circular(16)),
    this.headerBackgroundColor = const Color(0xFF4F46E5),
    this.headerTextColor = Colors.white,
    this.messageTextStyle,
    this.timestampTextStyle,
  });
}
