import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectionService {
  FaceDetectionService._();
  static final FaceDetectionService instance = FaceDetectionService._();

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: false,
      enableContours: false,
      enableClassification: true,
    ),
  );

  Future<bool> isValidFaceImage(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final faces = await _detector.processImage(inputImage);
    if (faces.length != 1) return false; // Un seul visage attendu

    final face = faces.first;

    // Seuils heuristiques (pixels et orientation)
    final faceArea = (face.boundingBox.width * face.boundingBox.height).toDouble();
    const minFaceAreaPixels = 5000; // suffisant pour éliminer de trop petits visages
    final isFrontal = _isApproximatelyFrontal(face);
    final bigEnough = faceArea >= minFaceAreaPixels;

    return isFrontal && bigEnough;
  }

  bool _isApproximatelyFrontal(Face face) {
    // Heuristique: angles de roulis/inclinaison limités pour un visage "frontal"
    final yaw = face.headEulerAngleY ?? 0.0; // gauche/droite
    final roll = face.headEulerAngleZ ?? 0.0; // rotation
    const maxDegrees = 20.0;
    return yaw.abs() <= maxDegrees && roll.abs() <= maxDegrees;
  }

  Future<void> close() async {
    await _detector.close();
  }
}


