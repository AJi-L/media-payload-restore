# restore-batch.ps1 - 目录递归批量：把受保护文件逐个转成 mp4（已完成的自动跳过）
#
# 用法:
#   .\restore-batch.ps1 -Input "D:\videos" -PlayerDir "D:\player"
#   .\restore-batch.ps1 -Input "D:\videos" -PlayerDir "D:\player" -Filter "*.sz"
#   .\restore-batch.ps1 -Input "D:\videos\lesson01.sz" -PlayerDir "D:\player"   # 单个也行
#
# 说明:
#   - 单个文件由 extract-stream.ps1 负责（它会自动判断明文是 TS 还是被改写的 MP4，
#     后者会转交 restore-payload.ps1）
#   - 已存在同名非空 mp4 会跳过 → 可随时中断、重跑（断点续跑）
#   - 单个文件失败只记一条 [FAIL] 并继续，不会拖死整批

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Input,
  [Parameter(Mandatory = $true)][string]$PlayerDir,
  [string]$PlayerExe = "",
  [string]$SourceDir = "",
  [string]$Work = "",
  [string]$Filter = "*.sz",
  [int]$TimeoutSec = 1800,
  [int]$FixTimeoutSec = 2400
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[batch] $m" }

if (-not $Work) { $Work = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$extract = Join-Path $Work 'scripts\extract-stream.ps1'
if (-not (Test-Path $extract)) { throw "缺少 scripts/extract-stream.ps1" }

$item = Get-Item -LiteralPath $Input
if ($item.PSIsContainer) {
  $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Filter $Filter | Sort-Object FullName)
} else {
  $files = @($item)
}

Info ("[BATCH-START] {0} 个（{1}）" -f $files.Count, $Filter)
$ok = 0; $skip = 0; $fail = 0
foreach ($f in $files) {
  $out = [IO.Path]::ChangeExtension($f.FullName, '.mp4')
  if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) {
    Info ("[SKIP] " + $f.Name); $skip++; continue
  }
  $t0 = Get-Date
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $extract `
        -Input $f.FullName -Out $out -PlayerDir $PlayerDir -PlayerExe $PlayerExe `
        -SourceDir $SourceDir -Work $Work -TimeoutSec $TimeoutSec
    if (-not ((Test-Path $out) -and (Get-Item $out).Length -gt 0)) { throw "没有产出 mp4" }
    $ok++
    Info ("[OK] {0}  ({1:N0} 字节, {2} 秒)" -f $out, (Get-Item $out).Length, [int]((Get-Date) - $t0).TotalSeconds)
  } catch {
    $fail++
    Write-Host "[batch] [FAIL] $($f.FullName) -- $_"
  }
}
Info ("[BATCH] 结束: 成功 {0}, 跳过 {1}, 失败 {2}" -f $ok, $skip, $fail)
