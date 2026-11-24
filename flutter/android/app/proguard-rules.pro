# PdfBox-Android uses reflection for fonts/filters and has optional JPEG2000 support.
-keep class com.tom_roush.** { *; }
-dontwarn com.tom_roush.**
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**
# Tesseract4Android: JNI calls back into these classes.
-keep class com.googlecode.tesseract.android.** { *; }
-keep class com.googlecode.leptonica.android.** { *; }
# ML Kit document scanner + Play services: registrars and options are created by reflection.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.gms.common.internal.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); *; }
-keep class com.google_mlkit_document_scanner.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-dontwarn com.google.mlkit.**

# DocScanner (doclens) scanner: rules from DS-Fult's tool/mlkit-proguard-rules.pro.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.firebase.components.** { *; }
# Name-based JNI exports (Java_dev_doclens_*) need the original class/method names.
-keep class dev.doclens.doclens.** { *; }
-keep class org.opencv.** { *; }
-dontwarn org.opencv.**
