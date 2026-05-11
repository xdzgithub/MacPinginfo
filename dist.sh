#!/bin/bash
set -e

APP_NAME="MacPinginfo"
PROJECT_DIR="$(dirname "$0")"
BUILD_DIR="$PROJECT_DIR/dist"
ARCHIVE="$PROJECT_DIR/${APP_NAME}.zip"

echo "=== Building $APP_NAME for distribution ==="

# Clean
rm -rf "$BUILD_DIR" "$ARCHIVE"

# Build Release
cd "$PROJECT_DIR"
./build.sh

# Locate the built app
APP=$(find ~/Library/Developer/Xcode/DerivedData/MacPinginfo-*/Build/Products/Release -name "${APP_NAME}.app" -type d | head -1)

if [ -z "$APP" ]; then
    echo "ERROR: App not found"
    exit 1
fi

echo "Found app: $APP"

# Copy .app to dist folder
cp -R "$APP" "$BUILD_DIR/"

# Create README next to the app
cat > "$BUILD_DIR/README.txt" << 'README'
MacPinginfo - 网络延迟监控工具
===============================

使用方法：
1. 双击 "MacPinginfo.app" 打开应用
2. 如果提示 "无法打开" 或安全警告：
   - 打开 "系统设置" → "隐私与安全性"
   - 滚动到底部，点击 "仍要打开"
   - 输入密码确认
3. 输入要监控的 IP 地址（每行一个）
4. 点击 "开始" 开始监控

故障排除：
- 如果提示 "无法验证开发者"，在 "系统设置" → "隐私与安全性" 中允许运行

---
README

# Create zip archive
cd "$BUILD_DIR"
zip -r "$ARCHIVE" "MacPinginfo.app" -x "*.DS_Store"

echo ""
echo "=== Distribution package created ==="
echo "Archive: $ARCHIVE"
echo "Size: $(du -h "$ARCHIVE" | cut -f1)"
echo ""
echo "分享 MacPinginfo.zip 给其他人即可，他们双击 .app 打开即可使用。"
