#!/usr/bin/env python3
"""
patch_manifest.py - 把 PE 内嵌清单里的 requireAdministrator 等长替换成 asInvoker

为什么要做：这类播放器往往声明了 requireAdministrator。以管理员身份运行时，
它的进程处于高完整性级别，普通权限的调试器/读取器拿不到它的内存，
也就没法把解密出来的流截下来。等长替换成 asInvoker 后，我们可以以普通权限、
相同完整性级别运行一份副本，从而正常读取它。

关键点是"等长"：清单在 PE 资源段里，改动长度会破坏文件。这里用尾部补空格的方式
保持长度不变（根元素之后补空白是合法 XML）。

用法:
    python patch_manifest.py <播放器.exe>
        # 会先备份成 <名字>.orig.exe，再原地改写
"""
import os, sys, shutil


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    exe = os.path.abspath(sys.argv[1])
    if not os.path.exists(exe):
        print("找不到文件:", exe)
        return 1
    bak = os.path.splitext(exe)[0] + ".orig" + os.path.splitext(exe)[1]

    if not os.path.exists(bak):
        shutil.copy2(exe, bak)
        print("backup ->", bak)

    d = bytearray(open(exe, "rb").read())
    i = d.find(b"<assembly")
    j = d.find(b"</assembly>", i) + len(b"</assembly>")
    if i < 0 or j <= 0:
        print("没找到内嵌清单，无需处理")
        return 1
    man = bytes(d[i:j])
    if b"requireAdministrator" not in man:
        print("清单里没有 requireAdministrator（可能已经处理过）")
        return 0

    new = man.replace(b"requireAdministrator", b"asInvoker")
    pad = len(man) - len(new)
    assert pad > 0
    new = new + b" " * pad          # 根元素之后补空白是合法 XML
    assert len(new) == len(man)
    d[i:j] = new
    open(exe, "wb").write(bytes(d))
    print("已原地改写清单，长度保持", len(man))
    print("校验: requireAdministrator 仍存在?",
          b"requireAdministrator" in bytes(d), "| asInvoker:", b"asInvoker" in bytes(d))
    print("大小:", os.path.getsize(exe), "原始:", os.path.getsize(bak))
    return 0


if __name__ == "__main__":
    sys.exit(main())
