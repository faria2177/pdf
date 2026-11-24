import 'package:doclens/doclens.dart';

/// PDF Studio build of DocScanner's "Online First" auto-crop: always off.
/// Every crop uses the on-device detectors, so no image ever leaves the phone.
class OnlineAutoCropConfig {
  const OnlineAutoCropConfig._();
  static Future<bool> canUpload() async => false;
}

class OnlineCropCandidate {
  const OnlineCropCandidate(this.detection, this.confidence, this.documentType);
  final ImageDetection detection;
  final double confidence;
  final String documentType;
}

class OnlineAutoCropService {
  const OnlineAutoCropService();
  Future<OnlineCropCandidate?> detect(String imagePath, {bool preferIdCardBounds = false}) async => null;
}
