/// Parses page specs such as "1-3, 5, 8-" (1-based, inclusive) into page numbers.
/// "8-" means page 8 to the end, "-3" means pages 1 to 3. Throws [FormatException].
List<int> parsePageList(String spec, int pageCount) {
  final result = <int>[];
  for (final group in parsePageGroups(spec, pageCount)) {
    result.addAll(group);
  }
  return result;
}

/// Like [parsePageList] but keeps each comma-separated part as its own group
/// (used by "split by ranges": every group becomes one file).
List<List<int>> parsePageGroups(String spec, int pageCount) {
  final groups = <List<int>>[];
  for (final raw in spec.split(RegExp(r'[,;]'))) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d*)\s*[-–]\s*(\d*)$').firstMatch(part);
    int start, end;
    if (m != null) {
      start = m.group(1)!.isEmpty ? 1 : int.parse(m.group(1)!);
      end = m.group(2)!.isEmpty ? pageCount : int.parse(m.group(2)!);
    } else {
      final n = int.tryParse(part);
      if (n == null) throw FormatException('"$part" is not a page number or range');
      start = end = n;
    }
    if (start < 1 || end > pageCount || start > end) {
      throw FormatException('"$part" is outside 1–$pageCount');
    }
    groups.add([for (var i = start; i <= end; i++) i]);
  }
  if (groups.isEmpty) throw const FormatException('No pages given');
  return groups;
}

/// Compact text for a sorted list of page numbers, e.g. [1,2,3,5] -> "1-3, 5".
String formatPageList(List<int> pages) {
  if (pages.isEmpty) return '';
  final sorted = [...pages]..sort();
  final parts = <String>[];
  var start = sorted.first, prev = sorted.first;
  for (final n in sorted.skip(1)) {
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = prev = n;
  }
  parts.add(start == prev ? '$start' : '$start-$prev');
  return parts.join(', ');
}
