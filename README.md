# 家庭作业 App

家长布置作业，孩子在自己手机上看今天要做什么、写完打勾。

## 两个端

| 端 | 目录 | 谁用 | 技术栈 |
|---|---|---|---|
| Android App | `lib/` | 孩子看作业打勾；家长也能用 | Flutter 3.27.4 / Dart 3.6.2 |
| 家长 Web 端 | `parent-web/` | 家长在电脑上布置管理作业 | React 19 + Vite 8 + TS + Tailwind v4 |

两端**共用同一份后端数据**（`families` / `children` / `homework` / `app_releases`）。电脑上布置完，孩子手机刷新即可看到。Web 端说明见 [parent-web/README.md](parent-web/README.md)，其中「和 App 的数据契约」一节改了字段就必须看。

**部署方式：整套自托管**。一台飞牛 fnOS NAS 上用 Docker Compose 起三个容器（PostgreSQL / Fastify + 静态站点 / Cloudflare Tunnel），通过自己的域名走隧道对外，不依赖任何公有云。原腾讯云开发 CloudBase 环境已停用。

- Android 平台：Android 8.0+（minSdk 26），手机竖屏 + 平板横屏自适应
- App 技术栈：Flutter 3.27.4 / Dart 3.6.2，本地 SQLite + 自建 PostgreSQL（双设备同步）
- 对应需求文档：[作业App-需求规格说明书-V1.md](作业App-需求规格说明书-V1.md)

## 已实现（V1 范围）

| 模块 | 内容 |
|---|---|
| 家庭 | 创建家庭、生成 6 位家庭码、家庭码校验进入家长端 |
| 孩子 | 添加 / 编辑 / 删除，同一家庭内姓名唯一，头像配色 |
| 布置作业 | 学科（8 个预设 + 自定义）、日期可选、文本 1000 字、图片不限张数（拍照 / 相册多选 / **剪贴板一键粘贴**） |
| 家长查看 | 今日布置列表、按日期切换、历史按日期分组、学科筛选、完成情况 |
| 孩子查看 | 中文姓名登录、今日作业（右上角「刷新」/ 下拉）、打勾、日历打点查历史、大图预览 |
| 响应式 | 手机竖屏单列 / 平板横屏导航栏 + 限宽列表，图片列数随宽度自适应 |
| 本地存储 | SQLite，离线可用，图片存 App 私有目录 |
| 云同步 | 全自动：操作即上传、断网先存本机、联网/回前台自动补；家庭码接入已有家庭 |
| 外观 | 跟随系统（默认）/ 浅色 / 深色，三选一，即时生效，选择持久化 |
| 版本更新 | 启动静默检查 + 设置页手动检查，有新版本弹窗引导下载，支持强制更新；下载地址由云端表驱动，可托管在任意 HTTPS 直链，`tool/release.sh` 一条命令发版 |

## 关键实现细节

**并发安全**：家长端写正文（subject / content / images / date），孩子端写完成状态（isDone / doneAt），两端字段不重叠，都用字段级增量更新，绝不用整条记录覆盖。所以孩子打的勾不会被家长的下一次编辑冲掉。

**多图**：不设数量上限。选图后先复制进 App 私有目录（系统相册给的是缓存路径，会被清理），编辑页显示「共 N 张 · 约 X MB」。

**响应式判定**：只看可用宽度不看 orientation。平板分屏、折叠屏展开、小窗下 orientation 都不可靠。

| 宽度 | 布局 |
|---|---|
| < 600dp | 单列 + 底部导航 |
| 600–839dp | 单列，内容 560dp 居中 |
| ≥ 840dp | 左侧 NavigationRail + 限宽 760（家长端 820）居中的列表，点条目整页看详情 |

**状态保持**：表单状态放在 State 里，横竖屏切换、分屏拖动都不丢草稿。

## 剪贴板粘贴（从微信直接拷过来）

老师的作业常在微信群：一段文字 + 几张图。家长在微信里「复制」整条消息，回到 App 粘到「作业内容」框里即可，图片不用再进相册一张张选。

Flutter 自带的 `Clipboard` 只认纯文本，安卓上复制多张图片时剪贴板里装的是若干 `content://` URI，Dart 侧根本看不到。所以加了一条原生通道 `com.shuge.homework_app/clipboard`（`android/.../MainActivity.kt`）：

| 方法 | 作用 |
|---|---|
| `peek` | 只探查：有没有图、几张、内容指纹、距今多久。不解码不落盘，可以高频调用 |
| `import` | 真正读取：按长边 1600、质量 85 压成 JPEG 落到 `cache/clip_images/`，返回本地路径 |

原生侧还会从 `htmlText` 里扒 `<img src>`，兼容那些只复制富文本（URI 藏在 HTML 里）的 App。

Dart 侧 `lib/data/clipboard_paste.dart` 封装通道 + 1 秒缓存 + 文件指纹（长度 + 头 64KB FNV-1a）用于去重。

三个入口，家长怎么顺手怎么来：

1. **自动**：在内容框里粘贴（一次补进 ≥4 个字符即判定为粘贴），若剪贴板里同时有图、且粘进来的文字和剪贴板文字对得上（忽略空白），图片自动跟进来，并在正文里写好位置标记。不再看「复制了多久」——家长从微信复制完，切到 App、过家庭码、选学科、点新建，很容易超过两分钟
2. **「添加」菜单**：内容框下方「添加」按钮弹出的选项里有「粘贴剪贴板里的图片（N 张）」，点一下收图（V1.5 起不再常驻提示条，界面上不提示也能粘）
3. **长按菜单**：选中文字后菜单里多一项「粘贴图片（N 张）」

同一个剪贴板只导入一次（按指纹判断）；同一张图重复粘不会重复添加（按文件指纹去重）。来源 App 的 URI 授权过期时提示「读不出来，试试从相册选择」。

## 多图折叠（微信式）

一张图正常显示；多图默认叠成一小摞，右下角一个「展开 3」的深色小徽标。点图直接全屏逐张看，点徽标才在原地铺成网格，网格下方有「收起」。组件在 `lib/widgets/image_stack.dart`，作业卡片、家长端预览、历史列表、孩子端日历共用。

家长端孩子端列表里的紧凑行只显示「学科 + 一行摘要 + 图片张数」，图片本身在详情页里看 —— 纯图作业（只有图没有文字）也能靠这个张数知道自己没错过。

## 看图手势（照微信那套）

点任意缩略图进全屏看图（`lib/widgets/image_grid.dart` 的 `_PhotoViewer`）：

**打开是整图居中，要放大自己双击。** 曾试过「竖长图打开即按宽度铺满」，实机上不行：铺满后一屏只剩试卷的一小块，上下要划三四屏，比原来看不清更难受，已回退（`1.0.5` 试过、`1.0.6` 撤掉）。

| 手势 | 行为 |
|---|---|
| 单击图片 | 直接退出，不用去右上角找 `×`（那个按钮已经删了） |
| 双击 | 在「整图」↔「左右填满屏幕」之间切换。填满后图片高度超出屏幕，单指上下拖看不同高度段——横屏看竖拍的作业照片正是这个用法 |
| 双指 | 自由缩放（1×–6×） |
| 竖向单指拖动 | 放大后上下看图片不同高度段；拖到图的顶/底就停住 |
| 横向单指拖动 | 没放大 → 切上一张 / 下一张；放大后横向**还有**平移余地（放大的横图）→ 平移；放大后横向**已无**余地（双击填满的竖图）→ 切上一张 / 下一张 |

双击的变换在 `_toggleZoom` 里算：按 `k = 视口宽 / 图片宽` 放大，再把图片左上角对齐视口左上角。宽度本来就填满的横图（`k≈1`）改成放大 2 倍，否则双击看起来毫无反应。

### 为什么放大后拖不出黑边

`InteractiveViewer` 的边界是按 **child 的布局尺寸** 算的，而这里的 child 是整个视口、图片居中摆在中间，左右本来就有留白。它拦不住「在留白里横向拖」——于是横屏双击填满后，一拖就能把图片挪开、露出两侧黑底。

改法是把 `boundaryMargin` 设成无限（关掉它自己的边界），然后按图片的真实可视矩形自己钳制矩阵（`_clampMatrix` / `_clampAxis`）：

- 缩放后的图片比视口窄 → 那一轴没有余量，钉死在居中
- 比视口宽 → 允许平移，但图片边缘不能进到视口内部

横屏竖图双击填满时，图片宽度刚好等于视口宽，横向的合法平移区间收缩成一个点，于是横向彻底锁死——只剩上下能拖。

### 为什么放大后横向还能翻页

放大后单指手势被 `InteractiveViewer` 接管，`PageView` 根本收不到事件。光钳制的话结果是「拖不动、也不翻页」。

所以在 `onInteractionUpdate` 里把横向位移自己攒起来（`_maybeSwipe`）：横向已无平移余地时，累计超过 64 逻辑像素就主动 `animateToPage`。一次手势只翻一张（`_swipeConsumed`），防止一划划过好几张。横向还有余地的场合（放大的横图）不拦，照常平移。

## 孩子端「刷新」按钮

孩子端「今日」页头部右端常驻一个「刷新」胶囊（下拉手势太隐蔽，孩子不知道，家长远程加完作业看着没变就会以为同步坏了）：

| 状态 | 表现 |
|---|---|
| 空闲 | 主色胶囊 + `↻ 刷新` |
| 点击后 | 转圈 + 「刷新中」，颜色转灰、`onTap` 置空 |
| 结束 | 底部弹一句 `已同步` / `同步失败：…`，取自 `SyncService.message` |

下拉刷新仍在，两者共用 `_refresh()`；`_refreshing` 挡住「下拉 + 连点」同时触发的重复请求。

按钮放在**页面头部**而不是 AppBar 的 `actions`：`ResponsiveScaffold` 在 ≥840dp（平板、手机横屏）不渲染 AppBar，放 actions 平板就看不到。为此 expanded 下 `SafeArea` 的 `top` 改为 true，让出状态栏，否则按钮会压在信号/电量图标上。

## 列表 → 全屏详情

点列表里任意一条，整页打开详情（`lib/features/shared/homework_detail_page.dart`）：正文按图文混排铺开，图片点开全屏看，大屏上也不再挤在右侧一栏里。

卡片本身只有三行摘要（`maxLines: 3`），长作业**只能**靠这一层看全文，所以每个列表入口都必须接上 `onTap`。曾经漏过孩子端日历页：卡片点了没反应，家长写的大段作业孩子永远看不全。

- 孩子端「今日」「日历」：两处都能点开。详情页底部是「我做好了」/「已完成 · 点此撤销」，勾完返回列表自动对齐
- 孩子端「日历」**不开启计时**：回看前几天的作业不该产生学习时长，否则家长统计里会凭空多出几分钟。计时只在「今日」页做
- 家长端：详情页右上角「编辑」，改完保存后**详情页自己换成新内容**，不用退出来再点一次

## 图文混排（图片跟着文字走）

一份作业常常是「一段话 + 几张图 + 又一段话」，图片全堆在末尾就读不出因果。所以正文里带**行内位置标记** `[图3]`：

```
第一段：练习册 P32-34 全部做完。

[图1]
[图2]

第二段：错题本订正到第 12 页。
```

渲染时把 `[图N]` 换成第 N 张图本身，位置就对了。实现在 `lib/core/rich_body.dart`（解析）+ `lib/widgets/rich_body_view.dart`（渲染），作业卡片、家长端详情、孩子端详情、编辑页预览共用。

**为什么用可见标记，而不是「图片序号 + 字符偏移」**：标记就是几个字符，选中、删除、剪切、粘贴、撤销全都天然生效。想把图从末尾挪到第二段后面，把那几个字剪过去就行，既不用做拖拽交互，也不会因为改了正文文字让偏移量失效。

编辑页的配合：

- 加图（相册 / 拍照 / 粘贴）→ 标记插在**光标所在处**，不是一律堆末尾；图片单独占行
- 图片缩略图左上角有序号，和正文里的 `[图N]` 对得上；右上角 `×` 删图会连标记一起删，后面的序号自动前移
- 段落式提示 + 右侧实时预览，看到的就是孩子端的样子
- 字数统计只算正文，标记不算

**位置从哪来**：

| 复制来源 | 能不能还原位置 |
|---|---|
| 网页 / 备忘录 / WPS（剪贴板带 HTML） | 能。解析 HTML 里 `<img>` 在正文中的字符位置，再映射到粘进来的文字上 |
| 微信，只复制了**文字**（HTML 为空、无 URI） | 图**根本没进剪贴板**，文字里只剩一个字面 `[图片]`。App 认这个占位，之后从相册补的图自动落回原位 |
| 微信 / 图库，复制的是**图片本身** | 能。剪贴板里是 `content://` URI，`import` 落地后按光标位置插标记 |

**容错**：保存前跑 `normalizeBody()`——重复的标记只留一个、没被标记引用的图在末尾补上标记。所以就算家长把 `[图1]` 手抖删成 `[图`，图也不会丢（变成排在末尾）。序号越界的标记（比如正文里本来就有的 `[图9]`）当普通文字留着，不吞用户的字。

> 踩坑：早期的「宽松标记」正则不要求数字，结果正文里「口头作业请见图片」写成的 `[图片]` 被当成标记吃掉，界面上只剩 `片]`。现在正则必须是 `[图` + 数字。

### 微信复制图文消息：图片不会跟着来

实测（微信 Android 版，机型 24122RKC7C / MIUI）：在微信里**长按一条「文字+图片」的消息 → 复制**，剪贴板里只有一个纯文本 item——261 个字，没有 HTML，没有任何 `content://` URI，图片原来的位置写成 `[图片]`。任何 App 都拿不到那张图，这是复制源的限制，不是读取失败。

所以 App 做了三件事把这半截活儿接住：

1. **认占位**：正文里的 `[图片]` 在编辑页涂成橙色，一眼看出「这儿缺一张图」
2. **自动补位**（`fillImageHoles` in `lib/core/rich_body.dart`）：从相册选图时，新图按顺序填进这些占位、把 `[图片]` 换成 `[图N]`，位置天然正确，不用再手动搬标记。占位比图多就只填前几张，占位不够多出来的图仍按光标位置插
3. **说明白**：粘贴后发现「文字里有 `[图片]` 但剪贴板没有任何图」，弹一句「图片没随文字一起复制过来……用『添加』从相册补上，会自动补到 [图片] 的位置」。同一份内容只提示一次

真要一键带图，让家长在微信里**长按那张图单独复制**，回 App 点「粘贴剪贴板里的图片」——这条路剪贴板里是真正的图片 URI，能直接导进来。

## 后端：自托管在 NAS 上

后端是 `server/` 里的 Node 22 + Fastify 5 + PostgreSQL 16 服务，跑在家里的飞牛 fnOS NAS 上，通过 Cloudflare Tunnel 用自己的域名对外。**同一个进程既发 API 又发静态站点**（`parent-web` 打包出来的 `dist/`），所以浏览器那边没有 CORS、没有跨站粘贴限制、也不存在前后端版本对不上。

原来用的是腾讯云开发 CloudBase 的 PostgreSQL 运行时，那套环境被平台停掉（`res_stopped`，连登录接口都直接返回 429）之后搬到了这里。搬迁时顺手改了一件事：**不再有「匿名登录 + 客户端自己查表」**。

| 能力 | 实现 |
|---|---|
| 登录 | `POST /auth/v1/signin/family` 交家庭码，服务端校验后签发绑定 `family_id` 的 JWT；孩子端走 `/auth/v1/signin/child`，交「家庭码 + 姓名」 |
| 数据 | PostgREST 风格 `/v1/rdb/rest/<表>`，运算符/排序/`select`/`Prefer` 语义照抄原来那套，客户端调用代码几乎没动 |
| 隔离 | **服务端强制注入** `family_id`：读的时候丢掉客户端传的同名列，写的时候用 token 里的值覆盖掉。路由层想漏都漏不掉 |
| 图片 | `POST /v1/storages/object/homework/f/<familyId>/...` 要带 token、且 key 必须落在自己家庭前缀下；读保持公开（`<img>` 带不了 Authorization 头），靠 key 里的 UUID 不可猜来防扫 |
| APK | `PUT /v1/admin/apk/<key>` 要 `X-Admin-Token`；下载同样是公开直链，支持 Range 断点续传 |
| 家长端 | 本地先写 → 标 `pending_sync` → 后台补传 → 成功后清标记 |
| 孩子端 | 打开即拉 + 头部「刷新」按钮 / 下拉刷新；拉到就落本地，断网看缓存 |

**为什么必须改成家庭级 token**：老的匿名 token 对三张表的 RLS 是 `USING (true)`，也就是**任何人拿到匿名 token 就能把全部家庭的作业读一遍**。那套逻辑之所以还能凑合用，是因为服务只在 CloudBase 上、默认域名没人知道。一旦挂到公网域名，家庭码就成了唯一的口令，而 `families.code` 本身可读——等于把口令明文摆在库门口。现在改成：家庭码只在登录那一次用，之后靠 token 说话；`families` 表孩子端完全读不到，家长端也只能读到自己的那一行。

**字段级并发**：家长端只 update `subject/content/images/date`，孩子端只 update `is_done/done_at`，两端永不整行覆盖，所以孩子打的勾不会被家长下次编辑冲掉。这条不靠客户端自觉——服务端有一张列白名单，孩子 token 去写 `content` 直接 403。

**同步串行队列**：`SyncService._chain` 把每次同步排到上一次之后执行。早前用「正在同步就直接 return」，会导致同步进行中打勾的那次请求被静默丢弃、勾传不上去。

**换机 / 重装**：家长端首次进入若本机无家庭，会要求输入 6 位家庭码接入已有家庭（家庭码在服务端 `families.code`），否则重装后就永久进不去了。

**从 CloudBase 版升级上来的设备会清空本地库**：`LocalDb.migrateToNewBackend()` 查 `meta.schema_epoch`，不是 `2` 就把本地作业/孩子/会话全清掉、并删掉旧的 `cb_token` 等偏好，然后写入 epoch 2。原因是老库里的数据都是匿名 token 写进去的，没有可信的 `family_id` 归属，搬不过来。服务端本来就要求「不要历史数据、从空白开始」，两边一致。

### 自动同步的三条触发线

同步不是一个需要用户点按钮的动作。除了每次业务操作（布置/编辑/删作业、增删改孩子、打勾、进出详情页）之后立即触发，还有三条兜底：

| 触发线 | 实现 | 解决什么 |
|---|---|---|
| 网络从无到有 | `connectivity_plus` 的 `onConnectivityChanged` | 断网时攒下的写入，网一回来立刻补传 |
| App 回到前台 | `AppLifecycleState.resumed` | 手机端最可靠的一次机会；切回来就该是最新的 |
| 失败退避重试 | 30s → 60s → 120s → 300s → 300s，最多 5 次 | 兜住「网通了但用户没动手机」的窗口 |

第 3 条不是冗余：Android 的 connectivity 只报告网卡状态，连上一个没有出口的 WiFi 也报「已连接」。真正的可用性要看请求是否成功，所以失败后必须自己再试几次。

**单条失败也算失败**：`_pushHomework` 里一条传不上去不会抛异常（不能拖累其它条），所以 `_doSync` 结束时看的是**残留待传数**。还有没传上去的就置 `failed`，否则自动重试永远不会被触发。

**离线提示**：`AppState.isOffline` 取两个来源的或——系统说没网，或者同步请求本身因网络原因失败。后者更可信（`CloudApi.lastErrorWasNetwork`）。提示条 `SyncNoticeBar` 挂在 `MaterialApp.builder` 上，家长端、孩子端、push 出来的编辑页全都有；正常态高度归零，不占版面。

## 外观与主题

三档：**跟随系统（默认）/ 浅色 / 深色**。选择存在本地 `meta.theme_mode`，在 `AppState.init()` 里读出来并**在第一帧之前**应用到调色板，所以冷启动不会先闪一下浅色再变深。

**为什么不用 `Theme.of(context)` 取色**：改造前全项目有 266 处直接引用 `AppColors.xxx`。改成 context 取色要动每一个调用点，收益只是「更符合 Flutter 惯例」，代价是几百处改动带来的回归风险。这里保留原有调用形式，把「当前用哪套」做成类级别状态，由 `AppColors.use(brightness)` 统一切换。

这条路线有一个必须遵守的约束：**含动态色的 widget 不能是 const**。const widget 实例相等，Element 会跳过 rebuild，颜色就停在旧值上。项目里 121 处受影响的 const 构造已经全部去掉；`tool/fix_const.py` 是当时用的解析脚本，按括号平衡找 const 的作用范围，以后往 const 里塞 `AppColors` 会再遇到同样的问题，可以直接复用。

深色调色板不是浅色反相，重新定了一套：

| 原则 | 做法 |
|---|---|
| 层级靠亮度差不靠阴影 | `pageBg #101218` < `card #181B23` < `surface2` < `surface3`，深色下阴影几乎看不见 |
| 主色提亮 | `#5B6BF5` → `#7C8AFF`，原色压在深底上会发灰 |
| 主色块上的前景色反转 | 浅色配白字，深色配深字（`AppColors.onAccent`），否则亮紫底 + 白字对比度不够 |
| 强调色降饱和 | `successSoft` / `warningSoft` / `dangerSoft` 在深色下是深色低饱和底，避免发光刺眼 |

状态栏和底部导航栏跟着切：`applySystemOverlay()` 把图标亮度重新下发给系统（状态栏是系统窗口，不跟着 Flutter 重建）。

学科色和孩子头像色**不随明暗切换**：八个色相在两种底上都够鲜明，做两套只会让家长和孩子看到不同的学科色，失去识别意义。

## 版本更新

`app_releases` 表是唯一事实来源。客户端**只读**：`GET /v1/app/releases/latest?platform=android` 是公开接口，但走服务端 REST 查表时只放出 `is_active = true` 的行；写入必须带 `X-Admin-Token`。放开写等于让任何人把全量用户的更新地址改到自己服务器上。

| 环节 | 实现 |
|---|---|
| 取当前版本 | `package_info_plus` 读 `version` / `buildNumber`，与 `pubspec.yaml` 的 `1.1.0+8` 对应 |
| 比对 | 比 `version_code`（整数）而不是版本名字符串——字符串比较会在 `1.10.0` 和 `1.9.0` 上判错 |
| 触发 | 冷启动 3 秒后静默查一次（`UpdateGate`）；设置页底部和孩子端「我的」可手动查 |
| 提示 | 弹窗展示版本号和更新说明；`force_update = true` 时没有「稍后」，点遮罩和返回键都关不掉 |
| 下载 | `url_launcher` 用外部应用打开链接，交给系统浏览器/下载器 |

**为什么不在 App 内直接下载 APK 并调安装**：那要额外申请 `REQUEST_INSTALL_PACKAGES`、配 FileProvider、处理 Android 8+ 的「未知来源安装」授权，任何一环出问题用户只看到「安装失败」。交给系统，行为可预期，也不用逐机型适配。代价是下载进度不可见。

### 发版流程

**安装包托管在哪里都行**，客户端不关心：它从 `app_releases.download_url` 读地址，拿到什么就打开什么。所以换服务器、换域名、临时挂个镜像，都只是改表里一行，**不需要发新版**——这一点很重要，否则「更新功能本身要靠更新才能改」就成了死结。

整套服务自己托管之后，一条命令跑完「构建 → 上传 → 校验 → 写表 → 回读」：

```bash
tool/release.sh "新增深色模式；修复离线作业偶发不自动上传"
tool/release.sh "紧急修一个闪退" --force        # 强制更新，客户端不给「稍后」
tool/release.sh "只改说明"      --no-build      # 复用已有 APK，只上传+写表
tool/release.sh "包已传到别处"   --url "https://.../homework-{version}.apk"   # 跳过上传
```

前置就两样：根目录有 `.env`（从 `.env.example` 复制，填 `APP_HOST` 和 `ADMIN_TOKEN`），且服务端在跑。脚本按这个顺序走：

1. 读 `.env`，`API_BASE` 取 `https://$APP_HOST`
2. 读 `pubspec.yaml` 算 `version_name` / `version_code`
3. `flutter build apk --release --dart-define=API_BASE=$API_BASE`
4. `PUT /v1/admin/apk/releases/homework-<version>.apk`（流式落盘，50MB 不会缓冲进内存）
5. **HEAD 回读**，拿 `Content-Length` 和本地包逐字节比
6. `POST /v1/admin/releases` 写表，最后用客户端那个公开接口再回读一次

第 5 步不能省：上传返回 200 不等于文件真能下载。MIME 被拒、`DATA_DIR` 挂载错、key 打错，都可能在下载那一刻才暴露成 403/404。这种错误发出去用户下完装不上，比发版失败难查得多。

APK 落在 `<DATA_DIR>/uploads/apk/releases/homework-<version>.apk`，下载地址是 `https://<域名>/v1/storages/object/apk/releases/homework-<version>.apk`。**key 里带版本号**，每个版本一个独立 URL——覆盖同一版本号时浏览器和 CDN 极可能还返回旧文件，「发了但没生效」是最难查的一种。

两个容易踩的点：

| 坑 | 后果 | 做法 |
|---|---|---|
| `API_BASE` 填成 `http://192.168.x.x:8787` | 表里存的是内网地址，手机在外网打不开 | 发版一律用对外域名；内网地址只在本机联调时用 |
| 系统代理（Clash/V2Ray 一类） | curl 把发往自家服务的请求也交给代理，代理对回环地址返回 502，看着像服务端挂了，实际服务端一个请求都没收到 | 脚本里所有 curl 都带 `--noproxy '*'` |

### GitHub Release 分发

NAS 之外还有一条路：打 `v*` tag 触发 `.github/workflows/release.yml`，CI 构建、校验、发 Release。适合「需要给版本留档、或手机在外网而 NAS 恰好不通」的场景。

```bash
# 改 pubspec.yaml 的 version（例如 1.2.2+14）→ 提交 → 打 tag
git tag v1.2.2 && git push origin v1.2.2
```

产物是 `homework-<版本>.apk` + `SHA256SUMS.txt`，文件名与 `app_releases.download_url` 的模板 `homework-{version}.apk` 一致，可以直接把 Release 里的资源地址填进表。

**签名已经换成正式密钥**（`android/upload-keystore.jks`，证书 `CN=StudyUp`），不再是 debug 密钥。副作用只有一次：**已安装的旧包都是 debug 签名，装新包会提示「签名不一致」，必须先卸载**。本项目 `allowBackup=false`，卸载会清空本地 SQLite，靠云端同步恢复——正式全量切换前先确认数据已同步。

一次性配置（四个 secrets）和排错见 `docs/github-release-runbook.md`。

#### 发完版先自检

`flutter build apk` **只产出文件，不更新版本表**。打完包忘了跑 `release.sh`，`build/` 里躺着新包、用户那边永远收不到更新——界面上没有任何迹象能暴露这件事，只能靠人记得。这个坑踩过一次（1.0.4 打包完成但没写表，手机端一直说「已是最新」）。

```bash
tool/version_status.sh
```

查询路径和 App 完全相同（同一个公开接口、同样的排序），所以它看到的就是客户端会看到的：

```
本地 pubspec : 1.1.0 (8)
本地 APK     : 有，50.9 MB
服务地址     : https://homework.example.com
云端最新     : 1.1.0 (8)
发布时间     : 2026-11-09T09:18:46.869Z
下载地址     : https://.../apk/releases/homework-1.1.0.apk
强制更新     : 否

结论：一致。装了这台设备上这个包的手机可以收到更新提示。
```

#### 手工发版（不走脚本）

`psql` 连上数据库直接插一行也行——`id` 用 `android-<version>`，`version_code` 必须和 `pubspec.yaml` 里 `+` 后面的数字一致：

```sql
INSERT INTO app_releases
  (id, platform, version_name, version_code, download_url, changelog, force_update, is_active)
VALUES
  ('android-1.1.0', 'android', '1.1.0', 8,
   'https://你的域名/v1/storages/object/apk/releases/homework-1.1.0.apk',
   E'· 新增深色模式\n· 修复离线作业偶发不自动上传', FALSE, TRUE)
ON CONFLICT (platform, version_code) DO UPDATE
  SET version_name = EXCLUDED.version_name,
      download_url = EXCLUDED.download_url,
      changelog = EXCLUDED.changelog,
      is_active = TRUE;
```

需要紧急撤回某次更新提示时不要删行，改 `is_active = FALSE`：删了再插会撞唯一索引，`is_active` 就是给这种场景准备的。

#### 已知限制

| 项 | 现状 |
|---|---|
| 旧版收不到这次更新 | 旧 APK 里写死的是已停用的 CloudBase 地址，只能人工装一次新包。之后的新版本走的是新通道，正常 |
| 隧道或 NAS 掉线 | 那一刻下载链接就是 404。APK 不含敏感信息，但别指望 7×24 |
| 上行带宽 | 家庭宽带 20–30 Mbps，一个用户约 15–20 秒；同时三个人下就明显变慢 |
| 明文 HTTP | Android 9+ 默认禁止，必须走 HTTPS。Cloudflare Tunnel 在边缘终结 TLS，回源那一段是内网明文，没有这个问题 |

## 后台运行、耗电与流量

### 实测：退到后台后到底发生什么

华为 BAH2-AL10 / Android 9 / 1920×1200，adb 采样：

| 时刻 | curProcState | oom adj | CPU | 唤醒锁 | 进程 |
|---|---|---|---|---|---|
| 前台 | 2（TOP） | 0 | 22% | 无 | 活 |
| 退后台 3 秒 | 14（CACHED） | 700 | — | 无 | 活 |
| 退后台 63 秒 | 14（CACHED） | 700 | **0%** | 无 | 活 |
| 退后台 183 秒 | 14（CACHED） | 700 | **0%** | 无 | 活 |

结论：**会被降级，但不会偷跑。** 按 Home 后系统立刻把进程从 TOP 降到 CACHED（oom adj 0 → 700），CPU 归零，不持唤醒锁。三点原因：

1. Flutter 引擎在 `onPause` 后停掉 vsync，不再渲染；
2. 代码里**没有任何常驻 Timer**，唯一的 `Timer` 是粘贴框 250ms 防抖，且只 `setState` 不联网；
3. 没有 Service / JobScheduler / AlarmManager / 前台服务，所以没有「保活」被系统反复拉起的开销。

### 关于「冻结」的版本差异

- **Android 9（本机）** 没有 cached app freezer，进程只是被降优先级，代码理论上还能跑，但没有任何东西在跑 → 实测 CPU 0%。
- **Android 11+ 且开启「缓存应用冻结」** 的机型，会把整个进程 SIGSTOP 冻住：Dart isolate 一起停，回到前台才解冻。对本 App 无影响，因为后台本来就不做事。
- 内存吃紧时 CACHED 进程会被直接杀掉，下次冷启动恢复。所以**不要依赖「App 在后台一直活着」**——本 App 的设计本来就是本地优先，杀掉不丢数据。

### 已知的代价（可接受，记录在案）

- 进程常驻内存 PSS 约 210 MB（Flutter 引擎基线就 100 MB+）。平板 3~4 GB 内存下会被正常回收。
- 退后台不跑定时任务。切回前台会自动同步一次（见「自动同步的三条触发线」），有网就拉新、没网用缓存，不会为了同步在后台常驻联网。

### 流量都在哪（V1.3 优化后）

| 动作 | 优化前 | 优化后 |
|---|---|---|
| 孩子打一次勾 | 上行 1 次 + **全量拉 500 条作业** | 只上行 1 次，不拉 |
| 家长每发布一条作业 | 每次同步都重推家庭档案（1+N 次请求） | 档案没变就跳过，只推作业 |
| 孩子看有图的作业 | 每次冷启动 `Image.network` 全量重下 | 按 key 落盘，一张图只下一次 |

**图片磁盘缓存**（`CloudImageCache`，`lib/widgets/image_grid.dart`）：key 转成文件名存 `cache/cloud_images/`，先写 `.part` 再 rename 防止半张图；上限 200 MB / 60 天，启动后首次使用时清理。刻意没用 `cached_network_image`——public 桶 + key 永不变，那层 HTTP 缓存协商是多余的。

**同步分级**：`syncAll(pull: false)` 只上行。打勾是最高频操作，之前每勾一次都顺手全量拉一遍，纯白烧。

**档案推送节流**：`SyncService._familyDirty` 标记，只有建家庭 / 加改删孩子 / 换机接入才置脏。家长日常布置作业不再每次重推档案。

**流量账本留在代码里，没放进界面**：`CloudApi` 仍记录 `requestCount / bytesIn / bytesOut`，排查时看日志即可。设置页原本有一行「本次运行流量」，已撤掉——那是开发者的账本，家长看不懂也不需要；真正要让他们看见的只有「N 条还没传上去」和「同步失败了」。

## 踩过的坑（改代码时别踩回去）

**1. `DoneCircle` 点不动。** 未打勾的时候圆内没有子节点，透明 `Container` 不参与命中测试，点击直接穿透到底下的卡片（卡片的 `onTap` 是空函数），表现就是「点了完全没反应」。修复：`GestureDetector(behavior: HitTestBehavior.opaque)` 显式撑开触摸区，并向右对齐以免改变视觉位置。

**2. 卡片整块不渲染。** 卡片里 `Row(crossAxisAlignment: CrossAxisAlignment.stretch)` 放在 `ListView` 里，纵向约束无界，stretch 导致布局失败；release 模式把异常吞掉、连日志都不打，表现是「卡片内容全没了」。修复：改用 `Stack` + `Positioned` 铺左侧学科色条。

**3. release 模式看不到报错。** `flutter build apk --release` 下 Dart 异常不会进 logcat。排查界面问题时改用 `flutter run --profile` 或用 debug 包。

**4. `BitmapFactory` 只量尺寸时返回 null。** `inJustDecodeBounds = true` 的 `decodeStream` 本来就返回 null（只回填宽高）。写成 `openInputStream(uri)?.use { decodeStream(...) } ?: return null` 会把每张图都判成失败，表现为「导入 0 张、耗时 20ms」。必须把「流打不开」和「解析结果」分开判断。剪贴板图片导入就是踩了这一个。

**5. 数据库迁移不幂等 → 启动白屏。** `_createSessions` 是「新建库」和「老库升级」共用的建表语句，里面从一开始就带着 v4 才引入的 `family_id`。于是从 v1/v2 跳版本升到 v4 的设备会走：先建表（表里已有该列）→ 紧接着 v3→v4 的 `ALTER TABLE homework_sessions ADD COLUMN family_id` 又加一遍 → `duplicate column name`，数据库打不开、`AppState.init()` 抛出、`runApp` 没执行，屏幕纯白。**主用机永远复现不了**：它经历过 v3→v4，只走 ALTER 不建表，一路正常；只有「装过很老版本、中间跨了好几个版本」的设备才炸。修复是 `_addColumnIfMissing`：先 `PRAGMA table_info` 查，有就跳过。规则——**迁移语句必须能在「这一列已经存在」时安静跳过**，不能假设表结构一定停在预期状态。

**6. 启动异常就是白屏。** `main()` 里 `await state.init()` 一抛异常，后面 `runApp` 根本不执行，屏幕上什么都没有，没有报错、没有入口，用户只能卸载重装，排查只能靠 adb。现在 `_bootstrap()` 兜住异常并挂 `BootFailureApp`，把报错原文摊出来 + 一个「重试」。启动链路里任何 `await` 都不该裸奔到 zone 外。

**7. 照片方向在上传时就被丢掉了，事后救不回来。** `pickImage` 带了 `imageQuality: 80, maxWidth: 1600`，`image_picker` 会重新编码一遍，**EXIF 整个不保留**。实测 11-03 语文那两张：文件扩展名 `.png`，内容其实是 JPEG，1168×2532，`getexif()` 一条记录都没有。这意味着「竖拍横放」的照片一旦传上来，谁都不知道它原本该是什么方向——任何查看器都只能按像素摆着。所以“自动按内容转正”这件事在数据层就不成立，正确的做法是在**上传时**读 EXIF、把方向烘进像素再编码（当前版本没做，等需要时补）。


**补充：卸载重装，本地数据其实还在。** 第 5 条最早出现在一台「刚卸载重装」的平板上，看着像卸载没清干净，其实是 `AndroidManifest.xml` 里没写 `allowBackup`，而 Android 的默认值是 `true`——应用数据会进系统自动备份。卸载时系统确实删掉了 `/data/data/<pkg>`，重装时备份服务又把它**原样恢复**回来，包括 `databases/homework.db`。于是新代码一启动就撞上一个「版本号停在旧值、表结构却是中间状态」的库。

**现在的取舍：备份已彻底关掉。** manifest 里 `allowBackup="false"` + `fullBackupContent="false"`，并配套 `res/xml/data_extraction_rules.xml`——光设 `allowBackup` 挡不住 Android 12+ 的「设备间迁移」(D2D)，那个不看这个开关，必须用规则把 `database` / `sharedpref` / `file` 全部 exclude。换机或重装后一律靠云端同步重建，本地不跟随。

代价要认：卸载那一刻还没上传成功的数据会丢。同步是操作即传、失败退避重试，正常使用下窗口只有几秒，但断网时布置完作业就立刻卸载，那份作业就没了。

即便关掉备份，下面这几层也保留——用户还可能手动降级安装、或者从别处导回旧库：
- `_addColumnIfMissing`：迁移对着任意旧状态都能跑
- `_recover`：库彻底打不开就改名留档、重建空库，App 先能起来
- `BootFailureApp`：启动异常不再是白屏

## 调试备忘（真机 adb）

- 平板会自动休眠，`input tap` 全部落空且截图全黑。必须把唤醒和点击放在同一条 shell 里：`adb shell "input keyevent KEYCODE_WAKEUP; sleep 0.3; input tap X Y"`
- Git Bash 下 `adb shell screencap -p /sdcard/x.png` 的路径会被自动转换，先 `export MSYS_NO_PATHCONV=1`
- MediaPad M5 实测：1200×1920，density 320 → 600×960dp（compact/medium 边界）。要测三栏可用 `wm size 2000x1200`，或直接转横屏（1920×1200 → 960dp 宽，进 expanded）


## 编译

环境要求：Flutter 3.27+、JDK 17、Android SDK。

本项目已固定 `android/gradle.properties` 中的 `org.gradle.java.home` 指向 JDK 17（系统默认 JDK 25 与 Gradle 8.3 不兼容）。

```bash
flutter pub get
flutter build apk --release        # 产物：build/app/outputs/flutter-apk/app-release.apk
flutter build apk --debug          # 调试版，可热重载
```

安装到手机：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

### 服务地址是编译期常量

`lib/data/cloud/cloud_config.dart` 里：

```dart
static const String baseUrl =
    String.fromEnvironment('API_BASE', defaultValue: 'https://homework.example.com');
```

要用 `--dart-define` 传，不能靠运行时改：

```bash
# 连正式服务（release 包必须这样打，tool/release.sh 自动带上）
flutter build apk --release --dart-define=API_BASE=https://你的域名

# 连局域网里的开发服务（只能 debug）
flutter run --dart-define=API_BASE=http://192.168.1.100:8787
```

两个坑：

| 坑 | 说明 |
|---|---|
| `defaultValue` 里带 `example.com` | `CloudConfig.isPlaceholder` 会为真，界面上会提示「还没配服务地址」。忘了传 `--dart-define` 就是这个表现 |
| 局域网用 `http://` | Android 9+ 默认禁明文。debug 包的清单里开了 `usesCleartextTraffic`，**release 包没开**——正式包只能走 HTTPS |

另外 `CloudConfig.cacheScope` 会把 host 做一次 FNV-1a 取前 8 位当缓存目录名，所以切换服务地址以后旧图片缓存不会被误用（`cache/cloud_images/<scope>/`）。

## 首次使用流程

1. 打开 → 「我是家长」→ 填家庭名 → 拿到 6 位家庭码
2. 设置 → 添加孩子（姓名 + 头像色），可加多个
3. 布置 → 选学科、写内容、（加图片，或直接把微信里的消息连图粘进来）→ 发布（自动上传到自家服务器）
4. 设置 → 「切换为孩子的界面」可预览孩子看到的效果
5. 孩子在自己手机上：「我是孩子」→ **输姓名 + 家庭码** → 进入，打开即拉取当天作业
6. 家长换手机或重装：点「我是家长」→ 输入 6 位家庭码 → 数据自动拉回本机

> 第 5 步和以前不一样了：原来只要输名字，因为登录是匿名 token + 客户端自己查表。现在孩子的 token 也必须绑定家庭，所以第一次要输一次家庭码（之后 token 续期，不用再输）。代价是家长得帮着输一次，收益是别人拿不到你家孩子的姓名列表。

## 目录结构

```
lib/
  main.dart                 入口，初始化 DB 与中文本地化
  app.dart                  根路由（按登录状态切换）
  core/                     主题、断点、日期工具、图文混排的正文解析（rich_body.dart）
  models/                   Family / Child / Homework
  data/                     SQLite 与数据访问层、剪贴板桥（clipboard_paste.dart）、云同步
  state/                    全局状态（家庭、孩子、身份）
  widgets/                  作业卡片、图片网格、多图折叠、图文混排渲染、响应式外壳
  features/
    onboarding/             角色选择、创建家庭、孩子登录
    parent/                 布置列表、新建编辑、历史、设置
    child/                  今日作业、日历、我的
```

## 快捷开始

```bash
# 1. 后端（Docker）
cp .env.example .env        # 按注释填 POSTGRES_PASSWORD / JWT_SECRET / ADMIN_TOKEN
docker compose up -d

# 2. 家长 Web 端
cd parent-web && npm install && npm run dev

# 3. Android App
flutter pub get
flutter run --dart-define=API_BASE=http://<你的局域网IP>:8787
```

## 开源说明

本仓库从一套真实在用的家庭作业系统中整理而来，发布前做了以下处理：

- **域名与网络拓扑脱敏**：公网域名统一替换为 `example.com`，NAS 与 Tailscale 地址改为环境变量读取，局域网示例 IP 改用 `192.168.1.100`
- **真实数据不入库**：孩子姓名、家庭码、作业正文、SQLite 快照、验收截图均已排除（见 `.gitignore`）
- **原型与文档保留**：`docs/` 下的部署 runbook 与设计文档按原样保留，可直接作为自托管参考
- **`.env` 不入库**：密钥与凭据一律走 `.env`，仓库只提供 `.env.example`

如果你要用这套代码，至少要替换：域名、`POSTGRES_PASSWORD`、`JWT_SECRET`、`ADMIN_TOKEN`，以及 COS 四项（不用对象存储可留空，图片会落本地卷）。

## 许可证

[MIT](LICENSE) © 2026 Tianshu Wang

可自由用于商业项目、修改、分发，保留版权声明即可。

