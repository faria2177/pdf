import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'file_service.dart';

class RecentFile {
  RecentFile({required this.path, required this.name, required this.openedAt});

  final String path;
  final String name;
  final DateTime openedAt;

  String get ext => p.extension(name).toLowerCase().replaceFirst('.', '');
  bool get isPdf => ext == 'pdf';
  bool get isImage => const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'].contains(ext);

  Map<String, Object> toJson() => {'path': path, 'name': name, 'at': openedAt.millisecondsSinceEpoch};

  static RecentFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final name = json['name'];
    final at = json['at'];
    if (path is! String || name is! String || at is! int) return null;
    return RecentFile(path: path, name: name, openedAt: DateTime.fromMillisecondsSinceEpoch(at));
  }
}

/// Recently opened documents. Files live in the app's own storage (see FileService),
/// so they stay readable after the picker's temporary grant expires.
class RecentStore extends ChangeNotifier {
  RecentStore._();
  static final instance = RecentStore._();

  static const _key = 'recent_files_v1';
  static const maxItems = 40;

  final List<RecentFile> _items = [];
  List<RecentFile> get items => List.unmodifiable(_items);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _items.clear();
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final r = RecentFile.fromJson(e);
          if (r != null && File(r.path).existsSync()) _items.add(r);
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> add(String path, String name) async {
    _items.removeWhere((e) => e.path == path);
    _items.insert(0, RecentFile(path: path, name: name, openedAt: DateTime.now()));
    while (_items.length > maxItems) {
      final removed = _items.removeLast();
      _deleteQuietly(removed.path);
    }
    await _save();
  }

  /// Stores a produced file (PDF, image, Word, Excel, text…) in the library and lists it.
  /// The same name + size already listed is moved to the top instead of duplicated.
  Future<RecentFile> addBytes(Uint8List bytes, String name) async {
    for (final e in [..._items]) {
      if (e.name == name) {
        try {
          final f = File(e.path);
          if (f.existsSync() && f.lengthSync() == bytes.length) {
            await add(e.path, e.name);
            return _items.first;
          }
        } catch (_) {}
      }
    }
    final path = await FileService.storeInLibrary(bytes, name);
    await add(path, name);
    return _items.first;
  }

  Future<void> remove(RecentFile item, {bool deleteFile = true}) async {
    _items.removeWhere((e) => e.path == item.path);
    if (deleteFile) _deleteQuietly(item.path);
    await _save();
  }

  /// Renames the entry and its file in app storage. Returns the updated entry.
  Future<RecentFile> rename(RecentFile item, String newName) async {
    var name = newName.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final ext = p.extension(item.name);
    if (ext.isNotEmpty && !name.toLowerCase().endsWith(ext.toLowerCase())) name = '$name$ext';
    final old = File(item.path);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final newPath = '${old.parent.path}${Platform.pathSeparator}${stamp}_$name';
    var path = item.path;
    if (old.existsSync()) {
      path = (await old.rename(newPath)).path;
    }
    final updated = RecentFile(path: path, name: name, openedAt: item.openedAt);
    final i = _items.indexWhere((e) => e.path == item.path);
    if (i >= 0) {
      _items[i] = updated;
    } else {
      _items.insert(0, updated);
    }
    await _save();
    return updated;
  }

  Future<void> clear() async {
    for (final e in _items) {
      _deleteQuietly(e.path);
    }
    _items.clear();
    await _save();
  }

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_items.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
}
