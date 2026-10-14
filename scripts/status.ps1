# status.ps1 - 批量转换的进度快照（配合 restore-batch.ps1 的日志使用）
#
# 用法:
#   .\status.ps1
#   .\status.ps1 -Work "D:\mywork"
#
# 默认观测 <Work>\restore_log.txt 与 <Work>\verify_log.txt（谁新看谁），
# 以及 <Work> 下的媒体目录（用 -MediaDir 指定，默认与 <Work> 相同）。

param(
  [string]$Work = "",
  [string]$MediaDir = "",
  [string[]]$ExeNames = @('python', 'ffmpeg')   # 想额外观察的进程名，例如你的播放器
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $Work) { $Work = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $MediaDir) { $MediaDir = $Work }

$now = Get-Date
Write-Host ("[STATUS] " + $now.ToString("MM-dd HH:mm:ss"))

$cands = @("$Work\restore_log.txt", "$Work\verify_log.txt") |
         Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ }
$act = $cands | Sort-Object LastWriteTime | Select-Object -Last 1
if ($act) {
    $age = [int]($now - $act.LastWriteTime).TotalMinutes
    Write-Host ("活动日志: {0}   最后更新 {1}  ({2} 分钟前)" -f $act.Name, $act.LastWriteTime.ToString("MM-dd HH:mm:ss"), $age)
    $c = Get-Content $act.FullName -Encoding utf8
    $m = $c | Select-String "(===== |启动播放器: )" | Select-Object -Last 1
    if ($m) { Write-Host ("当前处理: " + ($m -replace '^.*(===== |启动播放器: )', '')) }
    Write-Host ("最后一行: " + ($c | Select-Object -Last 1))
    Write-Host ("[OK]=" + ($c | Select-String "[OK]" -SimpleMatch).Count +
                "  [FAIL]=" + ($c | Select-String "[FAIL]" -SimpleMatch).Count +
                "  [SKIP]=" + ($c | Select-String "[SKIP]" -SimpleMatch).Count)
} else {
    $age = 9999
    Write-Host "没有日志文件（用 restore-batch.ps1 跑批时会生成 <Work>\restore_log.txt）"
}

$done  = @(Get-ChildItem $MediaDir -Recurse -Filter *.mp4 -ErrorAction SilentlyContinue)
$total = @(Get-ChildItem $MediaDir -Recurse -Include *.sz, *.vep -ErrorAction SilentlyContinue)
Write-Host ("mp4 {0} 个 / 源 {1} 个    合计 {2:N2} GB" -f `
    $done.Count, $total.Count, (($done | Measure-Object Length -Sum).Sum / 1GB))

$names = @($ExeNames) + @('python', 'ffmpeg') | Select-Object -Unique
$procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    Write-Host ("相关进程: " + (($procs | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', '))
} else {
    Write-Host "相关进程: 无"
}

if ($age -ge 25)      { Write-Host "[VERDICT] STALL  -- 日志超过 25 分钟没动，需要处理" }
elseif ($age -ge 15)  { Write-Host "[VERDICT] SLOW   -- 日志 15 分钟以上没动，继续观察" }
else                  { Write-Host "[VERDICT] RUNNING" }
