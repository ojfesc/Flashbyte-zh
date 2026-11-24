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

    // 注册自定义通道：判定后台 App 刷新，并打开本应用的系统设置页。
    // 用显式可选类型接收，无论 SDK 把 registrarForPlugin 标成可空还是非可空都能编译。
    let registrar: FlutterPluginRegistrar? = engineBridge.pluginRegistry.registrar(
      forPlugin: "BackgroundPermissionChannel"
    )
    guard let registrar else { return }

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
