#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="/Volumes/SSD-1TB/Projects/Apps/AIMeter"
cd "${WORKSPACE_DIR}"

echo "[AIMeter] Building release binary..."
swift build -c release

APP_DIR="${WORKSPACE_DIR}/AIMeter.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

mkdir -p "${MACOS_DIR}"
cp ".build/release/AIMeter" "${MACOS_DIR}/AIMeter"
chmod +x "${MACOS_DIR}/AIMeter"

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIMeter</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.AIMeter</string>
    <key>CFBundleName</key>
    <string>AIMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "[AIMeter] Successfully built ${APP_DIR}"
