#!/usr/bin/env bash
# 备份 / 演练。在 NAS 上、仓库根目录执行。
#
#   ops/backup.sh                  备份一次（数据库 + 图片），并清理过期备份
#   ops/backup.sh --keep 30        保留 30 天（默认 14）
#   ops/backup.sh --dir /vol2/bk   备份到另一块盘
#   ops/backup.sh --drill          拿最新备份真恢复一遍，核对行数，然后删掉临时库
#   ops/backup.sh --list           看现有备份
#
# 两个东西必须一起备：
#   数据库  homework 表 + families + children + app_releases
#   文件    <DATA_DIR>/uploads 里的图片和 APK
# 只备数据库，恢复后所有图片都是 404；只备文件，恢复后一条作业都不剩。
#
# 关于「备份放哪」：默认放在仓库下的 backup/，和源数据同一块盘。
# 这只能挡住「手滑删库」「升级失败」，挡不住磁盘坏掉或 NAS 进水。
# 真要防灾，用 --dir 指到另一块物理盘，或用 fnOS 的存储池快照/网盘同步再拉一份。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ---- 参数 ----
KEEP_DAYS=14
BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backup}"
MODE="backup"

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)  KEEP_DAYS="${2:?--keep 需要一个天数}"; shift ;;
    --dir)   BACKUP_DIR="${2:?--dir 需要一个路径}"; shift ;;
    --drill) MODE="drill" ;;
    --list)  MODE="list" ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）"; exit 1 ;;
  esac
  shift
done

# ---- sudo 前缀 ----
# 飞牛/群晖这类系统上，登录用户通常不在 docker 组，所有 docker 命令都要 sudo。
# 能免密就走 -n（不然脚本会卡在密码提示上），不能就退回会提示输密码的 sudo。
SUDO=()
if ! docker info >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO=(sudo -n)
  else
    SUDO=(sudo)
  fi
fi

# ---- compose 命令 ----
# 老系统只有 docker-compose v1，新的是 docker compose 插件，两个都试一遍。
if "${SUDO[@]}" docker compose version >/dev/null 2>&1; then
  DC=("${SUDO[@]}" docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=("${SUDO[@]}" docker-compose)
else
  echo "找不到 docker compose，确认 Docker 装好了"; exit 1
fi

# 守护进程没起来时 compose 的所有子命令都只会返回空，报错会误导向「服务没跑」。
# NAS 重启后 Docker 服务没自启是最常见的场景，单独判一次能省半小时。
if ! "${SUDO[@]}" docker info >/dev/null 2>&1; then
  echo "Docker 守护进程没在跑（NAS 重启后没自启？）"
  echo "  群晖/飞牛：在「Docker」应用里启动服务；命令行：sudo systemctl start docker"
  exit 1
fi

# .env 里的 POSTGRES_PASSWORD 是 compose 插值用的，这里只取库名/用户名
PGUSER_DB="homework"
PGNAME_DB="homework"

# ---- 工具 ----
human() { awk -v s="$1" 'BEGIN{ if (s>=1048576) printf "%.1f MB", s/1048576; else printf "%.0f KB", s/1024 }'; }
now()   { date '+%Y-%m-%d %H:%M:%S'; }
stamp() { date '+%Y%m%d-%H%M%S'; }

# 容器在不在跑。不跑就没法 exec，得先起来。
# 用 --filter 而不是 --status：docker-compose v1 没有 --status，--filter 两个版本都认。
running_services() {
  "${DC[@]}" ps --services --filter "status=running" 2>/dev/null || true
}

need_running() {
  if ! running_services | grep -qx "$1"; then
    echo "服务 $1 没在运行。先 docker compose up -d"; exit 1
  fi
}

# ---------- --list ----------
if [ "$MODE" = "list" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then echo "还没有备份目录 $BACKUP_DIR"; exit 0; fi
  echo "备份目录 $BACKUP_DIR"
  echo ""
  printf '%-24s %-10s %s\n' "时间" "大小" "文件"
  printf '%-24s %-10s %s\n' "------------------------" "----------" "----"
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/homework-db-*.sql.gz 2>/dev/null | while read -r f; do
    printf '%-24s %-10s %s\n' "$(date -r "$f" '+%Y-%m-%d %H:%M:%S')" "$(human "$(stat -c%s "$f")")" "$(basename "$f")"
  done
  [ -z "$(ls -1 "$BACKUP_DIR"/homework-db-*.sql.gz 2>/dev/null)" ] && echo "（空）"
  echo ""
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/homework-files-*.tar.gz 2>/dev/null | while read -r f; do
    printf '%-24s %-10s %s\n' "$(date -r "$f" '+%Y-%m-%d %H:%M:%S')" "$(human "$(stat -c%s "$f")")" "$(basename "$f")"
  done
  exit 0
fi

# ---------- 公共前置 ----------
need_running db
mkdir -p "$BACKUP_DIR"
TS="$(stamp)"

count_table() {
  # 表不存在就当 0，别让统计把整个备份搞失败
  "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d "$PGNAME_DB" -tAc \
    "SELECT count(*) FROM $1" 2>/dev/null | tr -d '[:space:]' || echo "?"
}

# ---------- --drill：真恢复一遍 ----------
if [ "$MODE" = "drill" ]; then
  # shellcheck disable=SC2012
  LATEST="$(ls -1t "$BACKUP_DIR"/homework-db-*.sql.gz 2>/dev/null | head -1 || true)"
  if [ -z "$LATEST" ]; then
    echo "没有可用的备份文件（$BACKUP_DIR 下没有 homework-db-*.sql.gz）"
    echo "先跑一次 ops/backup.sh"
    exit 1
  fi

  echo "==> 演练对象 $(basename "$LATEST")（$(human "$(stat -c%s "$LATEST")")）"
  echo "==> 完整性检查"
  gzip -t "$LATEST" || { echo "文件已损坏"; exit 1; }
  echo "    gzip 校验通过"

  DRILL_DB="homework_drill"
  echo "==> 建临时库 $DRILL_DB（不碰生产库 $PGNAME_DB）"
  "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $DRILL_DB" >/dev/null
  "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $DRILL_DB" >/dev/null

  echo "==> 导入"
  # ON_ERROR_STOP：中途出错立刻停，别把半截库当成恢复成功
  if ! gunzip -c "$LATEST" | "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d "$DRILL_DB" \
        -v ON_ERROR_STOP=1 -q >/tmp/_drill.log 2>&1; then
    echo "导入失败："; tail -20 /tmp/_drill.log
    "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d postgres -c "DROP DATABASE IF EXISTS $DRILL_DB" >/dev/null || true
    exit 1
  fi
  echo "    导入完成"

  echo ""
  echo "==> 行数比对  生产 / 恢复"
  DRILL_OK=1
  for t in families children homework app_releases; do
    LIVE="$("${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d "$PGNAME_DB" -tAc \
      "SELECT count(*) FROM $t" 2>/dev/null | tr -d '[:space:]')"
    REST="$("${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d "$DRILL_DB" -tAc \
      "SELECT count(*) FROM $t" 2>/dev/null | tr -d '[:space:]')"
    if [ "$LIVE" = "$REST" ]; then
      printf '    %-14s %6s / %6s  OK\n' "$t" "${LIVE:-0}" "${REST:-0}"
    else
      printf '    %-14s %6s / %6s  ← 不一致\n' "$t" "${LIVE:-0}" "${REST:-0}"
      DRILL_OK=0
    fi
  done

  echo ""
  echo "==> 清理临时库"
  "${DC[@]}" exec -T db psql -U "$PGUSER_DB" -d postgres \
    -c "DROP DATABASE IF EXISTS $DRILL_DB" >/dev/null
  rm -f /tmp/_drill.log

  echo ""
  if [ "$DRILL_OK" = "1" ]; then
    echo "演练通过：这份备份能恢复，行数和生产库一致。"
    echo "注意：只验证了数据库。图片要靠 homework-files-*.tar.gz，恢复后随机点开一张图确认。"
    exit 0
  else
    echo "演练失败：行数对不上。别指望这份备份，检查一下备份是不是在写入过程中拍的。"
    exit 1
  fi
fi

# ---------- 默认：备份 ----------
echo "==> 备份到 $BACKUP_DIR"
echo "    开始 $(now)"

# 1. 数据库
DB_FILE="$BACKUP_DIR/homework-db-$TS.sql.gz"
echo "==> 导出数据库"
# --clean --if-exists：恢复时不会因为「表已存在」报错，同一个文件既能灌进空库，
#   也能把生产库整个覆盖回去。--no-owner：恢复目标不一定有同名角色。
if ! "${DC[@]}" exec -T db pg_dump -U "$PGUSER_DB" -d "$PGNAME_DB" \
      --clean --if-exists --no-owner --no-privileges \
    | gzip -6 > "$DB_FILE.part"; then
  echo "pg_dump 失败"; rm -f "$DB_FILE.part"; exit 1
fi
# 先写 .part 再改名：中途断电不会留下一份看着正常、其实半截的备份
mv "$DB_FILE.part" "$DB_FILE"
gzip -t "$DB_FILE" || { echo "导出的文件损坏"; exit 1; }
echo "    $(basename "$DB_FILE")  $(human "$(stat -c%s "$DB_FILE")")"

# 2. 上传目录（图片 + APK）
FILES_FILE="$BACKUP_DIR/homework-files-$TS.tar.gz"
echo "==> 打包图片与 APK"
# api 容器把卷挂在 /data，uploads 在它下面。
# 优先 exec 正在跑的容器；没跑就用 compose run 临时起一个，只跑 tar 就退。
TAR_CMD=(tar czf - -C /data uploads)
if running_services | grep -qx api; then
  if ! "${DC[@]}" exec -T api "${TAR_CMD[@]}" > "$FILES_FILE.part"; then
    echo "打包失败（exec）"; rm -f "$FILES_FILE.part"; exit 1
  fi
else
  echo "    api 没在跑，用临时容器打包"
  if ! "${DC[@]}" run --rm --no-deps -T --entrypoint tar api \
        czf - -C /data uploads > "$FILES_FILE.part"; then
    echo "打包失败（run）"; rm -f "$FILES_FILE.part"; exit 1
  fi
fi
mv "$FILES_FILE.part" "$FILES_FILE"
gzip -t "$FILES_FILE" || { echo "打包的文件损坏"; exit 1; }
echo "    $(basename "$FILES_FILE")  $(human "$(stat -c%s "$FILES_FILE")")"

# 3. 清单——恢复时先看这个，比翻目录快
MANIFEST="$BACKUP_DIR/MANIFEST.txt"
{
  echo "时间       $TS"
  echo "数据库     $(basename "$DB_FILE")  $(human "$(stat -c%s "$DB_FILE")")"
  echo "文件       $(basename "$FILES_FILE")  $(human "$(stat -c%s "$FILES_FILE")")"
  echo "行数       families=$(count_table families) children=$(count_table children) homework=$(count_table homework) app_releases=$(count_table app_releases)"
} >> "$MANIFEST"
echo "==> 清单"
tail -4 "$MANIFEST" | sed 's/^/    /'

# 4. 清理过期
echo "==> 清理 $KEEP_DAYS 天前的备份"
# -mmin 而不是 -mtime：-mtime +14 是按「整天数」算，实测要到第 15 天才删，
# 想要「保留 14 份×每天一次」的直觉行为就用分钟数。
KEEP_MIN=$((KEEP_DAYS * 24 * 60))
REMOVED=0
while IFS= read -r old; do
  [ -z "$old" ] && continue
  rm -f -- "$old"; REMOVED=$((REMOVED + 1))
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
           \( -name 'homework-db-*.sql.gz' -o -name 'homework-files-*.tar.gz' \) \
           -mmin +"$KEEP_MIN" 2>/dev/null)
if [ "$REMOVED" -gt 0 ]; then
  echo "    删掉 $REMOVED 个过期文件"
else
  echo "    没有需要清理的"
fi

echo ""
echo "备份完成 $(now)"
COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name 'homework-db-*.sql.gz' | wc -l | tr -d ' ')
EARLIEST=$(ls -1t "$BACKUP_DIR"/homework-db-*.sql.gz 2>/dev/null | tail -1 || true)
echo "现有备份 $COUNT 份"
if [ -n "$EARLIEST" ]; then
  echo "最早的一份 $(basename "$EARLIEST")（$(date -r "$EARLIEST" '+%Y-%m-%d')）"
fi
echo ""
echo "下一步：ops/backup.sh --drill  真恢复一遍，确认这份能救回来。"
