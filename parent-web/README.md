# 家庭作业 · 家长 Web 端

在电脑浏览器里布置和管理作业。和 `study_up` 的 Android App **共用同一份后端数据**：电脑上布置完，孩子手机刷新就能看到。

```
parent-web/          ← 本目录（React 应用）
server/              ← Node + Fastify + PostgreSQL，既发 API 也发这里的 dist/
lib/                 ← 原 Flutter App
```

前端和 API **由同一个进程提供**（`server/` 容器里同时 serve `dist/` 和 `/v1/*`），所以线上是同源部署，`API.baseUrl` 默认是空串。`VITE_API_BASE` 只在 `npm run dev` 或把前端单独挂到别的域名时才需要设。

## 跑起来

```bash
cd parent-web
npm install
npm run dev        # http://127.0.0.1:5180
npm run build      # 产物在 dist/，纯静态
npm run typecheck
```

要求 Node 20.19+（当前用的是 Vite 8 / TypeScript 7 / React 19）。

## 登录

输入 6 位家庭码 —— 在手机 App 的「设置」里能看到。

现在是**服务端校验**：`POST /auth/v1/signin/family` 把家庭码交上去，服务端查到 `families` 行之后签发 JWT，`family_id` 写在载荷里，12 小时过期，配一个 180 天的 refresh token 续期。之后所有请求都带 `Authorization: Bearer`，服务端**从 token 里取 `family_id` 强制注入到查询条件**——客户端传上来的 `family_id` 一律被丢掉。

「谁拿到这 6 位码，谁就能进这个家」这条仍然成立（没有账号密码体系），但风险面比原来小了一个量级：以前是匿名 token 对三张表全放行，任何人拿到就能把全部家庭的作业读一遍；现在一个 token 只对一个家庭有效，而且 `families` 表只有家长身份读得到自己那一行，孩子身份连读都不行。

会话存在 `localStorage`：

| key | 内容 |
|---|---|
| `hw_web_token` | access token（12h） |
| `hw_web_refresh` | refresh token（180d），服务端只存它的 `sha256` |
| `hw_web_expire` | 本地过期时间戳，提前 60 秒续期 |
| `hw_web_device` | 随机设备 id，跟着请求头走 |
| `hw_web_family` | **只有 familyId**，退出登录时删掉 |
| `hw_web_theme` | 明暗主题选择 |

家庭名和码**不落本地**，每次用 `GET /v1/rdb/rest/families` 重新拉，避免别处改名后这边还显示旧的。请求撞上 401 时先自动 refresh 一次再重发；refresh 也失败才清会话、回登录页（`cloud.onAuthLost`）。

## 为什么是独立的 React 应用，而不是 Flutter Web

三者都不存在于浏览器，逐个做条件编译的代价比写一套页面高：

| App 里的依赖 | 在浏览器里 |
|---|---|
| `sqflite` 本地库 | 不存在，要换 WASM 版或整层重写 |
| `path_provider` 私有目录 | 不存在 |
| `com.shuge.homework_app/clipboard` 原生通道 | 不存在，剪贴板图片要走 `ClipboardEvent.files` |
| 大段文字编辑、多图粘贴 | Flutter Web 的文本域在 PC 上体验明显弱于原生 DOM |

所以两端只共享 **云端协议** 和 **[图N] 标记规则**，UI 各写各的。孩子端仍然是 App。

## 和 App 的数据契约（改代码前必读）

这五条错一条，两端的表现就会对不上：

1. **`homework.images` 存的是云存储 key 数组**，不是本地路径。App 端的本地路径只在它自己的 SQLite 里。
2. **正文图片位置用行内标记 `[图N]`**，N 从 1 起，对应 `images[N-1]`。位置靠标记本身表达，不靠字符偏移 —— 这样选中、删除、剪切全都天然生效。
3. **家长端只写 `child_id / family_id / date / subject / content / images`**。
   `is_done / done_at` 归孩子端写。两端字段不重叠，孩子在手机上打的勾才不会被家长在电脑上的一次保存冲掉。这条已经实测过（见下）。
4. **日期是 `yyyy-MM-dd` 字符串，按本地时区算**，不要用 `toISOString()`（那个会转 UTC，晚上 8 点后「今天」就变明天了）。
5. **图片 key 形如 `f/<familyId>/homework/<作业id>/<唯一标识>.<ext>`**，桶 `homework` 公开读，直链免鉴权。
   用唯一标识而不是「第几张」：电脑上删掉中间一张再补一张时，位置序号会重复，按序号命名会覆盖前一张。
   前缀 `f/<familyId>/` 不是装饰——上传时服务端会校验它必须等于 token 里的家庭 id，不等直接 403。所以别人即使猜到你的作业 id 也写不进去。

## 跨域

**线上没有跨域**。前端和 API 是同一个 Fastify 进程、同一个域名，浏览器看来就是同源请求，连 `OPTIONS` 预检都不会发。当初特意做成同源，是为了省掉三件麻烦事：

| 同源省掉的 | 否则会怎样 |
|---|---|
| CORS 响应头 | 每个响应都要带 `Access-Control-Allow-Origin` / `Allow-Headers`。`Prefer` 是自定义头，漏一个就 4xx |
| 预检往返 | `PATCH` + `Prefer` 的每次写操作前多一个 `OPTIONS` |
| 图床回源的跨域限制 | 「粘贴网页图文」要把外链图取回字节，跨域时 `<img>` 能显示但 `fetch` 拿不到 |

`npm run dev` 时确实不同源（Vite 在 5180、后端在 8787），靠 `vite.config.ts` 里的代理转发 `/auth`、`/v1`、`/healthz` 解决，默认指向 `http://127.0.0.1:8787`，可用 `VITE_DEV_BACKEND` 改。

## 功能

| 页面 | 内容 |
|---|---|
| 登录 | 6 位家庭码，回车即进；错误内联提示 |
| 作业列表 | 7 天日期条快切 + 日历跳转、按孩子筛选、搜索学科/内容、完成状态、学科色条、图片缩略图 |
| 作业详情 | **单击卡片**从右侧滑出抽屉，完整渲染正文与图片（和孩子手机同一套规则），可直接编辑或删除 |
| 布置 / 编辑 | 8 个预设学科 + 自定义、孩子、日期（今天/明天快捷）、正文、图片、右侧实时预览 |
| 孩子 | 新增 / 改名 / 换配色 / 移除（软删除，历史作业保留） |
| 设置 | 家庭码大字展示与复制、明暗主题、退出登录 |

### 为什么点卡片是看详情，不是直接编辑

列表卡片只显示两行摘要，够扫一眼，但看不出「图插在哪一段后面」。而家长打开一条作业，多数时候是想**核对**孩子今天到底要做什么，不是马上改。所以单击先看完整渲染，要改再点抽屉里的「编辑」——中间多一步，但不会手滑进编辑页。

抽屉里图片点开是大图灯箱，`Esc` 或点遮罩关闭。卡片内的编辑/删除按钮做了冒泡隔离，点它们不会顺带打开抽屉。

### 图片灯箱

点任意缩略图进入全屏看图：

| 操作 | 行为 |
|---|---|
| 滚轮 | 以鼠标位置为锚点连续缩放，1×–8×，顶部实时显示百分比 |
| 放大后拖动 | 平移，边界限制在图片实际超出视口的那部分，拖不丢 |
| 双击 | 1× ⇄ 2.5× 切换 |
| `R` / `Shift+R` | 顺时针 / 逆时针转 90°，也可点工具栏的 ↻ ↺ |
| `←` `→` | 多图时切换 |
| `+` `-` `0` | 放大 / 缩小 / 复位（复位同时把旋转归零） |
| `Esc` | 关闭。只关灯箱，抽屉留在原地 |

**旋转为什么要单独处理约束**：`transform: rotate` 不改变布局尺寸，转了 90° 之后视觉宽高互换，但浏览器仍按未旋转的长宽套 `max-h-full / max-w-full`，长图会直接撑出视口。所以 `rotation % 180 !== 0` 时改用交换后的舞台尺寸作上限（`maxWidth = 舞台高`、`maxHeight = 舞台宽`），舞台尺寸由 `ResizeObserver` 实时测量。转 180° 宽高不变，不需要交换。

旋转时平移量会归零：转了 90° 之后「刚才往右拖了 100px」在新方向上是另一个意思，保留只会让人找不到图。缩放倍率则保留。

**灯箱用 portal 挂到 `body`**，不是随手写的。抽屉带了 `animate-slide-in-right`，它的 transform 会让内部 `position: fixed` 的包含块变成抽屉本身；灯箱原本渲染在 `RichBodyView` 里、正好落在抽屉内部，于是「全屏」实际只有抽屉那 540px 宽，图片右侧整块甩到浏览器外面。portal 之后 fixed 永远相对视口，与父级的 transform / overflow / 层叠上下文无关。

滚轮缩放必须用原生 `addEventListener(..., { passive: false })`：React 的 `onWheel` 是 passive 监听，`preventDefault()` 不生效，缩小的同时页面还会跟着滚。

**Esc 的归属**：抽屉和灯箱都在 `document` 上挂了 `keydown`，直接写会按一次 `Esc` 两个一起关。`src/lib/modal.ts` 用一个后进先出的 token 栈解决：只有栈顶那层响应 `Esc`，`body` 滚动锁也按引用计数恢复，不会出现「灯箱关了、抽屉还在但页面能滚」。

### 图片的三条入口

1. **Ctrl+V 粘贴** —— 见下节，两种剪贴板形态都支持。
2. **拖拽** —— 把文件拖到表单任意位置，松开即加。
3. **点选** —— 「添加图片」，支持多选。

新图会优先填进正文里的 `[图片]` 占位（微信复制图文消息时图片没进剪贴板，只留这个占位），没有占位就插在光标处，标记单独占一行。上传立即开始，**没传完不让保存**，失败的缩略图上直接给「重试」。

### 粘贴「文字 + 图片」为什么需要单独处理

Windows 上从浏览器、Word、微信里选中一段图文复制，剪贴板其实有**两种截然不同的形态**，代码必须都认：

| 剪贴板形态 | `clipboardData.files` | 图片在哪 | 处理方式 |
|---|---|---|---|
| 截图、右键复制图片、资源管理器复制文件 | 有图片文件 | 字节就在剪贴板里 | 直接上传 |
| 网页 / Word / 微信里选中「文字+图片」复制 | **空** | 只在 `text/html` 的 `<img src>` 里 | 解析 HTML、下载地址、再上传 |

只读 `files` 就会漏掉第二种 —— 表现就是「文字粘进来了，图没了」。`src/lib/clipboard.ts` 专门解决这个：

1. 遍历 `text/html`，块级元素断行，`<img>` 换成 `[图片]` 占位并记下地址（`src` / `data-src` / `srcset` 都认，懒加载图也能取到）；
2. 按地址把图取回成 `File`，`data:` URI 直接解 base64，`http(s)` 走 `fetch`；
3. 取回后交给 `attachFiles()`，占位自动变成 `[图1] [图2]`；
4. **取不到的图不会留占位**（`dropTrailingHoles` 清掉），否则孩子手机会看到「[图片]」三个字，并弹提示让家长单独截图补。

单张上限 20 MB、一次最多 10 张，超了跳过并提示，不阻塞其余内容。

`pickSrc` 挑地址时**先挑能读的**：`<img src>` 是 `file:///` 占位、真地址在 `data-src` 里的情况很常见，无条件相信 `src` 会把本能取到的图误判成「读不到」。

### 两条硬边界（都实测过，不用再试）

**1. `file:///` 本地路径 —— 浏览器彻底封死，连显示都不行**

微信 PC、QQ 把「文字 + 图片」一起复制进剪贴板时，`<img src>` 写的是本地缓存路径
（`file:///C:/Users/.../AppData/Roaming/Tencent/WeChat/cache/*.png`），且 `files` 是**空的**。实测在 http(s) 页面里：

| 尝试 | 结果 |
|---|---|
| `fetch('file:///C:/...png')` | 抛 `Failed to fetch`，请求根本发不出去 |
| `<img src="file:///C:/...png">` | `naturalWidth === 0`，**连渲染都被拦** |
| `<img src="https://云存储直链">` | 正常，`naturalWidth = 1600` |

这是浏览器的安全模型（网页不能探测、读取任意本地路径），不是权限申请能解决的，改任何编辑器都一样。唯一的出口是回源程序**单张右键「复制图片」**（位图会进剪贴板），或直接截图，或把文件拖进页面（拖拽时浏览器主动授予 File）。

**2. 第三方图床不允许跨域**

公众号的 `mmbiz.qpic.cn` 这类，`fetch` 被 CORS 拦。本站和云存储直链是 public 且回显
`Access-Control-Allow-Origin`，所以自家图能读回字节。

### 为什么「单独复制一张图」就能贴

因为那不是同一份剪贴板内容。实测 `clipboardData` 看到的东西完全不同：

| 复制方式 | `types` | `files` |
|---|---|---|
| 选中「文字 + 图片」一起复制 | `["text/plain","text/html"]` | **空** —— 图只是一个地址 |
| 右键单张图片 → 复制 | `["Files"]` | 1 个 `image/png`，**字节就在里面** |

前者要按地址去下载（遇 `file://` 就断了），后者根本不需要访问任何文件。所以「单独复制能贴、一起复制不能贴」不是随机现象，是两条路径。

**为此不要引入富文本编辑器。** TipTap / Quill / Slate 拿到的是同一份剪贴板数据，`files` 空的时候它们一样没有图片字节，只是把外链 `<img>` 塞进文档里显示；要把外链转成云 key 仍需这套下载 + 上传逻辑。而换成 HTML 存储会打破「纯文本 + `[图N]` 标记」的数据契约，孩子端 Flutter 得跟着重写。问题在剪贴板层，不在编辑器层。

### Emoji 与输入法

正文是纯文本 `<textarea>`，所有 Unicode 都收，不需要额外的 emoji 输入入口（Windows 上 `Win + .` 就能调面板）。

真正会坏的是**复合 emoji**——它们由多个码点拼出来，中间靠 `U+200D`（ZWJ，零宽连接符）粘着：

| 字符 | 组成 | 误删 ZWJ 后 |
|---|---|---|
| 👨‍👩‍👧 | 3 个 emoji + 2 个 U+200D | 👨👩👧 散成三个独立的人 |
| 👩‍💻 | 2 个 emoji + 1 个 U+200D | 👩💻 人和电脑分开 |
| ❤️ | ❤ + U+FE0F（变体选择符） | ❤ 退化成黑白字符 |

所以 `clipboard.ts` 在做「隐形字符清洗」时只清 `U+200B`（零宽空格）、`U+200C`（零宽不连字）、`U+FEFF`（BOM），**`U+200D` 必须留着**。这一条曾经写错，导致粘贴微信里带家庭 emoji 的内容时被拆散。

字数统计刻意用 UTF-16 长度而不是字素簇数（一个 👨‍👩‍👧 算 8 个字），否则会和 Flutter 端 `rich_body.dart` 的 `plainLength` 算出不同的数。要改得两端一起改。

### 实时预览

右栏用与手机端同一套规则渲染（`src/lib/richBody.ts` 是 `lib/core/rich_body.dart` 的逐条移植）。家长在电脑上看到的就是孩子手机上的样子，包括图片插在哪一段后面。

## 实测记录

下面这一批是 CloudBase 时代在真实家庭（示例家庭 / `A1B2C3`）和线上地址上跑的。**结论仍然有效**——新服务端按原样保留了 PostgREST 语义和字段分工，所以「`is_done` 不会被家长保存冲掉」这类行为没变；只有图片 key 多了 `f/<familyId>/` 前缀。迁移后的端到端验证是在 `server/test/` 里做的（契约 18 条 + 隔离 10 条 + 存储 10 条），加上一轮真机走查。

老记录（CloudBase）：

- 网页创建作业 → `homework` 出现记录，`subject/content` 正确、`images` 为 key 数组
- 把孩子 `is_done` 置 `true`（模拟打勾）→ 网页编辑正文并保存 → **`is_done` 仍为 `true`，`done_at` 未被清空，正文已更新** ✅
- 删除 → `is_deleted = true`，孩子端不再展示 ✅
- 粘贴截图 → 自动插入 `[图1]`、上传后预览显示直链 ✅
- 浏览器控制台无报错，无失败请求

线上复测也一致：创建 → `images: ["homework/<id>/mvympwj2lzcx6o.png"]`（现在会变成 `f/<familyId>/homework/<id>/mvympwj2lzcx6o.png`），改写后 `is_done` 仍为 `true`、`done_at` 未清空，软删除生效。

### 图文粘贴（线上实测）

用真实系统剪贴板写入 `text/plain` + `text/html`（确认 `navigator.clipboard.read()` 返回的类型里**没有图片文件**），再按真实 `Ctrl+V`：

| 场景 | 结果 |
|---|---|
| 网页复制的图文（`<img src>` 是云存储直链） | ✅ 文字按原顺序进来，图下载后上传，`[图1]` 落在原位置 |
| Word 复制的图文（`<img src>` 是 `data:` URI） | ✅ base64 直接解出文件，占位正确填充 |
| 图片地址取不到（跨域 / 404） | ✅ 文字保留、占位被清干净、弹提示不缺字 |
| 保存后云端 | ✅ `images` 有 1 个 key，`content` 含 `[图1]` |

## 部署

**前端不单独部署**。`npm run build` 出来的 `dist/` 在镜像构建阶段就被拷进 API 容器，由 Fastify 一起对外提供。所以只要把服务端跑起来，Web 端就在了。

```bash
# 在 NAS 上，仓库根目录
cp .env.example .env          # 填 APP_HOST / JWT_SECRET / ADMIN_TOKEN / POSTGRES_PASSWORD
docker compose up -d --build
```

镜像里的三个阶段（`server/Dockerfile`）：

| 阶段 | 干什么 |
|---|---|
| `web` | 在 `parent-web/` 里 `npm ci && npm run build`，产出 `dist/` |
| `server-build` | `tsc` 编译 `server/src` → `dist` |
| `runtime` | 只装生产依赖，拷进前两个阶段的工件 + `migrations/`，以 `node` 用户跑 `node dist/main.js` |

这样 NAS 上不需要装 Node、不需要装 npm，也不用在 NAS 上跑前端构建——一个镜像搞定，也不会出现「前端是新版、API 是旧版」。

### 静态文件的缓存策略

`@fastify/static` 注册时**必须写 `cacheControl: false`**，否则插件会在 `setHeaders` 之后把 `Cache-Control` 覆盖成 `public, max-age=0`，前面写的规则全白写。实际生效的是：

| 路径 | Cache-Control | 为什么 |
|---|---|---|
| `index.html` | `no-cache` | 入口必须每次回源，否则发版后用户还指着旧的 hash 文件名，白屏 |
| `/assets/*` | `public, max-age=31536000, immutable` | 文件名带内容 hash，内容变了文件名就变了 |
| 其余静态文件 | `no-cache` | 兜底 |

图片和 APK 不走静态插件，走 `/v1/storages/object/*`，那边是 `immutable` 长缓存——key 里带 UUID 或版本号，同一个 key 的内容永不改变。

### 通用要求

- 前端没有路由（视图状态驱动，不依赖 URL），**不需要 SPA 回退规则**
- 只有 `index.html` 一个入口，注意别让 CDN 缓存 HTML（资源文件名带 hash，可以长缓存）
- 容器内端口固定 `8787`，不要在 compose 里 `ports:` 发布出去——外部一律经 Cloudflare Tunnel 进来
- 想临时用局域网直连调试，把 compose 里那段注释掉的 `ports` 打开即可（`8787:8787`），用完记得注释回去

### 历史：CloudBase 那套（已停用）

搬家之前用 CloudBase 应用部署（`manageApps`，`serviceName = homework`），地址是 `https://<your-env-id>.webapps.tcloudbase.com`，还要过一道默认域名的提醒中间页（`cloudbase_confirm_domain_access` cookie）。环境 `<your-env-id>` 现在处于 `res_stopped`，连登录接口都返回 429。留这段只为解释老截图和旧包里那些奇怪现象，新代码跟它无关。

## 已知边界

- **没有本地缓存**：离线打不开也存不了。手机上布置过的离线内容仍会在联网后自动补传，那是 App 的能力。
- **家庭码即凭证**：无二次验证，见上文「登录」。token 只锁住「哪个家庭」，锁不住「谁能拿到码」。
- **6 位家庭码，但字母表更干净**：服务端用 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（去掉易混的 I/O/0/1）随机生成，32^6 ≈ 10.7 亿种。真正拦暴力枚举的是登录接口的限流——同一 IP 每分钟 10 次，试满要三千年。
- **删除图片不删对象**：只从 `images` 数组里移出。因为一张图可能已经被别处引用，误删代价比留个孤儿文件大。长期靠 `ops/backup.sh` 之外的手工清理。
- **多人同时改同一条正文以最后保存为准**：没有冲突检测，两年没撞过，真撞了就是后写的赢。
- **第三方站点的图粘不进来**：跨域读取被浏览器拦住，微信/QQ 的图片 CDN 一般不开放 CORS。本站的图和 `data:` URI 正常。见上文「粘贴『文字 + 图片』为什么需要单独处理」。
- **刷新会回到列表页**：编辑中的内容靠离开确认保护，不跨刷新保留。
- **家里断电就打不开**：NAS 停、隧道断，网页和 App 一起不可用。这是自托管的固有代价。
