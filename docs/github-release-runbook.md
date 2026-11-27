# GitHub Release 发版手册

打 tag 触发 CI，构建并校验 Android 安装包，产出 GitHub Release。
本机手动发版（NAS 链路）仍是 `tool/release.sh`，两者互不冲突，可同时存在。

---

## 一、一次性配置

### 1. 生成密钥库的 base64

只在需要粘贴进 GitHub 时生成，生成后文件已被 `.gitignore` 排除：

```bash
base64 -w0 android/upload-keystore.jks > android/upload-keystore.base64.txt
```

Windows 上想把结果直接进剪贴板：

```bash
base64 -w0 android/upload-keystore.jks | clip
```

### 2. 填 5 个 secrets

仓库 → Settings → Secrets and variables → Actions → **New repository secret**：

| 名称 | 值 | 说明 |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | 上一步文件的内容（一整行） | 密钥库本体 |
| `ANDROID_KEYSTORE_PASSWORD` | `android/key.properties` 里的 `storePassword` | 密钥库口令 |
| `ANDROID_KEY_ALIAS` | `homework` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | `android/key.properties` 里的 `keyPassword` | 密钥口令 |
| `API_BASE` | `https://你的域名` | 服务端根地址；地址是编译期常量，缺了包会连占位域名 |

`API_BASE` 用 secret 而不是明文写进 workflow，是因为它会以 `--dart-define` 的形式出现在 runner 的命令行上，secret 会被日志自动打码。

### 3. 密钥备份（必做，且只能做一次）

**`android/upload-keystore.jks` 丢了，就再也无法给已安装的 App 发更新** —— 用户只能卸载重装，`allowBackup=false` 意味着本地 SQLite 一并清空。Android 官方对此没有找回途径。

建议：把 `upload-keystore.jks` 与 `key.properties` 一起打包加密，放两处离线介质（U 盘 + 网盘私有目录），并在日历上留一个年度提醒。

---

## 二、发版

```bash
# 1. 改版本号：versionCode 必须递增，否则客户端判定不出「有新版本」
#    pubspec.yaml: version: 1.2.2+14

# 2. 提交
git add -A && git commit -m "chore: 发布 1.2.2"

# 3. 打 tag 并推送 —— 这一下才触发 CI
git tag v1.2.2
git push origin main --tags
```

tag 名去掉 `v` 必须与 `pubspec.yaml` 的版本号一致，否则 CI 在「校验 tag 与版本号一致」这步就停。

不想发 Release、只想看看能不能构建：GitHub 页面 → Actions → Release → **Run workflow**。这种运行只把产物留在 workflow artifact（保留 14 天），不建 Release。

产物：

| 文件 | 说明 |
|---|---|
| `homework-<版本>.apk` | 通用包（arm64-v8a + armeabi-v7a + x86_64），约 23 MB |
| `SHA256SUMS.txt` | 校验和 |

命名刻意与 `app_releases.download_url` 的模板 `homework-{version}.apk` 对齐，**可以直接把 Release 里的资源地址填进版本表**，不需要改客户端。

---

## 三、CI 里做了哪些校验

发版事故里最难查的两类——「发出去的包签名不对」和「包连不上服务器」——都做成机器判定，不靠人眼看：

| 校验 | 手段 | 不通过时的症状 |
|---|---|---|
| 不是 debug 签名 | `apksigner verify --print-certs`，命中 `CN=Android Debug` 即失败 | 装了新版提示签名不一致，必须卸载 |
| 有 v2 签名 | `apksigner` 输出里必须出现 `v2 scheme ... true` | Android 7+ 直接拒绝安装 |
| `versionCode` 与 pubspec 一致 | `aapt2 dump badging` | 客户端认为没有新版本，静默不更新 |
| 域名已注入且无占位符 | 从 `libapp.so` 里搜 `API_BASE`，并搜 `homework.example.com` | 装上白屏 / 连不上服务 |

本地构建还有第二道闸：`android/app/build.gradle` 在缺 `key.properties` 时**直接中断 release 构建**，不再像以前那样静默退回 debug 签名。错误信息会写清本机和 CI 分别该补什么。

---

## 四、常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `Java home supplied is invalid` | `android/gradle.properties` 里钉了本机 JDK 绝对路径 `F:/...` | workflow 已有 `sed` 删除该行的步骤；若手动跑 Gradle 需自己处理 |
| `缺少 secrets: ...` | 上表五项没配齐 | 补齐后重跑 |
| `tag 是 x，pubspec 是 y` | 先打了 tag 后改的版本号 | 删 tag 重打：`git tag -d v1.2.2 && git push origin :refs/tags/v1.2.2` |
| `签名不一致`，装不上 | 旧包是 debug 签名 | 卸载旧包再装新包（本地数据靠云端同步恢复） |
| `包里残留占位域名` | 构建时 `API_BASE` 为空 | 检查 secret 是否存在、名字是否拼错 |

---

## 五、已知限制

- **iOS 未覆盖。** 仓库里没有 `ios/` 工程，且当前 Flutter 3.27.4 编不出 iOS 26 的产物，需先升级 Flutter 才能加 macOS runner。iOS 的安装包也不能像 APK 一样公开分发（描述文件绑设备 UDID），届时只能走「CI 出未签名 IPA + 本机侧载」。
- **macOS runner 按 10 倍系数扣分钟。** 私有仓库每月 2000 分钟额度，实际只够约 200 分钟 macOS 构建。当前 workflow 只用 `ubuntu-latest`，不受影响。
- **APK 未做混淆与符号表。** 线上崩溃栈只能靠 Flutter 的默认还原。真要排查线上问题，后续可加 `--split-debug-info`。
