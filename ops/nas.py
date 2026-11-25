"""NAS 远程执行小工具（paramiko）。凭密码走 SSH，避免在 Windows 上装 sshpass。

用法：
  NAS_PASS=... python ops/nas.py run "docker ps -a"
  NAS_PASS=... python ops/nas.py put <本地文件> <远程路径>
  NAS_PASS=... python ops/nas.py get <远程文件> <本地路径>

主机与用户可通过环境变量覆盖：NAS_HOST / NAS_USER / NAS_PORT。
"""

import base64
import os
import sys

import paramiko

HOST = os.environ.get("NAS_HOST", "")
USER = os.environ.get("NAS_USER", "admin")
PORT = int(os.environ.get("NAS_PORT", "22"))
PASS = os.environ.get("NAS_PASS", "")


def connect() -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        port=PORT,
        username=USER,
        password=PASS,
        timeout=20,
        banner_timeout=30,
        auth_timeout=30,
        look_for_keys=False,
        allow_agent=False,
    )
    return client


def run(command: str) -> int:
    client = connect()
    try:
        timeout = float(os.environ.get("NAS_TIMEOUT", "600"))
        _, stdout, stderr = client.exec_command(command, timeout=timeout, get_pty=False)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        if out:
            print(out, end="" if out.endswith("\n") else "\n")
        if err:
            print("--- stderr ---", file=sys.stderr)
            print(err, end="" if err.endswith("\n") else "\n", file=sys.stderr)
        print(f"--- exit {code} ---")
        return code
    finally:
        client.close()


def put(local: str, remote: str) -> int:
    # 不走 SFTP：飞牛的 sftp 服务对新建文件偶发返回 ENOENT。
    # 改成走 SSH 通道把 base64 喂给远端的 base64 -d，稳定且没有大小限制。
    size = os.path.getsize(local)
    with open(local, "rb") as f:
        payload = base64.b64encode(f.read())

    client = connect()
    try:
        cmd = f"mkdir -p \"$(dirname '{remote}')\" && base64 -d > '{remote}'"
        _, stdout, stderr = client.exec_command(cmd, timeout=900)
        stdin = stdout.channel
        stdin.sendall(payload)
        stdin.shutdown_write()
        code = stdin.recv_exit_status()
        err = stderr.read().decode("utf-8", "replace").strip()
        if code != 0:
            print(f"上传失败（exit {code}）：{err}", file=sys.stderr)
            return 1
        _, out, _ = client.exec_command(f"wc -c < '{remote}'", timeout=60)
        remote_size = int(out.read().decode().strip() or 0)
        if remote_size != size:
            print(f"大小不一致：本地 {size} / 远端 {remote_size}", file=sys.stderr)
            return 1
        print(f"已上传 {local} -> {remote}（{size} 字节）")
        return 0
    finally:
        client.close()


def get(remote: str, local: str) -> int:
    client = connect()
    try:
        sftp = client.open_sftp()
        sftp.get(remote, local)
        sftp.close()
        print(f"已下载 {remote} -> {local}")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    action = sys.argv[1]
    if action == "run":
        sys.exit(run(sys.argv[2]))
    if action == "put":
        sys.exit(put(sys.argv[2], sys.argv[3]))
    if action == "get":
        sys.exit(get(sys.argv[2], sys.argv[3]))
    print(__doc__)
    sys.exit(2)
