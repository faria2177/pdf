import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../screens/gallery_import_review_screen.dart';
import 'image_processor.dart';

export '../screens/gallery_import_review_screen.dart' show GalleryImportResult;

/// Import Images (PDF Studio build): system photo picker, then DocScanner's
/// auto-crop review screen.
Future<GalleryImportResult?> pickAndImportFromGallery(
  BuildContext context, {
  required ImagePicker picker,
  int? limit,
  bool initialAutoCrop = true,
  ScanFilter initialFilter = ScanFilter.enhance,
  bool preferIdCardBounds = false,
}) async {
  final List<String> paths;
  if (limit == 1) {
    final photo = await picker.pickImage(source: ImageSource.gallery);
    paths = [if (photo != null) photo.path];
  } else {
    final photos = await picker.pickMultiImage(limit: limit, requestFullMetadata: false);
    paths = [for (final photo in photos) photo.path];
  }
  if (paths.isEmpty || !context.mounted) return null;
  return Navigator.of(context).push<GalleryImportResult>(MaterialPageRoute(
    builder: (_) => GalleryImportReviewScreen(
      imagePaths: paths,
      initialAutoCrop: initialAutoCrop,
      initialFilter: initialFilter,
      preferIdCardBounds: preferIdCardBounds,
    ),
  ));
}
