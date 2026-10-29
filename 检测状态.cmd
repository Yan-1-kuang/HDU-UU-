@echo off
setlocal
cd /d "%~dp0"
set "SELF=%~f0"

echo.
echo  ==================================================
echo   DNS over TCP  -  STATUS CHECK  (standalone, read only)
echo  --------------------------------------------------
echo   1. scheduled task "DNSTCPProxy"  state / last result
echo   2. listener on 127.0.0.1:53      (UDP + TCP)
echo   3. adapter DNS servers
echo   4. resolution test               (baidu / google)
echo   5. proxy.log                     last lines
echo   Nothing is changed. Safe to run any time.
echo   No admin rights needed.
echo  ==================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8);$i=$c.IndexOf('#__PS_BLOCK_'+'START__');iex $c.Substring($i)"
set RC=%errorlevel%
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%
#__PS_BLOCK_START__
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$task    = 'DNSTCPProxy'
$port    = 53
$dataDir = Join-Path $env:ProgramData 'DNSTCPProxy'
$logFile = Join-Path $dataDir 'proxy.log'

$issues  = New-Object System.Collections.ArrayList

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) { Write-Host ("`n== " + $m + " ==") -ForegroundColor Cyan }
function Bad($m) { $null = $issues.Add([pscustomobject]@{Level="X";Text=$m}); Write-Host ("  [X] " + $m) -ForegroundColor Red }
function Warn($m) { $null = $issues.Add([pscustomobject]@{Level="!";Text=$m}); Write-Host ("  [!] " + $m) -ForegroundColor Yellow }
function Good($m) { Write-Host ("  [v] " + $m) -ForegroundColor Green }

function Inv-Exe {
    param([string]$FilePath, [string[]]$ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = & $FilePath @ArgList 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Out = $text.TrimEnd(); Code = $LASTEXITCODE }
}

# 单次 A 记录查询；-Server 为空时走系统默认解析器
function ResolveA {
    param([string]$Name, [string]$Server)
    try {
        if ($Server) {
            $r = Resolve-DnsName -Name $Name -Type A -Server $Server -QuickTimeout -ErrorAction Stop
        } else {
            $r = Resolve-DnsName -Name $Name -Type A -QuickTimeout -ErrorAction Stop
        }
        return @($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
    } catch { return @() }
}

$POISON = '^(185\.45\.5\.35|69\.171\.|104\.244\.|31\.13\.|223\.109\.|198\.41\.|0\.0\.0\.0)'
function Show-R($name, $ips) {
    if (-not $ips -or $ips.Count -eq 0) {
        Write-Host ("  " + $name + " -> ") -NoNewline
        Write-Host "解析失败" -ForegroundColor Red
        return $false
    }
    $poisoned = @($ips | Where-Object { $_ -match $POISON })
    Write-Host ("  " + $name + " -> " + ($ips -join ', ')) -NoNewline
    if ($poisoned.Count -gt 0) { Write-Host "   <-- 疑似被污染" -ForegroundColor Red }
    else { Write-Host "   OK" -ForegroundColor Green }
    return ($poisoned.Count -eq 0)
}

# ---------------- 1/5 计划任务 ----------------
Head "1/5 计划任务"
$taskOk = $false
try {
    $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
    $i = Get-ScheduledTaskInfo -TaskName $task -ErrorAction Stop
    $last = '从未运行'
    if ($i.LastRunTime -and $i.LastRunTime.Year -gt 1970) { $last = $i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
    Say ("  任务状态 : " + $t.State)
    Say ("  上次运行 : " + $last)
    Say ("  上次结果 : " + $i.LastTaskResult + "   (0=正常, 267009=运行中, 267011=本次开机还没跑)")
    if ($i.LastTaskResult -eq 0 -or $i.LastTaskResult -eq 267009) { Good "任务已成功启动过" }
    elseif ($i.LastTaskResult -eq 267011) { Warn "本次开机后任务还没运行过（可能刚开机，或触发器未生效）" }
    else { Warn ("上次结果为 " + $i.LastTaskResult + "，任务可能启动失败") }
    $taskOk = ($t.State -ne 'Disabled')
} catch {
    $q = Inv-Exe 'schtasks.exe' @('/query', '/tn', $task, '/v', '/fo', 'LIST')
    if ($q.Code -eq 0) {
        ($q.Out -split "`r?`n" | Where-Object { $_ -match '状态|Status|结果|Result|上次运行|Last Run' }) |
            ForEach-Object { Say ("  " + $_.Trim()) }
        $taskOk = $true
    } else {
        Bad "查不到计划任务 DNSTCPProxy（不存在，或本窗口权限不足；若代理仍在跑可忽略）"
    }
}

# ---------------- 2/5 端口监听 ----------------
Head "2/5 本地 $port 端口监听"
$udpOk = $false; $tcpOk = $false
$n = Inv-Exe 'netstat.exe' @('-ano')
$udpLine = @($n.Out -split "`r?`n" | Select-String '^\s*UDP\s+127\.0\.0\.1:53\s')
$tcpLine = @($n.Out -split "`r?`n" | Select-String '^\s*TCP\s+127\.0\.0\.1:53\s+\S+\s+LISTENING')
if ($udpLine.Count -gt 0) { $udpOk = $true; Good ("UDP 监听中  " + $udpLine[0].ToString().Trim()) }
else { Bad "没有 UDP 127.0.0.1:53 监听（代理没在跑）" }
if ($tcpLine.Count -gt 0) { $tcpOk = $true; Good ("TCP 监听中  " + $tcpLine[0].ToString().Trim()) }
else { Warn "没有 TCP 127.0.0.1:53 监听（只影响 nslookup -vc 这类显式 TCP 查询）" }

$pidValue = ''
if ($udpLine.Count -gt 0) { $pidValue = ($udpLine[0].ToString().Trim() -split '\s+')[-1] }
if ($pidValue) {
    $p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if ($p) { Good ("进程 : " + $p.ProcessName + " (PID " + $pidValue + ")") }
    else { Say ("  PID " + $pidValue + " 是 SYSTEM 进程，普通权限看不到名字（正常）") }
}
if ($pidValue) {
    $tasklist = Inv-Exe 'tasklist.exe' @('/FI', ("PID eq " + $pidValue), '/FO', 'CSV', '/NH')
    if ($tasklist.Out -match 'node') { Say "  命令行确认：node.exe" }
}

if (-not $taskOk -and $udpOk) {
    Say "  提示：读不到任务信息（权限），但代理在监听 -> 任务本身正常"
    $issues = @($issues | Where-Object { $_.Text -notlike '查不到计划任务*' })
}

# ---------------- 3/5 网卡 DNS ----------------
Head "3/5 网卡 DNS 设置"
$dnsFound = $false
try {
    $adapters = Get-DnsClientServerAddress -ErrorAction Stop
    foreach ($a in $adapters) {
        $srv = @($a.ServerAddresses)
        if ($srv.Count -eq 0) { continue }
        $line = ("  {0} ({1}) : {2}" -f $a.InterfaceAlias, $a.AddressFamily, ($srv -join ', '))
        if ($srv -contains '127.0.0.1') { $dnsFound = $true; Good $line.Trim() }
        else { Say $line }
    }
} catch {
    $netsh = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'show', 'dnsservers')
    ($netsh.Out -split "`r?`n") | Where-Object { $_ -match 'DNS|配置|Configuration|静态|Static|自动|DHCP' } |
        ForEach-Object { Say ("  " + $_.Trim()) }
    if ($netsh.Out -match '127\.0\.0\.1') { $dnsFound = $true }
}
if (-not $dnsFound) { Bad "没有任何网卡把 127.0.0.1 当 DNS（修改没生效，或网卡换了）" }

# ---------------- 4/5 解析测试 ----------------
Head "4/5 解析测试"
Say "  -- 经本地代理 (127.0.0.1) --"
$p1 = Show-R 'www.baidu.com' (ResolveA 'www.baidu.com' '127.0.0.1')
$p2 = Show-R 'www.google.com' (ResolveA 'www.google.com' '127.0.0.1')
Say "`n  -- 系统默认解析（实际生效路径） --"
$s1 = Show-R 'www.baidu.com' (ResolveA 'www.baidu.com' $null)
$s2 = Show-R 'www.google.com' (ResolveA 'www.google.com' $null)

if (-not $p1 -and -not $p2) { Bad "经代理的解析全失败（代理在监听但不转发，看 proxy.log）" }
if ($p2 -and -not $s2) { Bad "经代理干净，系统解析却拿到污染/失败 -> 有程序绕过代理（浏览器 Secure DNS 或次级 DNS）" }
if ($s1 -and -not $p1) { Warn "系统解析正常但代理侧失败（少见，可能是回环被拦截）" }

# ---------------- 5/5 代理日志 ----------------
Head "5/5 代理日志"
if (Test-Path $logFile) {
    $fi = Get-Item $logFile -ErrorAction SilentlyContinue
    if ($fi) { Say ("  最后写入 : " + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
    Say "  尾部 6 行 :"
    Get-Content $logFile -Tail 6 -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { Say ("    " + $_) }
} else {
    Warn ("没有日志文件 " + $logFile + "（说明 node 从未成功启动过）")
}

$boot = $null
try {
    $up = (Get-Counter '\System\System Up Time' -ErrorAction Stop).CounterSamples[0].CookedValue
    $boot = (Get-Date).AddSeconds(-1 * $up)
} catch {
    try {
        $tick = [Environment]::TickCount64 / 1000
        $boot = (Get-Date).AddSeconds(-1 * $tick)
    } catch {}
}
if ($boot) { Say ("`n  本次开机 : " + $boot.ToString('yyyy-MM-dd HH:mm:ss')) }

# ---------------- 结论 ----------------
Head "结论"
if ($issues.Count -eq 0) {
    Write-Host "  一切正常：开机自动拉起、监听正常、解析干净。" -ForegroundColor Green
} else {
    Write-Host ("  发现 " + $issues.Count + " 个问题：") -ForegroundColor Yellow
    foreach ($it in $issues) {
        if ($it.Level -eq "X") { Write-Host ("   [X] " + $it.Text) -ForegroundColor Red }
        else { Write-Host ("   [!] " + $it.Text) -ForegroundColor Yellow }
    }
    if (@($issues | Where-Object { $_.Level -eq "X" }).Count -eq 0) {
        Write-Host "  以上都是提示级，代理本身工作正常。" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  常见修法：" -ForegroundColor Cyan
    Write-Host "   - 代理没跑        : 双击「一键使用.cmd」重装（会自动清旧任务）"
    Write-Host "   - 系统解析被污染  : 网卡里删掉备用 DNS，只留 127.0.0.1；关掉浏览器 Secure DNS"
    Write-Host "   - 任务从未运行    : 管理员窗口执行  schtasks /run /tn DNSTCPProxy  再看本检测"
    Write-Host "   - 想全部撤销      : 双击「一键恢复.cmd」"
}
Write-Host ""
exit 0
