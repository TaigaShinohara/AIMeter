#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${WORKSPACE_DIR}"

echo "[AIMeter] Building release binary in ${WORKSPACE_DIR}..."
swift build -c release

APP_DIR="${WORKSPACE_DIR}/AIMeter.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
rm -f "${MACOS_DIR}/AIMeter"
cp ".build/release/AIMeter" "${MACOS_DIR}/AIMeter"
chmod +x "${MACOS_DIR}/AIMeter"

cp "${WORKSPACE_DIR}/scripts/update_usage.py" "${RESOURCES_DIR}/update_usage.py"
chmod +x "${RESOURCES_DIR}/update_usage.py"

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
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "[AIMeter] Signing app bundle (ad-hoc with bound Info.plist)..."
codesign --force --deep --sign - "${APP_DIR}"

ZIP_NAME="AIMeter-macos-universal.zip"
echo "[AIMeter] Creating distribution archive: ${ZIP_NAME}..."
rm -f "${WORKSPACE_DIR}/${ZIP_NAME}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${WORKSPACE_DIR}/${ZIP_NAME}"

echo "[AIMeter] Successfully built ${APP_DIR} and created ${WORKSPACE_DIR}/${ZIP_NAME}"
