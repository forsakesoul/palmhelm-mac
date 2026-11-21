#!/bin/sh
# 把内置 Bridge（Go 单文件）及其许可文件放进 App 资源目录（不入库）。只支持 Apple 芯片（arm64）。
#   scripts/bundle-bridge.sh                          默认：下载 scripts/bridge.env 固定的公开资产，并按其中的 SHA256 校验
#   scripts/bundle-bridge.sh --from-dist <路径>        维护者：从本地 palmhelm-bridge 仓库的 dist/ 复制二进制（按该目录的 SHA256SUMS 校验）
# 两种模式的许可文件都从同一固定 URL 下载并校验；不回退到其它来源；任何校验失败都立即退出非零。
#
# 安装状态：prepare（尚未改动 Resources）→ installing（已开始替换）→ committed（三件已核对，备份删除）
#                                                              └→ restored（已回滚，三件与清单一致，备份删除）
#                                                              └→ restore_failed（回滚失败，备份保留，打印人工恢复步骤）
# 备份目录由 mktemp 在 Resources 同级创建，只有 mktemp 成功返回的路径才登记为本轮所有；创建失败不清理任何路径。
# 备份目录内的 MANIFEST 逐行记录三个文件“原本存在（含 sha256）/原本不存在”，开始替换前写入，之后不再修改。
# 自动恢复用 cp -p 从备份复制回 Resources（备份在恢复成功前保持完整），并按清单复核三件；只有复核通过才删除备份。
# 退出时（EXIT）若处于 installing 则先回滚；回滚期间忽略 INT/TERM，保证一次回滚要么完整完成，要么保留备份。
# 边界：不承诺 SIGKILL、断电、两个打包进程并发运行时的恢复；这些情况下备份与清单可能残留，需人工核对。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../PalmhelmMac/Resources"

fail() { echo "bundle-bridge: $*" >&2; exit 1; }

is_sha256() { [ "${#1}" -eq 64 ] && case "$1" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac; }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

NAMES="palmhelm-bridge LICENSE-palmhelm-bridge.txt THIRD_PARTY_NOTICES.txt"
PHASE=prepare
STAGE=""      # 下载与暂存的临时目录：任何情况下都删除
BACKUP=""     # 只有 mktemp 成功返回的备份目录才登记在这里（本轮所有）
MANIFEST=""   # $BACKUP/MANIFEST：每行 “文件名 present sha256” 或 “文件名 absent -”
FAILED=""     # 最近一次失败的文件名（用于诊断）

# 按清单从备份恢复：present 用 cp -p 复制回去，absent 删除；全部完成后按清单复核三件。
restore_old() {
  r_ok=0
  while read -r r_name r_state r_sha; do
    if [ "$r_state" = present ]; then
      cp -p "$BACKUP/$r_name" "$RES/$r_name" || r_ok=1
    else
      rm -f "$RES/$r_name" || r_ok=1
    fi
  done < "$MANIFEST"
  [ "$r_ok" -eq 0 ] || return 1
  while read -r r_name r_state r_sha; do
    if [ "$r_state" = present ]; then
      [ -f "$RES/$r_name" ] && [ "$(sha_of "$RES/$r_name")" = "$r_sha" ] || return 1
    else
      [ ! -e "$RES/$r_name" ] || return 1
    fi
  done < "$MANIFEST"
  return 0
}

print_manual_steps() {
  echo "bundle-bridge: 旧文件未能完全恢复。备份目录（本轮创建，保持完整）：$BACKUP" >&2
  echo "bundle-bridge: 人工恢复步骤（依据清单 ${MANIFEST}，按顺序执行）：" >&2
  while read -r m_name m_state m_sha; do
    if [ "$m_state" = present ]; then
      echo "bundle-bridge:   cp -p \"$BACKUP/$m_name\" \"$RES/$m_name\"" >&2
    else
      echo "bundle-bridge:   rm -f \"$RES/$m_name\"" >&2
    fi
  done < "$MANIFEST"
  echo "bundle-bridge: 执行后三件的 sha256 应与清单一致；确认后再删除备份目录。" >&2
}

on_exit() {
  status=$?
  trap '' INT TERM
  if [ "$PHASE" = installing ]; then
    if restore_old; then PHASE=restored; else PHASE=restore_failed; fi
  fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
  case "$PHASE" in
    committed|restored|prepare)
      if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then rm -rf "$BACKUP"; fi ;;
    restore_failed)
      print_manual_steps ;;
  esac
  # 没有提交就不能以成功退出：即使某个分支的退出码丢失，也保证非零。
  if [ "$PHASE" != committed ] && [ "$status" -eq 0 ]; then status=1; fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MACHINE="$(uname -m)"
[ "$MACHINE" = "arm64" ] || fail "只支持 Apple 芯片（arm64），本机为 $MACHINE"
. "$HERE/bridge.env"
[ "$BRIDGE_ARCH" = "arm64" ] || fail "bridge.env 的 BRIDGE_ARCH 必须为 arm64"

for pair in "LICENSE_SHA256" "NOTICES_SHA256"; do
  eval "v=\${BRIDGE_$pair}"
  is_sha256 "$v" || fail "bridge.env 的 BRIDGE_$pair 仍是占位值或不是 64 位小写十六进制，拒绝下载（发布资产后由维护者填入）"
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/palmhelm-bridge-stage.XXXXXX")" || fail "无法创建临时目录"

# 下载到 STAGE 内的临时文件并校验摘要；成功时把路径写入 ${FETCHED}。
fetch_to_temp() {
  # $1 = URL，$2 = 期望 SHA256
  FETCHED="$(mktemp "$STAGE/download.XXXXXX")" || fail "无法创建下载临时文件"
  curl -fsSL --proto '=https' "$1" -o "$FETCHED" || fail "下载失败：$1"
  [ "$(sha_of "$FETCHED")" = "$2" ] || fail "下载内容的 SHA256 与 bridge.env 不符（资产缺失、被替换或损坏）：$1"
}

if [ "${1:-}" = "--from-dist" ]; then
  [ -n "${2:-}" ] || fail "--from-dist 需要 bridge 仓库路径"
  BRIDGE="$2"
  BIN_SRC="$BRIDGE/dist/palmhelm-bridge-darwin-arm64"
  test -f "$BIN_SRC" && test -f "$BRIDGE/dist/SHA256SUMS" || fail "先在 $BRIDGE 运行 scripts/build.sh <版本>"
  BIN_SHA="$(awk -v n="palmhelm-bridge-darwin-arm64" '$2 == n { print $1 }' "$BRIDGE/dist/SHA256SUMS")"
  [ -n "$BIN_SHA" ] || fail "SHA256SUMS 里没有 palmhelm-bridge-darwin-arm64"
  [ "$(sha_of "$BIN_SRC")" = "$BIN_SHA" ] || fail "产物摘要与 SHA256SUMS 不符：$BIN_SRC"
  BIN_TMP="$BIN_SRC"
elif [ "$#" -eq 0 ]; then
  is_sha256 "$BRIDGE_SHA256" || fail "bridge.env 的 BRIDGE_SHA256 仍是占位值或不是 64 位小写十六进制，拒绝下载（发布资产后由维护者填入）"
  fetch_to_temp "$BRIDGE_URL" "$BRIDGE_SHA256"
  BIN_TMP="$FETCHED"
  BIN_SHA="$BRIDGE_SHA256"
else
  fail "未知参数：$1"
fi

fetch_to_temp "$BRIDGE_LICENSE_URL" "$BRIDGE_LICENSE_SHA256"; LIC_TMP="$FETCHED"
fetch_to_temp "$BRIDGE_NOTICES_URL" "$BRIDGE_NOTICES_SHA256"; NOT_TMP="$FETCHED"

# 1) 在同一个临时资源目录里准备三个文件：每一步都检查返回值，并复核摘要。
NEW_DIR="$STAGE/new"
mkdir -p "$NEW_DIR" || fail "无法创建临时资源目录"
cp "$BIN_TMP" "$NEW_DIR/palmhelm-bridge" || fail "复制 Bridge 失败"
chmod 755 "$NEW_DIR/palmhelm-bridge" || fail "设置 Bridge 权限失败"
cp "$LIC_TMP" "$NEW_DIR/LICENSE-palmhelm-bridge.txt" || fail "复制许可文件失败"
chmod 644 "$NEW_DIR/LICENSE-palmhelm-bridge.txt" || fail "设置许可文件权限失败"
cp "$NOT_TMP" "$NEW_DIR/THIRD_PARTY_NOTICES.txt" || fail "复制第三方声明失败"
chmod 644 "$NEW_DIR/THIRD_PARTY_NOTICES.txt" || fail "设置第三方声明权限失败"

[ "$(sha_of "$NEW_DIR/palmhelm-bridge")" = "$BIN_SHA" ] || fail "临时目录中的 Bridge 摘要不符"
[ "$(sha_of "$NEW_DIR/LICENSE-palmhelm-bridge.txt")" = "$BRIDGE_LICENSE_SHA256" ] || fail "临时目录中的许可文件摘要不符"
[ "$(sha_of "$NEW_DIR/THIRD_PARTY_NOTICES.txt")" = "$BRIDGE_NOTICES_SHA256" ] || fail "临时目录中的第三方声明摘要不符"

# 2) 备份旧的三个文件到 Resources 同级的目录，并写入清单。此时还没有改动 Resources。
mkdir -p "$RES" || fail "无法创建资源目录"
RES="$(cd "$RES" && pwd)"
RES_PARENT="$(dirname "$RES")"
if B="$(mktemp -d "$RES_PARENT/.bridge-backup-XXXXXX")"; then
  BACKUP="$B"
else
  fail "无法创建备份目录（未改动任何文件）"
fi
MANIFEST="$BACKUP/MANIFEST"
: > "$MANIFEST" || fail "无法写入备份清单"
for n in $NAMES; do
  if [ -e "$RES/$n" ]; then
    FAILED="$n"
    cp -p "$RES/$n" "$BACKUP/$n" || fail "备份旧文件失败：${FAILED}"
    s="$(sha_of "$BACKUP/$n")"
    [ "$s" = "$(sha_of "$RES/$n")" ] || fail "备份旧文件摘要不符：${FAILED}"
    printf '%s present %s\n' "$n" "$s" >> "$MANIFEST" || fail "写入备份清单失败"
  else
    printf '%s absent -\n' "$n" >> "$MANIFEST" || fail "写入备份清单失败"
  fi
done

# 3) 整体替换。失败时在捕获文件名后回滚，并把结果记入 PHASE；EXIT 处理函数不会重复回滚。
PHASE=installing
for n in $NAMES; do
  FAILED="$n"
  if ! mv -f "$NEW_DIR/$n" "$RES/$n"; then
    if restore_old; then PHASE=restored; fail "安装失败（${FAILED}），已恢复旧文件"; fi
    PHASE=restore_failed; fail "安装失败（${FAILED}），恢复旧文件也失败"
  fi
done

# 4) 安装后复核 Resources 中的三个文件；不一致则同样回滚。
verify_installed() {
  [ "$(sha_of "$RES/palmhelm-bridge")" = "$BIN_SHA" ] && \
  [ "$(sha_of "$RES/LICENSE-palmhelm-bridge.txt")" = "$BRIDGE_LICENSE_SHA256" ] && \
  [ "$(sha_of "$RES/THIRD_PARTY_NOTICES.txt")" = "$BRIDGE_NOTICES_SHA256" ]
}
FAILED=""
if ! verify_installed; then
  if restore_old; then PHASE=restored; fail "安装后复核失败，已恢复旧文件"; fi
  PHASE=restore_failed; fail "安装后复核失败，恢复旧文件也失败"
fi

PHASE=committed
echo "bundled: palmhelm-bridge $BRIDGE_VERSION arch=arm64 + licence files (sha256-verified)"
