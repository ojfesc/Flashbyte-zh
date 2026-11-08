<div align="center">
    <img src="./media/app_icon.png" alt="Flashbyte Logo" width="200" height="200"/>
    <h1>Flashbyte</h1>
    <h3>一个简单且快速的本地文件共享应用。</h3>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.1.0-blue?style=for-the-badge" alt="Version"/>
  <img src="https://img.shields.io/github/actions/workflow/status/iamsami101/Flashbyte/ci.yml?label=CI&style=for-the-badge" alt="CI Status"/>
  <img src="https://img.shields.io/badge/flutter-3.29-blue?logo=flutter&style=for-the-badge" alt="Flutter"/>
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="Flutter"/>
</p>

### 特性
- **TLS 加密**：你可以通过加密连接发送文件。
- **跨平台支持**：Flashbyte 支持所有主流平台！
- **局域网文件共享**：你可以在无需 Wi-Fi 访问的情况下通过局域网发送文件。
- **无损文件共享**：以原始质量发送文件。
- **支持所有文件类型**：发送任何类型的文件。
- **无文件大小限制**：无论文件多大都可以发送。
- **不使用外部服务器**：Flashbyte 利用你的本地网络将文件发送到设备。
- **跨平台**：将文件传输到局域网内任何安装了 Flashbyte 的设备。
- **开源且不收集数据**：所有代码都在 GitHub 上公开可用。

### 工作原理
Flashbyte 使用纯 TCP socket 在隔离区（isolate，即隔离的内存通道）内建立两台局域网设备之间的连接，然后利用它来读取和发送文件字节流，同时保持前端（主 UI isolate）的流畅性。

你可以在以下平台体验 Flashbyte：

<!-- BEGIN AUTO RELEASE DOWNLOADS -->
| 平台 | 下载 |
|----------|----------|
| Android | [APK](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-android.apk) \| [AAB](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-android.aab) |
| Linux | [TAR](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-linux-x64.tar.gz) |
| macOS | [DMG](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-macos.dmg) |
| iOS | [APP](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-ios-unsigned-runner-app.zip) |
| Windows | [EXE](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-windows-setup-x64.exe) \| [ZIP](https://github.com/ojfesc/Flashbyte-zh/releases/download/v2.1.3/flashbyte-windows-x64.zip) |
<!-- END AUTO RELEASE DOWNLOADS -->

### 目录
- [截图](#截图)
- [安装说明](#安装说明)
  - [Android](#android)
  - [Linux](#linux)
  - [Windows](#windows)
  - [macOS](#macos)
  - [iOS](#ios)
- [签署发布构建](#签署发布构建)
- [从源码构建](#从源码构建)
  - [前置要求](#前置要求)
  - [克隆仓库](#克隆仓库)
  - [构建 Linux 版本](#构建-linux-版本)
  - [构建 Android 版本](#构建-android-版本)
  - [构建 iOS 版本](#构建-ios-版本)
  - [构建 macOS 版本](#构建-macos-版本)
  - [构建 Windows 版本](#构建-windows-版本)
  - [调试构建](#调试构建)

---

## 截图：
<img src="media/previews/mobile-android.png" alt="Flashbyte Android preview" height="300"/> <img src="media/previews/desktop-linux.png" alt="Flashbyte Linux preview" height="300"/>

## 安装说明：
- ### Android：
从 [releases](https://github.com/iamsami101/Flashbyte/releases) 页面下载 Flashbyte `.apk` 文件。现在，通过文件管理器或浏览器的下载页面运行该 `.apk` 文件。

- ### Linux：
#### 安装脚本（推荐）：
你可以在 Linux 终端中运行以下命令来安装 Flashbyte：
```bash
curl -fsSl "https://raw.githubusercontent.com/iamsami101/Flashbyte/refs/heads/main/install.sh" | bash
```
如果你想卸载它，可以运行：
```bash
curl -fsSl "https://raw.githubusercontent.com/iamsami101/Flashbyte/refs/heads/main/uninstall.sh" | bash
```
---
#### 手动安装

如果你不想运行安装脚本，可以手动设置 Flashbyte：

**1. 下载发布包**

从 [Releases 页面](https://github.com/iamsami101/flashbyte/releases) 获取最新的 `flashbyte-linux-x86_64.tar.gz`。

**2. 解压**

```bash
mkdir -p ~/.local/share/flashbyte
tar xzf flashbyte-linux-x86_64.tar.gz -C ~/.local/share/flashbyte
chmod +x ~/.local/share/flashbyte/flashbyte
```

**3. 创建启动器脚本**

这能确保应用在运行时能找到其捆绑的库：

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/flashbyte << 'EOF'
#!/bin/bash
HERE="$HOME/.local/share/flashbyte"
export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
exec "$HERE/flashbyte" "$@"
EOF
chmod +x ~/.local/bin/flashbyte
```

确保 `~/.local/bin` 在你的 `PATH` 中。用以下命令检查：

```bash
echo $PATH | grep -q "$HOME/.local/bin" && echo "OK" || echo "not on PATH"
```

如果不在，请将以下内容添加到你的 `~/.bashrc` 或 `~/.zshrc` 中，然后重启终端：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**4. 安装图标**

```bash
for size_dir in ~/.local/share/flashbyte/share/icons/hicolor/*/apps; do
    size_name=$(basename "$(dirname "$size_dir")")
    mkdir -p ~/.local/share/icons/hicolor/"$size_name"/apps
    cp "$size_dir/flashbyte.png" ~/.local/share/icons/hicolor/"$size_name"/apps/flashbyte.png
done
```

**5. 安装桌面入口**

> 桌面入口文件名和 `StartupWMClass` 必须与应用 GApplication ID（`com.iamsami.flashbyte`）匹配，这样 GNOME 才能在 Dock 中正确显示图标和应用名称。

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/com.iamsami.flashbyte.desktop << EOF
[Desktop Entry]
Type=Application
Name=Flashbyte
Comment=LAN file sharing app
Exec=$HOME/.local/bin/flashbyte
Icon=flashbyte
Categories=Network;
Terminal=false
StartupWMClass=com.iamsami.flashbyte
EOF
chmod +x ~/.local/share/applications/com.iamsami.flashbyte.desktop
rm -f ~/.local/share/applications/flashbyte.desktop
```

**6. 刷新桌面缓存**

```bash
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache ~/.local/share/icons/hicolor
```

**7. 运行**

在应用菜单中启动 **Flashbyte**，或直接运行：

```bash
flashbyte
```

#### 手动卸载

```bash
rm -rf ~/.local/share/flashbyte
rm -f ~/.local/bin/flashbyte
rm -f ~/.local/share/applications/com.iamsami.flashbyte.desktop
rm -f ~/.local/share/applications/flashbyte.desktop
rm -f ~/.local/share/icons/hicolor/*/apps/flashbyte.png
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache ~/.local/share/icons/hicolor
```

- ### Windows：

从 [releases](https://github.com/iamsami101/Flashbyte/releases) 页面下载 **Flashbyte 安装向导** (`flashbyte-windows-setup-x64.exe`) 或便携版 `flashbyte-windows-x64.zip`。

**安装程序（推荐）：** 运行安装程序并按照向导操作，然后从开始菜单或桌面快捷方式启动 **Flashbyte**。要移除 Flashbyte，请使用 **设置 > 应用**。

**便携版：** 解压 zip 文件，然后运行：

```powershell
flashbyte.exe
```

如果 Windows SmartScreen 警告你该应用来自未知发布者，请选择 **更多信息** 然后 **仍要运行**。发布版本使用自签名证书签名，因此 Windows 无法完全信任该签名。要消除警告，请使用受信任的代码签名证书签署发布版本（参见 [签署发布构建](#签署发布构建)）。要移除便携版应用，请删除解压后的文件夹。

- ### macOS：
从 [releases](https://github.com/iamsami101/Flashbyte/releases) 页面下载 `flashbyte-macos.dmg`。

打开 DMG，将 **flashbyte.app** 拖入 **Applications（应用程序）**，然后从应用程序中启动它。

如果 macOS 阻止该应用因为尚未签名/公证，请打开 **系统设置 > 隐私与安全性** 并允许 Flashbyte，或者右键点击应用并选择 **打开**。

- ### iOS：
当前的 iOS 发布产物是一个未签名的 `Runner.app` zip。它对 CI 输出和本地签名很有用，但不能直接安装在普通 iPhone 上。

要在设备上安装，请使用 Apple 开发者账号从源码构建/签名：

```bash
flutter build ipa --release
```

然后通过 TestFlight、Apple Configurator 或你自己的 MDM/内部发布设置分发已签名的 `.ipa`。

## 签署发布构建

GitHub 工作流会构建发布产物并将 macOS 打包为 DMG，但平台签名需要私有证书和配置文件，这些应存储在 GitHub Actions secrets 中。

要签署 Android 发布版本，请添加上传密钥库并使用 secrets 配置 Gradle 签名，例如 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。

要签署并公证 macOS 发布版本，请使用 Apple Developer ID Application 证书以及公证凭据，通常存储为 `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`、`APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`、`APPLE_TEAM_ID`、`APPLE_ID` 和 `APPLE_APP_SPECIFIC_PASSWORD`。

要创建可安装的 iOS 发布版本，请添加 Apple Distribution 证书和配置文件，通常存储为 `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`、`APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`、`IOS_PROVISIONING_PROFILE_BASE64` 和 `APPLE_TEAM_ID`。

对于 Windows 发布版本，当前工作流使用全新的自签名证书签署可执行文件和 Inno Setup 安装程序。这能保持二进制文件的防篡改性，但仍会触发 SmartScreen 警告，因为签名证书不受信任。要使用受信任的证书签名，请获取 Windows 代码签名证书并在工作流中配合 `signtool` 使用，通常存储为 `WINDOWS_CERTIFICATE_BASE64` 和 `WINDOWS_CERTIFICATE_PASSWORD`。

## 从源码构建

如果你想自己构建 Flashbyte 而不是使用预编译的发布版本，你需要安装 Flutter 并为你目标平台进行设置。

### 前置要求

- **Flutter SDK** (stable 频道) — [安装说明](https://docs.flutter.dev/get-started/install)
- **Git**

安装 Flutter 后验证你的设置：

```bash
flutter doctor
```

在继续之前解决它标记的任何问题（缺少 Android SDK、缺少 Linux 工具链等——下面按平台分别说明）。

### 克隆仓库

```bash
git clone https://github.com/iamsami101/flashbyte.git
cd flashbyte
flutter pub get
```

---

### 构建 Linux 版本

**额外前置要求：**

```bash
sudo apt update
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
```

如果尚未启用 Linux 桌面支持，请启用：

```bash
flutter config --enable-linux-desktop
```

构建发布二进制文件：

```bash
flutter build linux --release
```

输出包位于：

```bash
build/linux/x64/release/bundle/
```

这个 `bundle/` 文件夹正是打包进 `.tar.gz` 发布版本的内容——它包含 `data/`、`lib/`、`flashbyte` 可执行文件以及包含图标和桌面文件的 `share/`。你可以直接运行它：

```bash
cd build/linux/x64/release/bundle
./flashbyte
```

或者按照上面的 [手动安装](#手动安装) 步骤，使用这个 `bundle/` 文件夹作为源而不是下载的发布版本。

---

### 构建 Android 版本

**额外前置要求：**

- Android SDK（通过 [Android Studio](https://developer.android.com/studio) 或命令行工具）
- 配置好的 `ANDROID_HOME` 环境变量
- 至少接受一个 Android SDK 许可：

```bash
flutter doctor --android-licenses
```

构建发布 APK：

```bash
flutter build apk --release
```

输出位于：

```bash
build/app/outputs/flutter-apk/app-release.apk
```

将其安装到连接的设备或模拟器：

```bash
flutter install
```

或者手动将 APK 传输到设备并安装（你需要启用“从未知来源安装”，因为这不是通过 Play Store 分发的）。

如果你想要按架构拆分的 APK（文件更小）：

```bash
flutter build apk --split-per-abi --release
```

这会在同一输出文件夹中生成单独的 APK，每个 ABI 一个（`armeabi-v7a`、`arm64-v8a`、`x86_64`）。

---

### 构建 iOS 版本

**额外前置要求：**

- macOS
- Xcode
- CocoaPods
- 如果你想在物理设备上安装或创建可分发的 IPA，需要一个 Apple 开发者账号

启用 iOS 支持并检查你的设置：

```bash
flutter doctor
```

构建未签名的发布应用用于 CI/产物检查：

```bash
flutter build ios --release --no-codesign
```

在配置好 Apple 签名证书和配置文件后构建已签名的 IPA：

```bash
flutter build ipa --release
```

未签名的应用输出通常位于：

```bash
build/ios/iphoneos/Runner.app
```

已签名的 IPA 输出通常位于：

```bash
build/ios/ipa/
```

---

### 构建 macOS 版本

**额外前置要求：**

- macOS
- Xcode
- CocoaPods

如果尚未启用 macOS 桌面支持，请启用：

```bash
flutter config --enable-macos-desktop
```

构建发布应用：

```bash
flutter build macos --release
```

输出应用位于：

```bash
build/macos/Build/Products/Release/Flashbyte.app
```

要在你自己的机器之外分发，请签署并公证应用，然后打包为 DMG。

---

### 构建 Windows 版本

**额外前置要求：**

- Windows
- 带有“使用 C++ 的桌面开发”工作负载的 Visual Studio

如果尚未启用 Windows 桌面支持，请启用：

```powershell
flutter config --enable-windows-desktop
```

构建发布应用：

```powershell
flutter build windows --release
```

输出包位于：

```powershell
build\windows\x64\runner\Release\
```

压缩该文件夹的内容以分发便携式 Windows 构建。在 `windows/installer/flashbyte.iss` 提供了捆绑的 [Inno Setup](https://jrsoftware.org/isinfo.php) 安装脚本；发布工作流使用它来构建已签名的 **安装向导** (`flashbyte-windows-setup-x64.exe`)。要进行更广泛的分发，请使用受信任的 Windows 代码签名证书签署。

---

### 调试构建

对于开发/测试而非发布构建，去掉 `--release` 直接运行：

```bash
flutter run
```

Flutter 将检测任何连接的设备（或要求你选择一个）并在你进行更改时热重载。
