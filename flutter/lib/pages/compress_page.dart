import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../services/pdfbox_service.dart';
import '../widgets/dialogs.dart';
import '../widgets/result_actions.dart';

/// "Compress a PDF": recompresses embedded images; text and vector art are untouched.
class CompressPage extends StatefulWidget {
  const CompressPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _CompressPageState extends State<CompressPage> {
  CompressLevel _level = CompressLevel.recommended;
  bool _ready = false;
  bool _encrypted = false;
  int _pages = 0;
  late final int _origSize = File(widget.path).lengthSync();
  CompressResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    try {
      final doc = await openPdfDocument(context, widget.path);
      _encrypted = doc.isEncrypted;
      _pages = doc.pages.length;
      await doc.dispose();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      toast(context, "Couldn't open: $e");
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _run() async {
    final r = await withProgress(
      context,
      'Compressing images…',
      () => PdfBoxService.compress(input: widget.path, level: _level, password: knownPassword(widget.path)),
    );
    if (r != null && mounted) setState(() => _result = r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final outName = '${FileService.withoutExtension(widget.name)}_compressed.pdf';
    final saved = r == null ? 0.0 : 1 - r.bytes.length / _origSize;
    return Scaffold(
      appBar: AppBar(title: const Text('Compress a PDF')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                FileHeader(name: widget.name, subtitle: '$_pages pages · ${formatBytes(_origSize)}'),
                const SizedBox(height: 8),
                for (final l in CompressLevel.values)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: RadioListTile<CompressLevel>(
                      value: l,
                      groupValue: _level,
                      onChanged: (v) => setState(() {
                        _level = v!;
                        _result = null;
                      }),
                      title: Text(l.label),
                      subtitle: Text('${l.description} · images up to ${l.maxSide}px, JPEG ${(l.quality * 100).round()}%'),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Only images are recompressed, so text stays sharp and searchable. '
                  'Files that are mostly text may not get much smaller.'
                  '${_encrypted ? '\nThe password is removed from the compressed copy.' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if (r == null)
                  FilledButton.icon(onPressed: _run, icon: const Icon(Icons.compress), label: const Text('Compress'))
                else if (r.bytes.length >= _origSize)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        "This PDF couldn't be made smaller at this level "
                        '(${r.images} images found, ${r.replaced} recompressed). '
                        'Try "Strong", or the file may already be optimised.',
                      ),
                    ),
                  )
                else ...[
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text('${(saved * 100).toStringAsFixed(0)}% smaller',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 4),
                          Text('${formatBytes(_origSize)} → ${formatBytes(r.bytes.length)}'),
                          Text('${r.replaced} of ${r.images} images recompressed',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ResultActions(bytes: r.bytes, fileName: outName),
                ],
              ],
            ),
    );
  }
}
