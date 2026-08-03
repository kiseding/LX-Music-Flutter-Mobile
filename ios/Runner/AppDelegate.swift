import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "LXFileProtection"
    ) else { return }
    let channel = FlutterMethodChannel(
      name: "lx_music/file_protection",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "ensureBackgroundReadable",
            let arguments = call.arguments as? [String: Any],
            let rawPath = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let path = (rawPath as NSString).standardizingPath
      let home = (NSHomeDirectory() as NSString).standardizingPath + "/"
      guard path.hasPrefix(home), FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(
          code: "invalid_path",
          message: "Playback cache path is outside the application container",
          details: nil
        ))
        return
      }
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.none],
          ofItemAtPath: path
        )
        result(nil)
      } catch {
        result(FlutterError(
          code: "file_protection",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }
}
