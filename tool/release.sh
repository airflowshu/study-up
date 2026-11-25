#!/usr/bin/env bash
# 一条命令发版：构建 → 上传 APK 到 NAS → 写 app_releases。
#
# 用法：
#   tool/release.sh "本次更新说明"                     # 版本号取自 pubspec.yaml
#   tool/release.sh "本次更新说明" --force             # 强制更新（客户端不给「稍后」）
#   tool/release.sh "说明" --no-build                  # 复用已有 APK，只上传+写库
#   tool/release.sh "说明" --url <地址> --no-build      # APK 放别处，只写库
#
# 前置：
#   - 本机有 .env（从 .env.example 复制），里面有 APP_HOST 和 ADMIN_TOKEN；
#   - 服务端已经跑起来（本地或 NAS 都行），否则上传和写库都会失败；
#   - pubspec.yaml 的 version 形如 `1.1.0+8`（+ 后是 versionCode）。
#
# 为什么 key 里带版本号：每个版本一个独立 URL，杜绝 CDN 拿旧缓存顶替新包。
# 覆盖同一版本号时浏览器/CDN 极可能还返回旧文件，这种「发了但没生效」最难查。
set -euo pipefail

cd "$(dirname "$0")/.."

# 从 .env 取 APP_HOST / ADMIN_TOKEN。没有 .env 就要求显式 export。
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

API_BASE="${API_BASE:-https://${APP_HOST:-}}"
if [ -z "$API_BASE" ] || [ "$API_BASE" = "https://" ]; then
  echo "缺 APP_HOST：在 .env 里设好域名，或 export API_BASE=https://你的域名"
  exit 1
fi
: "${ADMIN_TOKEN:?缺 ADMIN_TOKEN，在 .env 里设好}"

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

CHANGELOG="${1:-}"
[ -z "$CHANGELOG" ] && { echo "用法：tool/release.sh \"更新说明\" [--url <地址>] [--force] [--no-build]"; exit 1; }
shift || true

FORCE="false"
DO_BUILD=1
EXTERNAL_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE="true" ;;
    --no-build) DO_BUILD=0 ;;
    --url)      EXTERNAL_URL="${2:-}"; shift ;;
    --page|--nas) echo "分享页模式已不再需要：APK 现在直接放 NAS 通过隧道分发。"; echo "如果仍要用外部地址，请用 --url <地址>。"; exit 1 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
  shift
done

echo "==> 目标服务 $API_BASE"

# ---- 1. 读版本 ----
FULL_VERSION=$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | tr -d '[:space:]')
VERSION_NAME="${FULL_VERSION%%+*}"
VERSION_CODE="${FULL_VERSION##*+}"
[ "$VERSION_CODE" = "$VERSION_NAME" ] && { echo "pubspec.yaml 的 version 需要写成 1.1.0+8 的形式（+ 后是整数 versionCode）"; exit 1; }

echo "==> 版本 $VERSION_NAME ($VERSION_CODE)"

# ---- 2. 构建 ----
if [ "$DO_BUILD" = "1" ]; then
  echo "==> 构建 release APK"
  # 地址是编译期常量，打正式包必须带上真实域名，否则装上去连不上服务
  flutter build apk --release --dart-define=API_BASE="$API_BASE"
fi
[ -f "$APK_PATH" ] || { echo "找不到 $APK_PATH"; exit 1; }
SIZE=$(stat -c%s "$APK_PATH" 2>/dev/null || stat -f%z "$APK_PATH")
echo "==> APK 大小 $(awk -v s="$SIZE" 'BEGIN{printf "%.1f MB", s/1048576}')"

# 再存一份带版本号的文件名：固定叫 app-release.apk 的包，
# 在目录里排一堆根本分不清哪个是新包，传错版本是发版环节最难查的错。
NAMED_APK="$(dirname "$APK_PATH")/homework-${VERSION_NAME}.apk"
cp -f "$APK_PATH" "$NAMED_APK"
echo "==> 带版本号副本 $NAMED_APK"

# ---- 3. 上传 ----
KEY="releases/homework-${VERSION_NAME}.apk"
if [ -n "$EXTERNAL_URL" ]; then
  echo "==> 使用外部地址，跳过上传"
  DOWNLOAD_URL="${EXTERNAL_URL//\{version\}/$VERSION_NAME}"
  DOWNLOAD_URL="${DOWNLOAD_URL//\{version_code\}/$VERSION_CODE}"
else
  echo "==> 上传到 $API_BASE 的 apk 桶"
  # 显式 if 包住：curl 失败时 set -e 会直接退出，什么错误都看不到
  # --noproxy '*'：目标是自家服务，绝不能走系统代理。
  # 本机若开着 http_proxy（Clash/V2Ray 一类），发往 127.0.0.1 的请求会被
  # 代理接走并返回 502，报错长得像服务端挂了，实际服务端一个请求都没收到。
  if ! curl -fsS --noproxy '*' -X PUT "$API_BASE/v1/admin/apk/$KEY" \
    -H "X-Admin-Token: $ADMIN_TOKEN" \
    -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary "@$APK_PATH" \
    --max-time 600 > /tmp/_rel_upload.json 2>&1; then
    echo "上传失败："; cat /tmp/_rel_upload.json; exit 1
  fi
  grep -q '"key"' /tmp/_rel_upload.json || { echo "上传返回异常："; cat /tmp/_rel_upload.json; exit 1; }
  DOWNLOAD_URL="$API_BASE/v1/storages/object/apk/$KEY"
fi

# ---- 4. 回读校验 ----
# 上传返回 200 不等于文件真能下载：MIME 被拒、桶权限没配好、路径打错，
# 都可能在下载那一刻才暴露成 403/404。发版前必须真探一遍。
echo "==> 校验下载"
HEAD=$(curl -sIL --noproxy '*' --max-time 30 "$DOWNLOAD_URL" | tr -d '\r')
CODE=$(printf '%s' "$HEAD" | grep '^HTTP/' | tail -1 | awk '{print $2}')
[ "$CODE" = "200" ] || { echo "下载校验失败：HTTP ${CODE:-无响应}  $DOWNLOAD_URL"; exit 1; }

REMOTE_LEN=$(printf '%s' "$HEAD" | grep -i '^content-length:' | tail -1 | awk '{print $2}')
if [ -n "$REMOTE_LEN" ]; then
  [ "$REMOTE_LEN" = "$SIZE" ] || {
    echo "大小不一致：本地 $SIZE / 远端 $REMOTE_LEN，远端可能不是这个包"; exit 1
  }
else
  echo "    远端未返回 Content-Length，跳过大小比对"
fi

# ---- 5. 写版本表 ----
echo "==> 写入 app_releases"
python - "$VERSION_NAME" "$VERSION_CODE" "$DOWNLOAD_URL" "$CHANGELOG" "$FORCE" > /tmp/_rel_body.json <<'PY'
import json, sys
name, code, url, changelog, force = sys.argv[1:6]
print(json.dumps({
    "platform": "android",
    "version_name": name,
    "version_code": int(code),
    "download_url": url,
    "changelog": changelog,
    "force_update": force == "true",
}, ensure_ascii=False))
PY

if ! curl -fsS --noproxy '*' -X POST "$API_BASE/v1/admin/releases" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/_rel_body.json \
  --max-time 30 > /tmp/_rel_db.json 2>&1; then
  echo "写库失败："; cat /tmp/_rel_db.json; exit 1
fi

# ---- 6. 从客户端视角回读 ----
# 用和 App 完全相同的公开接口查一次，确认客户端真的会看到这个版本。
echo "==> 回读确认"
LATEST=$(curl -fsS --noproxy '*' "$API_BASE/v1/app/releases/latest?platform=android" --max-time 20)
REMOTE_CODE=$(printf '%s' "$LATEST" | python -c "import sys,json; d=json.load(sys.stdin); print(d['version_code'] if d else '')")
[ "$REMOTE_CODE" = "$VERSION_CODE" ] || {
  echo "回读不一致：期望 $VERSION_CODE，实际 ${REMOTE_CODE:-无记录}"; echo "$LATEST"; exit 1; }

echo ""
echo "发版完成"
echo "  版本    $VERSION_NAME ($VERSION_CODE)"
echo "  地址    $DOWNLOAD_URL"
echo "  强更    $FORCE"
echo ""
echo "客户端：旧版本启动或手动「检查更新」即可看到提示。"
echo "注意：旧版 APK 指向的是已停用的云环境，收不到这次更新，只能手动装新包。"
