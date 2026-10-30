# 校园网 DNS 被污染？用 DNS-over-TCP 一键绕过去（Windows 单文件 exe）

> 适用于：校园网 / 运营商把 **UDP 53** 的 DNS 应答篡改（把域名解析到错误 IP），但 **TCP 53** 还能正常通行的情况。
> 不适用于：整站封锁、SNI 阻断、域名本身被 RST —— 那是另一类问题，本工具管不了。

## 它做了什么

不改 DNS 服务器，而是**改查询的传输通道**：

```
浏览器 / 系统  ──UDP 53──▶  127.0.0.1:53（本机代理）  ──TCP 53──▶  8.8.8.8:53
                   被污染                                 真实应答
```

DNS over TCP 的报文有一个 2 字节长度前缀，代理负责拆包、转发、再按 UDP 回给系统。校园网关按域名篡改 UDP 应答时，看不到也改不了这条 TCP 通道里的内容。

安装完成后：

| 项目 | 位置 / 内容 |
|---|---|
| 代理程序 | `C:\ProgramData\DNSTCPProxy\DNSTCPProxy.exe`（安装时自动复制过去） |
| 运行日志 | `C:\ProgramData\DNSTCPProxy\proxy.log`（每条查询一行，含耗时与上游；超过 4 MB 轮转） |
| 计划任务 | `DNSTCPProxy`（开机自启 / SYSTEM / 最高权限） |
| 网卡 DNS | 首选 `127.0.0.1`，备用 `223.5.5.5` |

## 下载与使用

到 [Releases](../../releases) 下载 `DNSTCPProxy.exe`，**双击即可**（无参数时打印帮助并暂停）。

| 命令 | 作用 | 需要管理员 |
|---|---|---|
| `DNSTCPProxy.exe install` | 安装并启用：自检上游 → 清旧任务与进程 → 建开机任务 → 改网卡 DNS → 验收（失败自动回滚） | 是（会自动弹 UAC） |
| `DNSTCPProxy.exe status` | 只读体检：任务状态 / 53 端口 / 网卡 DNS / 解析是否仍被污染 / 代理日志 | 否 |
| `DNSTCPProxy.exe uninstall` | 卸载：删任务、杀进程、清部署目录、把网卡 DNS 恢复为 DHCP | 是（会自动弹 UAC） |
| `DNSTCPProxy.exe selftest [上游]` | 测试某个上游的 TCP 53 是否可用，默认 `8.8.8.8` | 否 |
| `DNSTCPProxy.exe run [端口] [上游]` | 前台运行代理（计划任务用的就是它），默认 `53` / `8.8.8.8` | 否（端口 <1024 除外） |
| `DNSTCPProxy.exe version` | 版本号 | 否 |

典型用法：

1. 双击 `DNSTCPProxy.exe` → 弹 UAC 点“是”，看到 `安装完成`，随便打开一个网站确认能上网。
2. 以后每次开机，计划任务会自动拉起代理；想确认状态就运行 `DNSTCPProxy.exe status`。
3. 不想用了，运行 `DNSTCPProxy.exe uninstall`，网络设置会恢复为自动获取。

命令行快速自检（不需要管理员）：

```powershell
nslookup www.google.com
```

- 返回 `142.251.x.x` 这类 Google 网段 → 正常
- 返回 `185.45.5.35`、`69.171.x.x`、`104.244.x.x`、`0.0.0.0` → 仍在被污染

## 环境要求

- Windows 10 / 11（x64 / x86 均可，单文件未依赖特定 CPU 架构）
- **.NET Framework 4.x**（Windows 10/11 系统自带，无需安装任何东西）
- 安装 / 卸载时需要管理员权限（程序会自己请求提权）

不需要 Node.js、不需要 PowerShell 脚本、不受脚本执行策略限制 —— 这就是 exe 版存在的理由。

## 为什么是 exe

| | exe 版 | .cmd 版（仓库内保留） |
|---|---|---|
| 依赖 | 无（.NET Framework 系统自带） | 需要 Node.js 18+ |
| 执行策略 | 不受限 | 需 `-ExecutionPolicy Bypass` |
| 文件数 | 1 | 3 |
| 中文编码坑 | 无 | PS 5.1 按 GBK 解析会报错，依赖 BOM |

## 备用：三个自包含 .cmd

如果你机器上已经有 Node.js、或者想直接看源码逻辑，仓库里仍保留三个 `.cmd`（PowerShell 与代理源码全部内嵌，不需要 `.ps1` / `.js` 辅助文件）：

| 文件 | 作用 | 需要管理员 |
|---|---|---|
| `一键使用.cmd` | 安装并启用（等同 `install`） | 是（自动弹 UAC） |
| `检测状态.cmd` | 只读体检（等同 `status`） | 否 |
| `一键恢复.cmd` | 卸载并恢复 DHCP（等同 `uninstall`） | 是（自动弹 UAC） |

## 已知限制（重要）

1. **浏览器自带的 Secure DNS 会绕过系统 DNS**。Chrome / Edge 的 `设置 → 隐私 → 使用安全 DNS` 若开启，查询不走本机代理，请关掉。
2. **网卡的「DNS 服务器加密」要设为「仅未加密」**。否则 Windows 会尝试对 `127.0.0.1` 做 DoH，导致解析卡顿。
3. **备用 DNS `223.5.5.5` 是泄漏口**。首选无响应时会回落到它，此时仍可能拿到被污染的答案。追求纯净可以只留 `127.0.0.1`。
4. **会破坏「分域解析」**。部分校园网对内网资源（如 `webvpn.xxx.edu.cn`）校内返回内网 IP、校外返回公网 IP。本工具拿到的是公网记录，可能导致这类站点打不开。临时办法：直接访问内网 IP，或在 `C:\Windows\System32\drivers\etc\hosts` 里给它写死。
5. **上游默认只认 `8.8.8.8`**。实测多个公共 DNS 中只有它的 TCP 53 稳定可达；其余多数被 RST 或返回污染值。`run` 子命令可以临时换上游，`install` 用的是默认值。
6. **不解决 SNI 阻断**。如果丢包发生在 TLS 握手（按域名 RST），DNS 再干净也没用。

## 常见问题

**装完上不了网？** 运行 `DNSTCPProxy.exe uninstall` 立即恢复；`install` 第 5 步验收失败时也会自动回滚为 DHCP。

**提示 53 端口被占用？** 通常是上次的代理进程还在。`install` 会按端口找占用进程并结束它；若被别的程序（如某些加速器、Docker）占用，先退出那个程序。

**任务在跑但 127.0.0.1:53 无应答？** 看 `C:\ProgramData\DNSTCPProxy\proxy.log`：空文件说明进程没起来，有内容但报错说明上游不通（换个网络环境试试）。

**某些域名解析失败（SERVFAIL）？** 8.8.8.8 对少数只有国内解析器认识的域名（部分 CDN、内网域名）会返回 SERVFAIL。这是上游的局限，不是工具的问题。

## 卸载

```powershell
DNSTCPProxy.exe uninstall
```

它做的事：删计划任务 → 结束代理进程 → 把每块网卡的 IPv4/IPv6 DNS 恢复为 DHCP → 刷新缓存 → 清理 `C:\ProgramData\DNSTCPProxy`。

## 从源码构建

只有一个 C# 文件 `src/DNSTCPProxy.cs`，用系统自带的编译器即可：

```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /codepage:65001 /target:exe /platform:anycpu /r:System.dll /r:System.Core.dll /out:DNSTCPProxy.exe src\DNSTCPProxy.cs
```

或直接双击 `src\build.cmd`。

## 免责声明

- 仅供个人学习与自用。请遵守所在学校 / 单位的网络使用规定。
- 程序会修改系统网卡 DNS 并创建开机自启的系统级计划任务，请自行确认风险。
- 不保证在任何网络环境下可用，也不对因使用造成的网络中断负责。

## License

[MIT](LICENSE)

---

## English summary

A single-file Windows tool that bypasses UDP-53 DNS tampering by tunneling queries over TCP 53 to a public resolver. No Node.js, no scripts — just one `.exe` built on the .NET Framework that ships with Windows.

```
install:   proxy on 127.0.0.1:53 → upstream TCP 8.8.8.8:53, scheduled task at boot (SYSTEM),
           NIC DNS set to 127.0.0.1 with 223.5.5.5 as fallback, auto-rollback on failure
status:    read-only check of task / port / NIC DNS / poisoning / proxy log
uninstall: remove task, kill process, delete files, restore DHCP DNS
```

Caveats: browser Secure DNS bypasses it; split-horizon (campus-internal) domains may break; it does **not** defeat SNI-based blocking.
