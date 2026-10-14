import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
J = json.load(open(os.path.join(HERE, "avformat_exports.json"), encoding="utf-8"))
names = sorted(J["names"].keys())
# names implemented in C by proxy.c (logging probes + the hook)
CUSTOM = {
    "avio_alloc_context",
    "avformat_alloc_context", "avformat_open_input", "avformat_find_stream_info",
    "avformat_close_input", "av_read_frame", "av_seek_frame",
    "avio_read", "avio_open", "avio_open2", "avio_context_free", "avio_seek", "avio_size",
    "av_probe_input_buffer", "av_find_best_stream", "avformat_free_context",
}
HOOK = "avio_alloc_context"
OUT = os.environ.get("PROXY_OUT") or os.path.normpath(os.path.join(HERE, "..", "..", "build"))
os.makedirs(OUT, exist_ok=True)
print("exports:", len(names), " hook:", HOOK, " custom:", len(CUSTOM & set(names)))

# ---------- gen.S ----------
s = ["/* auto-generated proxy stubs: tail-jump through runtime-filled slots */", "\t.text"]
for n in names:
    if n in CUSTOM:
        continue
    s += ["", "\t.globl\t_%s" % n, "_%s:" % n,
          "\tjmp\t*_slot_%s" % n]
s += ["", "\t.data"]
for n in names:
    s += ["\t.globl\t_slot_%s" % n, "_slot_%s:\t.long 0" % n]
open(os.path.join(OUT, "gen.S"), "w").write("\n".join(s) + "\n")

# ---------- gen.c ----------
c = ['#include <windows.h>', '/* auto-generated slot table */']
for n in names:
    c.append("extern void *slot_%s;" % n)
c.append("")
c.append("const char *g_names[%d] = {" % len(names))
for n in names:
    c.append('  "%s",' % n)
c.append("};")
c.append("")
c.append("void **g_slot_ptrs[%d] = {" % len(names))
for n in names:
    c.append("  &slot_%s," % n)
c.append("};")
c.append("int g_nslots = %d;" % len(names))
c.append('const char *g_hook_name = "%s";' % HOOK)
c.append("void **g_hook_slot(void) { return &slot_%s; }" % HOOK)
open(os.path.join(OUT, "gen.c"), "w").write("\n".join(c) + "\n")

# ---------- gen.def ----------
d = ["LIBRARY avformat-58", "EXPORTS"]
for n in names:
    d.append("  %s" % n)
open(os.path.join(OUT, "gen.def"), "w").write("\n".join(d) + "\n")

print("wrote gen.S gen.c gen.def to", OUT)
