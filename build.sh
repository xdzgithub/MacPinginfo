#!/bin/bash
set -e

cd "$(dirname "$0")"

# Restore correct entitlements (XcodeGen overwrites with empty ones)
cat > MacPinginfo.entitlements << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Regenerate project
xcodegen generate

# Build Release
xcodebuild -project MacPinginfo.xcodeproj -scheme MacPinginfo -configuration Release build
