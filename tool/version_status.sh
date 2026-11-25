#!/usr/bin/env bash
# 查「本地打出来的包」和「云端发布的版本」是否对得上。
#
# 用途：发版后确认真的发出去了。
# 为什么需要它：`flutter build apk` 只会产出文件，**不会更新版本表**。
# 打完包忘了跑 release.sh，包看着是新的，用户那边永远收不到更新——
# 而且界面上没有任何提示能暴露这件事，只能靠人记得。
#
# 查询路径和 App 一模一样（同一个公开接口），所以它看到的结果
# 就是客户端会看到的结果，不是另开一条旁路。
set -euo pipefail

cd "$(dirname "$0")/.."

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

FULL=$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | tr -d '[:space:]')
NAME="${FULL%%+*}"
CODE="${FULL##*+}"
[ "$CODE" = "$NAME" ] && { echo "pubspec.yaml 的 version 要写成 1.1.0+8 的形式"; exit 1; }

APK="build/app/outputs/flutter-apk/homework-${NAME}.apk"
if [ -f "$APK" ]; then
  SIZE=$(stat -c%s "$APK" 2>/dev/null || stat -f%z "$APK")
  APK_DESC="有，$(awk -v s="$SIZE" 'BEGIN{printf "%.1f MB", s/1048576}')"
elif [ -f "build/app/outputs/flutter-apk/app-release.apk" ]; then
  APK_DESC="没有 homework-${NAME}.apk，但 app-release.apk 存在（可能还没跑过 release.sh）"
else
  APK_DESC="缺，还没构建"
fi

# --noproxy '*'：目标是自家服务，别让系统代理（Clash 一类）接走回环地址的请求
ROW=$(curl -fsS --noproxy '*' "$API_BASE/v1/app/releases/latest?platform=android" --max-time 20)

python - "$NAME" "$CODE" "$APK_DESC" "$ROW" "$API_BASE" <<'PY'
import json, sys

name, code, apk_desc, raw, base = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
row = json.loads(raw) if raw.strip() else None

print(f"本地 pubspec : {name} ({code})")
print(f"本地 APK     : {apk_desc}")
print(f"服务地址     : {base}")

if not row:
    print("云端发布     : 一条记录都没有")
    print("\n结论：还没发布过任何版本。客户端检查更新会说「已经是最新版本」。")
    sys.exit(2)

rname = row.get('version_name', '')
rcode = row.get('version_code', 0)
print(f"云端最新     : {rname} ({rcode})")
print(f"发布时间     : {row.get('published_at', '—')}")
print(f"下载地址     : {row.get('download_url', '—')}")
print(f"强制更新     : {'是' if row.get('force_update') else '否'}")

print()
if rcode == code and rname == name:
    print("结论：一致。装了这台设备上这个包的手机可以收到更新提示。")
elif rcode < code:
    print(f"结论：云端落后 {code - rcode} 个版本号。跑 tool/release.sh 把包发上去。")
elif rcode > code:
    print(f"结论：云端比本地新（云端 {rcode} > 本地 {code}）。"
          "本地 pubspec 忘记升版本，或这是旧分支。")
else:
    print(f"结论：versionCode 相同但版本名不同（本地 {name} / 云端 {rname}）。"
          "两者应当成对递增。")
PY
