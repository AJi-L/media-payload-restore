# 03 · 容器识别与无损重封装

## 判断明文是什么

两种常见明文：

| 类型 | 特征 | 处理 |
|---|---|---|
| MPEG-TS / M2TS | 每 188 或 **192** 字节出现 `0x47`（TS 同步字节）；开头常见 `47 40 11 …` + `"FFmpeg\tService01"` | 交给 ffmpeg 重封装 |
| MP4 | 开头 `00 00 00 xx 66 74 79 70`（`ftyp`） | 可能还需负载还原（见 02/04） |

脚本里用一个 16 字节的嗅探判断：

```powershell
$hb = 读前 16 字节
$isMp4 = ($hb[4..7] -join '' -eq 'ftyp' 的 ASCII)
```

> ⚠️ 判断 TS 对齐时 **188 和 192 都要试**。只按 188 去切，会把 M2TS 误判成"中间全是乱码"。

## 无损重封装（TS 路径）

```powershell
ffmpeg -hide_banner -y -fflags +genpts -i 明文.ts -c copy -movflags +faststart out.mp4
```

- `-c copy`：视频音频都不重编码，画质零损失
- `-fflags +genpts`：TS 的时间戳可能有空洞，重新生成 PTS
- mp4 复用器会自行处理 AAC 的 `ADTS -> ASC` 转换，不需要额外参数

## 无损重封装（负载还原路径）

还原脚本会输出裸 H.264（Annex-B 起始码）与音频 ADTS-AAC，然后：

```powershell
ffmpeg -y -hide_banner -v error -r <fps> -i out.h264 -i out.aac `
      -c:v copy -c:a copy -movflags +faststart out.mp4
```

`fps` 从原容器的 `mdhd.timescale` 与 `stts` 最常见 delta 推出，脚本会打印 `FPS=`。

## 几个容易踩的点

**① 末帧 DTS 提示**
源里有 B 帧重排时，封装到 mp4 后复用器会对**最后两帧**抱怨一次：

```
Application provided invalid, non monotonically increasing dts to muxer in stream 0: 11142 >= 11142
```

这**无害**：容器本身是完整的（`stsz` 样本数与源分毫不差、时长正确）。
校验脚本会把这条过滤掉；用 `-f null -` 解码时它也会出现，别被它误导。

**② 时长对不上**
若是"帧数正确但时长错"，通常是把容器帧率当成固定帧率强行套用。
优先从源容器的 `stts` 推帧率，而不是硬编码。

**③ 样本表读取**
MP4 的样本-文件偏移要靠 `stsc` + `stco/co64` + `stsz` 三者一起算：

```
按 stsc 描述把 chunk 切成若干个"每个 chunk 含 N 个样本"的组，
再按 stco 给出的 chunk 偏移逐样本累加 stsz 长度。
```

脚本 `src/payload_restore.py` 里的 `video_samples()` / `audio_samples()` 就是这套逻辑。

**④ `avcC` 的解析**
`avcC` 里的 SPS/PPS 是**完整 NAL**（自带 `0x67` / `0x68` 头），不要再补；
结构是 `[4字节' avcC'][version][profile][compat][level][lengthSize][numSPS][u16 长度 + SPS]…`
—— 那个 `numSPS` 字节很容易漏，漏了就会把长度字段当成数据。
