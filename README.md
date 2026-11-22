# PDF Tools (Android)

An Android wrapper for the WebAssembly build of [storytold/pdfcraft](https://github.com/storytold/pdfcraft),
an open-source PDF reader and editor written in Rust.

The app isn't built from Rust here. GitHub Actions downloads the upstream release's
`pdfcraft-web-<ver>.zip` into `app/src/main/assets/www`, then a small Kotlin WebView app serves it
from `https://appassets.androidplatform.net` and builds a signed APK that goes on
**[Releases](../../releases)**.

- Opens PDFs from the in-app dialog, or from other apps through "Open with".
- Saves through Android's "Save as" picker, so no storage permission is needed.
- Includes the OCR models, so OCR works offline.
- Checks for a new upstream release every day and builds it automatically.

## Building

- Push to `main` or run **Actions ▸ Build APK ▸ Run workflow**. Leave the tag blank for the
  latest upstream release, or give a tag such as `v0.21.1`.
- A local build needs the web zip unpacked into `app/src/main/assets/www`, plus
  `base64 -d keystore.b64 > release.jks`.

## Licence and naming

PdfCraft is MIT / Apache-2.0. The ArtCraft/PdfCraft names and logos are trademarks of their owners
and are not used for this app's name or icon. The bundled web build keeps its own `LICENSE-*`,
`NOTICE` and OCR model licences (CC-BY-SA-4.0) in `assets/www`.

> `keystore.b64` is a signing key for personal builds. It's committed so that every CI build has
> the same signature and updates install over the old version. Don't use it for a Play Store
> listing.
