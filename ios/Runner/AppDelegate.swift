import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundPermissionChannel: FlutterMethodChannel?
  private var iosSharingChannel: FlutterMethodChannel?

  private let shareAppGroup = "group.com.flashbyte"
  private let shareInboxFolder = "ShareInbox"
  private let shareManifestFile = "manifest.json"

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

    // 分享扩展把文件写进 App Group；主应用通过这个通道一次性取走。
    let sharingChannel = FlutterMethodChannel(
      name: "flashbyte/ios_sharing",
      binaryMessenger: registrar.messenger()
    )
    sharingChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePendingFiles":
        result(self?.takePendingShareFiles() ?? [])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    iosSharingChannel = sharingChannel
  }

  /// 读取分享扩展留下的清单，把文件移动到应用临时目录后返回给 Dart 侧。
  private func takePendingShareFiles() -> [[String: Any]] {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: shareAppGroup
      )
    else {
      return []
    }

    let inbox = container.appendingPathComponent(
      shareInboxFolder,
      isDirectory: true
    )
    let manifestURL = inbox.appendingPathComponent(shareManifestFile)
    guard
      let data = try? Data(contentsOf: manifestURL),
      let entries = try? JSONSerialization.jsonObject(with: data)
        as? [[String: Any]]
    else {
      return []
    }

    let fileManager = FileManager.default
    let destinationDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("SharedFromApps", isDirectory: true)
    try? fileManager.createDirectory(
      at: destinationDirectory,
      withIntermediateDirectories: true
    )

    var results: [[String: Any]] = []
    for entry in entries {
      guard
        let storedName = entry["file"] as? String,
        let displayName = entry["name"] as? String
      else {
        continue
      }

      let source = inbox.appendingPathComponent(storedName)
      let destination = destinationDirectory
        .appendingPathComponent(UUID().uuidString + "-" + displayName)
      do {
        try fileManager.moveItem(at: source, to: destination)
      } catch {
        continue
      }

      results.append([
        "name": displayName,
        "path": destination.path,
        "clipboard": entry["clipboard"] as? Bool ?? false,
      ])
    }

    try? fileManager.removeItem(at: manifestURL)
    return results
  }
}
