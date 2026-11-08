import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 600, height: 700)

    // 初始完全透明，避免用户在位置恢复前看到窗口或黑屏。
    // Dart 侧恢复位置后通过 window_manager.setOpacity 逐步提高透明度。
    self.alphaValue = 0

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
