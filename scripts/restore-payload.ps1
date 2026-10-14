# restore-payload.ps1 - 还原被二次改写过的媒体负载，输出标准 mp4（无损、不重编码）
#
# 用法:
#   .\restore-payload.ps1 -Input "D:\videos\lesson01.sz" -PlayerDir "D:\player"
#   .\restore-payload.ps1 -Input "..." -Out "D:\out\01.mp4" -PlayerDir "D:\player"
#   .\restore-payload.ps1 -Input "D:\videos\某课程目录" -PlayerDir "D:\player"   # 目录递归批量
#
# 原理（分两步）:
#   1) 容器层：受保护文件的解密只能由发行方的播放器完成。用代理 DLL 截住它解密后的
#      AVIOContext，顺序读出明文（一个结构完好的 MP4）—— 复用 extract-stream.ps1 -DumpOnly
#   2) 负载层：明文里的视频/音频负载被做过非标准改写，用 src/payload_restore.py 还原：
#        - 每个 slice 前有 1 字节 0x84 标记
#        - 头部前缀重排：[fmb=0][slice_type=0][pps_id=tag] ←→ [fmb=0][slice_type=tag][pps_id=0]
#        - 重排后的前缀之后被插入了 1 个比特（去掉它，并注意字节对齐边界）
#        - 音频每 256 帧有一个 17 字节标记块，紧随其后的那一帧被整体位移 1 位
#      还原后即为标准 H.264 + AAC，全部原样拷进 mp4
#      详细原理见 docs/02-avc-slice-restore.md 与 docs/04-audio-restore.md
#
# 前置: 播放器工作副本与代理 DLL 由 extract-stream.ps1 首次运行时准备（本脚本会自动触发）。

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Input,
  [string]$Out = "",
  [Parameter(Mandatory = $true)][string]$PlayerDir,
  [string]$PlayerExe = "",
  [string]$SourceDir = "",
  [string]$Work = "",
  [string]$Python = "",
  [string]$Filter = "*.sz",
  [int]$TimeoutSec = 1800,
  [int]$FixTimeoutSec = 2400,
  [switch]$KeepTemp,
  [switch]$ReuseDump
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[restore] $m" }

if (-not $Work) { $Work = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ffmpeg = Join-Path $Work 'ffmpeg.exe'
$fix    = Join-Path $Work 'src\payload_restore.py'
$dump   = Join-Path $Work 'decrypted_1.bin'
$bootstrap = Join-Path $Work 'scripts\extract-stream.ps1'

if (-not (Test-Path $ffmpeg)) { throw "缺少 ffmpeg: $ffmpeg" }
if (-not (Test-Path $fix))    { throw "缺少 src/payload_restore.py" }

# Python: 参数 > PATH 上的 python
if (-not $Python) {
  $c = Get-Command python -ErrorAction SilentlyContinue
  if ($c) { $Python = $c.Source } else { throw "找不到 python，请用 -Python 指定" }
}

function Convert-One([string]$path, [string]$outPath) {
  if (-not $outPath) { $outPath = [IO.Path]::ChangeExtension($path, '.mp4') }
  if ((Test-Path $outPath) -and (Get-Item $outPath).Length -gt 0) {
    Info ("跳过（已存在）: {0}" -f (Split-Path $outPath -Leaf)); return
  }
  Info "===== $(Split-Path $path -Leaf) ====="

  # ---- 1) 播放器解密出容器明文 ----
  if ($ReuseDump -and (Test-Path $dump) -and (Get-Item $dump).Length -gt 0) {
    Info ("1/3 复用已有明文 dump ({0:N0} 字节)" -f (Get-Item $dump).Length)
  } else {
    Info '1/3 解密容器（启动播放器 + 代理 DLL）...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap `
        -Input $path -PlayerDir $PlayerDir -PlayerExe $PlayerExe -SourceDir $SourceDir `
        -Work $Work -TimeoutSec $TimeoutSec -DumpOnly
    if (-not (Test-Path $dump)) { throw "解密失败：没有生成 $dump" }
  }

  # ---- 2) 还原被改写的负载（带超时 + 产物检查，防止挂死拖垮整批）----
  $h264 = Join-Path $Work '_video.h264'
  $aac  = Join-Path $Work '_audio.aac'
  $oout = Join-Path $Work '_payload.out'
  $oerr = Join-Path $Work '_payload.err'
  Remove-Item $h264, $aac, $oout, $oerr -Force -ErrorAction SilentlyContinue
  Info '2/3 还原视频/音频负载...'
  $p = Start-Process -FilePath $Python -ArgumentList @('-u', $fix, $dump, $h264, $aac) `
        -NoNewWindow -PassThru -RedirectStandardOutput $oout -RedirectStandardError $oerr
  if (-not $p.WaitForExit($FixTimeoutSec * 1000)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw ("payload_restore.py 超时（{0} 秒）" -f $FixTimeoutSec)
  }
  $ec = $null
  try { $ec = $p.ExitCode } catch { }
  $lines = @(Get-Content $oout -Encoding utf8 -ErrorAction SilentlyContinue)
  $lines | ForEach-Object { Info "    $_" }
  # 以产物为准（$p.ExitCode 在 Start-Process + 重定向下不总是可靠）
  $h264ok = (Test-Path $h264) -and (Get-Item $h264).Length -gt 0
  $aacok  = (Test-Path $aac)  -and (Get-Item $aac).Length  -gt 0
  $done   = ($lines | Where-Object { "$_" -match '^\[DONE\]' }).Count -gt 0
  if (-not ($h264ok -and $aacok -and $done)) {
    @(Get-Content $oerr -Encoding utf8 -ErrorAction SilentlyContinue) | Select-Object -Last 15 |
      ForEach-Object { Info "    $_" }
    throw ("payload_restore 产物不完整 (h264={0} aac={1} 完成标记={2} 退出码={3})" -f $h264ok, $aacok, $done, $ec)
  }
  if ($ec -ne $null -and $ec -ne 0) { Info ("    注: 退出码 {0}，但产物完整，继续" -f $ec) }
  $fps = 20.0
  foreach ($l in $lines) { if ("$l" -match '^FPS=([0-9.]+)') { $fps = [double]$Matches[1] } }

  # ---- 3) 无损封装 ----
  $dir = Split-Path $outPath -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Info "3/3 无损封装 -> $outPath"
  $ErrorActionPreference = 'Continue'
  & $ffmpeg -y -hide_banner -v error -r $fps -i $h264 -i $aac `
            -c:v copy -c:a copy -movflags +faststart $outPath 2>&1 |
    Where-Object { $_ -notmatch 'non monotonically' } | ForEach-Object { Info "    $_" }
  $ErrorActionPreference = 'Stop'
  if (-not (Test-Path $outPath)) { throw "封装失败" }

  Info ("全片校验 ...")
  $cmdline = '"{0}" -hide_banner -v error -i "{1}" -f null - 2>&1' -f $ffmpeg, $outPath
  $txt = (cmd /c $cmdline) | Out-String
  # 末帧 B 帧重排会让 mp4 复用器抱怨一次 dts，属无害提示
  $txt = [regex]::Replace($txt, '(?s)Application provided invalid, non monotonically.*?in stream 0: [0-9]+ >= [0-9]+', '')
  $rest = ($txt -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\[[^\]]+\]\s*$' })
  $n = ($rest | Measure-Object).Count
  $dur = (cmd /c ('"{0}" -hide_banner -i "{1}" -f null - 2>&1' -f $ffmpeg, $outPath)) -join "`n"
  if ($dur -match 'Duration: ([0-9:.]+)') { $dur = $Matches[1] } else { $dur = '?' }
  $size = (Get-Item $outPath).Length
  if ($n -eq 0) {
    Info ("[OK] {0}  时长 {1}  {2:N0} 字节" -f $outPath, $dur, $size)
  } else {
    Info ("[OK-WARN] 剩余 {0} 条提示  {1}  时长 {2}" -f $n, $outPath, $dur)
    $rest | Select-Object -First 5 | ForEach-Object { Info "    $_" }
  }

  if (-not $KeepTemp) {
    Remove-Item $h264, $aac, $oout, $oerr -Force -ErrorAction SilentlyContinue
    Remove-Item $dump -Force -ErrorAction SilentlyContinue
  }
}

$item = Get-Item -LiteralPath $Input
if ($item.PSIsContainer) {
  $files = Get-ChildItem -LiteralPath $item.FullName -Recurse -Filter $Filter | Sort-Object FullName
  Info ("批量: 找到 {0} 个 {1}" -f $files.Count, $Filter)
  $ok = 0; $fail = 0
  foreach ($f in $files) {
    try { Convert-One $f.FullName ''; $ok++ }
    catch { Write-Host "[restore] [FAIL] $($f.FullName) -- $_"; $fail++ }
  }
  Info ("[BATCH] 结束: 成功 {0}, 失败 {1}" -f $ok, $fail)
} else {
  Convert-One $item.FullName $Out
}
