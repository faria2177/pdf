import 'package:material_ui/material_ui.dart';

import '../utils/page_ranges.dart';
import 'dialogs.dart';

/// "All pages" or a custom page list like "1-3, 7".
class PageSelection {
  const PageSelection.all() : custom = null;
  const PageSelection.custom(this.custom);
  final String? custom;

  bool get isAll => custom == null;

  /// 1-based page numbers; throws [FormatException] for bad input.
  List<int> resolve(int pageCount) =>
      isAll ? [for (var i = 1; i <= pageCount; i++) i] : parsePageList(custom!, pageCount);

  String? error(int pageCount) {
    try {
      resolve(pageCount);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }
}

class PageRangeSelector extends StatefulWidget {
  const PageRangeSelector({required this.pageCount, required this.value, required this.onChanged, super.key});
  final int pageCount;
  final PageSelection value;
  final ValueChanged<PageSelection> onChanged;

  @override
  State<PageRangeSelector> createState() => _PageRangeSelectorState();
}

class _PageRangeSelectorState extends State<PageRangeSelector> {
  late final _ctrl = TextEditingController(text: widget.value.custom ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.value.isAll;
    final err = all ? null : widget.value.error(widget.pageCount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text('All ${widget.pageCount} pages'), icon: const Icon(Icons.library_books_outlined)),
            const ButtonSegment(value: false, label: Text('Choose pages'), icon: Icon(Icons.filter_list)),
          ],
          selected: {all},
          onSelectionChanged: (s) => widget.onChanged(s.first ? const PageSelection.all() : PageSelection.custom(_ctrl.text)),
        ),
        if (!all) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: 'Pages',
              hintText: 'e.g. 1-3, 5, 8-',
              errorText: _ctrl.text.trim().isEmpty ? null : err,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => widget.onChanged(PageSelection.custom(v)),
          ),
        ],
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}

/// A card of mutually exclusive choices with descriptions.
class ChoiceCards<T> extends StatelessWidget {
  const ChoiceCards({required this.options, required this.value, required this.onChanged, super.key});
  final List<(T, IconData, String, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final (v, icon, title, subtitle) in options)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 3),
            color: v == value ? scheme.primaryContainer : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: v == value ? scheme.primary : scheme.outlineVariant),
            ),
            child: ListTile(
              leading: Icon(icon, color: v == value ? scheme.primary : null),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(subtitle),
              trailing: v == value ? Icon(Icons.check_circle, color: scheme.primary) : null,
              onTap: () => onChanged(v),
            ),
          ),
      ],
    );
  }
}

/// Progress reporter handed to long tasks.
class ProgressUpdate {
  ProgressUpdate(this._label, this._value);
  final ValueNotifier<String> _label;
  final ValueNotifier<double?> _value;
  void call(String label, [double? value]) {
    _label.value = label;
    _value.value = value;
  }
}

/// Runs [task] behind a dialog with a live label/progress bar and optional Cancel.
Future<T?> runWithProgress<T>(
  BuildContext context,
  String title,
  Future<T> Function(ProgressUpdate update) task, {
  Future<void> Function()? onCancel,
}) async {
  final label = ValueNotifier<String>('Starting…');
  final value = ValueNotifier<double?>(null);
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder(valueListenable: value, builder: (_, v, _) => LinearProgressIndicator(value: v)),
            const SizedBox(height: 12),
            ValueListenableBuilder(valueListenable: label, builder: (_, v, _) => Text(v)),
          ],
        ),
        actions: [
          if (onCancel != null) TextButton(onPressed: () => onCancel(), child: const Text('Cancel')),
        ],
      ),
    ),
  );
  try {
    return await task(ProgressUpdate(label, value));
  } catch (e) {
    if (context.mounted) toast(context, '$e'.replaceFirst('Exception: ', ''));
    return null;
  } finally {
    nav.pop();
    label.dispose();
    value.dispose();
  }
}
