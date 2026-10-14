# media-payload-restore

把一类**被二次改写过的 H.264/AAC 媒体**无损还原成标准 mp4 —— 不重新编码。

> 适用于：你手上有一份**通过合法途径拿到、但负载被发行方改写过**的加密课程/录像文件
> （例如你自己的付费备份）。它自带播放器能播，但任何标准工具链都打不开或解码失败。
>
> **使用时请遵守 `DISCLAIMER.md`：仅限你本人有权访问的内容做个人备份。**

---

## 它解决什么问题

有些加密媒体被解密之后，拿到的仍然不是标准码流：**容器（MP4 / MPEG-TS）结构完好，
但里面的视频、音频负载被做过非标准改写**。典型表现：

- 自带播放器能正常播放，但 ffmpeg / VLC / 剪辑软件打开就报错：

  ```
  [h264] non-existing PPS 0 referenced
  [h264] decode_slice_header error
  [h264] no frame!
  [h264] Missing reference picture, default is 65
  [h264] Reference 4 >= 4
  [h264] corrupt decoded frame
  ```

- 或者能打开，但只有开头几秒正常、后面全花，或者时长莫名其妙地短

本工具做两件事：

1. **取出明文容器**：受保护文件的解密只能由发行方的播放器完成，于是用一个
   **代理 DLL** 把播放器当成"解密黑盒"，顺序读出它解密后的流（原理见
   `docs/05-methodology.md`）。
2. **还原被改写的负载**：逐比特修复视频 slice 头、恢复音频帧位移，
   然后**原样拷贝**重新封装成标准 mp4（视频音频都不重编码，画质零损失）。

---

## 已支持的改写形态

| # | 改写手法 | 本工具的处理 |
|---|---|---|
| 1 | 每个 slice 负载前多 1 字节标记 `0x84`（SEI 包没有） | 去掉 |
| 2 | slice 头前缀两个字段值互换：`slice_type` ↔ `pic_parameter_set_id` | 换回 |
| 3 | 前缀之后**额外插入 1 个比特**，并把头部补齐到字节边界 | 去掉那 1 bit，含"头部原本就字节对齐"的特例 |
| 4 | 音频每 256 帧一个 17 字节标记块，紧随其后那一帧整体位移 1 位 | 去块 + 右移 1 位还原 |

第 3 条里那个特例是整件事的关键，值得单独说：
若原始头部位数 `X` 满足 `X % 8 == 0`，插入 1 bit 后会**多带出 7 个填充位**，
必须一并去掉，否则 CABAC 起点后移 1 字节。不处理它时，出错比例恰好是 **1/8** ——
这个"奇怪的 12.5%"正是当初定位到真因的线索。详见 `docs/02-avc-slice-restore.md`。

---

## 环境要求

- **Windows**（用到 win32 API 做窗口点击、进程操作）
- **PowerShell 5.1+**（脚本本身是 UTF-8 with BOM；若自行改动请注意编码）
- **Python 3.8+**（核心还原脚本只用标准库）
- **ffmpeg.exe** 放在仓库根目录（或改脚本里的路径）
- **你自己的播放器安装目录**（第一步取明文要用）
- 编译代理 DLL 需要 **mingw-w64 的 32 位 gcc**（见 `src/dll-proxy/README.md`）

---

## 快速开始

> **运行前准备清单**（仓库里刻意不带二进制和大文件，所以克隆后需要凑齐这四样）：
>
> | 需要 | 放哪 | 说明 |
> |---|---|---|
> | `ffmpeg.exe` | 仓库根目录 | 自己下载，静态版即可 |
> | 代理 DLL | `build\avformat-58.dll` | 用下面的命令编译（源码在 `src\dll-proxy\`） |
> | 播放器副本 | 任意目录，用 `-PlayerDir` 指过去 | 你自己的播放器安装；首次可用 `-SourceDir` 拷一份 |
> | Python 3.8+ | PATH 上 | 只用标准库，不需要 pip |
>
> 编译代理 DLL 需要 **mingw-w64 的 gcc（能编 32 位）**：
> 实测 **64 位 mingw-w64 加 `-m32` 也可以**（会链接它的 32 位库），
> 纯 32 位 mingw32 当然也行。

```powershell
# 0) 编译代理 DLL（只需一次）
cd src\dll-proxy
python gen_proxy.py
gcc -m32 -O2 -shared -o ..\..\build\avformat-58.dll proxy.c ..\..\build\gen.c ..\..\build\gen.S ..\..\build\gen.def
cd ..\..

# 1) 单个文件（自动完成：取明文 -> 判断容器 -> 还原负载 -> 封装 -> 全片校验）
.\scripts\extract-stream.ps1 -Source "D:\videos\lesson01.sz" -PlayerDir "D:\player"

# 2) 目录递归批量（已存在同名 mp4 会自动跳过，可断点续跑）
.\scripts\restore-batch.ps1 -Source "D:\videos" -PlayerDir "D:\player"

# 3) 只看进度
.\scripts\status.ps1
```

输出：与源文件同目录同名的 `.mp4`。

> 直接跑 `.ps1` 被策略拦时，用：
> `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-batch.ps1 ...`

---

## 项目结构

```
media-payload-restore/
├─ scripts/
│  ├─ extract-stream.ps1    # 取明文 + 自动判断容器类型 + 封装（单文件主入口）
│  ├─ restore-payload.ps1   # 负载还原流程（被上面自动调用，也可单独用）
│  ├─ restore-batch.ps1     # 目录递归批量
│  ├─ verify.ps1            # 全片解码校验，汇总有问题的文件
│  └─ status.ps1            # 批量进度快照（配合日志）
├─ src/
│  ├─ payload_restore.py    # 核心：视频 slice 头还原 + 音频帧位移还原（只用标准库）
│  └─ dll-proxy/            # 通用 DLL 代理：转发导出 + 截取解密后的流
│     ├─ proxy.c            # 代理本体（avio_* / avformat_* 探针 + 明文 dump）
│     ├─ gen_proxy.py       # 由导出表生成转发存根
│     ├─ patch_manifest.py  # 等长替换 PE 清单里的 requireAdministrator
│     └─ avformat_exports.json
├─ docs/                    # 原理、定位过程、踩过的坑
└─ build/                   # 生成的代理 DLL（不入库）
```

---

## 常见问题

**Q：脚本报"找不到播放器目录"？**
用 `-PlayerDir` 指向你自己的播放器安装目录；想保留系统那份不动，可以先用
`-SourceDir` 把安装目录拷一份到工作副本目录再处理。

**Q：卡在"等 dump 稳定"？**
说明播放器没有真正开始解密。多数情况是"播放"按钮没点到（脚本会按固定窗口尺寸找按钮，
换皮肤/分辨率可能需要改坐标），或者播放器弹了额外的授权窗口。

**Q：转换出来的 mp4 全花 / 报 `Missing reference picture`？**
先看 `docs/02-avc-slice-restore.md` 里"8 分之一"那一节 —— 这类问题几乎都出在
slice 头的比特对齐上。

**Q：为什么必须有播放器？**
受保护文件的密钥在播放器里，本工具不破解密钥，只是把它解密后的流取出来。
所以这一步无法脱离播放器完成。

**Q：会不会重新编码？**
不会。视频 `-c:v copy`、音频 `-c:a copy`，只做字节级还原与容器重封装。

---

## 文档

| 文档 | 内容 |
|---|---|
| `docs/01-background.md` | 问题背景与整体思路 |
| `docs/02-avc-slice-restore.md` | 核心技术：slice 头的比特插入与还原（含 1/8 对齐陷阱） |
| `docs/03-container-and-remux.md` | 容器层：TS/MP4 识别、时间戳、无损重封装 |
| `docs/04-audio-restore.md` | 音频帧位移与标记块处理 |
| `docs/05-methodology.md` | 方法论：怎么定位这类改写 + 取明文的一种做法 |
| `DISCLAIMER.md` | 使用范围与免责声明 |

---

## License

MIT（见 `LICENSE`）。使用前请阅读 `DISCLAIMER.md`。
