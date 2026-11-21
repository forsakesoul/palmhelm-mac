# 发行构建的编译条件（#108）：只有发行用 Release 构建带它（package-mac.sh、build-release-mac.sh 共用，不在 project.yml 全局打开）。
DISTRIBUTION_CONDITIONS='$(inherited) PALMHELM_DISTRIBUTION'
# 构建号单一来源：project.yml 的 CURRENT_PROJECT_VERSION（公开仓只有一个提交，提交数不再单调）。PALMHELM_BUILD_NUMBER 可覆盖。
PROJECT_BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\([0-9][0-9]*\)".*/\1/p' "$ROOT/project.yml" | head -n 1)"
[ -n "$PROJECT_BUILD_NUMBER" ] || { echo "project.yml 中缺少 CURRENT_PROJECT_VERSION" >&2; exit 1; }
# 内置 Bridge 来源：默认从 scripts/bridge.env 的固定公开资产取得；PALMHELM_BRIDGE_DIST 指向本地 bridge 仓库时改走 --from-dist。
# 参数分别传递（路径可含空格），不拼接字符串。
bundle_bridge() {
  if [ -n "${PALMHELM_BRIDGE_DIST:-}" ]; then
    "$ROOT/scripts/bundle-bridge.sh" --from-dist "$PALMHELM_BRIDGE_DIST"
  else
    "$ROOT/scripts/bundle-bridge.sh"
  fi
}
# 打包后核对 App 内的 Bridge 与两份许可文件：存在、可执行、版本正确，许可文件摘要与 bridge.env 一致。
verify_bridge_resources() {
  APP_RES="$1/Contents/Resources"
  . "$ROOT/scripts/bridge.env"
  for f in palmhelm-bridge LICENSE-palmhelm-bridge.txt THIRD_PARTY_NOTICES.txt; do
    [ -f "$APP_RES/$f" ] || { echo "App 缺少资源：$f" >&2; exit 1; }
  done
  [ -x "$APP_RES/palmhelm-bridge" ] || { echo "内置 Bridge 不可执行" >&2; exit 1; }
  # 两种模式都核对 App 内二进制的字节摘要：默认模式对照 bridge.env；from-dist 模式对照本地 dist/SHA256SUMS。
  if [ -z "${PALMHELM_BRIDGE_DIST:-}" ]; then
    BIN_EXPECT="$BRIDGE_SHA256"
  else
    BIN_EXPECT="$(awk -v n="palmhelm-bridge-darwin-arm64" '$2 == n { print $1 }' "$PALMHELM_BRIDGE_DIST/dist/SHA256SUMS")"
    [ -n "$BIN_EXPECT" ] || { echo "dist/SHA256SUMS 里没有 palmhelm-bridge-darwin-arm64" >&2; exit 1; }
  fi
  [ "$(shasum -a 256 "$APP_RES/palmhelm-bridge" | cut -d' ' -f1)" = "$BIN_EXPECT" ] || { echo "内置 Bridge 摘要与预期不符" >&2; exit 1; }
  [ "$("$APP_RES/palmhelm-bridge" version 2>/dev/null | cut -d' ' -f2)" = "$BRIDGE_VERSION" ] || { echo "内置 Bridge 版本与 bridge.env 不符" >&2; exit 1; }
  [ "$(shasum -a 256 "$APP_RES/LICENSE-palmhelm-bridge.txt" | cut -d' ' -f1)" = "$BRIDGE_LICENSE_SHA256" ] || { echo "许可文件摘要不符" >&2; exit 1; }
  [ "$(shasum -a 256 "$APP_RES/THIRD_PARTY_NOTICES.txt" | cut -d' ' -f1)" = "$BRIDGE_NOTICES_SHA256" ] || { echo "第三方声明摘要不符" >&2; exit 1; }
  echo "App 内 Bridge 与许可文件核对通过"
}
