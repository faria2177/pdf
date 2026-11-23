import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../services/pdfbox_service.dart';
import '../widgets/dialogs.dart';
import '../widgets/result_actions.dart';

/// "Protect a PDF": AES-256 password with optional permission limits.
class ProtectPage extends StatefulWidget {
  const ProtectPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<ProtectPage> createState() => _ProtectPageState();
}

class _ProtectPageState extends State<ProtectPage> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _owner = TextEditingController();
  bool _show = false;
  bool _advanced = false;
  bool _print = true;
  bool _copy = true;
  bool _modify = true;
  bool _ready = false;
  bool _wasEncrypted = false;
  int _pages = 0;
  Uint8List? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    for (final c in [_pw, _pw2, _owner]) {
      c.addListener(() => setState(() => _result = null));
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    _owner.dispose();
    super.dispose();
  }

  /// Opens once with pdfrx so an already-protected input asks for its password up front.
  Future<void> _check() async {
    try {
      final doc = await openPdfDocument(context, widget.path);
      _wasEncrypted = doc.isEncrypted;
      _pages = doc.pages.length;
      await doc.dispose();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      toast(context, "Couldn't open: $e");
      Navigator.of(context).maybePop();
    }
  }

  String? get _problem {
    if (_pw.text.isEmpty) return 'Enter a password';
    if (_pw.text.length < 4) return 'Use at least 4 characters';
    if (_pw.text != _pw2.text) return "Passwords don't match";
    if (_owner.text.isNotEmpty && _owner.text == _pw.text) return 'Owner password must differ from the open password';
    return null;
  }

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final bytes = await withProgress(
      context,
      'Encrypting…',
      () => PdfBoxService.protect(
        input: widget.path,
        userPassword: _pw.text,
        ownerPassword: _advanced && _owner.text.isNotEmpty ? _owner.text : null,
        password: knownPassword(widget.path),
        allowPrint: !_advanced || _print,
        allowCopy: !_advanced || _copy,
        allowModify: !_advanced || _modify,
      ),
    );
    if (bytes != null && mounted) setState(() => _result = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    final outName = '${FileService.withoutExtension(widget.name)}_protected.pdf';
    return Scaffold(
      appBar: AppBar(title: const Text('Protect a PDF')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                FileHeader(
                  name: widget.name,
                  subtitle: '$_pages pages · ${formatBytes(File(widget.path).lengthSync())}'
                      '${_wasEncrypted ? ' · already protected' : ''}',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pw,
                  obscureText: !_show,
                  decoration: InputDecoration(
                    labelText: 'Password to open the PDF',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pw2,
                  obscureText: !_show,
                  decoration: const InputDecoration(labelText: 'Repeat password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Restrict what readers can do'),
                  subtitle: const Text('Owner password and permissions'),
                  value: _advanced,
                  onChanged: (v) => setState(() {
                    _advanced = v;
                    _result = null;
                  }),
                ),
                if (_advanced) ...[
                  TextField(
                    controller: _owner,
                    obscureText: !_show,
                    decoration: const InputDecoration(
                      labelText: 'Owner password (optional)',
                      helperText: 'Lifts the restrictions below. Leave empty to use the open password.',
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _print,
                    onChanged: (v) => setState(() {
                      _print = v!;
                      _result = null;
                    }),
                    title: const Text('Allow printing'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _copy,
                    onChanged: (v) => setState(() {
                      _copy = v!;
                      _result = null;
                    }),
                    title: const Text('Allow copying text and images'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _modify,
                    onChanged: (v) => setState(() {
                      _modify = v!;
                      _result = null;
                    }),
                    title: const Text('Allow editing and page changes'),
                  ),
                ],
                const SizedBox(height: 8),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Uses AES-256 encryption. If you forget the password, the file cannot be opened. '
                      'Permission limits are honoured by most PDF apps, but not all.',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: problem == null ? _run : null,
                    icon: const Icon(Icons.lock_outline),
                    label: Text(problem ?? 'Protect PDF'),
                  )
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: const Text('Protected'),
                    subtitle: Text('$outName · ${formatBytes(_result!.length)}'),
                  ),
                  ResultActions(bytes: _result!, fileName: outName, allowOpen: false),
                ],
              ],
            ),
    );
  }
}
