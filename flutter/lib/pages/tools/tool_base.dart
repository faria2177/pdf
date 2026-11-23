import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/pdf_open.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/result_actions.dart';

/// Base for tool screens that work on one PDF: opens it (asking for a password if needed),
/// keeps it open while the screen lives and closes it afterwards.
abstract class PdfToolState<T extends StatefulWidget> extends State<T> {
  String get path;
  String get name;

  PdfDocument? doc;
  int get pageCount => doc?.pages.length ?? 0;
  late final int fileSize = File(path).lengthSync();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    doc?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final d = await openPdfDocument(context, path);
      if (!mounted) {
        d.dispose();
        return;
      }
      setState(() => doc = d);
      onOpened(d);
    } catch (e) {
      if (!mounted) return;
      toast(context, "Couldn't open: $e");
      Navigator.of(context).maybePop();
    }
  }

  void onOpened(PdfDocument doc) {}

  Widget header() => Row(
        children: [
          Container(
            width: 46,
            height: 62,
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
            child: doc == null ? null : PdfPageView(document: doc, pageNumber: 1, maximumDpi: 40),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('$pageCount pages · ${formatBytes(fileSize)}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      );

  Widget loading() => const Center(child: CircularProgressIndicator());
}
