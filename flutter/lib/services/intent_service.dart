import 'package:flutter/services.dart';

/// Receives PDFs that other apps send to us ("Open with" / "Share").
/// The Android side (MainActivity.kt) copies the content:// stream into the cache
/// and hands us a plain file path.
class IntentService {
  IntentService._();
  static final instance = IntentService._();

  static const _channel = MethodChannel('pdf_studio/intent');

  void Function(String path)? _onFile;
  String? _pending;

  void start(void Function(String path) onFile) {
    _onFile = onFile;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFile' && call.arguments is String) {
        _deliver(call.arguments as String);
      }
      return null;
    });
    _fetchInitial();
  }

  Future<void> _fetchInitial() async {
    try {
      final path = await _channel.invokeMethod<String>('getInitialFile');
      if (path != null && path.isNotEmpty) _deliver(path);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// HomePage calls this once its first frame is up, in case a file arrived earlier.
  String? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  void _deliver(String path) {
    final cb = _onFile;
    if (cb == null) {
      _pending = path;
    } else {
      // The navigator may not exist yet during cold start; keep it until HomePage asks.
      _pending = path;
      Future.delayed(const Duration(milliseconds: 300), () {
        final p = takePending();
        if (p != null) cb(p);
      });
    }
  }
}
