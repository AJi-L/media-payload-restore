/* avformat-58.dll proxy with probes.
   Forwards all exports to the renamed original and implements a handful of
   functions in C so we can log how the player drives FFmpeg and dump the
   decrypted (plaintext) stream.

   Build: gcc -m32 -O2 -shared -o avformat-58.dll proxy.c gen.c gen.S gen.def
*/
#include <windows.h>
#include <stdarg.h>

typedef struct AVIOContext   AVIOContext;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVPacket      AVPacket;
typedef struct AVInputFormat AVInputFormat;
typedef struct AVDictionary  AVDictionary;
typedef struct AVIOInterruptCB { int (*callback)(void *); void *opaque; } AVIOInterruptCB;

typedef int  (*ReadPacket)(void *opaque, unsigned char *buf, int buf_size);
typedef int  (*WritePacket)(void *opaque, unsigned char *buf, int buf_size);
typedef long long (*SeekFn)(void *opaque, long long offset, int whence);
typedef AVIOContext *(*t_alloc_ctx)(unsigned char *, int, int, void *, ReadPacket, WritePacket, SeekFn);
typedef int      (*t_open_input)(AVFormatContext **, const char *, const AVInputFormat *, AVDictionary **);
typedef int      (*t_find_stream_info)(AVFormatContext *, AVDictionary **);
typedef void     (*t_close_input)(AVFormatContext **);
typedef int      (*t_read_frame)(AVFormatContext *, AVPacket *);
typedef int      (*t_seek_frame)(AVFormatContext *, int, long long, int);
typedef int      (*t_avio_read)(AVIOContext *, unsigned char *, int);
typedef int      (*t_avio_open2)(AVIOContext **, const char *, int, const AVIOInterruptCB *, AVDictionary **);
typedef int      (*t_avio_open)(AVIOContext **, const char *, int);
typedef void     (*t_ctx_free)(AVIOContext **);
typedef long long (*t_avio_seek)(AVIOContext *, long long, int);
typedef long long (*t_avio_size)(AVIOContext *);
typedef int      (*t_probe)(AVIOContext *, AVInputFormat **, const char *, void *, unsigned int, unsigned int);
typedef AVFormatContext *(*t_fmt_alloc)(void);
typedef void     (*t_fmt_free)(AVFormatContext *);
typedef int      (*t_best_stream)(AVFormatContext *, int, int, int, void **, int);

extern const char *g_names[];
extern void **g_slot_ptrs[];
extern int g_nslots;
extern void **g_hook_slot(void);

static t_alloc_ctx   real_alloc;
static t_open_input  real_open_input;
static t_find_stream_info real_find_stream_info;
static t_close_input real_close_input;
static t_read_frame  real_read_frame;
static t_seek_frame  real_seek_frame;
static t_avio_read   real_avio_read;
static t_avio_open   real_avio_open;
static t_avio_open2  real_avio_open2;
static t_ctx_free    real_ctx_free;
static t_avio_seek   real_avio_seek;
static t_avio_size   real_avio_size;
static t_probe       real_probe;
static t_fmt_alloc   real_fmt_alloc;
static t_fmt_free    real_fmt_free;
static t_best_stream real_best_stream;

static LONG g_dump_n = 0;
/* 明文 dump 的输出目录：默认写到进程当前目录（= 播放器所在目录）。
   可以用环境变量 MEDIA_DUMP_DIR 覆盖，脚本侧据此找文件。 */
#ifndef DUMP_DIR
#define DUMP_DIR ".\\"
#endif
#define LOG_PATH DUMP_DIR "proxy_log.txt"

static void logmsg(const char *fmt, ...)
{
    char buf[1024];
    int n;
    va_list ap;
    va_start(ap, fmt);
    n = wvsprintfA(buf, fmt, ap);
    va_end(ap);
    {
        HANDLE h = CreateFileA(LOG_PATH, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD w;
            SetFilePointer(h, 0, NULL, FILE_END);
            WriteFile(h, buf, (DWORD)n, &w, NULL);
            WriteFile(h, "\r\n", 2, &w, NULL);
            CloseHandle(h);
        }
    }
}

static HANDLE open_dump(const char *fmt, int idx)
{
    char path[300];
    wsprintfA(path, fmt, idx);
    return CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static int mem_ok(void *p, unsigned size)
{
    MEMORY_BASIC_INFORMATION mbi;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if ((unsigned char *)p + size > (unsigned char *)mbi.BaseAddress + mbi.RegionSize) return 0;
    return 1;
}

/* avutil module range, used to recognize an AVClass pointer */
static unsigned int g_avutil_lo, g_avutil_hi;

static AVIOContext *guess_pb(AVFormatContext *ic)
{
    unsigned int *p = (unsigned int *)ic;
    int i;
    if (!mem_ok(ic, 64)) return 0;
    for (i = 0; i < 16; i++) {
        unsigned int cand = p[i];
        if (cand < 0x10000) continue;
        if (!mem_ok((void *)cand, 8)) continue;
        {
            unsigned int v = *(unsigned int *)cand;
            if (v >= g_avutil_lo && v < g_avutil_hi) return (AVIOContext *)cand;
        }
    }
    return 0;
}

/* ---------------- capture / passive dump ---------------- */
#define MAXCTX 8
static struct { AVIOContext *ctx; void *opaque; ReadPacket rp; } g_ctx[MAXCTX];
static int g_nctx = 0;
static CRITICAL_SECTION g_cs;

static int find_ctx(void *opaque)
{
    int i, best = -1;
    for (i = 0; i < g_nctx; i++) if (g_ctx[i].opaque == opaque) best = i;
    if (best < 0 && g_nctx == 1) best = 0;
    return best;
}

static HANDLE g_passive = INVALID_HANDLE_VALUE;
static void passive_write(unsigned char *buf, int n)
{
    if (g_passive == INVALID_HANDLE_VALUE)
        g_passive = CreateFileA(DUMP_DIR "plain_passive.bin", GENERIC_WRITE,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_passive != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(g_passive, buf, (DWORD)n, &w, NULL); }
}

static int hook_read_packet(void *opaque, unsigned char *buf, int buf_size)
{
    int idx = find_ctx(opaque), r;
    if (idx < 0) return -1;
    r = g_ctx[idx].rp(opaque, buf, buf_size);
    if (r > 0) passive_write(buf, r);
    return r;
}

/* ---------------- exported implementations ---------------- */

AVIOContext *avio_alloc_context(unsigned char *buffer, int buffer_size, int write_flag,
                                void *opaque, ReadPacket rp, WritePacket wp, SeekFn seek)
{
    AVIOContext *ctx;
    if (!real_alloc) return 0;
    ctx = real_alloc(buffer, buffer_size, write_flag, opaque, rp, wp, seek);
    logmsg("avio_alloc_context(buf=%x,size=%d,write=%d,opaque=%x,rp=%x,seek=%x)->%x",
           (unsigned)buffer, buffer_size, write_flag, (unsigned)opaque, (unsigned)rp,
           (unsigned)seek, (unsigned)ctx);
    if (!ctx || !rp || write_flag) return ctx;
    EnterCriticalSection(&g_cs);
    if (g_nctx < MAXCTX) {
        g_ctx[g_nctx].ctx = ctx; g_ctx[g_nctx].opaque = opaque; g_ctx[g_nctx].rp = rp; g_nctx++;
    }
    LeaveCriticalSection(&g_cs);
    /* also passively mirror via read_packet */
    {
        unsigned int *p = (unsigned int *)ctx;
        int i;
        for (i = 0; i < 32; i++)
            if (p[i] == (unsigned int)rp) {
                DWORD op;
                if (VirtualProtect(&p[i], 4, PAGE_READWRITE, &op)) {
                    p[i] = (unsigned int)hook_read_packet;
                    VirtualProtect(&p[i], 4, op, &op);
                }
                logmsg("read_packet wrapper installed at ctx+%d", i * 4);
                break;
            }
    }
    return ctx;
}

AVFormatContext *avformat_alloc_context(void)
{
    AVFormatContext *c = real_fmt_alloc ? real_fmt_alloc() : 0;
    logmsg("avformat_alloc_context -> %x", (unsigned)c);
    return c;
}

void avformat_free_context(AVFormatContext *c)
{
    logmsg("avformat_free_context(%x)", (unsigned)c);
    if (real_fmt_free) real_fmt_free(c);
}

void avio_context_free(AVIOContext **s)
{
    logmsg("avio_context_free(%x)", (unsigned)s);
    if (real_ctx_free) real_ctx_free(s);
}

int avformat_open_input(AVFormatContext **ps, const char *url, const AVInputFormat *fmt,
                        AVDictionary **options)
{
    int r;
    AVIOContext *pb;
    logmsg("avformat_open_input(url=%s, fmt=%x, *ps=%x)", url ? url : "(null)",
           (unsigned)fmt, (unsigned)(ps ? *ps : 0));
    r = real_open_input ? real_open_input(ps, url, fmt, options) : -1;
    logmsg("  -> ret=%d, *ps=%x", r, (unsigned)(ps ? *ps : 0));

    /* AVFormatContext.pb is the 5th pointer (offset 16 on 32-bit ffmpeg 4.x) */
    pb = (ps && *ps) ? *(AVIOContext **)((char *)*ps + 16) : 0;
    logmsg("  pb=%x ok=%d", (unsigned)pb, pb ? mem_ok(pb, 64) : 0);

    if (pb && mem_ok((void *)pb, 96)) {
        unsigned int *q = (unsigned int *)pb;
        int i;
        char line[256];
        int ln = 0;
        for (i = 0; i < 12; i++)
            ln += wsprintfA(line + ln, "%x ", q[i]);
        logmsg("  avioctx[0..11]: %s", line);
        logmsg("  avio_size=%d seekable(hdr)=%d", (int)(real_avio_size ? real_avio_size(pb) : -1),
               (int)q[0]);
    }

    if (r >= 0 && pb && mem_ok((void *)pb, 64) && real_avio_read && g_dump_n < 3) {
        int n = (int)InterlockedIncrement(&g_dump_n);
        HANDLE h;
        unsigned char *tmp;
        long long total = 0;
        int rc = 0;
        h = open_dump(DUMP_DIR "decrypted_%d.bin", n);
        tmp = (unsigned char *)HeapAlloc(GetProcessHeap(), 0, 1 << 20);
        if (real_avio_seek) logmsg("  seek(0) -> %d", (int)real_avio_seek(pb, 0, SEEK_SET));
        if (h != INVALID_HANDLE_VALUE && tmp) {
            for (;;) {
                DWORD w;
                rc = real_avio_read(pb, tmp, 1 << 20);
                if (rc <= 0) break;
                WriteFile(h, tmp, (DWORD)rc, &w, NULL);
                total += rc;
                if (total > (1500LL << 20)) break;
            }
        }
        if (tmp) HeapFree(GetProcessHeap(), 0, tmp);
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
        if (real_avio_seek) logmsg("  seek(0) restore -> %d", (int)real_avio_seek(pb, 0, SEEK_SET));
        logmsg("  PB DUMP #%d: rc=%d, %u MB", n, rc, (unsigned)(total >> 20));
    }
    return r;
}

int avformat_find_stream_info(AVFormatContext *ic, AVDictionary **options)
{
    int r = real_find_stream_info ? real_find_stream_info(ic, options) : -1;
    logmsg("avformat_find_stream_info(%x) -> %d", (unsigned)ic, r);
    return r;
}

void avformat_close_input(AVFormatContext **s)
{
    logmsg("avformat_close_input(%x)", (unsigned)s);
    if (real_close_input) real_close_input(s);
}

int av_read_frame(AVFormatContext *s, AVPacket *pkt)
{
    int r = real_read_frame ? real_read_frame(s, pkt) : -1;
    static int cnt = 0;
    if (cnt < 20) { logmsg("av_read_frame(%x) -> %d", (unsigned)s, r); cnt++; }
    return r;
}

int av_seek_frame(AVFormatContext *s, int idx, long long ts, int flags)
{
    int r = real_seek_frame ? real_seek_frame(s, idx, ts, flags) : -1;
    logmsg("av_seek_frame(idx=%d, ts=%d, flags=%d) -> %d", idx, (int)(ts >> 20), flags, r);
    return r;
}

int avio_read(AVIOContext *s, unsigned char *buf, int size)
{
    int r = real_avio_read ? real_avio_read(s, buf, size) : -1;
    static int cnt = 0;
    if (r > 0) passive_write(buf, r);
    if (cnt < 40) { logmsg("avio_read(%x, size=%d) -> %d", (unsigned)s, size, r); cnt++; }
    return r;
}

int avio_open(AVIOContext **s, const char *url, int flags)
{
    int r = real_avio_open ? real_avio_open(s, url, flags) : -1;
    logmsg("avio_open(url=%s, flags=%d) -> %d", url ? url : "(null)", flags, r);
    return r;
}

int avio_open2(AVIOContext **s, const char *url, int flags, const AVIOInterruptCB *cb, AVDictionary **o)
{
    int r = real_avio_open2 ? real_avio_open2(s, url, flags, cb, o) : -1;
    logmsg("avio_open2(url=%s) -> %d", url ? url : "(null)", r);
    return r;
}

long long avio_seek(AVIOContext *s, long long off, int whence)
{
    long long r = real_avio_seek ? real_avio_seek(s, off, whence) : -1;
    static int cnt = 0;
    if (cnt < 30) { logmsg("avio_seek(off=%u, whence=%d) -> %d", (unsigned)off, whence, (int)r); cnt++; }
    return r;
}

long long avio_size(AVIOContext *s)
{
    long long r = real_avio_size ? real_avio_size(s) : -1;
    logmsg("avio_size -> %u", (unsigned)r);
    return r;
}

int av_probe_input_buffer(AVIOContext *pb, AVInputFormat **fmt, const char *url, void *logctx,
                          unsigned int off, unsigned int maxprobe)
{
    int r = real_probe ? real_probe(pb, fmt, url, logctx, off, maxprobe) : -1;
    logmsg("av_probe_input_buffer(url=%s) -> %d", url ? url : "(null)", r);
    return r;
}

int av_find_best_stream(AVFormatContext *ic, int type, int wanted, int related, void **dec, int flags)
{
    int r = real_best_stream ? real_best_stream(ic, type, wanted, related, dec, flags) : -1;
    logmsg("av_find_best_stream(type=%d) -> %d", type, r);
    return r;
}

/* ---------------- init ---------------- */
static void *real_of(const char *n)
{
    int i;
    for (i = 0; i < g_nslots; i++)
        if (!lstrcmpA(g_names[i], n)) return *g_slot_ptrs[i];
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HMODULE orig, avutil;
        int i, missing = 0;
        InitializeCriticalSection(&g_cs);
        logmsg("=== proxy loaded ===");
        orig = LoadLibraryW(L"avformat-58_orig.dll");
        if (!orig) { logmsg("LoadLibrary orig FAILED err=%d", (int)GetLastError()); return TRUE; }
        for (i = 0; i < g_nslots; i++) {
            void *p = (void *)GetProcAddress(orig, g_names[i]);
            *g_slot_ptrs[i] = p;
            if (!p) { missing++; logmsg("MISSING %s", g_names[i]); }
        }
        logmsg("slots=%d missing=%d orig=%x", g_nslots, missing, (unsigned)orig);

        real_alloc        = (t_alloc_ctx)real_of("avio_alloc_context");
        real_open_input   = (t_open_input)real_of("avformat_open_input");
        real_find_stream_info = (t_find_stream_info)real_of("avformat_find_stream_info");
        real_close_input  = (t_close_input)real_of("avformat_close_input");
        real_read_frame   = (t_read_frame)real_of("av_read_frame");
        real_seek_frame   = (t_seek_frame)real_of("av_seek_frame");
        real_avio_read    = (t_avio_read)real_of("avio_read");
        real_avio_open    = (t_avio_open)real_of("avio_open");
        real_avio_open2   = (t_avio_open2)real_of("avio_open2");
        real_ctx_free     = (t_ctx_free)real_of("avio_context_free");
        real_avio_seek    = (t_avio_seek)real_of("avio_seek");
        real_avio_size    = (t_avio_size)real_of("avio_size");
        real_probe        = (t_probe)real_of("av_probe_input_buffer");
        real_fmt_alloc    = (t_fmt_alloc)real_of("avformat_alloc_context");
        real_fmt_free     = (t_fmt_free)real_of("avformat_free_context");
        real_best_stream  = (t_best_stream)real_of("av_find_best_stream");

        avutil = GetModuleHandleA("avutil-56.dll");
        if (avutil) {
            unsigned int sz = *(unsigned int *)((unsigned char *)avutil + 0x50);
            g_avutil_lo = (unsigned int)avutil;
            g_avutil_hi = g_avutil_lo + sz;
        }
        logmsg("avutil=[%x,%x) probes: open=%x read=%x seek=%x",
               g_avutil_lo, g_avutil_hi, (unsigned)real_open_input,
               (unsigned)real_avio_read, (unsigned)real_avio_seek);
    }
    return TRUE;
}
