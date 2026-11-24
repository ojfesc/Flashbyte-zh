import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundPermissionChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "BackgroundPermissionChannel"
    ) else { return }

    let channel = FlutterMethodChannel(
      name: "flashbyte/battery_optimization",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isIgnoringBatteryOptimizations":
        // iOS 没有电池优化开关，用“后台 App 刷新”作为等价条件
        result(UIApplication.shared.backgroundRefreshStatus == .available)
      case "openAppInfoSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    backgroundPermissionChannel = channel
  }
}
