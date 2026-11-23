import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

Future<String?> askPassword(BuildContext context, String fileName, {bool retry = false}) {
  final controller = TextEditingController();
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(retry ? 'Wrong password' : 'Password required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('"$fileName" is protected.', maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.visiblePassword,
            decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Open')),
      ],
    ),
  );
}

Future<String?> askText(
  BuildContext context, {
  required String title,
  String? hint,
  String? initial,
  String? helper,
  TextInputType keyboardType = TextInputType.text,
  String okLabel = 'OK',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String?>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: keyboardType,
        decoration: InputDecoration(hintText: hint, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder()),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(okLabel)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String message, {String ok = 'OK', String title = 'Are you sure?'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// Runs [task] behind a modal progress indicator.
Future<T?> withProgress<T>(BuildContext context, String label, Future<T> Function() task) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  try {
    return await task();
  } catch (e) {
    if (context.mounted) toast(context, 'Error: $e');
    return null;
  } finally {
    nav.pop();
  }
}

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, 'Copied');
}
