#!/bin/bash
# 一键编译 + 打包 .app
# 用法: bash build.sh
set -e
cd "$(dirname "$0")"

APP="ClipboardHistory.app"

# 1) 清理旧 bundle
rm -rf "$APP"

# 2) 创建目录结构
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# 3) 写 Info.plist (LSUIElement=true:启动即后台运行,无 Dock 图标)
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClipboardHistory</string>
    <key>CFBundleDisplayName</key>
    <string>ClipboardHistory</string>
    <key>CFBundleIdentifier</key>
    <string>com.z.clipboardhistory</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>ClipboardHistory</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 4) 编译进 bundle
swiftc -O ClipboardHistory.swift -framework Cocoa -framework Carbon -o "$APP/Contents/MacOS/ClipboardHistory"

echo "✓ 编译完成"
echo "  应用路径: $(pwd)/$APP"
echo "  启动: open \"$APP\""
