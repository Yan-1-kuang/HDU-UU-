@echo off
setlocal
cd /d "%~dp0"
set "SELF=%~f0"

net session >nul 2>&1
if not errorlevel 1 goto run
echo [i] Administrator rights required. Requesting UAC elevation...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
exit /b

:run
echo.
echo  ==================================================
echo   DNS over TCP  -  one click RESTORE  (standalone)
echo  --------------------------------------------------
echo   removes : scheduled task "DNSTCPProxy"
echo   removes : C:\ProgramData\DNSTCPProxy  (proxy + log)
echo   resets  : every adapter back to DHCP DNS (v4 + v6)
echo   keeps   : nothing. machine goes back to plain DNS
echo  ==================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8);$i=$c.IndexOf('#__PS_BLOCK_'+'START__');iex $c.Substring($i)"
set RC=%errorlevel%
echo.
if "%RC%"=="0" (
    echo [OK] Restored. DNS is back to what the router hands out.
) else (
    echo [FAIL] exit code %RC% . Read the messages above.
)
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

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Inv-Exe {
    param([string]$FilePath, [string[]]$ArgList, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = & $FilePath @ArgList 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    $text = $text.TrimEnd()
    if (-not $AllowFail -and $code -ne 0) { throw "执行 $FilePath 失败 (exit=$code)：`n$text" }
    return [pscustomobject]@{ Out = $text; Code = $code }
}

function Test-LocalDns {
    try {
        $r = Resolve-DnsName -Name 'www.baidu.com' -Server '127.0.0.1' -Type A -QuickTimeout -ErrorAction Stop
        return [bool]($r | Where-Object { $_.IPAddress })
    } catch { return $false }
}

# 结束占用本地 53 端口的代理进程：CIM 命令行匹配 -> Get-NetUDPEndpoint -> netstat 三级兜底
function Stop-Proxy {
    $killed = 0
    try {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*dns-tcp-proxy.js*' } |
            ForEach-Object {
                try {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                    Say "  已结束代理进程 PID $($_.ProcessId)" Green
                    $killed++
                } catch { Say "  PID $($_.ProcessId) 无法结束：$($_.Exception.Message)" Yellow }
            }
    } catch { Say "  CIM 查询不可用，改用端口/进程名兜底" Yellow }

    if (-not $killed -and -not (Test-LocalDns)) { return 0 }

    for ($i = 0; $i -lt 3; $i++) {
        if (-not (Test-LocalDns)) { break }
        $owners = @()
        try {
            $owners = @(Get-NetUDPEndpoint -LocalPort $port -ErrorAction Stop | ForEach-Object { $_.OwningProcess })
        } catch {
            $owners = @(& netstat.exe -ano -p UDP 2>$null |
                        Select-String ':(53)\s' |
                        ForEach-Object { ($_.Line -split '\s+')[-1] } |
                        Where-Object { $_ -match '^\d+$' })
        }
        $owners = @($owners | Where-Object { $_ -and $_ -ne 0 } | Select-Object -Unique)
        if (-not $owners) { break }
        foreach ($procId in $owners) {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Say "  已结束占用 53 端口的进程 PID $procId" Green
                $killed++
            } catch { Say "  PID $procId 无法结束：$($_.Exception.Message)" Yellow }
        }
        Start-Sleep -Seconds 1
    }
    return $killed
}

# 需要把 DNS 改回自动获取的网卡：当前 DNS 含 127.0.0.1 的（含断开状态）+ 已连接的
function Get-ResetTargets {
    $set = New-Object System.Collections.ArrayList

    try {
        Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object {
            if (@($_.ServerAddresses) -contains '127.0.0.1') { $null = $set.Add($_.InterfaceAlias) }
        }
    } catch {
        $raw = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'show', 'dnsservers')
        $cur = $null
        foreach ($line in ($raw.Out -split "`r?`n")) {
            if ($line -match '^接口 "(.+?)" 的配置' -or $line -match '^Configuration for interface "(.+?)"') {
                $cur = $Matches[1]
            } elseif ($cur -and $line -match '127\.0\.0\.1') {
                $null = $set.Add($cur)
            }
        }
    }

    try {
        Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } |
            ForEach-Object { $null = $set.Add($_.Name) }
    } catch {
        & netsh.exe interface show interface 2>$null |
            Select-String -Pattern '\s(Connected|已连接)\s' |
            ForEach-Object { $null = $set.Add((($_.Line -split '\s{2,}')[-1]).Trim()) }
    }

    return @($set | Where-Object { $_ } | Select-Object -Unique)
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '需要管理员权限：请右键本文件 → 以管理员身份运行' }

    # ---------- 1/4 删除计划任务 ----------
    Say "`n[1/4] 删除计划任务 $task ..." Cyan
    $null = Inv-Exe 'schtasks.exe' @('/end', '/tn', $task) -AllowFail
    $d = Inv-Exe 'schtasks.exe' @('/delete', '/tn', $task, '/f') -AllowFail
    try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    if ($d.Code -eq 0) { Say "  任务已删除" Green } else { Say "  任务本来就不存在，跳过" }

    # ---------- 2/4 结束进程并清理部署目录 ----------
    Say "`n[2/4] 结束代理进程并清理部署目录 ..." Cyan
    $k = Stop-Proxy
    Start-Sleep -Seconds 1
    if (Test-LocalDns) { Say "  警告：127.0.0.1:53 仍有程序在应答（可能是别的软件）" Yellow }
    else { Say "  本地 53 端口已释放" Green }

    if (Test-Path $dataDir) {
        try {
            Remove-Item $dataDir -Recurse -Force -ErrorAction Stop
            Say "  已删除 $dataDir" Green
        } catch {
            Say "  删除 $dataDir 失败：$($_.Exception.Message)" Yellow
        }
    } else { Say "  部署目录不存在，跳过" }

    # ---------- 3/4 网卡 DNS 恢复 DHCP ----------
    Say "`n[3/4] 网卡 DNS 恢复为自动获取 ..." Cyan
    $ifaces = Get-ResetTargets
    if (-not $ifaces -or $ifaces.Count -eq 0) {
        Say "  未找到需要重置的网卡，跳过（可手动改回自动获取）" Yellow
    } else {
        foreach ($iface in $ifaces) {
            $ifArg = 'name="' + $iface + '"'
            $r4 = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'set', 'dns', $ifArg, 'dhcp') -AllowFail
            $r6 = Inv-Exe 'netsh.exe' @('interface', 'ipv6', 'set', 'dns', $ifArg, 'dhcp') -AllowFail
            if ($r4.Code -eq 0) { Say "  ${iface} (IPv4) -> 自动获取" Green }
            else { Say "  ${iface} (IPv4) 恢复失败：$($r4.Out)" Yellow }
            if ($r6.Code -ne 0) { Say "  ${iface} (IPv6) 恢复失败（通常可忽略）" Yellow }
        }
    }
    $null = Inv-Exe 'ipconfig.exe' @('/flushdns') -AllowFail
    Start-Sleep -Seconds 2

    # ---------- 4/4 验证 ----------
    Say "`n[4/4] 验证解析（应走路由器/DHCP 下发的 DNS）..." Cyan
    $ok = $false
    try {
        $r = Resolve-DnsName -Name 'www.baidu.com' -Type A -ErrorAction Stop
        $ips = @($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($ips.Count -gt 0) { $ok = $true; Say "  www.baidu.com -> $($ips -join ', ')" Green }
    } catch { $ok = $false }
    if (-not $ok) {
        Say "  解析仍然失败，可能需要禁用再启用网卡，或重启一次" Yellow
    }

    Say @"

恢复完成 ✔
  计划任务 : 已删除
  部署目录 : 已清理（$dataDir）
  网卡 DNS : 已恢复自动获取
  之前的设置全部撤销，网络回到普通 UDP DNS 状态。

如果之前把「DNS 服务器加密」改成了「仅未加密」，可以改回默认了。
"@ Cyan
    exit 0
}
catch {
    Write-Host ""
    Write-Host ("  [失败] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
