# OmniFetch

OmniFetch 是视频、音频和图集的多端下载工具（支持 macOS SwiftUI、Windows Qt 6 桌面端与命令行 CLI）。它接受单条链接、批量链接和平台分享文案，针对 B 站、小红书和微信视频号提供专门解析，X、YouTube 及其他站点由视频和图集引擎处理。

## 下载（Releases 发布版）

前往 [GitHub Releases (v1.0.0)](https://github.com/logex-linux/OmniFetch/releases/tag/v1.0.0) 直接下载已封装安装包：

| 平台 | 下载文件 | 中文说明 |
|---|---|---|
| **macOS 14+** | [OmniFetch-1.0.0-universal.dmg](https://github.com/logex-linux/OmniFetch/releases/download/v1.0.0/OmniFetch-1.0.0-universal.dmg) | macOS 通用磁盘镜像安装包（Apple Silicon + Intel 芯片均支持，打开拖入「应用程序」即可） |
| **Windows 10/11 (x64)** | [OmniFetch-1.0.0-windows-x64.exe](https://github.com/logex-linux/OmniFetch/releases/download/v1.0.0/OmniFetch-1.0.0-windows-x64.exe) | Windows 64 位独立可执行程序（Qt 6 桌面版，无需安装 Python，双击直接运行） |
| **校验文件** | [SHA256SUMS.txt](https://github.com/logex-linux/OmniFetch/releases/download/v1.0.0/SHA256SUMS.txt) / [SHA256SUMS-windows.txt](https://github.com/logex-linux/OmniFetch/releases/download/v1.0.0/SHA256SUMS-windows.txt) | macOS 与 Windows 安装包的 SHA-256 完整性校验码 |

> 首次打开提示：macOS 版为 ad-hoc 签名，如遇系统拦截请右键「打开」或执行 `xattr -dr com.apple.quarantine /Applications/OmniFetch.app`；Windows 版未做商业代码签名，SmartScreen 提示时点击「更多信息 → 仍要运行」即可。

## 快速开始（命令行 CLI）

当前 CLI 支持 macOS 14+，构建需要 Swift 5.9 或更新版本。请在仓库目录运行以下命令。

```bash
swift run omnifetch --help
swift run omnifetch sites
swift build -c release --product omnifetch
```

可将 Release 二进制放到 `PATH` 下，例如 `install -m 755 .build/release/omnifetch "$HOME/.local/bin/omnifetch"`。目标目录须已存在。也可以直接运行 `.build/release/omnifetch`。

```bash
omnifetch probe "$MEDIA_URL"
omnifetch download "$MEDIA_URL" --quality 1080 -o ./downloads
omnifetch download "$MEDIA_URL" "$SECOND_URL" --audio
omnifetch download - --json -o ./downloads < links.txt
omnifetch selftest
```

`probe` 显示标题、实际引擎、格式 ID 和分 P 信息。用 `download --format ID` 选择格式。默认下载到 `~/Movies/OmniFetch`。例如 `omnifetch download --connections 8 URL` 将单任务并发上限设为 8，适用于直链分片、原生图集和支持分片的 yt-dlp 视频。用 `--limit-kbps` 按 KiB/s 限速。Ctrl-C 后可用同一链接和输出目录继续支持续传的下载。

批量输入按链接顺序处理并去重，单条失败后继续下载剩余链接。`--json` 在标准输出写一个包含 `results` 数组的对象。条目含 `url`、`engine` 以及可用的 `title`、`formats`、`parts`、`outputPath` 或 `error` 字段。格式 ID 位于 `formats[].id`。诊断信息写到标准错误。退出码为 `0`（全部成功）、`1`（有任务失败）、`2`（用法错误）或 `130`（中断）。

OmniFetch 会优先使用已安装的引擎。缺少 yt-dlp 时会下载官方 macOS 程序。可运行 `omnifetch install-gallery` 提前安装图集引擎，或用 `brew install gallery-dl`。合并音视频和部分音频提取任务需要 ffmpeg，可用 `brew install ffmpeg` 安装。

原命令 `--probe`、`--download`、`--sites`、`--install-gallery` 和 `--selftest` 仍可作为子命令的别名。

## 一、调研：这些下载器是怎么做的

| 项目 | 语言 / 星标 | 核心思路 | 本项目的取舍 |
|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Python，204k★ | 每个站点一个 extractor，插件式扩展；`--concurrent-fragments` 并发分片；`--progress-template` 输出结构化进度 | 作为兜底引擎，首次使用时自动下载官方 macOS 独立二进制（无需 Python 环境） |
| [哔哩哔哩下载姬 downkyi](https://github.com/leiurayer/downkyi) | C#，24k★ | 走 B 站官方 `view` / `playurl` 接口，拿 DASH 音视频分离流，多线程分段下载后用 ffmpeg 合流 | 复刻为原生 `BilibiliEngine`，不依赖网页解析，速度快且稳定 |
| 微信视频号 | WebKit / Swift | 使用腾讯元宝分享解析或官方预览页提供的播放信息 | 保留媒体 URL 的签名参数并检查输出文件能否播放 |
| [XHS-Downloader](https://github.com/JoeanAmier/XHS-Downloader) | JS，13k★ | 抓笔记页 `window.__INITIAL_STATE__` 里的 `noteDetailMap`，取 `masterUrl` | 复刻为 `XiaohongshuEngine`，失败时自动回落 yt-dlp |
| [N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE) | C#，9k★ | 专注 HLS/DASH/ISM 分片并发下载与合并 | 不自研，HLS 交给 yt-dlp + ffmpeg |
| [you-get](https://github.com/soimort/you-get) | Python，56k★ | 早期多站点解析，启发式嗅探媒体地址 | 仅作参考，未直接使用 |
| Downie | 闭源商业软件 | 队列 + 格式选择 + 浏览器扩展/剪贴板接管 | UI 与交互形态参考：队列、画质选择、剪贴板监听、Finder 定位 |

国内平台的原生解析、yt-dlp 与 gallery-dl 共用引擎路由。预览结果记录实际选用的引擎，下载时沿用该结果。

## 二、架构

```
omnifetch CLI                 SwiftUI / DownloadManager
        └────────────┬─────────────┘
                OmniFetchCore
EngineRegistry ── 按 URL 路由
   ├── BilibiliEngine      官方 API + DASH 双轨 + ffmpeg 合流
   ├── XiaohongshuEngine   笔记 JSON 解析
   ├── WeChatChannelsEngine 视频号分享链接与 CDN 直链
   ├── DirectMediaEngine   视频、音频与图片直链
   ├── XMediaEngine        可选 X API，按帖子原顺序读取附件
   ├── GalleryDLEngine     图集、图片与混合媒体帖子
   └── YTDLPEngine         视频、音频、播放列表与流媒体清单
        │
FileFetcher ── Range 分片并行、断点续传、限速、重试
```

SwiftUI 界面直接调用 `OmniFetchCore`。后续 Windows Electron 界面可通过 CLI 子进程和 JSON 结果接入。

## 三、性能优化

**网络层**

- 在「设置 → 每任务并发上限」选择 1–16 路，默认 6 路。新建任务的「高级选项」可单独设置。支持 HTTP Range 的视频按大小分配连接，每路至少约 2 MiB。小于 4 MiB 使用单路，4 至不足 32 MiB 最多 4 路，32 MiB 起可用满所设上限。
- 每个文件的探测、分片和重试共用一个 `URLSession`，单主机最多 16 个连接。HTTP/1.1 可以复用连接，支持 HTTP/2 的源站可以在同一连接上传输多个分片。
- 已知的小文件和单连接新任务直接发起 GET，从响应头取得长度和 ETag。已有断点仍先核验远端版本。直接提交的媒体链接只在下载时探测，单独预览仍显示文件大小。
- 分片进度每 2 秒写入 `.omni-resume`，暂停或失败时立即保存。重试时即使修改了并发上限，仍可复用同一来源、同一版本已经写入的字节。旧断点存在不连续的区间时，按新的并发上限调度原有分片。
- 指数退避重试（0.4s→4s，最多 5 次），单分片失败不影响其他分片。
- 服务器对局部 Range 返回 200 时，立即取消其余分片，等旧写入结束后再从头下载。服务器返回有效但较短的 206 时，直接从已写入的位置继续。
- 探测阶段先跟随重定向，分片请求直达最终 URL：跨域重定向会丢掉 `Range` 头，直接打原链接会退化成单流（实测 samplelib 短链即为此情况）。
- 每个文件可带备用 CDN 地址（B 站 `backupUrl`）：主源失败自动换源重下；403/404/410 直接失败换源，不做无意义重试。
- 子进程 stdin 接 `/dev/null`，ffmpeg 额外加 `-nostdin`，不会读走 App 的输入。
- 缩略图使用 32 MB 内存 + 256 MB 磁盘的 `URLCache`，滚动和重启后不再重复下载。
- 暂停/取消会立即终止对应子进程与探测请求；ffmpeg 合并阶段也能中断，不会干等合并跑完。
- DASH 合并先写 `.merge.part`，成功后再改名，取消或失败不会留下看似完成的半成品。
- 匿名单视频预览在内存中最多保留 8 条，每条最多 2 MiB，有效期 90 秒。YouTube 等来源由 yt-dlp 选定的公开 MP4 或 MP4 + M4A 有确定大小且至少一轨达到 4 MiB 时，可交给原生并发下载，并遵守提取器给出的单次 Range 长度。其他格式继续交给 yt-dlp。HLS/DASH 清单沿用 yt-dlp 的分片并发。纯 YouTube 播放列表预览只读取第一项的简要信息。
- 直链、图集和播放列表在隐藏目录中续传。文件确认写入后发布结果，同名输出自动编号。
- 小红书和 X 的原生图集共用连接池，同时传输的附件以单任务设置为上限。一个附件完成就开始下一个，文件编号按原帖顺序排列。附件少于可用连接时，视频附件可以利用空余连接分片。
- 全局令牌桶限速，跨分片、跨文件、跨任务共享同一个桶（并行分片不能各睡各的配额，否则实际速率会翻倍）；突发上限 250 ms；yt-dlp 走 `--limit-rate`。设置页的限速对原生下载和 yt-dlp 同时生效。
- yt-dlp 参数：`--concurrent-fragments`、`--http-chunk-size 10M`、`--buffer-size 1M`、`--retries 10`、`--fragment-retries 10`。
- 格式选择优先 `avc1 + m4a`，避免 AV1/VP9 在 QuickTime 无法播放，同时保证 mp4 直出。

**本地层**

- 先 `truncate` 预分配文件，再按 offset 写入，内存占用与文件大小无关；预分配前检查可用空间，不足直接报错。
- 每个分片使用独立文件句柄，每次尝试只定位一次，随后顺序写入。小数据块合并到 256 KiB 或 250 ms 后写盘。大块直接从接收缓冲区写入，断点和进度按系统实际写入的字节数更新。
- 进度回调 10 Hz 节流（`ProgressGate`），进度条不会因回调风暴卡顿。
- 速度采样 0.35 秒 + EMA 平滑，避免数字乱跳。
- 进度回调不写盘：只有状态变化才序列化任务列表，长时间下载不会反复重写 tasks.json；退出时保存最终进度。
- 任务行按值比较（`EquatableView`），一次进度更新只重绘真正变化的行；侧栏计数与列表过滤各只遍历一遍。
- 续传前核对 sidecar 与实际文件大小，文件被外部截断时自动重下，避免零字节空洞。
- sidecar 记录远端 `ETag`：同一链接的文件已更新时丢弃旧进度重新下载，不会把新旧版本拼在一起。
- 单流下载会校验实际字节数与声明大小，短包（服务器提前正常关闭）判失败而不是"完成"。
- B 站等原生双轨下载共用一个连接池和同一任务预算。设为 1 路时依次传输视频和音频。设为多路时两轨并行，优先分配给视频。完成的轨道保存在任务暂存目录，恢复后可直接用来合并。
- 历史超过 1000 条时丢弃最旧的已完成任务；关闭"保留下载历史"后已完成任务不再落盘。
- 队列并发默认 3，兼顾带宽与磁盘 IO；暂停/取消即时终止对应 `URLSession` 任务。
- 批量链接和多分 P 视频一次入队、一次写入任务历史。全部暂停和恢复也只写一次；快速恢复会等旧写入结束再启动。
- yt-dlp/ffmpeg 子进程按 utility QoS 运行，stdout 边读边解析，避免管道写满导致卡死。

## 四、桌面界面与打包分发

- **macOS**：从 [GitHub Releases](https://github.com/logex-linux/OmniFetch/releases) 下载 `OmniFetch-1.0.0-universal.dmg`（Apple Silicon + Intel 通用版），或在仓库根目录本地打包并安装到 `/Applications`：

```bash
./scripts/build_app.sh              # 本机架构 .app
./scripts/build_dmg.sh --install    # Universal (arm64 + x86_64) .app + .dmg 并安装到 /Applications
open /Applications/OmniFetch.app
```

- **Windows（Qt 6）**：源码位于 `windows/`，与 macOS 共享同一套 Visual DNA（冷矿物灰 + 光学青，浅/深自动跟随系统）。可直接从 [GitHub Releases](https://github.com/logex-linux/OmniFetch/releases) 下载单文件 `OmniFetch-1.0.0-windows-x64.exe`，或在 Windows 上本地封装：

```powershell
cd windows
.\build_windows.ps1                 # 生成 dist\OmniFetch-1.0.0-windows-x64.exe
```

构建 Release CLI 后，可运行 `python3 scripts/check_social_engines.py`，在本地核验批量输入、JSON 输出、预览复用、文件完整性和合集失败后的恢复。传入 `--baseline /path/to/old/OmniFetch` 可对照旧版的源页面请求次数与耗时。该检查使用 `PATH` 中的 yt-dlp 和 ffmpeg。

2026-11-24 在同一台 Mac 上交替运行新旧版 5 轮。测试页每次访问固定等待 120 ms。旧版每次下载请求页面 2 次，本版 1 次，两版都只传输 1 次媒体文件，输出字节一致。端到端耗时中位数从 1.749 秒降至 1.134 秒。

运行 `python3 scripts/benchmark.py` 可在本机复测 Release 性能。加 `--baseline /path/to/old/OmniFetch --csv build/performance.csv` 可与旧版源码交替运行五轮并保存每轮耗时、请求数和同时传输的峰值。`--connections 8 --case short --case album` 可单测 6 MiB 短视频和 24 个附件。测试还覆盖 48 MiB 按连接限速、256 MiB 不限速、小文件、忽略 Range 的源站，以及 500 条任务入队。下载完成后校验 SHA-256。

2026-11-28 在同一台 Mac 上以 8 路上限交替测试新旧版 9 轮。6 MiB 按连接限速的短视频耗时中位数从 0.499 秒降至 0.191 秒，实际并发从 1 路升至 3 路。24 个附件从 0.400 秒降至 0.236 秒，实际并发从 3 路升至 8 路。48 MiB 限速文件两版均约 0.52 秒。256 MiB 不限速回环下载分别为 0.166 秒和 0.181 秒。新版另测 7 轮，48 MiB 限速文件设为 1 路时中位数为 3.769 秒。

自检输出示例：

```
PASS  route bilibili / xiaohongshu / wechat / direct / ytdlp
PASS  bilibili canonical url / part url / parts parse
PASS  xhs image files / image download
PASS  legacy settings decode
PASS  cancel kills child process
PASS  resume seed
PASS  resume accounting
PASS  download size
PASS  parallel ranges      requests=5
PASS  content integrity
PASS  resume integrity
PASS  resume skips finished chunks
PASS  stale sidecar ignored
PASS  range-lie fallback integrity
PASS  short body rejected
PASS  rate limiter / rate limiter concurrency
PASS  backup source failover
PASS  cancel during probe
PASS  etag change restarts
RESULT  all checks passed
```

## 五、站点与限制

| 平台 | 可用场景 | 使用条件 |
|---|---|---|
| 哔哩哔哩 | BV、av、短链、指定分 P、全部分 P 排队、按清晰度选轨和备用 CDN。动态与专栏走通用引擎 | 可选清晰度取决于播放接口实际返回的轨道。双轨合并需要 ffmpeg |
| 小红书 | 分享文案、长短链、视频画质切换、有序图集、实况照片的静图与动态视频 | 需要登录的笔记可在「新建下载 → 高级选项」登录小红书并启用应用内会话。也支持已配置所属域名的手动 Cookie。应用只保存笔记页面实际提供的媒体 |
| 微信视频号 | 微信 `/sph/` 分享、完整官方预览链接、媒体直链、可用的 H.264/H.265 格式 | 分享链接使用应用内腾讯元宝登录。官方预览保留原始签名，过期、受限或无法播放的文件会提示失败 |
| X / Twitter | 视频、图片、同帖多段视频、图文混排。可选 X 官方 API 按原顺序读取附件并支持单个附件链接 | gallery-dl 与 yt-dlp 依次尝试。可见范围、登录状态和上游提取器决定可取的附件。若已开通 X API，可通过运行环境提供 `OMNIFETCH_X_BEARER_TOKEN` |
| YouTube | 单视频、Shorts、纯播放列表、画质上限、手动选格式、提取音频 | 含 `v` 和 `list` 的观看页默认保存当前视频。要下载全列表，请使用 `/playlist?list=…` |
| 微博、抖音、知乎、AcFun、斗鱼、虎牙等 | 由相应视频或图集提取器处理 | 每个平台支持的内容类型不同。快手使用通用解析，结果取决于具体链接 |
| Instagram、Reddit、Bluesky、Mastodon、Pinterest、Flickr、TikTok、Vimeo、Twitch 等 | 图片、相册、视频或公开嵌入，按引擎能力路由 | 部分链接需账号、实例支持或地区访问权限 |
| 媒体直链 | 常用图片、视频、音频，HLS/DASH 清单 | 普通媒体由原生传输层下载，清单由 yt-dlp 处理 |

运行 `omnifetch sites` 可查看重点识别的域名。其他 HTTP(S) 链接也会进入通用解析。上游维护各自的提取器清单，条目数包含同一站点的不同内容类型。[视频提取器清单](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) · [图集提取器清单](https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md)

- 可用 `brew install ffmpeg` 安装合并和提取音频所需的工具。
- 小红书的应用内会话由本机 WebKit 保存。命令行使用已有会话时须显式传入 `--xhs-app-session`。
- 手动 Cookie 在设置中绑定所属域名。旧设置中可识别的 B 站和小红书登录项仍能使用，其他旧项需要填写域名。
- CLI 接受环境变量 `OMNI_COOKIE`。设置后，一批链接须使用相同的协议、主机和端口。
- 播放列表或图集的进度按文件项数显示，中断时可再次提交同一任务继续。原生视频直链使用 Range 续传。

- 未做公证（notarization），首次打开如被拦截：右键 → 打开，或 `xattr -dr com.apple.quarantine build/OmniFetch.app`。

## 六、目录

```
Sources/OmniFetchCLI/   独立 CLI 入口
Sources/OmniFetch/      macOS SwiftUI 界面
Sources/OmniFetchCore/
  Models.swift          任务/设置/媒体模型
  AppPaths.swift        数据目录与日志
  Shell.swift           进程执行与流式输出
  HTTPProbe.swift       HEAD 探测 + 令牌桶
  ChunkDownloader.swift 单分片下载器
  FileFetcher.swift     分片编排、续传、限速
  Engine.swift          引擎协议与路由
  DirectPipeline.swift  直链流水线、ffmpeg 合并
  DirectMediaEngine.swift / BilibiliEngine.swift / XiaohongshuEngine.swift / YTDLPEngine.swift
  DownloadManager.swift 队列与持久化
  SelfTest.swift        本地 Range 服务器自检
  CommandLineTool.swift CLI 参数、任务执行与输出
```

## 七、合规

仅用于个人备份与离线观看。请遵守目标站点的服务条款与版权规定，不要用于批量抓取、二次分发或商业用途。
