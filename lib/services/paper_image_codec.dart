import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// A picture ready to store in a paper: JPEG bytes and height/width ratio.
class PreparedPicture {
  final Uint8List bytes;
  final double aspect;

  const PreparedPicture(this.bytes, this.aspect);
}

/// Shrinks pictures for storage inside a paper document.
///
/// The longest side is limited to [maxSide] pixels and the result is saved
/// as JPEG at [quality]. Transparent areas are filled with white. Decoding
/// runs in a background isolate so the editor stays responsive.
abstract final class PaperImageCodec {
  static const int maxSide = 1400;
  static const int quality = 85;

  /// Returns null if [raw] is not a picture this codec can read.
  static Future<PreparedPicture?> prepare(Uint8List raw) =>
      compute(_prepareSync, raw);

  static PreparedPicture? _prepareSync(Uint8List raw) {
    final decoded = img.decodeImage(raw);
    if (decoded == null || decoded.width < 1 || decoded.height < 1) {
      return null;
    }
    var picture = decoded;
    if (picture.width > maxSide || picture.height > maxSide) {
      final landscape = picture.width >= picture.height;
      picture = img.copyResize(
        picture,
        width: landscape ? maxSide : null,
        height: landscape ? null : maxSide,
      );
    }
    final flat = img.Image(
      width: picture.width,
      height: picture.height,
      numChannels: 3,
    );
    for (var y = 0; y < flat.height; y++) {
      for (var x = 0; x < flat.width; x++) {
        flat.setPixelRgb(x, y, 255, 255, 255);
      }
    }
    img.compositeImage(flat, picture);
    final jpg = img.encodeJpg(flat, quality: quality);
    return PreparedPicture(
      Uint8List.fromList(jpg),
      flat.height / flat.width,
    );
  }
}
