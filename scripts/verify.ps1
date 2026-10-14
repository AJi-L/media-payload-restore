# verify.ps1 - 对转换出来的 mp4 做全片解码校验，汇总有问题的文件
#
# 用法:
#   .\verify.ps1 -MediaDir "D:\videos"
#   .\verify.ps1 -MediaDir "D:\videos" -Filter "*.mp4"
#
# 判定标准：ffmpeg -v error 的输出里，除已知无害的一类提示
#   "Application provided invalid, non monotonically increasing dts ..."
# （末帧 B 帧重排导致，容器本身完整）之外，不再有其它行。
#
# 退出：仅打印结果，不修改任何文件。

param(
  [string]$MediaDir = "",
  [string]$Work = "",
  [string]$Filter = "*.mp4"
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $Work) { $Work = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $MediaDir) { $MediaDir = $Work }
$ff = Join-Path $Work 'ffmpeg.exe'
if (-not (Test-Path $ff)) { throw "缺少 ffmpeg: $ff" }

$all = @(Get-ChildItem $MediaDir -Recurse -Filter $Filter -ErrorAction SilentlyContinue | Sort-Object FullName)
Write-Host ("[verify] 待校验: {0} 个" -f $all.Count)

$bad = 0; $n = 0
foreach ($f in $all) {
    $n++
    $t = (cmd /c ('"{0}" -hide_banner -v error -i "{1}" -f null - 2>&1' -f $ff, $f.FullName)) -join "`n"
    $t = [regex]::Replace($t, '(?s)Application provided invalid, non monotonically.*?in stream \d+: [0-9]+ >= [0-9]+', '')
    $rest = @($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\[[^\]]+\]\s*$' })
    if ($rest.Count -gt 0) {
        $bad++
        Write-Host ("[verify] [BAD] {0}   ({1} 条)" -f $f.Name, $rest.Count)
        $rest | Select-Object -First 3 | ForEach-Object { Write-Host ("          " + $_) }
    }
    if ($n % 25 -eq 0) { Write-Host ("[verify] ... {0}/{1}   已发现 {2} 个异常" -f $n, $all.Count, $bad) }
}
Write-Host ("[verify] [DONE] 共 {0} 个, 异常 {1} 个" -f $all.Count, $bad)
