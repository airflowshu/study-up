"""把 homework_edge 外部网络写进 cf_tunnel 的 compose，让隧道重建后仍然接得到 api。

幂等：已经改过就直接退出。改前留 .bak-<日期> 备份。
"""

import pathlib
import shutil
import sys

COMPOSE = pathlib.Path("/vol2/1000/docker/cf_tunnel/docker-compose.yml")
BACKUP = pathlib.Path("/vol2/1000/docker/cf_tunnel/docker-compose.yml.bak-20261110")

SERVICE_NETWORKS = """
    networks:
      - default
      - homework_edge

networks:
  homework_edge:
    external: true
"""

text = COMPOSE.read_text(encoding="utf-8")
if "homework_edge" in text:
    print("已经接入过 homework_edge，无需修改")
    sys.exit(0)

shutil.copy2(COMPOSE, BACKUP)
if not text.endswith("\n"):
    text += "\n"
COMPOSE.write_text(text + SERVICE_NETWORKS.lstrip("\n"), encoding="utf-8")
print(f"已修改，备份在 {BACKUP}")
print("--- 文件末尾 ---")
print("\n".join(COMPOSE.read_text(encoding="utf-8").splitlines()[-8:]))
