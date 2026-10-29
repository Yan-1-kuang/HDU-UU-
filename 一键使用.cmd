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
echo   DNS over TCP  -  one click ENABLE  (standalone)
echo  --------------------------------------------------
echo   problem : campus/ISP rewrites answers on UDP 53
echo   fix     : ask 8.8.8.8 over TCP 53 instead
echo   local   : 127.0.0.1:53  -^>  TCP 8.8.8.8:53
echo   startup : scheduled task "DNSTCPProxy" (SYSTEM)
echo   backup  : 223.5.5.5
echo  ==================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8);$i=$c.IndexOf('#__PS_BLOCK_'+'START__');iex $c.Substring($i)"
set RC=%errorlevel%
echo.
if "%RC%"=="0" (
    echo [OK] Enabled. Quick test:  nslookup www.google.com
    echo      expect 142.251.x.x  ^(not 185.45.5.35 / 69.171.x.x^)
) else (
    echo [FAIL] exit code %RC% . Nothing was left half-configured.
    echo        Read the messages above for the failing step.
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%
#__PS_BLOCK_START__
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$task        = 'DNSTCPProxy'
$port        = 53
$ups         = '8.8.8.8'
$dataDir     = Join-Path $env:ProgramData 'DNSTCPProxy'
$installedJs = Join-Path $dataDir 'dns-tcp-proxy.js'
$runCmd      = Join-Path $dataDir 'run-proxy.cmd'
$logFile     = Join-Path $dataDir 'proxy.log'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# 调外部程序：外部程序的 stderr 会被 PS 当成错误对象，在 Stop 策略下会终止脚本。
# 统一走这里，临时降级策略并自行判断退出码。
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

# 取一个"已连接"的网卡名，三种方式逐级兜底（部分环境 WMI/CIM 被策略禁用）
function Get-UpIfName {
    try {
        $n = (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } |
              Select-Object -First 1).Name
        if ($n) { return $n }
    } catch {}
    try {
        $n = (Get-NetIPConfiguration -ErrorAction Stop |
              Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway } |
              Select-Object -First 1).InterfaceAlias
        if ($n) { return $n }
    } catch {}
    $line = (& netsh.exe interface show interface 2>$null |
             Select-String -Pattern '\s(Connected|已连接)\s' | Select-Object -First 1)
    if ($line) { return (($line -split '\s{2,}')[-1]).Trim() }
    return $null
}

function Test-LocalDns {
    try {
        $r = Resolve-DnsName -Name 'www.baidu.com' -Server '127.0.0.1' -Type A -QuickTimeout -ErrorAction Stop
        return [bool]($r | Where-Object { $_.IPAddress })
    } catch { return $false }
}

function Stop-ProxyByPort {
    for ($i = 0; $i -lt 3; $i++) {
        if (-not (Test-LocalDns)) { return $true }
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
        if (-not $owners) { return $false }
        foreach ($procId in $owners) {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Say "  已结束占用 53 端口的进程 PID $procId"
            } catch { Say "  PID $procId 无法结束：$($_.Exception.Message)" Yellow }
        }
        Start-Sleep -Seconds 1
    }
    return (-not (Test-LocalDns))
}

# ---- 内嵌的代理源码：本文件自包含，不再依赖外部 dns-tcp-proxy.js ----
$JS = @'
// dns-tcp-proxy.js v2 —— 本地 UDP/TCP DNS → 上游 TCP 53，绕过 UDP 53 劫持
// 用法:
//   自检:  node dns-tcp-proxy.js --selftest
//   运行:  node dns-tcp-proxy.js [端口，默认 53] [上游，默认 8.8.8.8]
'use strict';
const dgram = require('dgram');
const net = require('net');

const argv = process.argv.slice(2);
const SELFTEST = argv.includes('--selftest');
const rest = argv.filter(a => !a.startsWith('--'));
const PORT = parseInt(rest[0] || '53', 10);
const upstreams = (rest[1] || '8.8.8.8').split(',').map(s => s.trim()).filter(Boolean)
  .map(h => ({ host: h, port: 53 }));
const TIMEOUT = 4000;
let rr = 0;

const t0 = () => Date.now();
function ts() { return new Date().toLocaleTimeString('zh-CN', { hour12: false }); }

// ---- DNS 报文小工具 ----
function qname(buf) {
  try {
    let i = 12, labels = [];
    while (i < buf.length && buf[i] !== 0) {
      const len = buf[i];
      if ((len & 0xc0) === 0xc0) break;
      labels.push(buf.subarray(i + 1, i + 1 + len).toString('ascii'));
      i += len + 1;
    }
    return labels.join('.');
  } catch { return '?'; }
}
function qtype(buf) {
  try {
    let i = 12;
    while (i < buf.length && buf[i] !== 0) { i += buf[i] + 1; }
    return buf.readUInt16BE(i + 1);
  } catch { return -1; }
}
function buildQuery(name, type) {
  const b = [Buffer.from([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])];
  for (const p of name.split('.')) { b.push(Buffer.from([p.length])); b.push(Buffer.from(p, 'ascii')); }
  b.push(Buffer.from([0x00, (type >> 8) & 0xff, type & 0xff, 0x00, 0x01]));
  return Buffer.concat(b);
}
function answers(buf) {
  try {
    const an = buf.readUInt16BE(6);
    if (!an) return `(0 条应答, rcode=${buf[3] & 0x0f})`;
    let i = 12;
    const qd = buf.readUInt16BE(4);
    for (let q = 0; q < qd; q++) {
      while (i < buf.length && buf[i] !== 0) { i += (buf[i] & 0xc0) === 0xc0 ? 2 : buf[i] + 1; if ((buf[i - 2] & 0xc0) === 0xc0) break; }
      i += 1 + 4;
    }
    const out = [];
    for (let a = 0; a < an && i + 10 < buf.length; a++) {
      if ((buf[i] & 0xc0) === 0xc0) i += 2; else { while (i < buf.length && buf[i] !== 0) i += buf[i] + 1; i += 1; }
      const type = buf.readUInt16BE(i), rdlen = buf.readUInt16BE(i + 8);
      const rdata = buf.subarray(i + 10, i + 10 + rdlen);
      if (type === 1 && rdlen === 4) out.push([...rdata].join('.'));
      else if (type === 5) out.push('CNAME');
      else if (type === 16) out.push('TXT');
      else out.push('type' + type);
      i += 10 + rdlen;
    }
    return out.slice(0, 4).join(', ');
  } catch (e) { return '(解析失败)'; }
}

// ---- 上游 TCP 查询 ----
function queryTCP(msg) {
  return new Promise((resolve, reject) => {
    const u = upstreams[rr++ % upstreams.length];
    const sock = net.connect(u.port, u.host);
    let buf = Buffer.alloc(0), done = false;
    const fail = e => { if (!done) { done = true; sock.destroy(); reject(e); } };
    sock.setTimeout(TIMEOUT, () => fail(new Error('超时 ' + u.host)));
    sock.on('error', e => fail(e));
    sock.on('connect', () => {
      const len = Buffer.alloc(2); len.writeUInt16BE(msg.length, 0);
      sock.write(Buffer.concat([len, msg]));
    });
    sock.on('data', d => {
      buf = Buffer.concat([buf, d]);
      if (buf.length < 2) return;
      const need = buf.readUInt16BE(0);
      if (buf.length < 2 + need) return;
      if (done) return;
      done = true;
      resolve({ resp: buf.subarray(2, 2 + need), upstream: u.host });
      sock.end();
    });
    sock.on('close', () => fail(new Error('连接被关闭 ' + u.host)));
  });
}

async function serve(msg, label) {
  const t = t0();
  const name = qname(msg);
  try {
    const { resp, upstream } = await queryTCP(msg);
    console.log(`[${ts()}] ${label}  ${name} (type${qtype(msg)})  ${Date.now() - t}ms  via TCP ${upstream}  -> ${answers(resp)}`);
    return resp;
  } catch (e) {
    console.log(`[${ts()}] ${label}  ${name}  失败 ${Date.now() - t}ms: ${e.message}`);
    return null;
  }
}

// ---- 自检模式 ----
if (SELFTEST) {
  (async () => {
    console.log('自检: 直接对每个上游做一次 TCP 查询（不经过本地端口）\n');
    let bad = 0;
    for (const u of upstreams) {
      const saved = rr;
      rr = upstreams.indexOf(u);
      const t = t0();
      try {
        const { resp } = await queryTCP(buildQuery('www.google.com', 1));
        console.log(`  ${u.host}: 成功 ${Date.now() - t}ms -> ${answers(resp)}`);
      } catch (e) {
        bad++;
        console.log(`  ${u.host}: 失败 ${Date.now() - t}ms -> ${e.message}`);
      }
      rr = saved;
    }
    console.log('\n如果上面是「成功」，说明上游 TCP 通，问题只可能在本机监听/回环。');
    // 机器可读结果：避免调用方依赖中文文案（控制台代码页不同会乱码）
    console.log('SELFTEST_RESULT=' + (bad === 0 ? 'OK' : 'FAIL'));
    process.exit(bad === 0 ? 0 : 1);
  })();
}

// ---- 服务模式 ----
if (!SELFTEST) {
const udp = dgram.createSocket('udp4');
udp.on('message', async (msg, rinfo) => {
  const resp = await serve(msg, 'UDP<-' + rinfo.address);
  if (!resp) return;
  udp.send(resp, rinfo.port, rinfo.address, err => { if (err) console.log('  回包失败: ' + err.message); });
});
udp.on('error', e => console.log('UDP 错误: ' + e.message));
udp.bind(PORT, '127.0.0.1', () => console.log(`UDP 已监听 127.0.0.1:${PORT}`));

const tcp = net.createServer(sock => {
  let buf = Buffer.alloc(0);
  sock.on('data', async d => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 2) {
      const need = buf.readUInt16BE(0);
      if (buf.length < 2 + need) break;
      const q = buf.subarray(2, 2 + need);
      buf = buf.subarray(2 + need);
      const resp = await serve(q, 'TCP<-客户端');
      if (!resp) { sock.destroy(); return; }
      const len = Buffer.alloc(2); len.writeUInt16BE(resp.length, 0);
      sock.write(Buffer.concat([len, resp]));
    }
  });
  sock.on('error', () => {});
});
tcp.on('error', e => console.log('TCP 错误: ' + e.message));
tcp.listen(PORT, '127.0.0.1', () => console.log(`TCP 已监听 127.0.0.1:${PORT}`));
}
'@

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '需要管理员权限：请右键本文件 → 以管理员身份运行' }

    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) {
        foreach ($c in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", 'D:\nodejs\node.exe', 'C:\nodejs\node.exe', "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
            if ($c -and (Test-Path $c)) { $node = $c; break }
        }
    }
    if (-not $node) { throw '找不到 node.exe：请先安装 Node.js 18 或更高版本（https://nodejs.org），或把 node.exe 所在目录加入 PATH' }
    Say "node   : $node"

    # ---------- 0. 落地代理源码 ----------
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    [System.IO.File]::WriteAllText($installedJs, $JS, (New-Object System.Text.UTF8Encoding($false)))
    Say "proxy  : $installedJs  （已从本文件内嵌源码生成）"

    # ---------- 1. 上游自检 ----------
    Say "`n[1/5] 上游 TCP ${ups}:53 自检 ..." Cyan
    $r = Inv-Exe $node @($installedJs, '--selftest')
    Write-Host $r.Out
    if ($r.Code -ne 0) { throw "自检未通过（exit=$($r.Code)）：走 TCP 到 $ups 拿不到应答。已中止，未改动任何设置。" }
    Say "  自检通过" Green

    # ---------- 2. 确认本地 53 端口空闲 ----------
    Say "`n[2/5] 检查本地 $port 端口 ..." Cyan
    $null = Inv-Exe 'schtasks.exe' @('/delete', '/tn', $task, '/f') -AllowFail
    try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*dns-tcp-proxy.js*' } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                Say "  已结束旧代理 PID $($_.ProcessId)"
            }
    } catch {
        if (Test-LocalDns) {
            Say "  发现已有代理在应答，尝试结束它 ..." Yellow
            $null = Stop-ProxyByPort
        }
    }
    Start-Sleep -Seconds 1
    if (Test-LocalDns) { $null = Stop-ProxyByPort; Start-Sleep -Seconds 1 }
    if (Test-LocalDns) { throw "127.0.0.1:53 仍被占用。请在管理员 PowerShell 里查：netstat -ano -p UDP | findstr :53" }
    Say "  端口空闲" Green

    $n53 = Inv-Exe 'netstat.exe' @('-ano', '-p', 'UDP') -AllowFail
    $used = @($n53.Out -split "`r?`n" | Select-String ':(53)\s')
    if ($used.Count -gt 0) {
        Say "  注意：53 端口已有监听，可能抢不到端口：" Yellow
        $used | ForEach-Object { Say "    $_" Yellow }
    }

    # ---------- 3. 建计划任务并立即启动 ----------
    Say "`n[3/5] 创建开机自启任务（SYSTEM）..." Cyan
    $wrap = "@echo off`r`n" +
            '"' + $node + '" "' + $installedJs + '" ' + $port + ' ' + $ups + ' >> "' + $logFile + '" 2>&1' + "`r`n"
    [System.IO.File]::WriteAllText($runCmd, $wrap, (New-Object System.Text.ASCIIEncoding))
    if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

    $registered = $false
    try {
        $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $runCmd + '"')
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description 'DNS over TCP proxy for 127.0.0.1:53' -Force | Out-Null
        Start-ScheduledTask -TaskName $task
        $registered = $true
    } catch {
        Say "  计划任务 cmdlet 不可用，退回 schtasks.exe：$($_.Exception.Message)" Yellow
    }
    if (-not $registered) {
        $line = 'schtasks /create /tn "' + $task + '" /tr "cmd /c \"' + $runCmd + '\""' +
                ' /sc onstart /ru SYSTEM /rl HIGHEST /f'
        $c = Inv-Exe 'cmd.exe' @('/c', $line) -AllowFail
        if ($c.Code -ne 0) { throw "创建计划任务失败（exit=$($c.Code)）：`n$($c.Out)" }
        $null = Inv-Exe 'schtasks.exe' @('/run', '/tn', $task) -AllowFail
    }
    Say "  任务已启动，等待代理就绪 ..."

    $ok = $false
    foreach ($i in 1..10) {
        Start-Sleep -Seconds 2
        if (Test-LocalDns) { $ok = $true; break }
    }
    if (-not $ok) {
        Say "`n---- 启动失败，诊断信息 ----" Yellow
        $q = Inv-Exe 'schtasks.exe' @('/query', '/tn', $task, '/v', '/fo', 'LIST') -AllowFail
        ($q.Out -split "`r?`n" | Where-Object { $_ -match '状态|Status|结果|Result|上次运行|Last Run|任务名|TaskName' }) |
            ForEach-Object { Say "  $_" }
        if (Test-Path $logFile) {
            Say "`n  --- proxy.log ---" Yellow
            Get-Content $logFile -Tail 25 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Say "  $_" }
        } else {
            Say "  没有生成 proxy.log：说明 node 根本没被拉起来（任务动作或权限问题）" Yellow
        }
        $n = Inv-Exe 'netstat.exe' @('-ano', '-p', 'UDP') -AllowFail
        ($n.Out -split "`r?`n" | Select-String ':(53)\s') | ForEach-Object { Say "  端口占用: $_" }
        $null = Inv-Exe 'schtasks.exe' @('/end', '/tn', $task) -AllowFail
        $null = Inv-Exe 'schtasks.exe' @('/delete', '/tn', $task, '/f') -AllowFail
        try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        throw "任务启动了但 127.0.0.1:53 无应答（诊断信息见上）。日志文件: $logFile"
    }
    Say "  本地代理应答正常" Green

    # ---------- 4. 切换系统 DNS ----------
    Say "`n[4/5] 把系统 DNS 指向 127.0.0.1 ..." Cyan
    $iface = Get-UpIfName
    if (-not $iface) { throw '找不到已连接的网卡，请手动把 DNS 设为 127.0.0.1' }
    Say "  网卡: $iface"

    $ifArg = 'name="' + $iface + '"'
    $null = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'set', 'dns', $ifArg, 'static', '127.0.0.1', 'primary') -AllowFail
    $null = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'add', 'dns', $ifArg, '223.5.5.5', 'index=2') -AllowFail
    $null = Inv-Exe 'ipconfig.exe' @('/flushdns') -AllowFail
    Start-Sleep -Seconds 2

    # ---------- 5. 验收 ----------
    Say "`n[5/5] 验收（走系统解析器）..." Cyan
    $finalOk = $false
    try {
        $sys = Resolve-DnsName -Name 'www.baidu.com' -Type A -ErrorAction Stop
        $ips = @($sys | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        $finalOk = ($ips.Count -gt 0)
        if ($finalOk) { Say "  www.baidu.com -> $($ips -join ', ')" Green }
    } catch { $finalOk = $false }
    if (-not $finalOk) {
        Say "验收失败，正在回滚网卡 DNS 为 DHCP ..." Red
        $null = Inv-Exe 'netsh.exe' @('interface', 'ipv4', 'set', 'dns', $ifArg, 'dhcp') -AllowFail
        $null = Inv-Exe 'ipconfig.exe' @('/flushdns') -AllowFail
        throw '已回滚网卡 DNS（计划任务保留，可手动排查后再切）。'
    }

    Say @"

安装完成 ✔
  计划任务 : $task  （开机自启 / SYSTEM / 最高权限）
  部署目录 : $dataDir
  运行日志 : $logFile
  上游     : TCP ${ups}:53
  网卡 DNS : $iface -> 127.0.0.1（备用 223.5.5.5）

还需你手动做一件事（很重要）：
  设置 → 网络和 Internet → 网卡 → 硬件属性
  → 把「DNS 服务器加密」改成「仅未加密」（或关闭）
  否则 Windows 会尝试对 127.0.0.1 做 DoH，解析会变慢甚至失败。

以后想确认是否正常：双击「检测状态.cmd」
撤销全部改动：双击「一键恢复.cmd」
"@ Cyan
    exit 0
}
catch {
    Write-Host ""
    Write-Host ("  [失败] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
