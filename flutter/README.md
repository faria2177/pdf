# PDF Studio (Flutter)

PDF Studio is a native Flutter PDF reader and page organizer. Its feature set follows
[PdfCraft](https://github.com/storytold/pdfcraft), and it renders and edits PDFs with PDFium through
[pdfrx](https://pub.dev/packages/pdfrx). It works offline and needs no account.

| PdfCraft feature | PDF Studio |
|---|---|
| Read: continuous, two-up, single page, dark | ✅ continuous, one page at a time, horizontal, two-up (cover page optional), dark pages |
| Find as you type | ✅ search with match highlights and previous/next |
| Bookmarks, thumbnails, page labels | ✅ bookmarks, thumbnail grid, scroll thumb, go to page |
| Select and copy text | ✅ text selection; "Copy page text" |
| Organize pages (rotate, delete, insert, move, undo) | ✅ drag to reorder, multi-select, rotate, delete, duplicate, blank page, insert from file, undo/redo |
| Combine files | ✅ PDFs and images, mixed |
| Extract / Split | ✅ every N pages, by ranges (one file each), extract into one PDF; several parts are saved as a ZIP |
| Passwords, permissions, properties | ✅ open protected files, show permissions, "Save without password" |
| Export | ✅ page as PNG, share, save a copy |
| Open from other apps | ✅ "Open with" / "Share" from Android |
| Protect (passwords, permissions) | ✅ AES-256 with an open password, an optional owner password and print/copy/edit limits (PdfBox-Android) |
| Redact | ✅ draw boxes or find text; marked pages are flattened to images, so the hidden content is removed |
| Compress | ✅ recompresses images at three levels; text stays vector (PdfBox-Android) |
| OCR, forms editing, annotations | ❌ not available |

## Build

`.github/workflows/build-flutter.yml` builds the app on every push that changes `flutter/**`:

1. Sets up Flutter 3.50.1.
2. Runs `flutter create` to generate the Gradle files that aren't committed. The committed
   manifest, `MainActivity.kt` and icons are left as they are.
3. Signs with `android/debug.keystore.b64`, the same key on every run, so new APKs install as updates.
4. Builds an APK for arm and arm64 and publishes it as a release named `studio-v<version>-b<run>`.

To build locally:

```sh
cd flutter
flutter create --platforms=android --org com.faria2177 --project-name pdf_studio .
flutter pub get
flutter build apk --release
```

## Code layout

```
lib/
  main.dart                 app + theme, "Open with" hookup
  pages/home_page.dart      open, tools, recent files
  pages/viewer_page.dart    reader: layouts, search, bookmarks, thumbnails, export, properties
  pages/organize_page.dart  page grid (organize / combine / images to PDF), undo/redo, save
  pages/split_page.dart     split every N, by ranges, extract
  pages/protect_page.dart   password + permissions (More ▸ Protect)
  pages/redact_page.dart    draw/find, burn in (More ▸ Redact)
  pages/compress_page.dart  image recompression (More ▸ Compress)
  services/                 file picking/saving, recent list, passwords, Android intents
  utils/                    page-range parser, image→JPEG→PDF, page→PNG
android/app/src/main/       manifest (intent filters), MainActivity.kt (intent channel),
                            PdfBoxChannel.kt (protect/compress via PdfBox-Android)
android/app/build.gradle.kts adds the pdfbox-android dependency
```

## Scanner

Scan and ID Card use the DocScanner (DS-Fult, github.com/faria2177/DS-Fult) camera:
`third_party/doclens` (local fork of MIT-licensed doclens with DS-Fult's own C++ boundary
engine, OpenCV and the DocNet model) plus the screens/services in `lib/ds/`. The online
auto-crop option is removed in this build; all detection runs on the device.
