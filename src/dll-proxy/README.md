# dll-proxy —— 通用 DLL 代理（转发导出 + 截流）

## 这是什么

一个把目标 DLL 的**全部导出符号**转发出去的"代理 DLL"骨架，并额外在若干
FFmpeg 解复用接口上加了探针。目标是：**顶替播放器依赖的 FFmpeg 模块，
在它解密之后、解码之前，把数据流截下来。**

核心思路：

```
            ┌────────────────── 代理 DLL ──────────────────┐
 播放器 ──► │ ① 转发全部导出（尾跳 jmp *slot_xxx）          │
            │ ② avformat_open_input 返回后：                │
            │      取 (*ps)->pb  -> AVIOContext             │
            │      记下 class / buffer / read_packet / ...  │
            │ ③ 对着它 avio_seek(0) + avio_read 循环写盘     │
            └──────────────────────────────────────────────┘
```

## 文件

| 文件 | 说明 |
|---|---|
| `avformat_exports.json` | 目标 DLL 的导出表快照（`names` 里是全部导出名） |
| `gen_proxy.py` | 由导出表生成 `gen.S`（转发存根）/ `gen.c`（槽表）/ `gen.def` |
| `proxy.c` | 代理本体：`avio_*`、`avformat_*` 探针 + 明文 dump |
| `patch_manifest.py` | 把 PE 内嵌清单里的 `requireAdministrator` 等长替换成 `asInvoker` |

## 编译

需要 **mingw-w64 的 32 位 gcc**（目标播放器是 32 位）：

```powershell
cd src\dll-proxy
python gen_proxy.py                     # 生成到 <repo>\build\
gcc -m32 -O2 -shared -o ..\..\build\avformat-58.dll `
    proxy.c ..\..\build\gen.c ..\..\build\gen.S ..\..\build\gen.def
```

产物：`build\avformat-58.dll`，由 `scripts\extract-stream.ps1` 自动安装到播放器副本目录。

## 换一个播放器 / 换一个 FFmpeg 模块

1. 把目标的 `avformat-*.dll` 导出表导出成 JSON（`{"names": {"符号名": 序号, ...}}`）
   覆盖 `avformat_exports.json`；
2. 视需要调整 `gen_proxy.py` 里的 `HOOK` 与 `CUSTOM`（哪些由 C 实现、哪些纯转发）；
3. 在 `proxy.c` 里按新的 DLL 名/偏移调整（例如 `AVFormatContext.pb` 的偏移
   随位数与 FFmpeg 版本而变：32 位 FFmpeg 4.x 是 16）。

## 注意

- **必须是 32 位**，且导出表要与目标 DLL 逐一对齐，否则播放器会在加载阶段崩溃；
- 代理 DLL 会往工作目录写 `decrypted_N.bin`，可用环境变量 `MEDIA_DUMP_DIR` 改目录；
- 少数播放器对模块做完整性校验，换掉某些 DLL 会直接退出 —— 那就只替换解密路径
  上的那一个模块（本项目里只需要 `avformat-58.dll`）。

## 运行期日志

代理会把关键事件写到工作目录的 `proxy_log.txt`，例如：

```
avformat_open_input(url=stream:122577664, ...)
pb=4de6580  avioctx: class=... buffer=... size=0x8000 read_packet=...
avio_size = 282146787
PB DUMP #1: ...
```

`scripts\extract-stream.ps1` 就是靠 `avformat_open_input` 与 `PB DUMP #1:`
这两个标记判断"播放器开始解密了"和"明文 dump 好了"。
