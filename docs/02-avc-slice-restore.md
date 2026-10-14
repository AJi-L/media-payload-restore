# 02 · AVC slice 头还原：那个被插入的比特

这是整个项目里最难、也最关键的一块。结论先行：

> 改写方对每个 slice 头做了三件事 ——
> ① 在前面加 1 字节 `0x84`；
> ② 把 `slice_type` 和 `pic_parameter_set_id` 两个字段的**值互换**；
> ③ 在重排后的前缀之后**插入 1 个比特**，并把头部补齐到字节边界。
>
> **把 ③ 的 1 个比特去掉，一切就都对了。** ①②③ 之外的字段全是标准语义。

---

## 1. 现象

容器结构完全正常（`stsz`/`stsc`/`stco`/`stts` 自洽，样本长度框架 100% 对得上），
但解码器不认：

```
[h264] non-existing PPS 0 referenced      <- avcC 里只声明了 PPS 0，码流却引用 5/6/7
[h264] A non-intra slice in an IDR NAL unit
[h264] decode_slice_header error
[h264] no frame!
```

去掉每个 slice 前的 `0x84` 之后，头部立刻能解析出"看着很合理"的值，
但总有约四分之一的切片从 `slice_qp_delta` 之后开始错位，
解析出 `disable_deblocking_filter_idc = 15` 这类非法值；
解码侧则表现为：

```
[h264] Reference 4 >= 4                 <- 出现率恰好 12.14% ≈ 1/8
[h264] Missing reference picture, default is 65
[h264] corrupt decoded frame
```

## 2. 两个已经确认的事实

**① 每个 slice 前面多 1 字节 `0x84`**（SEI 包没有，全量统计无一例外）：

```
文件 slice 负载 = [0x84] [slice 头 ...] [对齐位] [CABAC]
```

**② 头部前缀两个字段值互换**：

```
文件: [first_mb_in_slice=0][slice_type=0][pps_id=tag]
真实: [first_mb_in_slice=0][slice_type=tag][pps_id=0]
```

其中 `tag` 是帧类型标记：**5 = P、6 = B、7 = I**。

为什么前缀互换"看起来不改变长度"？因为 `slice_type` 与 `pps_id` 都是 ue(v) 编码，
而 `tag`（5/6/7）与 `0` 的 ue 长度凑巧互补：

| | slice_type 的 ue 长度 | pps_id 的 ue 长度 | 合计 |
|---|---|---|---|
| 文件 | `ue(0)` = 1 bit | `ue(tag)` = 5 或 7 bit | 6 / 8 bit |
| 真实 | `ue(tag)` = 5 或 7 bit | `ue(0)` = 1 bit | 6 / 8 bit |

所以**只做前缀互换的话，头部长短不变、CABAC 起点不变** —— 这也是为什么
"改完前缀后 IDR 帧竟然能解出真实画面"，让人误以为大功告成。

## 3. 关键一步：用 `frame_num` 当探针扫比特偏移

剩下的错位说明"某个地方少了/多了一个比特"。与其猜，不如**穷举**：

> 对每种切片类型，在**前缀之后**依次多跳 k 个比特，然后解析 `frame_num`，
> 看哪个 k 能得到"应该有的值"。

一个 IDR 的 `frame_num` 按标准**必须是 0**，紧随其后的第一个 P 帧应当是 1：

| k（前缀后跳过的比特数） | IDR 解析结果 | 第 1 个 P 帧 | 判断 |
|---|---|---|---|
| 0 | `frame_num=8`, `idr_pic_id=1` | `frame_num=8` | ✗ IDR 的帧号必须是 0 |
| **1** | **`frame_num=0`, `idr_pic_id=0`, `poc=0`** | **`frame_num=1`, `poc=8`** | ✓ 全部合理 |
| 2 | `frame_num=1`, `idr_pic_id=2040` | `frame_num=2` | ✗ 明显发散 |

**k = 1。** 也就是说：文件里前缀之后被**插入了 1 个比特**，真实头部从"前缀 + 1 bit"
之后开始。

同一份实验还能顺带解释一堆旧谜团：`frame_num=8` 会让解码器判定"帧号跳变"，
于是插入假帧，把只有 4 个槽位的 DPB 冲爆 —— 后面的参考帧全没了，
`Missing reference picture` 随之而来。

## 4. 逆变换与"1/8 陷阱"

```python
# 伪码：nal = 完整 NAL（含 1 字节 NAL header），nal[1] == 0x84
bits        = rbsp(nal[2:])                  # 去掉标记字节
fmb, st, tag = ue(bits), ue(bits), ue(bits)  # 读出被换过位置的前缀
pe          = 前缀结束位置

real_prefix = ue(0) + ue(tag) + ue(0)        # 换回来（长度与文件里一致）

# 从头字段区（pe+1 起，跳过被插入的那 1 bit）解析到字段结束
Hd = parse_slice_header(bits, start=pe + 1)   # 返回"文件头部"的比特数
X  = Hd - 1                                   # 真实头部的比特数

rebuilt = real_prefix + bits[pe+1 : Hd]       # 长度 == X
b_orig  = ceil8(X)                            # 真实头部补齐后的字节边界
b_used  = ceil8(Hd)                           # 文件里实际使用的字节边界
out     = rebuilt + "0" * (b_orig - X) + bits[b_used:]   # 剩下的是 CABAC
```

**陷阱在这里**：如果 `X % 8 == 0`（真实头部正好字节对齐、本不需要填充位），
那么插入 1 bit 之后，厂商为了对齐要补 **7 个** 零比特：

```
X % 8 != 0 :  ceil8(X) == ceil8(X+1)      -> 直接丢 1 bit
X % 8 == 0 :  ceil8(X+1) == X + 8         -> 要丢 1 + 7 个比特
```

第二种情况下若只丢 1 bit，CABAC 起点会**后移整整 1 字节**，该切片必然解错。
而这种情况出现的概率正好是 **1/8 = 12.5%** —— 与当初观测到的
`Reference 4 >= 4` 报错率 12.14% 对上了。**这个数字本身就是定位真因的证据。**

## 5. 走过的弯路（值得一读）

在找到"插入 1 比特"之前，一系列"看起来有效"的补丁其实都在补偿这 1 个比特：

| 当时的"结论" | 真相 |
|---|---|
| PPS 的 `weighted_pred_flag` 必须从 1 改成 0，否则解不出 | **不用改**。文件里的 PPS 是对的；改成 0 恰好掩盖了头部错位 |
| `pic_init_qp_minus26` 要从 -3 改成 -5 来补偿 QP | **不用改**。原来的 -3 正确 |
| B 帧必须额外再丢 1 bit | **不用**。三种切片类型统一丢那 1 bit 即可 |
| IDR 的 `frame_num=8` 是编码器特性 | 是被**错位读出来**的；真实值是 0 |

这些补丁都能让"一部分"切片解对，因此具有很强的欺骗性：
它们把问题从"系统性错位 1 bit"降级成了"约 1/8 的随机失败"，
看起来像"参考帧管理有问题"，从而把排查引向错误方向。

**教训**：当"某些字段解析出的值看着合理、但后面莫名错位"时，
优先怀疑**比特对齐**，而不是逐个字段去猜语义。

## 6. 验证

还原后按标准 AVC 直接 `-c:v copy` 封装，全片解码校验：

| 素材规模 | 切片还原 | 全片 `-v error` |
|---|---|---|
| 1.1 万切片 | 11145 / 11145 | **0 行** |
| 1.5 万切片 | 15105 / 15105 | **0 行** |
| 3.0 万切片 | 29846 / 29846 | **0 行** |
| 4.1 万切片 | 41010 / 41010 | **0 行** |

（累计 400+ 个文件、数十万切片，还原后均为零解码错误。）

## 7. 复现

```bash
python src/payload_restore.py 明文.mp4 out.h264 out.aac
ffmpeg -r <fps> -i out.h264 -i out.aac -c:v copy -c:a copy -movflags +faststart out.mp4
```

`fps` 可从容器 `mdhd.timescale / stts.delta` 推出（脚本会打印 `FPS=`）。
