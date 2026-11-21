#!/bin/sh
# Developer ID 签名 → 公证 → staple → Gatekeeper 校验（分发第二步，需要付费开发者账号）：
#   scripts/notarize-mac.sh --app <Palmhelm.app> [--out <DMG>] [--identity <证书名或片段>] [--profile <notarytool 钥匙串配置>] [--dry-run]
# 默认值：--identity "Developer ID Application"（找不到或不唯一即失败，不回退到其他身份）；--profile palmhelm；
# --out build/notarize/Palmhelm.dmg（相对于仓库根目录）。
# 输入 .app 必须来自 scripts/build-release-mac.sh（带发行编译条件 PALMHELM_DISTRIBUTION）：公证与重签都不能补回该条件，普通 Release 产物会让正式 App 禁用 Claude 钩子的安装 / 修复。
# 输入 .app 不会被原地修改：先复制到临时目录再签名。内置 Bridge 先于外层 App 签名，外层不使用 --deep 代替逐件签名。
# --dry-run 不签名、不上传、不联网：只检查当前构建的前置条件并打印将执行的步骤。
# 凭据只通过 notarytool 钥匙串配置读取，脚本不接收、不打印任何密码或 Apple ID。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/PalmhelmMac/PalmhelmMac.entitlements"
APP=""
OUT="$ROOT/build/notarize/Palmhelm.dmg"
IDENTITY="Developer ID Application"
PROFILE="palmhelm"
DRY=0

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --identity) [ $# -ge 2 ] || usage; IDENTITY="$2"; shift 2 ;;
    --profile) [ $# -ge 2 ] || usage; PROFILE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数：$1" >&2; usage ;;
  esac
done
[ -n "$APP" ] || usage
[ -d "$APP" ] || { echo "找不到 .app：$APP" >&2; exit 1; }
BRIDGE="$APP/Contents/Resources/palmhelm-bridge"

say() { printf '%s\n' "$*"; }
need_fix() { say "  需处理：$*"; FIX=$((FIX + 1)); }
ok_item() { say "  已满足：$*"; }

# ---------- 前置检查（dry-run 与真实运行共用，只读） ----------
FIX=0
BLOCK=0
preflight() {
  say "前置检查（${APP}）："
  if [ -f "$BRIDGE" ]; then ok_item "内置 Bridge 存在（$(shasum -a 256 "$BRIDGE" | cut -c1-12)…）"; else need_fix "内置 Bridge 缺失，需先运行 scripts/bundle-bridge.sh"; fi
  if [ -f "$BRIDGE" ]; then
    BFLAGS="$(codesign -dv "$BRIDGE" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
    case "$BFLAGS" in
      *runtime*) ok_item "内置 Bridge 已开启 hardened runtime（${BFLAGS}）" ;;
      *) need_fix "内置 Bridge 未开启 hardened runtime（当前 flags=${BFLAGS:-无}），签名时加 --options runtime" ;;
    esac
    if codesign -dv "$BRIDGE" 2>&1 | grep -q 'Signature=adhoc'; then need_fix "内置 Bridge 为 ad-hoc 签名，签名时用 Developer ID 重签"; else ok_item "内置 Bridge 已有非 ad-hoc 签名（仍需 Developer ID 重签）"; fi
  fi
  AFLAGS="$(codesign -dv "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
  case "$AFLAGS" in
    *runtime*) ok_item "外层 App 已开启 hardened runtime（${AFLAGS}）" ;;
    *) need_fix "外层 App 未开启 hardened runtime（当前 flags=${AFLAGS:-无}），签名时加 --options runtime" ;;
  esac
  ENT_TMP="$(mktemp)"
  codesign -d --entitlements :- "$APP" >"$ENT_TMP" 2>/dev/null || true
  if grep -q 'get-task-allow' "$ENT_TMP"; then
    need_fix "当前签名的 entitlements 含 com.apple.security.get-task-allow（开发签名注入），Developer ID 签名须用仓库内的 entitlements 重签（不含该项）"
  else
    ok_item "当前 entitlements 不含 get-task-allow"
  fi
  say "  当前 entitlements 键（仅列键名）：$(/usr/libexec/PlistBuddy -c 'Print' "$ENT_TMP" 2>/dev/null | sed -n 's/^ *\(com\.apple[^ =]*\) = .*/\1/p' | tr '\n' ' ')"
  rm -f "$ENT_TMP"
  [ -f "$ENTITLEMENTS" ] && ok_item "仓库 entitlements 存在（签名时使用）" || need_fix "缺少 $ENTITLEMENTS"
  DEVID_N="$(security find-identity -v -p codesigning | grep -c "$IDENTITY" || true)"
  if [ "$DEVID_N" -eq 1 ]; then ok_item "钥匙串中有 1 个匹配的签名身份"; else say "  阻塞：钥匙串中匹配 '$IDENTITY' 的签名身份数为 ${DEVID_N}（需恰好 1 个；未创建时先按 docs/distribution.md 创建证书）"; BLOCK=$((BLOCK + 1)); fi
  xcrun --find notarytool >/dev/null 2>&1 && ok_item "notarytool 可用" || need_fix "找不到 notarytool（需安装 Xcode 命令行工具）"
}

if [ "$DRY" -eq 1 ]; then
  say "== dry-run：不签名、不上传、不联网"
  preflight
  say "将执行的步骤："
  say "  1. 复制 .app 到临时目录（不修改输入）"
  say "  2. 解析签名身份（唯一匹配，否则失败）；检查 notarytool 配置 '$PROFILE'"
  say "  3. 签名内置 Bridge：codesign --force --timestamp --options runtime（无 entitlements）；签后计算 SHA-256"
  say "  4. 签名外层 App：codesign --force --timestamp --options runtime --entitlements <仓库 entitlements>（不用 --deep）"
  say "  5. 校验：codesign --verify --deep --strict；确认不含 get-task-allow"
  say "  6. 生成 DMG（含 Applications 链接）并签名"
  say "  7. xcrun notarytool submit --wait，失败时取 log 并退出"
  say "  8. xcrun stapler staple / validate DMG；spctl 校验 DMG 与挂载后的 App"
  say "  9. 复制到输出路径：$OUT"
  say "dry-run 结论：签名相关需处理 ${FIX} 项（签名步骤会处理）；阻塞 ${BLOCK} 项（真实运行前必须解决）"
  exit 0
fi

# ---------- 真实运行 ----------
if [ "$(security find-identity -v -p codesigning | grep -c "$IDENTITY" || true)" -eq 0 ]; then
  cat >&2 <<EOF
没有可用的「${IDENTITY}」证书。请先在 Apple Developer 账号中创建 Developer ID Application 证书，并安装到登录钥匙串（Xcode › Settings › Accounts › Manage Certificates，或证书助理）。
脚本不会回退到其他身份。
EOF
  exit 1
fi
if [ "$(security find-identity -v -p codesigning | grep -c "$IDENTITY" || true)" -ne 1 ]; then
  echo "匹配 '$IDENTITY' 的签名身份不唯一，请用 --identity 指定完整名称。" >&2; exit 1
fi
ID="$(security find-identity -v -p codesigning | sed -n "s/.*\"\\(.*$IDENTITY.*\\)\".*/\\1/p" | head -n 1)"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
找不到可用的 notarytool 凭据配置「${PROFILE}」（或网络不可用）。请在终端运行一次，按提示输入 Apple ID、Team ID 与 App 专用密码（不要把密码写进命令行）：
  xcrun notarytool store-credentials "$PROFILE"
然后重新运行本脚本。
EOF
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
LOG="$STAGE/notary"
mkdir -p "$LOG"
WORK="$STAGE/Palmhelm.app"
ditto "$APP" "$WORK"
BRIDGE="$WORK/Contents/Resources/palmhelm-bridge"

say "1/8 签名内置 Bridge"
codesign --force --timestamp --options runtime --sign "$ID" "$BRIDGE"
say "    Bridge 签名后 sha256=$(shasum -a 256 "$BRIDGE" | cut -d' ' -f1)"

say "2/8 签名嵌套组件（若有，由内向外）"
find "$WORK/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -name '*.xpc' \) 2>/dev/null | while IFS= read -r c; do
  codesign --force --timestamp --options runtime --sign "$ID" "$c"
done

say "3/8 签名外层 App（仓库 entitlements，不用 --deep）"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$ID" "$WORK"

say "4/8 校验签名"
codesign --verify --deep --strict --verbose=2 "$WORK"
if codesign -d --entitlements :- "$WORK" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "签名后仍含 get-task-allow，中止" >&2; exit 1
fi

say "5/8 生成并签名 DMG"
DMGSTAGE="$STAGE/dmg"
mkdir -p "$DMGSTAGE"
ditto "$WORK" "$DMGSTAGE/Palmhelm.app"
ln -s /Applications "$DMGSTAGE/Applications"
RAW_DMG="$STAGE/Palmhelm.dmg"
hdiutil create -volname "Palmhelm" -srcfolder "$DMGSTAGE" -ov -format UDZO "$RAW_DMG" >/dev/null
codesign --force --timestamp --sign "$ID" "$RAW_DMG"

say "6/8 公证（notarytool submit --wait）"
set +e
xcrun notarytool submit "$RAW_DMG" --keychain-profile "$PROFILE" --wait >"$LOG/submit.txt" 2>&1
SUBMIT_RC=$?
set -e
cat "$LOG/submit.txt"
SUB_ID="$(sed -n 's/^ *id: *//p' "$LOG/submit.txt" | head -n 1)"
STATUS="$(sed -n 's/^ *status: *//p' "$LOG/submit.txt" | tail -n 1)"
if [ -n "$SUB_ID" ]; then
  xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE" "$LOG/notary-log.json" >/dev/null 2>&1 || true
fi
if [ "$SUBMIT_RC" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
  echo "公证未通过（status=${STATUS:-未知}）。公证日志保存在：$LOG/notary-log.json（临时目录，脚本退出即删除，需要请先复制）" >&2
  exit 1
fi

say "7/8 staple 并校验"
xcrun stapler staple "$RAW_DMG"
xcrun stapler validate "$RAW_DMG"

say "8/8 Gatekeeper 校验"
spctl --assess --type open --context context:primary-signature -vv "$RAW_DMG"
MNT="$STAGE/mnt"
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$RAW_DMG" >/dev/null
set +e
spctl --assess --type execute -vv "$MNT/Palmhelm.app"
RC=$?
hdiutil detach "$MNT" >/dev/null 2>&1
set -e
[ "$RC" -eq 0 ] || { echo "挂载后的 App 未通过 Gatekeeper 校验" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$RAW_DMG" "$OUT"
say "完成：$OUT"
say "安装闭环（人工）：拷入 /Applications → 确认 com.apple.quarantine 存在 → 首次打开无「无法验证」提示。"
