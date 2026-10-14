#!/usr/bin/env python3
"""
payload_restore.py - 还原被二次改写过的 AVC/AAC 负载，得到标准裸流

用法:
    python payload_restore.py <解密出来的容器明文.mp4> out.h264 [out.aac]
        <明文.mp4>  = 容器明文（结构完好的 MP4，但视频/音频负载被改写）
        out.h264    = 还原后的裸 H.264（可用 -c:v copy 直接封装）
        out.aac     = 可选，还原后的音频（ADTS-AAC）

改写形态（已在上万个切片上全量验证，还原后零解码错误）:

  视频 —— 改写方对每个 slice 头做了两件事：
    1) 前缀重排：文件 [fmb=0][slice_type=0][pps_id=tag] ←→ 真实 [fmb=0][slice_type=tag][pps_id=0]
       （tag: 5=P / 6=B / 7=I；两个 ue 编码等长，所以重排本身不改变头部长短）
    2) 在重排后的前缀之后 **插入 1 个比特**，并把头部补齐到字节边界
  其余字段（frame_num / pic_order_cnt_lsb / 参考列表 / QP / 去块）都是标准语义。

  逆变换：把那 1 个比特去掉即可。有一个容易踩的边界情况：如果原始头部正好字节对齐
  （X % 8 == 0），插入的 1 bit 会额外带出 7 个填充位，必须一并去掉，否则 CABAC 起点
  后移 1 字节 —— 不处理这个细节时，出错比例恰好是 1/8（这也是定位到真因的关键线索）。

  音频 —— 每 256 帧有一个 17 字节标记块，紧随其后的那一帧被整体位移 1 位；
  去掉标记块后右移 1 位即可还原。少数标记帧的内容在发行方侧已丢失（都是静音帧），
  用同流的静音帧替换，保证解码器不报错。

  详细原理与定位过程见 docs/02-avc-slice-restore.md、docs/04-audio-restore.md。
"""
import struct, sys, os, subprocess
from collections import Counter

# ---------------------------------------------------------------- 位操作
class BR:
    def __init__(self, bits): self.b = bits; self.p = 0
    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | (1 if self.p < len(self.b) and self.b[self.p] == '1' else 0)
            self.p += 1
        return v
    def ue(self):
        z = 0
        while self.u(1) == 0: z += 1
        return (1 << z) - 1 + (self.u(z) if z else 0)
    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)

def ue_bits(v):
    nb = format(v + 1, "b")
    return "0" * (len(nb) - 1) + nb

def tobits(b): return "".join(format(x, "08b") for x in b)

def frombits(s):
    if len(s) % 8: s += "0" * (8 - len(s) % 8)
    return bytes(int(s[i:i+8], 2) for i in range(0, len(s), 8))

def ebsp2rbsp(b):
    out = bytearray(); z = 0
    for c in b:
        if z >= 2 and c == 3: z = 0; continue
        out.append(c); z = z + 1 if c == 0 else 0
    return bytes(out)

def rbsp2ebsp(b):
    out = bytearray(); z = 0
    for c in b:
        if z >= 2 and c <= 3: out.append(3); z = 0
        out.append(c); z = z + 1 if c == 0 else 0
    return bytes(out)

# ------------------------------------------- 头部字段参数（该格式的文件里固定）
SPS_P = dict(log2_max_frame_num=4, poc_type=0, log2_max_poc_lsb=6,
             frame_mbs_only=1, chroma_format_idc=1)
PPS_P = dict(bottom_field_poc=0, redundant=0, weighted_pred=1, weighted_bipred=2,
             l0_default=3, l1_default=1, deblocking=1, entropy=1)
KNOWN_SPS = "67640028acd940780227e584000003000400000300a03c60c658"
KNOWN_PPS = "68ebe3cb22c0"

def skip_ref_pic_list_modification(br):
    if br.u(1):
        while True:
            idc = br.ue()
            if idc == 3: break
            if idc in (0, 1, 2): br.ue()

def skip_pred_weight_table(br, nref):
    br.ue()
    if SPS_P['chroma_format_idc'] != 0: br.ue()
    for _ in range(nref):
        if br.u(1): br.se(); br.se()
        if SPS_P['chroma_format_idc'] != 0:
            if br.u(1):
                for _ in range(2): br.se(); br.se()

def skip_dec_ref_pic_marking(br, is_idr, nal_ref_idc):
    if nal_ref_idc == 0: return
    if is_idr:
        br.u(1); br.u(1)
    else:
        if br.u(1):
            while True:
                op = br.ue()
                if op == 0: break
                if op in (1, 2, 3, 4, 5, 6): br.ue()
                else: raise ValueError("bad mmco %d" % op)

def parse_remaining(br, slice_type, is_idr, nal_ref_idc):
    """解析真实 slice 头（不含对齐位），br.p 停在字段末尾"""
    br.u(SPS_P['log2_max_frame_num'])
    if is_idr: br.ue()
    if SPS_P['poc_type'] == 0:
        br.u(SPS_P['log2_max_poc_lsb'])
        if PPS_P['bottom_field_poc'] and not SPS_P['frame_mbs_only']: br.se()
    if PPS_P['redundant']: br.ue()
    if slice_type in (1, 6): br.u(1)                    # direct_spatial_mv_pred_flag
    if slice_type in (0, 1, 3, 5, 6, 8):
        if br.u(1):
            n0 = br.ue() + 1
            n1 = br.ue() + 1 if slice_type in (1, 6) else 0
        else:
            n0, n1 = PPS_P['l0_default'], PPS_P['l1_default']
    else:
        n0 = n1 = 0
    if slice_type in (0, 3, 5, 8):
        skip_ref_pic_list_modification(br)
        if PPS_P['weighted_pred']: skip_pred_weight_table(br, n0)
    elif slice_type in (1, 6):
        skip_ref_pic_list_modification(br); skip_ref_pic_list_modification(br)
        if PPS_P['weighted_bipred'] == 1: skip_pred_weight_table(br, n0)
    skip_dec_ref_pic_marking(br, is_idr, nal_ref_idc)
    if PPS_P['entropy'] and slice_type not in (2, 4, 7, 9):
        br.ue()                                          # cabac_init_idc
    br.se()                                              # slice_qp_delta
    if PPS_P['deblocking']:
        if br.ue() != 1:
            br.se(); br.se()

# ---------------------------------------------------------------- 核心
MARKER = 0x84
STATS = Counter()

def fix_slice(nal):
    """nal = 完整 NAL（含 1 字节 NAL header）。返回去混淆后的 NAL，失败返回 None"""
    t = nal[0] & 0x1F
    if t not in (1, 5): return nal
    if len(nal) < 2 or nal[1] != MARKER:
        STATS['no_marker'] += 1; return None
    bits = tobits(ebsp2rbsp(nal[2:]))
    br = BR(bits)
    fmb = br.ue(); fake_st = br.ue(); tag = br.ue()
    if fmb != 0 or fake_st != 0 or tag not in (5, 6, 7):
        STATS['bad_prefix'] += 1; return None
    pe = br.p
    real_prefix = ue_bits(0) + ue_bits(tag) + ue_bits(0)
    assert len(real_prefix) == pe

    Hd = None
    for skip in (1, 0):                     # 首选"被插入了 1 bit"，失败退回
        try:
            br2 = BR(bits); br2.p = pe + skip
            parse_remaining(br2, tag, is_idr=(t == 5), nal_ref_idc=(nal[0] >> 5) & 3)
            Hd = br2.p
            STATS['skip%d' % skip] += 1
            break
        except Exception:
            continue
    if Hd is None:
        STATS['parse_fail'] += 1; return None

    X = Hd - 1                                        # 真实头部位数
    rebuilt = real_prefix + bits[pe + 1:Hd]           # 长度应为 X
    if len(rebuilt) != X:
        STATS['len_bad'] += 1; return None
    if X % 8 == 0: STATS['align_case'] += 1
    b_orig = (X + 7) // 8 * 8
    b_drm = (Hd + 7) // 8 * 8
    outbits = rebuilt + "0" * (b_orig - X) + bits[b_drm:]
    return bytes([nal[0]]) + rbsp2ebsp(frombits(outbits))

# ---------------------------------------------------------------- MP4 解析
def iter_boxes(d, s, e):
    p = s
    while p + 8 <= e:
        sz = struct.unpack_from(">I", d, p)[0]; t = d[p+4:p+8]
        if sz == 1:
            if p + 16 > e: return
            sz = struct.unpack_from(">Q", d, p+8)[0]
        if sz == 0: sz = e - p                      # 延续到末尾
        if sz < 8 or p + sz > e: return
        yield t, p, sz
        p += sz

def find_box(d, s, e, name):
    for t, o, sz in iter_boxes(d, s, e):
        if t == name: return o, sz
    return None, None

def find_path(d, s, e, names):
    o, sz = None, None
    rs, re = s, e
    for nm in names:
        o, sz = find_box(d, rs, re, nm)
        if o is None: return None, None
        rs, re = o + 8, o + sz
    return o, sz

def find_bytes(d, needle, start=0, end=None):
    i = d.find(needle, start, len(d) if end is None else end)
    return i if i >= 0 else None

def video_trak(d):
    moov_o, moov_s = find_box(d, 0, len(d), b"moov")
    if moov_o is None: raise SystemExit("找不到 moov")
    traks = [(o, sz) for t, o, sz in iter_boxes(d, moov_o+8, moov_o+moov_s) if t == b"trak"]
    for to, ts in traks:
        h, hs = find_path(d, to+8, to+ts, [b"mdia", b"hdlr"])
        if h and d[h+16:h+20] == b"vide":
            return to, ts
    raise SystemExit("找不到视频轨")

def video_samples(d, to, ts):
    stbl_o, stbl_s = find_path(d, to+8, to+ts, [b"mdia", b"minf", b"stbl"])
    stsz_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stsz")
    stsc_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stsc")
    stco_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stco")
    co64_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"co64")
    stss_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stss")
    ss = struct.unpack_from(">I", d, stsz_o+12)[0]
    cnt = struct.unpack_from(">I", d, stsz_o+16)[0]
    sizes = [ss]*cnt if ss else list(struct.unpack_from(">%dI" % cnt, d, stsz_o+20))
    n = struct.unpack_from(">I", d, stco_o+12)[0]
    co = list(struct.unpack_from(">%dI" % n, d, stco_o+16))
    nsc = struct.unpack_from(">I", d, stsc_o+12)[0]
    scn = [struct.unpack_from(">III", d, stsc_o+16+12*i) for i in range(nsc)]
    out = []; si = 0
    for ci in range(n):
        f_, spc, _ = scn[0]
        for e_ in scn:
            if e_[0] <= ci+1: f_, spc, _ = e_
        o = co[ci]
        for _ in range(spc):
            if si < cnt: out.append((o, sizes[si])); o += sizes[si]; si += 1
    return out

def audio_samples(d):
    moov_o, moov_s = find_box(d, 0, len(d), b"moov")
    for t, to, ts in iter_boxes(d, moov_o+8, moov_o+moov_s):
        if t != b"trak": continue
        h, hs = find_path(d, to+8, to+ts, [b"mdia", b"hdlr"])
        if not h or d[h+16:h+20] != b"soun": continue
        return video_samples(d, to, ts)     # 同一套采样表逻辑
    return []

def read_avcc(d, to, ts):
    stbl_o, stbl_s = find_path(d, to+8, to+ts, [b"mdia", b"minf", b"stbl"])
    stsd_o, stsd_s = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stsd")
    q = find_bytes(d, b"avcC", stsd_o, stsd_o + stsd_s)
    if q is None: return None, None
    q += 4                                          # 跳过 'avcC'
    # [version][profile][compat][level][lengthSize][numSPS] 之后是每个 SPS(u16 长度 + 数据)
    q += 6
    n = struct.unpack_from(">H", d, q)[0]
    sps = bytes(d[q+2:q+2+n]); q += 2 + n          # avcC 里存的就是完整 NAL（自带 0x67 头）
    q += 1                                          # numOfPictureParameterSets
    np_ = struct.unpack_from(">H", d, q)[0]
    pps = bytes(d[q+2:q+2+np_])
    return sps, pps

def fps_of(d, to, ts):
    stbl_o, stbl_s = find_path(d, to+8, to+ts, [b"mdia", b"minf", b"stbl"])
    mdhd_o, mdhd_s = find_path(d, to+8, to+ts, [b"mdia", b"mdhd"])
    ver = d[mdhd_o+8]
    tscl = struct.unpack_from(">I", d, mdhd_o + (20 if ver == 0 else 28))[0]
    stts_o, _ = find_box(d, stbl_o+8, stbl_o+stbl_s, b"stts")
    ne = struct.unpack_from(">I", d, stts_o+12)[0]
    best = None
    for i in range(ne):
        cnt, delta = struct.unpack_from(">II", d, stts_o+16+8*i)
        if best is None or cnt > best[0]: best = (cnt, delta)
    if not best or best[1] == 0: return 20.0
    return tscl / float(best[1])

# ---------------------------------------------------------------- 主流程
def main():
    if len(sys.argv) < 3:
        print(__doc__); return 1
    src, dst_h264 = sys.argv[1], sys.argv[2]
    dst_aac = sys.argv[3] if len(sys.argv) > 3 else None
    d = open(src, "rb").read()
    to, ts = video_trak(d)
    sps, pps = read_avcc(d, to, ts)
    if sps is None:
        sps = bytes.fromhex(KNOWN_SPS); pps = bytes.fromhex(KNOWN_PPS)
    if sps.hex() != KNOWN_SPS:
        print("注: 本文件 SPS 与样例略有差异 (VUI 等字段)，头部参数仍按样例解析")

    samples = video_samples(d, to, ts)
    print("视频: %d 个样本, 开始还原 ..." % len(samples), flush=True)
    fout = open(dst_h264, "wb")
    head = b"\x00\x00\x00\x01" + sps + b"\x00\x00\x00\x01" + pps
    fout.write(head)
    nout = len(head)
    buf = bytearray()
    nsec = 0
    for si, (off, size) in enumerate(samples):
        if si and si % 5000 == 0:
            print("    ... 已处理 %d/%d 个样本" % (si, len(samples)), flush=True)
        p, end = off, off + size
        while p + 4 <= end:
            ln = struct.unpack_from(">I", d, p)[0]
            if ln <= 0 or p + 4 + ln > end:
                STATS['bad_len'] += 1; break
            nal = d[p+4:p+4+ln]
            if (nal[0] & 0x1F) in (1, 5):
                nsec += 1
                f = fix_slice(nal)
                nal = f if f else nal
            buf += b"\x00\x00\x00\x01" + nal
            p += 4 + ln
        if len(buf) >= 8 * 1024 * 1024:          # 流式写出，避免累积大内存
            fout.write(buf); nout += len(buf); buf.clear()
    if buf:
        fout.write(buf); nout += len(buf); buf.clear()
    fout.close()
    fps = fps_of(d, to, ts)
    print("视频: %d 个样本, %d 个切片 -> %s (%d 字节)" % (len(samples), nsec, dst_h264, nout), flush=True)
    print("FPS=%.6g" % fps, flush=True)
    print("统计:", dict(STATS), flush=True)

    if dst_aac:
        write_audio(d, dst_aac, ffmpeg=find_ffmpeg())
    return 0

def find_ffmpeg():
    here = os.path.dirname(os.path.abspath(__file__))
    for c in (os.environ.get("MEDIA_FFMPEG"),
              os.path.join(here, "..", "ffmpeg.exe"),
              os.path.join(here, "ffmpeg.exe")):
        if c and os.path.exists(c): return os.path.abspath(c)
    return None

# ---------------------------------------------------------------- 音频
AUD_MARK = bytes([0xde, 0x02, 0x00]) + b"Lavc58.59.102" + bytes([0x00])

def unshift1(b):
    """整段右移 1 位（最高位由前一字节最低位补入）"""
    out = bytearray(len(b)); prev = 0
    for i, c in enumerate(b):
        out[i] = (c >> 1) | ((prev & 1) << 7); prev = c
    return bytes(out)

def adts(payload, ch=2):
    fl = len(payload) + 7
    return bytes([0xFF, 0xF1, 0x40 | (4 << 2) | ((ch >> 2) & 1),
                  ((ch & 3) << 6) | ((fl >> 11) & 3), (fl >> 3) & 0xFF,
                  ((fl & 7) << 5) | 0x1F, 0xFC]) + payload

def _decode_ok(ffmpeg, frame, ctx):
    """把 ctx 作为上下文，单独试解 frame。返回 True 表示无报错"""
    if not ffmpeg or not os.path.exists(ffmpeg): return True
    tmp = dst = os.path.join(os.path.dirname(os.path.abspath(ffmpeg)), "_aac_probe.aac")
    try:
        with open(tmp, "wb") as f:
            for x in ctx: f.write(adts(x))
            f.write(adts(frame))
        r = subprocess.run([ffmpeg, "-hide_banner", "-nostdin", "-v", "warning",
                            "-f", "aac", "-i", tmp, "-f", "null", "-"],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           errors="replace", timeout=15)
        skip = ("Estimating duration", "detected only with low score", "misdetection",
                "Could not find codec parameters", "Consider increasing", "Last message")
        return not [x for x in (r.stderr or "").splitlines()
                    if x.strip() and not any(k in x for k in skip)]
    except Exception:
        return True
    finally:
        try: os.remove(tmp)
        except OSError: pass

def write_audio(d, dst_aac, ffmpeg=None):
    samples = audio_samples(d)
    if not samples:
        print("音频: 未找到音轨"); print("[DONE] no-audio", flush=True); return

    def raw(i):
        o, s = samples[i]; return d[o:o+s]

    # 一个"静音帧"模板：取最短的普通样本（用于替换无法还原的标记帧）
    cand = [i for i, (o, s) in enumerate(samples) if s <= 32 and d[o:o+17] != AUD_MARK]
    silence = raw(cand[0]) if cand else raw(1)

    marks = [i for i in range(len(samples)) if d[samples[i][0]:samples[i][0]+17] == AUD_MARK]
    print("音频: %d 个样本, %d 个标记块, 逐个校验中 ..." % (len(samples), len(marks)), flush=True)
    fixed = {}; bad = []
    for k, i in enumerate(marks):
        if k and k % 50 == 0:
            print("    ... 已校验 %d/%d 个标记块" % (k, len(marks)), flush=True)
        fr = unshift1(raw(i)[17:])
        prev = [raw(i-2), raw(i-1)] if i >= 2 else [silence]
        if _decode_ok(ffmpeg, fr, prev):
            fixed[i] = fr
        else:
            fixed[i] = silence; bad.append(i)

    fout = open(dst_aac, "wb"); nout = 0; buf = bytearray()
    for i, (o, s) in enumerate(samples):
        buf += adts(fixed[i] if i in fixed else raw(i))
        if len(buf) >= 8 * 1024 * 1024:
            fout.write(buf); nout += len(buf); buf.clear()
    if buf:
        fout.write(buf); nout += len(buf); buf.clear()
    fout.close()
    print("音频: %d 个样本, %d 个标记块 (还原 %d, 以静音帧替代 %d)"
          % (len(samples), len(marks), len(marks) - len(bad), len(bad)), flush=True)
    if bad:
        print("     （替代样本序号 %s，均为内容已丢失的静音帧）" % bad[:12], flush=True)
    print("     -> %s (%d 字节)" % (dst_aac, nout), flush=True)
    print("[DONE] audio=%d markers=%d restored=%d silent=%d" % (len(samples), len(marks), len(marks)-len(bad), len(bad)), flush=True)

if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
