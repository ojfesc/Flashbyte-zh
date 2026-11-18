# 分支说明

本仓库是 Flashbyte 的中文本地化分支，代码基线为上游 v3.1.4。

- 上游仓库：https://github.com/iamsami101/Flashbyte
- 本分支版本：`3.1.4+0`
- 维护原则：功能与修复跟随上游；本地化、桌面窗口、发布分发改动由本分支维护

## 与上游一致

以下内容与上游 3.1.4 相同，本分支未做修改：

- 设备名默认取设备型号，内部型号码回退到品牌 / 主机名
- 设备名重置按钮、可信设备列表（按证书指纹）、"始终接受来自…"
- 分享菜单接收文件、文本转 `.txt`、会话中直接发送
- 安卓仅对 `content://` 使用 SAF 读取，普通路径直接读取
- 发布工作流：Windows 自签名（证书、`flashbyte.exe`、安装程序）、CHANGELOG 自动分节、`body_path: release-body.md`

## 本分支新增

### 本地化

- 新增 `lib/l10n/app_localizations.dart`：全部界面文案的中英文取词
- 新增 `lib/app/controllers/app_locale_controller.dart`：语言控制器，支持跟随系统 / 简体中文 / 英文
- 设置页新增"语言"选项，切换即时生效并持久化
- 通知渠道名称、界面提示随语言设置刷新
- 新增 iOS / macOS 的 `zh-Hans` 权限弹窗说明（`Runner/{Base,zh-Hans}.lproj/InfoPlist.strings`）
- 新增 macOS 中文菜单 `Runner/zh-Hans.lproj/MainMenu.strings`
- 新增 `fastlane/metadata/android/zh-CN/`：应用商店中文文案
- `README.md` 改为中文正文，新增 `README-en.md` 英文正文
- `windows/installer/flashbyte.iss` 增加简体中文安装界面
- `install.sh` / `uninstall.sh` 按 `LANG` 输出中文或英文
- `linux/com.iamsami.flashbyte.desktop` 增加中文 `Comment`

### 桌面端窗口

- 新增 `lib/platform/window_state_manager.dart`：记录并恢复窗口位置、尺寸、最大化状态
- Linux / Windows / macOS 原生层不在首帧显示窗口，由 Dart 恢复位置后再显示
- macOS / Windows 显示后执行约 160ms 淡入，避免空白窗口和位置跳变
- 恢复的位置不在任何显示器可见区域内时回退居中；无法获取几何信息时沿用上次位置
- `lib/main.dart` 用 `WindowStateManager` 替换上游的 `windowManager.waitUntilReadyToShow`

### 传输逻辑

- `device_discovery_service.dart`：`startDiscovery` / `startAdvertising` / `stop` 改为串行队列，避免并发重入导致端口与广播状态错乱
- `android_connection_notification_service.dart`：通知渠道名称与语言设置同步刷新

### 发布与分发

- `release.yml` 保留 `Download Inno Setup Chinese Language File` 步骤
- `release.yml` 的 README 下载表按文件写入：`README.md` 中文表、`README-en.md` 英文表，任一标记缺失直接失败
- 其余发布步骤与上游一致

### 依赖

- `flutter_localizations`、`intl`：界面本地化
- `screen_retriever`：校验恢复后的窗口是否仍在可见屏幕内

## 差异文件清单

### 本分支新增（12）

| 文件 | 用途 |
|---|---|
| `lib/l10n/app_localizations.dart` | 中英文文案 |
| `lib/app/controllers/app_locale_controller.dart` | 语言控制器 |
| `lib/platform/window_state_manager.dart` | 窗口位置与尺寸持久化 |
| `README-en.md` | 英文说明 |
| `ios/Runner/Base.lproj/InfoPlist.strings` | iOS 权限说明（英文） |
| `ios/Runner/zh-Hans.lproj/InfoPlist.strings` | iOS 权限说明（中文） |
| `macos/Runner/Base.lproj/InfoPlist.strings` | macOS 权限说明（英文） |
| `macos/Runner/zh-Hans.lproj/InfoPlist.strings` | macOS 权限说明（中文） |
| `macos/Runner/zh-Hans.lproj/MainMenu.strings` | macOS 中文菜单 |
| `fastlane/metadata/android/zh-CN/full_description.txt` | 商店长描述（中文） |
| `fastlane/metadata/android/zh-CN/short_description.txt` | 商店短描述（中文） |
| `fastlane/metadata/android/zh-CN/changelogs/2.txt` | 商店更新日志（中文） |

### 上游独有（1）

| 文件 | 说明 |
|---|---|
| `.github/workflows/ci.yml` | 本分支没有 CI；启用前需先确认 `dart format`、`flutter analyze`、`flutter test`、`dart test -C packages/flashbyte_core` 全部通过 |

### 内容不同（27）

| 类别 | 文件 |
|---|---|
| 本地化 | `lib/features/settings/settings_page.dart`、`lib/features/transfers/pages/file_selection_page.dart`、`incoming_transfer_offer_page.dart`、`outgoing_transfer_offer_page.dart`、`tcp_chat_page.dart`、`lib/features/transfers/widgets/transfer_widget.dart`、`file_preview_widget.dart`、`lib/app/app_settings.dart`、`lib/services/platform/android_saf_service.dart`、`lib/services/security/trusted_devices_service.dart`、`README.md` |
| 窗口 | `lib/main.dart`、`linux/runner/my_application.cc`、`windows/runner/flutter_window.cpp`、`macos/Runner/MainFlutterWindow.swift` |
| 平台资源 | `ios/Runner.xcodeproj/project.pbxproj`、`macos/Runner.xcodeproj/project.pbxproj`、`macos/Runner/Info.plist` |
| 传输 | `lib/services/discovery/device_discovery_service.dart`、`lib/services/platform/android_connection_notification_service.dart` |
| 发布分发 | `.github/workflows/release.yml`、`windows/installer/flashbyte.iss`、`linux/com.iamsami.flashbyte.desktop`、`install.sh`、`uninstall.sh` |
| 依赖 | `pubspec.yaml`（多 `flutter_localizations`、`intl`、`screen_retriever`） |

## 同步上游的流程

1. 取上游新版本代码，与本文"差异文件清单"逐项比对
2. 上游的功能改动只应用到 `lib/` 与 `packages/flashbyte_core/`
3. 下列内容不得被上游覆盖：
   - `lib/l10n/`、`lib/app/controllers/app_locale_controller.dart`
   - `lib/platform/window_state_manager.dart` 与三端原生窗口显示时机
   - `release.yml` 的 README 双文件写入段与 Inno 中文语言文件步骤
   - `windows/installer/flashbyte.iss`、`install.sh`、`uninstall.sh`、`.desktop`
   - `macos/Runner/Info.plist` 的 `CFBundleLocalizations`
   - 各平台 `zh-Hans` / `Base` 字符串文件
4. 同步后更新 `pubspec.yaml` 版本号与 `CHANGELOG.md` 条目（发布时工作流自动建立带日期的版本分节）
5. 新增/删除文件时同步更新本文的"差异文件清单"
