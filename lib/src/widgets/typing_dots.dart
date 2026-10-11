import 'package:flutter/material.dart';

/// The three animated "..." dots shown while the other side is typing.
class TypingDots extends StatefulWidget {
  final Color dotColor;

  const TypingDots({super.key, this.dotColor = Colors.grey});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = (_controller.value - i * 0.15) % 1.0;
              final bounce = t < 0.3 ? (1 - (t / 0.3 - 0.5).abs() * 2) : 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.translate(
                  offset: Offset(0, -4 * bounce),
                  child: Opacity(
                    opacity: 0.4 + 0.6 * bounce,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: widget.dotColor, shape: BoxShape.circle),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
