#!/bin/bash
set -e

GITHUB_REPO="iamsami101/flashbyte"
APP_NAME="flashbyte"
APP_DISPLAY_NAME="Flashbyte"
APP_DISPLAY_NAME_ZH="Flashbyte"
DESKTOP_ENTRY="com.iamsami.flashbyte"

APP_DIR="$HOME/.local/share/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE_DIR="$HOME/.local/share/icons/hicolor"

# 根据当前语言环境选择输出语言，仅当 LANG/LC_ALL/LC_MESSAGES 含 zh 时使用中文。
case "${LANG:-}${LC_ALL:-}${LC_MESSAGES:-}" in
  zh*|*zh_*|*zh.*) LANG_ZH=1 ;;
  *) LANG_ZH=0 ;;
esac

# 输出当前语言的文本：第一个参数为英文，第二个参数为中文。
say() {
  if [ "$LANG_ZH" = 1 ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$1"
  fi
}

# ---- Banner ----
print_banner() {
    LOGO=(
    '      ████████████████'
    '      ██            ██'
    '    ██            ██  '
    '    ██          ██    '
    '  ██          ██      '
    '  ██        ████████  '
    '██                ██  '
    '████████        ██    '
    '      ██      ██      '
    '    ██      ██        '
    '    ██    ██          '
    '  ██    ██            '
    '  ██  ██              '
    '██  ██                '
    '████                  '
    )

    TEXT=(
    '░██████████░██                       ░██        ░██                      ░██               '
    '░██        ░██                       ░██        ░██                      ░██               '
    '░██        ░██  ░██████    ░███████  ░████████  ░████████  ░██    ░██ ░████████  ░███████  '
    '░█████████ ░██       ░██  ░██        ░██    ░██ ░██    ░██ ░██    ░██    ░██    ░██    ░██ '
    '░██        ░██  ░███████   ░███████  ░██    ░██ ░██    ░██ ░██    ░██    ░██    ░█████████ '
    '░██        ░██ ░██   ░██         ░██ ░██    ░██ ░███   ░██ ░██   ░███    ░██    ░██        '
    '░██        ░██  ░█████░██  ░███████  ░██    ░██ ░██░█████   ░█████░██     ░████  ░███████  '
    '                                                                  ░██                      '
    '                                                            ░███████                       '
    )

    logo_lines=${#LOGO[@]}
    text_lines=${#TEXT[@]}
    max_lines=$(( logo_lines > text_lines ? logo_lines : text_lines ))
    logo_pad_top=$(( (max_lines - logo_lines) / 2 ))
    text_pad_top=$(( (max_lines - text_lines) / 2 ))

    logo_width=0
    for line in "${LOGO[@]}"; do
        len=${#line}
        (( len > logo_width )) && logo_width=$len
    done

    GAP="   "

    for (( i=0; i<max_lines; i++ )); do
        logo_idx=$(( i - logo_pad_top ))
        text_idx=$(( i - text_pad_top ))
        logo_part=""
        text_part=""
        (( logo_idx >= 0 && logo_idx < logo_lines )) && logo_part="${LOGO[$logo_idx]}"
        (( text_idx >= 0 && text_idx < text_lines )) && text_part="${TEXT[$text_idx]}"
        printf "%-${logo_width}s%s%s\n" "$logo_part" "$GAP" "$text_part"
    done
}

print_banner
echo ""
say "Installing $APP_DISPLAY_NAME..." "正在安装 $APP_DISPLAY_NAME_ZH..."

# 1. Check dependencies
for cmd in curl jq tar; do
    if ! command -v "$cmd" &> /dev/null; then
        say "Error: '$cmd' is required but not installed. Install it with: sudo apt install $cmd" \
            "错误：需要 '$cmd'，但未安装。请运行：sudo apt install $cmd"
        exit 1
    fi
done

# 2. Get the latest release download URL from GitHub API
say "Checking latest release..." "正在检查最新版本..."
API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
DOWNLOAD_URL=$(curl -fsSL "$API_URL" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ]; then
    say "Error: could not find a .tar.gz asset in the latest release." \
        "错误：未能从最新版本中找到 .tar.gz 资源。"
    exit 1
fi

say "Found: $DOWNLOAD_URL" "找到：$DOWNLOAD_URL"

# 3. Download and extract
mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"
TMP_TARBALL=$(mktemp)
say "Downloading $APP_DISPLAY_NAME..." "正在下载 $APP_DISPLAY_NAME_ZH..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_TARBALL"

say "Extracting..." "正在解压..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
tar xzf "$TMP_TARBALL" -C "$APP_DIR"
rm -f "$TMP_TARBALL"

chmod +x "$APP_DIR/$APP_NAME"

# 4. Create a launcher script on PATH
cat > "$BIN_DIR/$APP_NAME" << LAUNCHER_EOF
#!/bin/bash
HERE="$APP_DIR"
export LD_LIBRARY_PATH="\$HERE/lib:\$LD_LIBRARY_PATH"
exec "\$HERE/$APP_NAME" "\$@"
LAUNCHER_EOF
chmod +x "$BIN_DIR/$APP_NAME"

# 5. Install all icon sizes bundled in share/icons/hicolor
if [ -d "$APP_DIR/share/icons/hicolor" ]; then
    for size_dir in "$APP_DIR"/share/icons/hicolor/*/apps; do
        [ -d "$size_dir" ] || continue
        size_name=$(basename "$(dirname "$size_dir")")
        mkdir -p "$ICON_BASE_DIR/$size_name/apps"
        cp "$size_dir/$APP_NAME.png" "$ICON_BASE_DIR/$size_name/apps/$APP_NAME.png" 2>/dev/null || true
    done
else
    say "Warning: no icons found in bundle, skipping icon install." \
        "警告：安装包中未找到图标，跳过图标安装。"
fi

# 6. Create the .desktop file, pointing at the launcher (not the raw binary)
#    The filename and StartupWMClass must match the app's GApplication ID so
#    GNOME can associate the running window with this entry (dock icon + name).
cat > "$DESKTOP_DIR/$DESKTOP_ENTRY.desktop" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Name[zh_CN]=$APP_DISPLAY_NAME_ZH
Comment=LAN file sharing app
Comment[zh_CN]=局域网文件共享应用
Exec=$BIN_DIR/$APP_NAME
Icon=$APP_NAME
Categories=Network;
Terminal=false
StartupWMClass=$DESKTOP_ENTRY
DESKTOP_EOF
chmod +x "$DESKTOP_DIR/$DESKTOP_ENTRY.desktop"

# Remove the legacy desktop entry name so the menu/dock don't show duplicates.
if [ -f "$DESKTOP_DIR/$APP_NAME.desktop" ]; then
    rm -f "$DESKTOP_DIR/$APP_NAME.desktop"
    say "Removed legacy entry: $DESKTOP_DIR/$APP_NAME.desktop" \
        "已移除旧版入口：$DESKTOP_DIR/$APP_NAME.desktop"
fi

# 7. Refresh caches
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache "$ICON_BASE_DIR" 2>/dev/null || true

echo ""
say "$APP_DISPLAY_NAME installed successfully." "$APP_DISPLAY_NAME_ZH 已成功安装。"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    say "Note: $BIN_DIR is not on your PATH." "注意：$BIN_DIR 不在你的 PATH 中。"
    say "Add this to your ~/.bashrc or ~/.zshrc to run '$APP_NAME' from anywhere:" \
        "将以下内容添加到 ~/.bashrc 或 ~/.zshrc 以便在任何地方运行 '$APP_NAME'："
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
say "You can now find it in your application menu, or run it directly:" \
    "你现在可以在应用菜单中找到它，或直接运行："
echo "  $BIN_DIR/$APP_NAME"
