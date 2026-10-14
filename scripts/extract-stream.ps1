# extract-stream.ps1 - 从发行方自带的播放器里取出它解密后的媒体流，并转成 mp4
#
# 用法:
#   .\extract-stream.ps1 -Source "D:\videos\lesson01.sz" -PlayerDir "D:\player"
#   .\extract-stream.ps1 -Source "..." -PlayerDir "..." -Out "D:\out\01.mp4"
#   .\extract-stream.ps1 -Source "..." -PlayerDir "..." -DumpOnly     # 只取明文流
#
# 原理:
#   这类受保护的媒体只能由发行方自带的播放器解密，所以把播放器当作"解密黑盒"：
#     1) 播放器要求管理员权限运行，先把它内嵌清单里的 requireAdministrator 等长替换为
#        asInvoker —— 这样我们能以普通权限、相同完整性级别启动自己的副本，
#        否则读不到它的内存（CreateProcess err=740 就是被这一步挡住）
#     2) 用一个"代理 DLL"替换播放器依赖的 FFmpeg avformat-58.dll：代理转发它的全部导出，
#        并在 avformat_open_input 返回后取出 FFmpeg 内部的 AVIOContext：(*ps)->pb
#        （32 位 FFmpeg 4.x 中 AVFormatContext.pb 在偏移 16），顺序读取即得到
#        播放器自己解密出来的明文流（avio_size 与源文件等长，说明是逐字节原地解密）
#     3) 明文可能是 MPEG-TS(188/192 字节包) 或 MP4：
#          - TS  -> 交给 ffmpeg 无损重封装
#          - MP4 -> 负载可能被二次改写，转交 restore-payload.ps1 还原（原理见 docs/）
#
# 依赖（见 src/dll-proxy/README.md）:
#   - 编译好的代理 DLL（默认 build/avformat-58.dll）
#   - 播放器自身的安装目录：用 -PlayerDir 指定工作副本所在目录，
#     首次可以用 -SourceDir 把系统里已安装的那份拷贝过来

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Source,
  [string]$Out = "",
  [Parameter(Mandatory = $true)][string]$PlayerDir,
  [string]$PlayerExe = "",
  [string]$SourceDir = "",
  [string]$Work = "",
  [string]$ProxyDll = "avformat-58.dll",
  [int]$TimeoutSec = 900,
  [switch]$KeepDump,
  [switch]$DumpOnly
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[extract] $m" }

$inputPath = (Resolve-Path -LiteralPath $Source).Path
if (-not $Out) { $Out = [IO.Path]::ChangeExtension($inputPath, '.mp4') }
if (-not $Work) { $Work = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Test-Path $PlayerDir)) { throw "找不到播放器目录: $PlayerDir" }
if (-not $PlayerExe) {
  $cand = @(Get-ChildItem $PlayerDir -Filter *.exe -File -ErrorAction SilentlyContinue)
  if ($cand.Count -eq 1) { $PlayerExe = $cand[0].Name }
  elseif ($cand.Count -gt 1) { $PlayerExe = ($cand | Sort-Object Length -Descending)[0].Name }
  else { throw "在 $PlayerDir 找不到 exe，请用 -PlayerExe 指定" }
}
$exe       = Join-Path $PlayerDir $PlayerExe
$proxySrc  = Join-Path $Work "build\$ProxyDll"
$proxyDst  = Join-Path $PlayerDir $ProxyDll
$origDll   = Join-Path $PlayerDir ($ProxyDll -replace '\.dll$', '_orig.dll')
$ffmpeg    = Join-Path $Work 'ffmpeg.exe'
$log       = Join-Path $PlayerDir 'proxy_log.txt'
$dump      = Join-Path $PlayerDir 'decrypted_1.bin'

# ---------------------------------------------------------------- 1. 准备播放器
if ($SourceDir -and -not (Test-Path $exe)) {
  Info "拷贝播放器副本 -> $PlayerDir"
  Copy-Item $SourceDir $PlayerDir -Recurse -Force
}
if (-not (Test-Path $exe)) { throw "找不到播放器: $exe（用 -SourceDir 拷贝一份，或直接把 -PlayerDir 指向安装目录）" }

# 1a. 去掉 requireAdministrator
$enc = [Text.Encoding]::GetEncoding(28591)
$bytes = [IO.File]::ReadAllBytes($exe)
$s = $enc.GetString($bytes)
if ($s.IndexOf('requireAdministrator') -ge 0) {
  Info '改写 exe 清单: requireAdministrator -> asInvoker (等长填充)'
  $i = $s.IndexOf('requireAdministrator')
  $s = $s.Remove($i, 'requireAdministrator'.Length).Insert($i, 'asInvoker')
  $j = $s.IndexOf('</assembly>', $i) + '</assembly>'.Length
  $s = $s.Insert($j, ' ' * ('requireAdministrator'.Length - 'asInvoker'.Length))
  [IO.File]::WriteAllBytes($exe, $enc.GetBytes($s))
}

# 1b. 换代理 DLL
if (-not (Test-Path $origDll)) {
  Info "备份原 $ProxyDll"
  Move-Item $proxyDst $origDll
}
if (-not (Test-Path $proxySrc)) { throw "缺少代理 DLL: $proxySrc（见 src/dll-proxy/README.md 编译）" }
$need = (Get-Item $proxySrc).Length -ne (Get-Item $proxyDst -ErrorAction SilentlyContinue).Length
if ($need) { Copy-Item $proxySrc $proxyDst -Force; Info "安装代理 $ProxyDll" }

# ---------------------------------------------------------------- 2. 清场
Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($PlayerExe)) -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like "$PlayerDir\*" } |
  ForEach-Object { $_.Kill(); try { $_.WaitForExit(8000) | Out-Null } catch { } }
Start-Sleep -Milliseconds 800
Remove-Item $log -ErrorAction SilentlyContinue
Remove-Item $dump -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 3. 启动 + 点"播放"
Add-Type @"
using System; using System.Runtime.InteropServices;
public class V2M {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public const uint LEFTDOWN=0x0002, LEFTUP=0x0004;
}
"@

function Click-Play([int]$procId) {
  $script:dlgRect = $null
  $cb = [V2M+EnumProc]{
    param($h, $p)
    $q = 0
    [V2M]::GetWindowThreadProcessId($h, [ref]$q) | Out-Null
    if ($q -eq $procId -and [V2M]::IsWindowVisible($h)) {
      $r = New-Object V2M+RECT
      [V2M]::GetWindowRect($h, [ref]$r) | Out-Null
      if (($r.Right - $r.Left) -eq 764 -and ($r.Bottom - $r.Top) -eq 539) { $script:dlgRect = $r }
    }
    return $true
  }
  [V2M]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  if ($script:dlgRect) {
    $r = $script:dlgRect
    $x = $r.Left + 556; $y = $r.Top + 337     # "播放" 按钮
    [V2M]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 250
    [V2M]::mouse_event([V2M]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [V2M]::mouse_event([V2M]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    return $true
  }
  return $false
}

Info "启动播放器: $(Split-Path $inputPath -Leaf)"
$proc = Start-Process -FilePath $exe -ArgumentList "`"$inputPath`"" -WorkingDirectory $PlayerDir -PassThru

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$clicked = $false; $started = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 800
  if (-not $clicked -and (Get-Date) -lt $deadline) { $clicked = Click-Play $proc.Id }
  else { Click-Play $proc.Id | Out-Null }      # 授权窗口可能重复出现
  if (Test-Path $log) {
    $c = Get-Content $log -Raw -ErrorAction SilentlyContinue
    if ($c -match 'avformat_open_input') { $started = $true }
    if ($c -match 'PB DUMP #1:') { break }
  }
  if ($proc.HasExited) { break }
}
if (-not $started) { Info '警告: 没有看到播放器开始解密，请确认已点"播放"' }

# ---------------------------------------------------------------- 4. 等 dump 稳定
if (Test-Path $dump) {
  $last = -1
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 1
    $len = (Get-Item $dump).Length
    if ($len -eq $last -and $len -gt 0) { break }
    $last = $len
  }
  Info ("明文 dump: {0:N0} 字节" -f $last)
} else {
  throw "没有生成明文 dump，检查 $log"
}

# ---------------------------------------------------------------- 4b. 仅解密 dump
if ($DumpOnly) {
  Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
  Info ("解密 dump 完成: {0} ({1:N0} 字节)" -f $dump, (Get-Item $dump).Length)
  return
}

# ---------------------------------------------------------------- 5. 输出 mp4
# 嗅探明文容器类型：如果明文就已经是 MP4，说明负载很可能被二次改写
# （原理见 docs/02-avc-slice-restore.md），转交 restore-payload.ps1 走"还原负载"流程；
# 否则（TS/M2TS）交给 ffmpeg 直接无损重封装。
$fs = [IO.File]::OpenRead($dump)
$hb = New-Object byte[] 16
$nread = $fs.Read($hb, 0, 16)
$fs.Close()
$isMp4 = ($nread -ge 8) -and ([Text.Encoding]::ASCII.GetString($hb, 4, 4) -eq 'ftyp')
if ($isMp4) {
  Info "明文是 MP4 -> 转交 restore-payload.ps1 做负载还原"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Work 'scripts\restore-payload.ps1') `
      -Source $inputPath -Out $Out -Work $Work -PlayerDir $PlayerDir -PlayerExe $PlayerExe -ReuseDump -KeepTemp
  Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
  if (Test-Path $Out) { Info ("完成(经负载还原流程): {0}" -f $Out); return } else { throw "转换失败（负载还原流程）" }
}

$dir = Split-Path $Out -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Info "ffmpeg 重封装 -> $Out"
# 明文可能是 TS(M2TS) 也可能是 mp4，交给 ffmpeg 自动识别；
# mp4 复用器会自行插入 aac_adtstoasc，无需显式指定。
$ErrorActionPreference = 'Continue'     # ffmpeg 往 stderr 写进度，别当中断
& $ffmpeg -hide_banner -y -fflags +genpts -i $dump -c copy -movflags +faststart $Out 2>&1 |
  Where-Object { $_ -notmatch 'changing packet size|^frame=|Non-monotonic|^\[|^  |^Input|^Output|^Stream|^$' } |
  Select-Object -Last 6
$ErrorActionPreference = 'Stop'

Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

if (Test-Path $Out) {
  $f = Get-Item $Out
  Info ("完成: {0}  ({1:N0} 字节)" -f $f.FullName, $f.Length)
  if (-not $KeepDump) { Remove-Item $dump -Force -ErrorAction SilentlyContinue }
} else {
  throw "转换失败"
}
