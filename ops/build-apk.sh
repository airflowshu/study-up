#!/usr/bin/env bash
# 打一个可以发版的 arm64 APK，顺带做产物校验。
#
# 为什么不直接 flutter build apk：
#   1. 不指定 --target-platform 会把 x86_64 / arm64 / armv7 三套引擎都塞进一个包，
#      51 MB 里 49 MB 是 .so，真机只用得到其中一套；
#   2. 服务地址是编译期常量，漏了 --dart-define 就会连占位域名，装上去白屏。
#
# 用法：ops/build-apk.sh [版本号]   # 不传就取 pubspec.yaml 里的
# 产物：build/dist/homework-<版本>-arm64.apk
set -euo pipefail

cd "$(dirname "$0")/.."

API_BASE="${API_BASE:-https://your-domain.example.com}"
BT="$(ls -d /f/android/Sdk/build-tools/*/ 2>/dev/null | sort -V | tail -1)"

VER="$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
APK="build/app/outputs/flutter-apk/app-release.apk"
OUT="build/dist/homework-${VER}-arm64.apk"

echo "== 构建 ${VER}（arm64 only）"
flutter build apk --release --target-platform android-arm64 \
  --dart-define=API_BASE="${API_BASE}"

echo "== 校验"
if [ -n "${BT}" ]; then
  "${BT}aapt2.exe" dump badging "${APK}" | head -1
fi

unzip -p "${APK}" lib/arm64-v8a/libapp.so > /tmp/_verify.so
grep -a -o "${API_BASE}" /tmp/_verify.so | head -1
BAD="$(grep -a -c 'homework\.example\.com' /tmp/_verify.so || true)"
rm -f /tmp/_verify.so
if [ "${BAD}" != "0" ]; then
  echo "!! 包里还有占位域名 ${BAD} 处，别发" >&2
  exit 1
fi

mkdir -p build/dist
cp "${APK}" "${OUT}"
echo "== 产物"
ls -la "${OUT}"
sha256sum "${OUT}"
