import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Play/pause + progress for a voice note. Plays the on-device file when there
/// is one (the visitor's own, possibly not yet uploaded), otherwise the URL.
class VoiceNotePlayer extends StatefulWidget {
  final String? localPath;
  final String? url;
  final Color color;

  const VoiceNotePlayer({super.key, this.localPath, this.url, required this.color});

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final AudioPlayer _player = AudioPlayer();
  late final List<StreamSubscription> _subs;

  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _loadFailed = false;

  Source? get _source {
    if (widget.localPath != null) return DeviceFileSource(widget.localPath!);
    if (widget.url != null) return UrlSource(widget.url!);
    return null;
  }

  @override
  void initState() {
    super.initState();
    _subs = [
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _state = s);
      }),
      _player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      }),
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = Duration.zero);
      }),
    ];
    // Load up front so the total length shows before the first tap.
    final source = _source;
    if (source != null) {
      _player.setReleaseMode(ReleaseMode.stop);
      _player.setSource(source).catchError((_) {
        if (mounted) setState(() => _loadFailed = true);
      });
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final source = _source;
    if (source == null) return;
    try {
      if (_state == PlayerState.playing) {
        await _player.pause();
      } else if (_state == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.play(source);
      }
      if (_loadFailed && mounted) setState(() => _loadFailed = false);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  static String _format(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final playing = _state == PlayerState.playing;
    final shown = playing || _position > Duration.zero ? _position : total;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: Icon(
            _loadFailed ? Icons.error_outline : (playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
            color: widget.color,
            size: 34,
          ),
          onPressed: _toggle,
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 120,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: widget.color,
              inactiveTrackColor: widget.color.withValues(alpha: 0.3),
              thumbColor: widget.color,
            ),
            child: Slider(
              value: progress,
              onChanged: total == Duration.zero
                  ? null
                  : (v) => _player.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(_format(shown), style: TextStyle(color: widget.color, fontSize: 12)),
      ],
    );
  }
}
