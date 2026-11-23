import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../widgets/dialogs.dart';
import 'file_service.dart';

/// Passwords the user typed this session, so the organizer/split tools can
/// reopen a protected file without asking again.
final _passwords = <String, String>{};

String? knownPassword(String path) => _passwords[path];

/// A password provider that first tries a remembered password, then asks.
/// pdfrx calls it again after every wrong attempt until it returns null.
PdfPasswordProvider passwordProviderFor(BuildContext context, String path) {
  var attempt = 0;
  return () async {
    attempt++;
    final known = _passwords[path];
    if (attempt == 1 && known != null) return known;
    if (!context.mounted) return null;
    final pw = await askPassword(context, FileService.displayName(path), retry: attempt > (known != null ? 2 : 1));
    if (pw != null) _passwords[path] = pw;
    return pw;
  };
}

Future<PdfDocument> openPdfDocument(BuildContext context, String path) {
  return PdfDocument.openFile(path, passwordProvider: passwordProviderFor(context, path));
}
