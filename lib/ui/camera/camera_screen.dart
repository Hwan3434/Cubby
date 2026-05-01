import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app.dart';

enum _Mode { photo, video }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.album});

  final AssetPathEntity album;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  String? _error;
  _Mode _mode = _Mode.photo;
  bool _busy = false; // capturing photo or stopping video
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _error = '사용 가능한 카메라가 없습니다');
        return;
      }
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카메라를 열 수 없습니다: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() => _busy = true);
    try {
      final xfile = await controller.takePicture();
      final bytes = await xfile.readAsBytes();
      if (!mounted) return;
      final repo = AppScope.of(context).mediaRepository;
      final asset = await repo.saveImage(
        bytes: bytes,
        filename: 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
        album: widget.album,
      );
      if (!mounted) return;
      Navigator.pop(context, asset);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('촬영 실패: $e')),
      );
    }
  }

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null || _busy) return;

    if (!_recording) {
      try {
        await controller.startVideoRecording();
        if (!mounted) return;
        setState(() => _recording = true);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('녹화 시작 실패: $e')),
        );
      }
      return;
    }

    setState(() => _busy = true);
    try {
      final xfile = await controller.stopVideoRecording();
      if (!mounted) return;
      final repo = AppScope.of(context).mediaRepository;
      final asset = await repo.saveVideo(
        file: File(xfile.path),
        filename: 'VID_${DateTime.now().millisecondsSinceEpoch}.mp4',
        album: widget.album,
      );
      if (!mounted) return;
      Navigator.pop(context, asset);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _recording = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 실패: $e')),
      );
    }
  }

  void _setMode(_Mode mode) {
    if (_recording || _busy) return;
    setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.album.name),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Center(child: CameraPreview(controller)),
        if (_recording)
          const Positioned(
            top: 16,
            left: 16,
            child: _RecordingChip(),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Column(
            children: [
              _ModeToggle(
                mode: _mode,
                enabled: !_recording && !_busy,
                onChanged: _setMode,
              ),
              const SizedBox(height: 16),
              _ShutterButton(
                mode: _mode,
                busy: _busy,
                recording: _recording,
                onTap: _mode == _Mode.photo ? _capturePhoto : _toggleRecording,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final _Mode mode;
  final bool enabled;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SegmentedButton<_Mode>(
        segments: const [
          ButtonSegment(value: _Mode.photo, label: Text('사진')),
          ButtonSegment(value: _Mode.video, label: Text('영상')),
        ],
        selected: {mode},
        onSelectionChanged: enabled
            ? (selection) => onChanged(selection.first)
            : null,
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.mode,
    required this.busy,
    required this.recording,
    required this.onTap,
  });

  final _Mode mode;
  final bool busy;
  final bool recording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isVideo = mode == _Mode.video;
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: busy ? Colors.white54 : Colors.white,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.black,
                ),
              )
            : Center(
                child: isVideo
                    ? Container(
                        width: recording ? 24 : 36,
                        height: recording ? 24 : 36,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(
                            recording ? 4 : 18,
                          ),
                        ),
                      )
                    : null,
              ),
      ),
    );
  }
}

class _RecordingChip extends StatelessWidget {
  const _RecordingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
          SizedBox(width: 6),
          Text(
            'REC',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
