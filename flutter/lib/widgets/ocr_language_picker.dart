import 'package:material_ui/material_ui.dart';

import '../services/ocr_service.dart';
import 'dialogs.dart';
import 'result_actions.dart';

/// Lets the user pick OCR languages (downloading their data on demand) and the model.
class OcrLanguagePicker extends StatefulWidget {
  const OcrLanguagePicker({
    required this.selected,
    required this.model,
    required this.onChanged,
    required this.onModelChanged,
    super.key,
  });

  final List<String> selected;
  final OcrModel model;
  final ValueChanged<List<String>> onChanged;
  final ValueChanged<OcrModel> onModelChanged;

  @override
  State<OcrLanguagePicker> createState() => _OcrLanguagePickerState();
}

class _OcrLanguagePickerState extends State<OcrLanguagePicker> {
  final _installed = <String, int>{}; // code -> bytes
  final _downloading = <String, double>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant OcrLanguagePicker old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _refresh();
  }

  Future<void> _refresh() async {
    final m = <String, int>{};
    for (final l in ocrLanguages) {
      final size = await OcrService.installedSize(l.code, widget.model);
      if (size > 1000) m[l.code] = size;
    }
    if (!mounted) return;
    setState(() {
      _installed
        ..clear()
        ..addAll(m);
    });
  }

  Future<void> _download(String code) async {
    setState(() => _downloading[code] = 0);
    try {
      await OcrService.download(code, widget.model, onProgress: (p) {
        if (mounted) setState(() => _downloading[code] = p);
      });
      await _refresh();
      if (!widget.selected.contains(code)) widget.onChanged([...widget.selected, code]);
    } catch (e) {
      if (mounted) toast(context, 'Download failed: $e. Check your internet connection.');
    } finally {
      if (mounted) setState(() => _downloading.remove(code));
    }
  }

  void _toggle(String code) {
    if (!_installed.containsKey(code)) {
      _download(code);
      return;
    }
    final next = [...widget.selected];
    if (!next.remove(code)) next.add(code);
    widget.onChanged(next);
  }

  Future<void> _manage() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (_, scroll) => ListView(
            controller: scroll,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('OCR languages', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              for (final l in ocrLanguages)
                ListTile(
                  title: Text('${l.name} · ${l.native}'),
                  subtitle: _downloading.containsKey(l.code)
                      ? LinearProgressIndicator(value: _downloading[l.code])
                      : Text(_installed.containsKey(l.code) ? 'Installed · ${formatBytes(_installed[l.code]!)}' : 'Not downloaded'),
                  trailing: _installed.containsKey(l.code)
                      ? IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await OcrService.delete(l.code, widget.model);
                            widget.onChanged(widget.selected.where((c) => c != l.code).toList());
                            await _refresh();
                            setSheet(() {});
                          },
                        )
                      : IconButton(
                          tooltip: 'Download',
                          icon: const Icon(Icons.download),
                          onPressed: _downloading.containsKey(l.code)
                              ? null
                              : () async {
                                  final f = _download(l.code);
                                  setSheet(() {});
                                  await f;
                                  setSheet(() {});
                                },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final l in ocrLanguages.take(8))
              FilterChip(
                label: Text(_downloading.containsKey(l.code)
                    ? '${l.name} ${((_downloading[l.code] ?? 0) * 100).round()}%'
                    : l.name),
                avatar: _installed.containsKey(l.code)
                    ? null
                    : Icon(Icons.download, size: 16, color: scheme.primary),
                selected: widget.selected.contains(l.code),
                onSelected: _downloading.containsKey(l.code) ? null : (_) => _toggle(l.code),
              ),
            ActionChip(
              avatar: const Icon(Icons.translate, size: 16),
              label: const Text('More…'),
              onPressed: _manage,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.selected.isEmpty
              ? 'Pick at least one language. Data downloads once (2–15 MB each), then OCR works offline.'
              : 'Using: ${widget.selected.map((c) => ocrLanguages.firstWhere((l) => l.code == c, orElse: () => OcrLanguage(c, c, c)).name).join(' + ')}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        SegmentedButton<OcrModel>(
          segments: [
            for (final m in OcrModel.values) ButtonSegment(value: m, label: Text(m.label)),
          ],
          selected: {widget.model},
          onSelectionChanged: (s) => widget.onModelChanged(s.first),
        ),
        const SizedBox(height: 4),
        Text(widget.model.description, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
