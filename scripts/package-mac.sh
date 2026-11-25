#!/bin/sh
# 打包 Release 版 Palmhelm.app 为 DMG（分发第一步，不需要付费开发者账号）：
#   scripts/package-mac.sh [输出目录]   → <输出目录>/Palmhelm-<版本>.dmg
# 先用 bundle-bridge.sh 把 Bridge 单文件打进资源；签名沿用 project.yml（Apple Development + Team），没有可用身份即失败，不回退 ad-hoc。
# 稳定的 Team 与 Bundle ID 让 designated requirement 跨构建不变，钥匙串的「始终允许」才能跨版本生效。
# 有付费账号后在此脚本之后追加：Developer ID 签名 → notarytool 公证 → stapler；本脚本不做这几步。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/dist}"
mkdir -p "$OUT"
test "$(security find-identity -v -p codesigning | grep -c "Apple Development")" -gt 0 || { echo "没有可用的 Apple Development 签名身份，无法打包（不回退 ad-hoc）" >&2; exit 1; }
. "$ROOT/scripts/distribution-flags.sh"
BUILD_NUMBER="${PALMHELM_BUILD_NUMBER:-$PROJECT_BUILD_NUMBER}"
bundle_bridge
(cd "$ROOT" && xcodegen generate >/dev/null)
BUILD_LOG="$(mktemp)"
xcodebuild -project "$ROOT/PalmhelmMac.xcodeproj" -scheme PalmhelmMac -configuration Release -derivedDataPath "$ROOT/build/dd-release" build CURRENT_PROJECT_VERSION="$BUILD_NUMBER" SWIFT_ACTIVE_COMPILATION_CONDITIONS="$DISTRIBUTION_CONDITIONS" PALMHELM_DISTRIBUTION_STRIP=YES >"$BUILD_LOG" 2>&1 || { tail -n 40 "$BUILD_LOG" >&2; rm -f "$BUILD_LOG"; echo "Release 构建失败（签名或编译）" >&2; exit 1; }
rm -f "$BUILD_LOG"
APP="$ROOT/build/dd-release/Build/Products/Release/Palmhelm.app"
test -d "$APP" || { echo "未找到 Release 产物：$APP" >&2; exit 1; }
verify_bridge_resources "$APP"
verify_no_home_paths "$APP"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Palmhelm-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Palmhelm" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg: $DMG"
