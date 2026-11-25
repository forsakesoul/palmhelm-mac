#!/bin/sh
# 公证前的发行 Release 构建（分发第二步的输入）：与 package-mac.sh 使用同一发行编译条件 PALMHELM_DISTRIBUTION。
#   scripts/build-release-mac.sh [构建号]   → 打印 Palmhelm.app 路径（build/dd-distribution），交给 notarize-mac.sh --app
#   构建号缺省取 project.yml 的 CURRENT_PROJECT_VERSION（可用参数或 PALMHELM_BUILD_NUMBER 覆盖）；内置 Bridge 见 scripts/bundle-bridge.sh。
# 直接 `xcodebuild -configuration Release` 的产物不带该条件：正式 App 会禁止 Claude 钩子的安装 / 修复，公证与重签都无法补回。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/distribution-flags.sh"
BUILD_NUMBER="${1:-${PALMHELM_BUILD_NUMBER:-$PROJECT_BUILD_NUMBER}}"
bundle_bridge
(cd "$ROOT" && xcodegen generate >/dev/null)
BUILD_LOG="$(mktemp)"
xcodebuild -project "$ROOT/PalmhelmMac.xcodeproj" -scheme PalmhelmMac -configuration Release -derivedDataPath "$ROOT/build/dd-distribution" build CURRENT_PROJECT_VERSION="$BUILD_NUMBER" SWIFT_ACTIVE_COMPILATION_CONDITIONS="$DISTRIBUTION_CONDITIONS" PALMHELM_DISTRIBUTION_STRIP=YES >"$BUILD_LOG" 2>&1 || { tail -n 40 "$BUILD_LOG" >&2; rm -f "$BUILD_LOG"; echo "发行 Release 构建失败" >&2; exit 1; }
rm -f "$BUILD_LOG"
APP="$ROOT/build/dd-distribution/Build/Products/Release/Palmhelm.app"
test -d "$APP" || { echo "未找到发行产物：$APP" >&2; exit 1; }
verify_bridge_resources "$APP"
verify_no_home_paths "$APP"
echo "$APP"
