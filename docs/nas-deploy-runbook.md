# 飞牛 NAS 部署与运维手册

这份文档记录的是**实际部署状态**，不是理想设计。路径、命令、耦合关系都以这台机器为准。

## 一、拓扑

```
公网 https://study-up.example.com
   ↓  Cloudflare 边缘（TLS 在边缘终止，Let's Encrypt 通配符 *.example.com）
cloudflared 容器（compose 项目 cf_tunnel，常驻）
   ↓  docker 内网 homework_edge，解析容器名 api
homework-api-1  (homework-api:1.1.0)   Node 22 + Fastify 5，同时发 API 和家长端静态站
   ↓  docker 内网 homework_backend（internal，无出站）
homework-db-1   (postgres:16-alpine)
```

**对外零端口**：宿主机没有为这套服务发布任何端口。唯一入口是 cloudflared 的出站隧道。

## 二、路径清单

| 内容 | 路径 |
|---|---|
| 项目目录（compose + 源码） | `/vol1/1000/homework` |
| 环境变量 | `/vol1/1000/homework/.env` |
| 数据库卷 | docker 卷 `homework_pgdata` |
| 上传卷（图片 + APK） | docker 卷 `homework_uploads` → 容器内 `/data` |
| 备份产物 | `/vol1/1000/homework/backup` |
| 隧道项目（不在本项目内） | `/vol2/1000/docker/cf_tunnel` |
| Docker 根目录 | `/vol1/docker` |
| 历史 APK 存放 | `/vol1/1000/homework_apk` |

## 三、这套编排和隧道的耦合关系（最容易踩）

隧道**不属于**本项目。本项目只有 `db` 和 `api` 两个容器，它们加入了名为 `homework_edge` 的 docker 网络，而公网入口那台 cloudflared 必须也在这个网络里，否则面板里的 `http://api:8787` 无法解析，表现为 **502**。

当前状态：
- 运行时：已用 `docker network connect homework_edge cloudflared` 接入（容器重启不会丢）
- 持久化：已写进 `/vol2/1000/docker/cf_tunnel/docker-compose.yml`（容器重建也不会丢）

**如果哪天网站 502**，按这个顺序查：

```bash
# 1. cloudflared 还在不在 homework_edge 网络里
docker inspect cloudflared --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}'

# 2. 不在就补回去（零停机）
docker network connect homework_edge cloudflared

# 3. api 自己活着吗
docker ps --filter name=homework-api-1

# 4. 从同网络探一次，绕过隧道定位问题
docker run --rm --network homework_edge node:22-alpine \
  node -e "fetch('http://api:8787/healthz').then(r=>r.text()).then(console.log)"
```

## 四、日常命令

`admin` 已在 `docker` 组，**不用 sudo**。

```bash
cd /vol1/1000/homework

# 状态
docker compose ps

# 日志（api 是 JSON 行日志）
docker compose logs -f --tail 100 api

# 重启
docker compose restart api

# 备份 / 演练 / 看历史
bash ops/backup.sh
bash ops/backup.sh --drill
bash ops/backup.sh --list
```

## 五、发新版本

代码改动后**必须重新构建镜像**，镜像标签写在 `docker-compose.yml` 的 `image:` 上（当前 `homework-api:1.1.0`）。改了代码却忘了改标签，`compose up -d` 会用旧镜像，看着"没生效"。

```bash
cd /vol1/1000/homework

# 1. 同步源码（见下一节的上传方式）
# 2. 构建（只重建变化的层，通常 30-60 秒）
docker compose build

# 3. 滚动替换 api（数据库容器不动）
docker compose up -d api

# 4. 确认迁移和健康检查
docker compose logs --tail 20 api
curl -s http://127.0.0.1:8787/healthz   # 宿主机没有端口，实际用下面的方式
docker run --rm --network homework_edge node:22-alpine \
  node -e "fetch('http://api:8787/healthz').then(r=>r.text()).then(console.log)"
```

> 注意：宿主机没发布 8787 端口，所以**不能在 NAS 上直接 curl 127.0.0.1:8787**，要走同网络的临时容器或直接访问公网域名。

## 六、源码怎么传上去

这台机器与 NAS 不在同一局域网，走 Tailscale 中继（DERP），实测 **约 80KB/s**。所以：

- **传源码（约 100KB）**：可行，几秒钟
- **传 50MB 的 APK 或镜像 tar**：不要走这条路，要十几分钟

上传用 `ops/nas.py`（在开发机上，需要 `NAS_PASS` 环境变量）：

```bash
# Git Bash 下必须加 MSYS_NO_PATHCONV=1，否则 /vol1/... 会被转成 Windows 路径
export NAS_PASS='<密码>' MSYS_NO_PATHCONV=1

python ops/nas.py run "docker compose -f /vol1/1000/homework/docker-compose.yml ps"
python ops/nas.py put <本地文件> /vol1/1000/homework/<目标路径>
```

APK 这种大文件：先用飞牛网页 UI 传到 `/vol1/1000/homework_apk`，再在 NAS 上 `docker cp` 进卷，绕开慢链路。

## 七、两个只有在这台机器上才会遇到的问题

### 1. 源码文件权限是 000

飞牛的文件系统会把文件的 mode 抹成 `000`，`COPY` 会原样带进镜像，运行时 `node` 用户读不到文件，报 `EACCES: permission denied, open '/app/migrations/0001_init.sql'`，容器无限重启。

`server/Dockerfile` 里已有兜底：`RUN chmod -R a+rX /app`。**不要删这一行**，本机构建时它是空操作，删了在 NAS 上就崩。

同理，`docker cp` 进来的脚本也是 000，执行前要 `chmod 644`。

### 2. `.env` 里的 `APP_HOST`

`APP_HOST` 决定 `PUBLIC_ORIGIN`，APK 下载链接是用它拼的。改域名时这里和 Cloudflare 面板的 Public Hostname 必须同时改。

### 3. `admin` 的 home 目录

飞牛默认不给 `admin` 建 `/home/admin`，SSH 登录会一直提示 `Could not chdir`。
更坑的是 `docker compose build` 会因为 `mkdir /home/admin: permission denied` 直接失败（构建工具要往 HOME 写东西）。
已建好（`admin:Users`，755）。**如果哪天被删了，构建就会莫名其妙失败**，报错信息完全指不到真正原因。

## 八、隧道配置在哪

| 项 | 位置 |
|---|---|
| 隧道本体、ingress、DNS | Cloudflare Zero Trust 面板（token 方式，配置不在本机） |
| Public Hostname | `study-up.example.com` → `http://api:8787` |
| 容器 | compose 项目 `cf_tunnel`，容器名 `cloudflared` |

面板里改了 hostname 会实时下发，**不需要重启 cloudflared**。

## 九、上传慢的根因与对策（2026-11-10 实测）

**现象**：Web 端传一张 485KB 的图要近 20 秒。

实测三段链路，结论是**问题不在家宽，在隧道**：

| 路径 | 速度 |
|---|---|
| NAS → 国内源（清华镜像） | **3.75 MB/s** |
| NAS → Cloudflare（直连，不用隧道） | 0.46 MB/s |
| 浏览器 → 隧道 → NAS（上传图片） | **0.025 MB/s** |
| NAS 网卡协商 | 2500 Mb/s 全双工（不是瓶颈） |

### 家宽真实带宽（2026-11-10 实测，以这次数字为准）

Ookla speedtest CLI 在这台 NAS 上跑不起来（`bind(3, ...)` 报错，系统拦了地址绑定），所以改用「往腾讯云上海 PUT 20MB 随机数据」直接量上行，两次结果几乎完全一致：

| 方向 | 目标 | 实测 | 换算 |
|---|---|---|---|
| 上行 | 腾讯云上海（COS） | **5.79 MB/s**（20MB / 3.61s） | ≈ 46 Mbps |
| 上行 | 腾讯云上海（COS）复测 | 5.79 MB/s（20MB / 3.62s） | ≈ 46 Mbps |
| 下行 | 腾讯云上海（COS） | **35.0 MB/s**（20MB / 0.60s） | ≈ 280 Mbps |
| 上行 | Cloudflare（同一台机器） | **0.30 MB/s**（8MB / 27.3s） | ≈ 2.4 Mbps |

**关键结论：家宽上行 46Mbps，到 Cloudflare 只剩 2.4Mbps，差 19 倍。** 隧道的天花板就在这里，任何客户端优化都改不了。之前写的「上行只有 1Mbps」是测到 Cloudflare 的结果，不代表家宽本身。

顺带否掉了两个曾经考虑过的方案：**IPv6 直连**和**优选 IP** —— 图片改走 COS 之后已经不占隧道带宽，再做这些收益极小、复杂度却很高。

**根因**：家里网络阻断了 QUIC（UDP 443）。cloudflared 预检日志明确写着：

```
UDP Connectivity / QUIC connection failed    status=fail
TCP Connectivity / HTTP/2 connection successful
suggested_protocol=http2
```

云隧道默认用 QUIC，在 QUIC 被干扰的网络里会退化成极低吞吐。

**已做的两个对策**：

1. **隧道切 HTTP/2**（零画质损失，收益 2-4 倍）
   在 `/vol2/1000/docker/cf_tunnel/docker-compose.yml` 的 command 里加了 `--protocol http2`。
   实测上传从 25KB/s 提升到 57-105KB/s。**这一行不要删。**
   判断当前协议：`docker logs cloudflared | grep -i protocol`

2. **Web 端上传前压缩**（`parent-web/src/lib/imageCompress.ts`）
   长边上限 2400px，PNG 源质量 0.90、其它 0.85；≤300KB 且未超长边的图完全不动。
   取值偏保守的原因：作业图多为文字，压到 1600px 时截图小字放大会发软。
   压完反而更大或压缩失败时回退原图。

**还没做的**（需要时再上）：

- Flutter App 端同样压缩（要引入 `flutter_image_compress`，改动较大）
- 图片走国内对象存储（COS/OSS），只让 API 走 CF —— 能彻底绕开国际链路，但引入外部依赖
- 上行抖动大是国际链路固有性质，别指望压到稳定高速

## 十、图片走腾讯云 COS（2026-11-10 上线）

**为什么**：图片经隧道往返时下行约 90KB/s，一张 500KB 的图要等 5 秒以上。改成客户端直传 COS 后，读图实测 **2.7-3.5 MB/s**。

**架构**：客户端先从服务端换一个 PUT 预签名 URL，再直连 COS 上传；读图直接读 COS 域名，不经过 NAS 和隧道。密钥只在服务端，客户端永远拿不到。

| 项 | 值 |
|---|---|
| 桶 | `homework-0000000000`，地域 `ap-shanghai` |
| 图片公网前缀 | `https://homework-0000000000.cos.ap-shanghai.myqcloud.com` |
| 密钥位置 | NAS 的 `/vol1/1000/homework/.env` 里 `COS_*` 四项（不进镜像、不进仓库） |
| 读权限 | 桶策略放行匿名 `GetObject`/`HeadObject`，**不放行列举**；写入仍需预签名 |
| 对象 ACL | 默认私有，COS 不继承桶 ACL，靠桶策略放行读 |

**关键接口**：

- `GET /v1/storage/config` → `{ image_base, max_image_bytes }`，客户端启动取一次
- `POST /v1/storages/presign`（需 Bearer）→ 15 分钟有效的 PUT URL，key 必须以自己家庭的 `f/<familyId>/` 开头

**三个坑**：

1. **COS 对象 ACL 不继承桶 ACL**。桶设公有读、对象仍是私有，必须用桶策略放行匿名读，或上传时带 `x-cos-acl: public-read`。当前用桶策略。
2. **COS 默认域名禁止分发 APK/IPA**，下载返回 `DownloadForbidden`，官方要求绑自定义域名（要备案）。所以 **APK 仍存 NAS 本地卷**，图片不受这条限制。
3. **CSP 必须放行 COS 域名，否则上传和看图双双静默失败**。`server/src/app.ts` 里的安全头原本是 `connect-src 'self'` / `img-src 'self' data: blob:`，浏览器会拦掉两条跨域请求：
   - 预签名直传是跨域 `fetch` → 被 `connect-src` 拦，报 `TypeError: Failed to fetch`
   - COS 图片是跨域 `<img>` → 被 `img-src` 拦，缩略图显示"加载失败"

   最坑的是**网络面板里根本看不到这条请求**，服务端日志也只有 presign 200，看起来一切正常。现在 `cosOrigin()` 会把 `https://<bucket>.cos.<region>.myqcloud.com` 拼进这两条指令。**以后换桶或换地域，这段会自动跟着 `.env` 走，不用改代码**；但如果给 COS 绑了自定义域名，要把新域名也加进去。

   排查口诀：上传报"失败重试"但服务端有 presign 200、且面板无请求 → 先看响应头的 `Content-Security-Policy`。

**存量迁移**：`ops/migrate-images-to-cos.mjs`，在容器内跑，本地文件保留不删。

### 默认域名的三个副作用（2024 年后创建的桶都这样）

腾讯云对 2024-01-01 之后创建的桶，用默认域名访问对象时会在响应里加强制下载头：

```
Content-Disposition: attachment
x-cos-force-download: true
```

实测影响范围（本项目的结论）：

| 场景 | 是否受影响 | 说明 |
|---|---|---|
| 页面里 `<img>` 显示缩略图、灯箱大图 | **不受影响** | 子资源加载不看 Content-Disposition，已实测 |
| Flutter App `Image.network` | 不受影响 | 同上 |
| 浏览器直接打开图片地址 | **受影响** | 变成下载文件 |
| 下载 `.apk` / `.ipa` | **直接 403** | `DownloadForbidden`，只能绑自定义域名 |

所以 `parent-web/src/components/image.tsx` 的「在新标签打开原图」不能写成 `<a target="_blank">`，必须 `fetch` 成 blob 再开——否则用户点一下只会得到下载文件。窗口要在 `await` 之前同步 `window.open`，否则被弹窗拦截。

### 图片缓存头

`Cache-Control: public, max-age=31536000, immutable` 由 presign 接口在签名时一起带上（`cache-control` 参与签名，客户端 PUT 必须原样带）。

- 前提：key 里的 slot 是「时间戳+随机串」，写一次永不覆盖，所以长缓存安全
- 存量图片用 `ops/cos-backfill-cache.mjs` 补（PUT Copy 到自己，只换元数据）
- 收益：孩子端刷新页面不再重复下载同一批图，省的是下行流量费（0.5 元/GB）

**签名注意**：加了 `cache-control` 之后 `q-header-list` 变成 `cache-control;content-type;host`，客户端漏带任何一个头都会被 COS 拒掉。

**未做**：Flutter 端仍拼本地路径读图（服务端 302 到 COS，多一次跳转，但能用），要等下次打包一起改。

## 十一、App 启动慢的根因与优化（2026-11-10 实测）

**现象**：孩子端打开 App，今日作业列表要 7-8 秒才出来。

用 `--dart-define=SYNC_TRACE=true` 打点测出完整链路（打点代码在 `lib/core/boot_trace.dart`，正式包不带这个 define 就完全静默）：

| 阶段 | 优化前 | 优化后 |
|---|---|---|
| 本地初始化（读库迁移 → state.init → runApp） | 148ms | 180ms |
| **今日列表上屏** | **5198ms** | **253ms** |
| 后台同步（不挡界面） | 2 次 / 约 4.4s | 1 次 / 约 4.2s |

**两个真因，都跟隧道带宽无关：**

1. **列表在等网络**（主因）。`child_today_page` 的 `initState` 直接调 `_refresh()`，而 `_refresh()` 的写法是「先 `await syncAll()`，再 `_load()` 读本地库」。也就是说本地明明有数据，界面却要等云端往返走完才肯读库。改成先 `_load()` 上屏、再后台 `_refresh()`。
2. **每个请求都重新握手**。`cloud_api.dart` 用的是 `Request.send()` —— 那是顶层函数，每调一次新建一个 `http.Client`，发完即关，等于每个请求都重走 DNS + TCP + TLS。这条链路的冷连接实测约 1.5-2.5 秒，复用连接只要 0.6-0.9 秒。改成全进程单例 `http.Client`。

**顺带修掉的浪费**：启动时 `AppState` 和今日页各触发一次同步，而 `SyncService` 内部是串行队列，第二次会完整重跑一遍（多花 1.7 秒）。现在自动刷新检测到已有同步在跑就直接复用，并监听 `SyncPhase.done` 重新读库。

**还慢的地方（未处理，也不影响首屏）**：

- TLS 握手仍要约 1.9 秒 —— 隧道出口在洛杉矶，握手要跨太平洋几个来回，除非换架构否则改不了
- `checkRevoked` 和 `pullHomework` 是两次独立请求，前者其实可以并进后者
- `pullHomework` 一次拉 500 条全字段，没有增量水位

**排查口诀**：以后遇到「打开慢」，先看是**数据等网络**还是**网络本身慢**。前者往往是客户端写法问题，改一行就够；后者才需要动基础设施。

## 十二、内存占用：实测构成与优化（2026-11-11）

**先记一个容易搞错的点**：`docker stats` 显示的 `MemUsage` **包含页缓存**，不是进程真实占用。
在这套服务上两者差了 2-3 倍，看错就会得出错误结论。

### 实测分解（cgroup memory.stat）

| 容器 | docker stats | anon（进程真实内存） | file（页缓存） |
|---|---|---|---|
| api | 42-71 MB（浮动） | **22.6 MB** | 20-49 MB |
| db | 16.9 MB | **5.6 MB** | 21 MB |

`MemUsage` 之所以在 42 到 71 之间跳，就是页缓存被回收又重建的结果 —— **这个数字不能当优化指标用**。
要看真实占用，读 `/sys/fs/cgroup/memory.stat` 里的 `anon`。

Node 侧的实际用量更直观：

```bash
docker exec homework-api-1 node -e 'console.log(require("v8").getHeapStatistics().used_heap_size/1048576)'
# 4.0 MB
```

**整库 + 整个 API 进程加起来不到 30MB。** 剩下全是可回收的页缓存，内核有内存压力时会自动释放。

### 做了哪五项（2026-11-11）

| 项 | 改动 | 实际收益 |
|---|---|---|
| App · ImageCache 上限 | Flutter 默认 100MB/1000 张 → 50MB/60 张（`lib/main.dart` 的 `_tuneImageCache`） | **最大的一项**，孩子翻图时能省几十 MB |
| App · 全屏解码上限 | 灯箱按 3200px 宽解码（`image_grid.dart` 的 `_kZoomDecodeWidth`） | 只对大图生效：4000 宽手机照从 48MB 降到 31MB；2275 宽的截图不动，不损清晰度 |
| db · shared_buffers | 96MB → 32MB | **1-2MB**。PG 对匿名映射是延迟分配物理页，并不会一次性占满，所以这项主要是压天花板 |
| db · 连接池 | api 侧 max 10 → 3 | **接近 0**。实测稳态本来就只开 2 个连接，等于没改到 |
| api · Node 堆上限 | `NODE_OPTIONS=--max-old-space-size=128` | **当前无收益**（堆只用 4MB），价值是防止将来内存无节制爬升 |

### 结论

**服务端本来就不占内存，不需要为它换语言。** 之前看到的 57MB 里大头是页缓存；
换成 Go 能把 22.6MB 的进程内存压到 10MB 出头，净省 12MB —— 相当于 NAS 总内存的 0.3%，
而代价是重写五个路由、迁移逻辑和 COS 签名。

真正值得优化的在客户端：Flutter 默认的 ImageCache 上限对"看大量作业图"这个场景明显偏松。
App 端的收益要实测才知道，测法：

```bash
adb shell dumpsys meminfo com.shuge.homework_app | grep -E "TOTAL|Native Heap|Dalvik Heap"
```

翻十几张图之后再测一次，对比 `TOTAL PSS` 的变化。

## 十三、Web 端（parent-web）改动与部署

家长端网页（React + Vite）不打独立服务，**构建产物打进 api 镜像的 `/app/public`**，
和接口同源。所以 Web 端改动 = 重建 api 镜像，不是单独发一个站点。

`server/Dockerfile` 是多阶段构建：第一阶段在 `parent-web/` 里跑 `npm run build`，
最后 `COPY --from=web /w/dist ./public`。改前端源码必须 `docker compose build api`，
只重启容器不会生效。

### 1. 附件与链接（2026-11-19 上线，镜像 `homework-api:1.1.2`；同日 `1.1.3` 修正了本地文件的 Content-Type）

App 端先支持了 PDF/DOCX 附件和网页链接卡片，Web 端补齐同一套能力。两端共用
`homework.attachments` 这一个 JSONB 字段，结构必须一字不差地对齐，否则一端写的
另一端读不出来。

**改动的文件**

| 文件 | 内容 |
|---|---|
| `parent-web/src/lib/types.ts` | `Attachment` 接口 + `Homework.attachments` / `HomeworkDraft.attachments` |
| `parent-web/src/lib/api.ts` | 云端 JSON ⇄ 本地结构互转；`uploadHomeworkFile`；`fetchLinkPreview`；`MAX_ATTACHMENT_BYTES` |
| `parent-web/src/components/AttachmentCard.tsx` | 文件卡 / 链接卡 / `AttachmentList`（支持 `compact`、`max`） |
| `parent-web/src/pages/HomeworkEditPage.tsx` | 「附件与链接」区、选完即传、失败可重试、链接弹窗、保存带 attachments、右侧预览同步 |
| `parent-web/src/pages/HomeworkListPage.tsx` | 卡片摘要露前 2 个附件；正文为空时提示「正文为空，附件见下」 |
| `parent-web/src/components/HomeworkDetailDrawer.tsx` | 正文之后渲染全量附件 |
| `server/src/routes/link.ts`（新） | 链接预览接口 |
| `server/src/app.ts` | 注册 `linkRoutes` |

**服务端前置（缺了 App 和 Web 都传不上去）**

| 项 | 位置 |
|---|---|
| `homework.attachments` 列 | `server/migrations/0002_attachments.sql`，容器启动时自动执行（幂等） |
| PDF / DOCX 的 MIME 白名单 | `server/src/config.ts` 的 `allowedUploadMime`；`storage.ts` 和 `cos.ts` 两处校验都用它 |
| PDF 的 content-type parser | `server/src/app.ts` 的 `addContentTypeParser`——**漏了它会返回 415**，不是白名单问题 |

传附件报 400「只支持图片 / PDF / DOCX」先查白名单，报 415 先查 parser。

**几个不能改错的地方**

- 文件在 COS 上的 key 用**附件自身的 id** 拼：`f/<familyId>/homework/<homeworkId>/att-<attachmentId>.<ext>`。
  不要用「第几个附件」当下标——删掉中间一个再补一个，下标会重复，会把前一个文件覆盖掉。
- 写回云端前把空字段剔掉（链接没有 key、文件没有 url），结构见 `toCloudAttachment`。
- 上传在**选中文件时就发起**，不等点保存。20 MB 的 PDF 在家宽上要几十秒，
  等到保存时才传，家长已经写完一大段了，失败一次全白费。
- 保存前拦 `pendingCount > 0`：还有文件在传就不让保存，避免把没有 key 的附件写进云端。

### 2. 新增接口 `GET /v1/link/preview?url=`

链接卡片要显示标题/描述/缩略图，但浏览器直接 `fetch` 第三方页面会被 CORS 挡死——
家长最常粘的公众号、图书平台基本都不回 `Access-Control-Allow-Origin`。所以必须绕服务端。
（App 端没有这个限制，预览是客户端自己抓的，所以 App 不依赖这个接口。）

要按「这是一个能读任意 URL 的接口」来防，现有限制：

| 项 | 做法 |
|---|---|
| 协议 | 只允许 `http:` / `https:` |
| SSRF | DNS 解析后拒绝内网、回环、链路本地地址（`127.0.0.1` 实测返回 403） |
| 重定向 | **逐跳重新校验**，最多 3 跳——只查第一跳的话一个 302 就绕过去了 |
| 资源 | 5 秒超时、最多读 512 KB |
| 解析 | 只跑正则取 `og:*` / `<title>`，不执行脚本 |
| 缓存 | 进程内 10 分钟、最多 200 条（同一篇文章常被反复粘贴） |

抓不到就让前端降级成「域名 + 完整 URL」，**不能因此挡掉发布**。

### 3. 部署

```bash
# 1. 本机先确认能构建（npm run build 里带 tsc --noEmit，类型错就别往下走，
#    否则要等 NAS 那边把镜像构建到一半才失败）
cd parent-web && npm run build && cd ..

# 2. 同步改动到 NAS（Git Bash 下 MSYS_NO_PATHCONV=1 不能漏，否则 /vol1 会被转成 Windows 路径）
MSYS_NO_PATHCONV=1 NAS_PASS='...' python ops/nas.py put parent-web/src/pages/HomeworkEditPage.tsx \
  /vol1/1000/homework/parent-web/src/pages/HomeworkEditPage.tsx

# 3. 升镜像标签，避免 compose 复用旧镜像（版本号按当前实际值改）
sed -i 's|image: homework-api:1.1.1|image: homework-api:1.1.2|' docker-compose.yml

# 4. 构建
docker compose build api

# 5. 起临时容器验证，别直接切生产
docker compose run -d --name hw-api-test2 --no-deps api

# 6. 确认无误再切（有 5–10 秒中断，客户端会自动重试）
docker compose up -d api
```

### 4. 验证

```bash
# 线上包的文案里应该有新功能（文件名取自首页 HTML 里引用的 assets/*.js）
curl -s https://study-up.example.com/ | grep -o 'assets/[^"]*\.js' | head -1
curl -s https://study-up.example.com/assets/<上面那个> | grep -c '附件与链接'

# 预览接口：正常链接 200，内网地址 403，非法 URL 400
curl -s 'https://study-up.example.com/v1/link/preview?url=https%3A%2F%2Fwww.qq.com' \
  -H "Authorization: Bearer <token>"
curl -s 'https://study-up.example.com/v1/link/preview?url=http%3A%2F%2F127.0.0.1%3A8787%2Fhealthz' \
  -H "Authorization: Bearer <token>"     # 必须 403
```

浏览器侧（playwright + 本机 Chrome）走一遍：登录 → 布置作业 → 填正文 → 选 PDF →
粘链接 → 保存 → 列表出现卡片。控制台除了下面那条 CSP 噪音，不该有应用报错。

### 5. 控制台的 CSP 警告是正常的，不用管

发版后浏览器控制台会出现类似：

```
Refused to load the script 'https://static.cloudflareinsights.com/beacon.min.js'
because it violates the following Content Security Policy directive: "script-src 'self'"
```

**是什么**：服务端在 `server/src/app.ts` 里给所有响应设了 CSP 头，其中
`script-src 'self'` 的意思是「只准执行本域名下的 JS」。而 Cloudflare 作为反向代理
会往 HTML 里塞一段自己家的访问统计脚本（`cloudflareinsights.com/beacon.min.js`，
对应后台的 Web Analytics），它的域名不是 `'self'`，浏览器就按规则拒绝执行并报这一条。

**影响**：只有 Cloudflare 那边的访问统计收不到数据，**业务功能一点不受影响**。
不用去改 CSP 放开它——放开了等于允许任意第三方脚本注入，为一条统计不值。

真要消掉，去 Cloudflare 后台关掉 Web Analytics 即可，代码不用动。

### 6. 附件读不到 / `NoSuchKey` 的排查顺序

对象可能在三处：**COS**、**容器卷** `/data/uploads/homework`、**都不在**（真丢了）。
读路径 `/v1/storages/object/homework/<key>` 的逻辑是「本地有就发本地，没有才 302 到 COS」，
所以同一个 key 有两种正常表现，别把它们当成故障：

```bash
K='f/.../att-xxxx.pdf'
# 200 = 在本地卷；302 = 本地没有，跳去 COS；404 = 两边都没有
curl -sI "https://study-up.example.com/v1/storages/object/homework/$K" | head -3
# 直链 404 但上面是 200/302 → 对象只在本地卷，COS 没有
curl -sI "https://homework-0000000000.cos.ap-shanghai.myqcloud.com/$K" | head -3
```

**已知的历史欠账**：1.2.0 之前附件走 NAS 中转上传，对象只落在容器卷，**从未进 COS**。
所以那批老附件直链访问一定 404，而 App/Web 走中转是正常的（两端 `imageUrl` 都是中转地址，
不会拼出 COS 直链）。

批量盘点：容器内遍历 `/data/uploads/homework` 的所有文件，对每个 key 做一次 COS `HEAD`，
缺的列出来。补传用：

```js
// 容器内执行（/app/dist/cos.js 已导出 signPutUrl）
const url = signPutUrl(key, mime, 3600, 'public, max-age=31536000, immutable')
await fetch(url, {
  method: 'PUT',
  headers: { 'Content-Type': mime, 'Cache-Control': 'public, max-age=31536000, immutable' },
  body: createReadStream(abs),
  duplex: 'half',   // Node fetch 传流必须有
})
```

补完一定回读 `HEAD` 比对 `content-length`，一致才算成功。
只补**被作业引用**的 key，别整目录扫上去——卷里可能还留着 speedtest / probe 之类测试垃圾。

**Content-Type 也要查**：`storage.ts` 的 `contentTypeOf` 只按扩展名推断，
新增附件类型时如果忘了加分支，会落到 `application/octet-stream`，
浏览器点开就变成下载而不是预览。报 `octet-stream` 先看这个函数。

**缓存会骗人**：这个响应带 `Cache-Control: public, max-age=31536000, immutable`，
Cloudflare 会缓存一年。改完 `contentTypeOf` 后如果线上还是旧类型，先确认是不是缓存：

```bash
curl -sI ".../att-xxx.pdf" | grep -iE 'content-type|cf-cache-status|age'
curl -sI ".../att-xxx.pdf?cb=$RANDOM" | grep -i 'content-type'   # 绕过缓存再要一次
```

`?cb=` 那次是新的就说明边缘缓存了旧的，去 Cloudflare 后台 Purge 这个 URL。
App 不受影响（自己下载后按扩展名交给 `open_filex`，不看 Content-Type），
只有浏览器直开文档时才会表现为「变成下载」。

## 十四、APK 发版流程

按顺序做，每一步都别跳 —— 之前的坑全在这几条里。

### 1. 本机构建

```bash
# 版本号先改 pubspec.yaml，例如 1.2.0+12
flutter build apk --release --target-platform android-arm64 \
  --dart-define=API_BASE=https://study-up.example.com
```

`--dart-define` **不能漏**：服务地址是编译期常量，漏了会连到占位域名
`homework.example.com`，装上去直接白屏。

`--target-platform android-arm64` **也不能漏**：不带它默认把 x86_64 / arm64-v8a /
armeabi-v7a 三套引擎都打进一个包，51 MB 里有 49 MB 是这些用不上的 .so。
带上它只留 arm64 一套，配合 `android/app/build.gradle` 里的
`jniLibs.useLegacyPackaging = true`（把 .so 压进包），产物从 51 MB 降到 **8.6 MB**。

代价与前提：
- 包内只有 arm64-v8a，**armeabi-v7a 的 32 位老设备装不上**（会报 NO_MATCHING_ABIS）。
  当前两台设备（小米手机 Android 16、华为 BAH2-AL10 平板 Android 8.0）都是 arm64，够用；
  以后要支持 32 位机，得改成 `--split-per-abi` 出两个包并按 ABI 下发。
- `useLegacyPackaging` 让安装时多一步解压：安装略慢、磁盘多占约 17 MB，
  Android 6+ 都支持，已在 Android 8.0 平板上实测通过。
- 用 `--target-platform` 而不是 `--split-per-abi`，**versionCode 保持在 pubspec 里写的值**；
  `--split-per-abi` 会给每个 ABI 加偏移（12 会变成 2012），把升级判断搞乱。

### 2. 校验产物（必做）

```bash
# 服务地址确实编进去了，且没有残留占位域名
unzip -p build/app/outputs/flutter-apk/app-release.apk lib/arm64-v8a/libapp.so > /tmp/a.so
grep -a -o "https://study-up\.example\.com" /tmp/a.so | head -1
grep -a -c "homework\.example\.com" /tmp/a.so     # 必须是 0

# 版本号
/f/android/Sdk/build-tools/36.1.0/aapt2.exe dump badging build/app/outputs/flutter-apk/app-release.apk | head -1
```

Gradle 若报 `journal-1.lock 拒绝访问`，是残留 daemon 占着锁，不是网络问题：
停掉 java 进程、删掉那个 lock 文件即可。

### 3. 上传到 NAS

走飞牛网页 UI 传到 `/vol1/1000/homework_apk/`，文件名保持 `homework-<版本>.apk`。

**上传过程中会出现 `.~#0` 结尾的临时名，那不是最终文件。** 判断传完没传完只看两件事：
文件名去掉后缀、字节数与本地一致。

### 4. 核对哈希（必做）

```bash
sha256sum /vol1/1000/homework_apk/homework-1.1.2.apk
# 与本机 sha256sum 的结果对比，必须一字不差
```

这条链路有过丢包，包坏了装上去会解析失败。

### 5. 放进容器卷

绕开隧道慢链路，直接拷进容器（不经过 HTTP 上传）：

```bash
docker exec homework-api-1 mkdir -p /data/uploads/apk/releases
docker cp /vol1/1000/homework_apk/homework-1.1.2.apk \
  homework-api-1:/data/uploads/apk/releases/homework-1.1.2.apk
# NAS 上解压出的文件权限是 000，必须补可读位，否则 node 用户读不到
docker exec homework-api-1 chmod 644 /data/uploads/apk/releases/homework-1.1.2.apk
```

### 6. 登记版本

```bash
curl -X POST https://study-up.example.com/v1/admin/releases \
  -H "X-Admin-Token: <ADMIN_TOKEN>" -H 'Content-Type: application/json' \
  -d '{"platform":"android","version_name":"1.1.2","version_code":10,
       "download_url":"{BASE}/v1/storages/object/apk/releases/homework-1.1.2.apk",
       "changelog":"更新说明","force_update":false}'
```

`download_url` 里写 `{BASE}`，服务端会替换成 `PUBLIC_ORIGIN`。写绝对地址也行，但换域名时要改数据。

### 7. 验证（必做）

```bash
curl 'https://study-up.example.com/v1/app/releases/latest?platform=android'   # 应返回新版本
curl -I 'https://study-up.example.com/v1/storages/object/apk/releases/homework-1.1.2.apk'
# Content-Length 必须等于文件字节数，Content-Type 是 application/vnd.android.package-archive
curl -r 0-1048575 -o /tmp/head.bin '<上面的下载地址>'    # 应 206
```

最后比对前 1MB 的 sha256 与本地一致 —— **上传成功不等于能下载**，这一步不能省。

### 8. 为什么 APK 不走 COS

COS 默认域名禁止分发 `.apk` / `.ipa`，GET 会返回：

```
Code: DownloadForbidden
Message: The APK/IPA file is not allowed to be distributed in a public
         network using COS default domain, please use custom domain instead.
```

要绑定自定义域名才行，而国内 COS 绑自定义域名必须 ICP 备案。
所以**图片走 COS（快），APK 留在 NAS 本地卷（受隧道带宽限制）**。这个分工是刻意的。

## 十五、当前验证基线

2026-11-10 部署完成时的实测结果，以后出问题可以对比：

| 项 | 结果 |
|---|---|
| 公网首页 | 200，`Server: cloudflare` |
| `http://` 跳 `https://` | 301 |
| 证书 | `*.example.com`，Let's Encrypt，至 2027-02-07 |
| 端到端 12 项（建家庭/建孩子/布置作业/打勾/权限） | 全过，走公网 URL |
| 备份 + 恢复演练 | 通过，行数一致 |
