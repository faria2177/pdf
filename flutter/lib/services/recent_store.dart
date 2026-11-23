import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecentFile {
  RecentFile({required this.path, required this.name, required this.openedAt});

  final String path;
  final String name;
  final DateTime openedAt;

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
  static const maxItems = 15;

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

  Future<void> remove(RecentFile item, {bool deleteFile = true}) async {
    _items.removeWhere((e) => e.path == item.path);
    if (deleteFile) _deleteQuietly(item.path);
    await _save();
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
