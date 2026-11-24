import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // 点击 Dock 图标或重新打开应用时，把最小化或落在后面的主窗口恢复到最前。
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard let window = sender.windows.first(where: { $0 is MainFlutterWindow }) else {
      return true
    }

    if window.isMiniaturized {
      window.deminiaturize(nil)
    } else if window.alphaValue == 0 {
      // Dart 侧首帧显示前窗口保持透明，此时交给 window_manager.show() 显示。
      return true
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
}
