#!/bin/sh
# Mac 测试入口（O1-075）：测试宿主使用独立 bundle id，不与正式 App（com.forsakesoul.palmhelm.mac）或 .dev 共用偏好域。
# 用命令行覆盖而不改 project.yml：Debug/Release 的 bundle id 与签名保持不变，只有这次 test 动作换成测试宿主 id。
# 覆盖同时作用于测试包（它的 bundle id 也会变成同一个值，不影响测试）。测试语言默认 zh-Hans/CN（与 scheme 的 test 段一致）；调用方给出 -testLanguage 时整体交给调用方，例如英文对照 -testLanguage en -testRegion US。其余参数原样交给 xcodebuild。
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# xcodebuild 只接受一次 -testLanguage，所以仅在调用方未给出时补默认值。
case " $* " in *" -testLanguage "*) LANG_ARGS="" ;; *) LANG_ARGS="-testLanguage zh-Hans -testRegion CN" ;; esac
exec xcodebuild test -project "$HERE/PalmhelmMac.xcodeproj" -scheme PalmhelmMac -destination "platform=macOS" \
  $LANG_ARGS PRODUCT_BUNDLE_IDENTIFIER=com.forsakesoul.palmhelm.mac.testhost "$@"
