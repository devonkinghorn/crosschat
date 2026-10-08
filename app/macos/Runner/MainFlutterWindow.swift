import Cocoa
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    WebAuthWindow.register(with: flutterViewController.engine.binaryMessenger)
    ImageConverter.register(with: flutterViewController.engine.binaryMessenger)
    ContactsChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// `app.crosschat/image`: decode images Flutter can't (HEIC/HEIF from
/// iPhones) with ImageIO and hand back a JPEG, scaled to `maxDimension`.
enum ImageConverter {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.crosschat/image", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "toJpeg",
            let args = call.arguments as? [String: Any],
            let data = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterMethodNotImplemented)
        return
      }
      let maxDimension = args["maxDimension"] as? Int ?? 2048
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = toJpeg(data.data, maxDimension: maxDimension)
        DispatchQueue.main.async {
          if let jpeg = jpeg {
            result(FlutterStandardTypedData(bytes: jpeg))
          } else {
            result(FlutterError(code: "decode_failed", message: "Couldn't decode the image", details: nil))
          }
        }
      }
    }
  }

  static func toJpeg(_ data: Data, maxDimension: Int) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }
}
