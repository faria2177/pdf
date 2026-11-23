# PdfBox-Android uses reflection for fonts/filters and has optional JPEG2000 support.
-keep class com.tom_roush.** { *; }
-dontwarn com.tom_roush.**
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**
# Tesseract4Android: JNI calls back into these classes.
-keep class com.googlecode.tesseract.android.** { *; }
-keep class com.googlecode.leptonica.android.** { *; }
