// DNSTCPProxy - 校园网 DNS 污染绕过工具（DNS-over-TCP 单文件版）
// 编译：csc /codepage:65001 /target:exe /out:DNSTCPProxy.exe DNSTCPProxy.cs
// 用法：DNSTCPProxy.exe install | uninstall | status | run [port] [upstream] | selftest [upstream]

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Threading;

static class Program
{
    const string Version = "1.0.0";
    const string TaskName = "DNSTCPProxy";
    const int DefaultPort = 53;
    const string DefaultUpstream = "8.8.8.8";
    const string FallbackDns = "223.5.5.5";

    static string DataDir
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DNSTCPProxy"); }
    }
    static string InstalledExe { get { return Path.Combine(DataDir, "DNSTCPProxy.exe"); } }
    static string LogFile { get { return Path.Combine(DataDir, "proxy.log"); } }

    static readonly object LogLock = new object();
    static bool RunningAsServiceLike;
    static string _logPath;          // null = 不写文件（没有写权限时只输出控制台）
    static bool _logReady;

    static void EnsureLog()
    {
        if (_logReady) return;
        _logReady = true;
        try
        {
            Directory.CreateDirectory(DataDir);
            _logPath = LogFile;
        }
        catch
        {
            // 没有管理员权限时退到临时目录，至少保留日志
            try
            {
                var alt = Path.Combine(Path.GetTempPath(), "DNSTCPProxy");
                Directory.CreateDirectory(alt);
                _logPath = Path.Combine(alt, "proxy.log");
            }
            catch { _logPath = null; }
        }
    }

    static int Main(string[] rawArgs)
    {
        int code = 0;
        try { code = Dispatch(rawArgs); }
        catch (Exception ex) { try { Console.WriteLine("[!] 出错：" + ex.Message); } catch { } code = 1; }

        bool wantsPause = rawArgs.Length == 0 || rawArgs.Any(a => a.Equals("--pause", StringComparison.OrdinalIgnoreCase));
        if (wantsPause)
        {
            try { Console.WriteLine(); Console.WriteLine("按任意键退出 ..."); Console.ReadKey(true); } catch { }
        }
        return code;
    }

    static int Dispatch(string[] rawArgs)
    {
        try { Console.OutputEncoding = new UTF8Encoding(false); }
        catch { }

        var args = rawArgs.Select(a => a.ToLowerInvariant()).ToArray();
        string cmd = args.Length > 0 ? args[0] : "help";
        EnsureLog();

        if (cmd == "run")
        {
            int port = args.Length > 1 ? ParseIntOr(rawArgs[1], DefaultPort) : DefaultPort;
            string ups = rawArgs.Length > 2 ? rawArgs[2] : DefaultUpstream;
            return RunProxy(port, ups);
        }
        if (cmd == "selftest")
        {
            string ups = rawArgs.Length > 1 ? rawArgs[1] : DefaultUpstream;
            return SelfTest(ups);
        }
        if (cmd == "install") return RequireAdmin("install", DoInstall);
        if (cmd == "uninstall") return RequireAdmin("uninstall", DoUninstall);
        if (cmd == "status") return DoStatus();
        if (cmd == "version" || cmd == "-v" || cmd == "--version") { Console.WriteLine("DNSTCPProxy " + Version); return 0; }

        // 双击运行（无参数）= 交互菜单
        if (rawArgs.Length == 0) return RunMenu();

        PrintHelp();
        return 0;
    }

    // ---------------------------------------------------------------- 双击菜单

    static bool TaskExists()
    {
        return Run("schtasks.exe", "/query /tn " + TaskName, true).ExitCode == 0;
    }

    static bool IsListening(int port)
    {
        try
        {
            var ns = Run("netstat.exe", "-ano -p UDP", true);
            foreach (var line in ns.Output.Split('\n'))
            {
                var t = line.Trim();
                if (!t.StartsWith("UDP")) continue;
                var parts = t.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length >= 2 && parts[1].EndsWith(":" + port)) return true;
            }
        }
        catch { }
        return false;
    }

    static int RunMenu()
    {
        bool admin = IsAdmin();
        while (true)
        {
            try { Console.Clear(); } catch { }
            Console.WriteLine();
            Console.WriteLine("  DNSTCPProxy " + Version + "   校园网 DNS 污染绕过（DNS over TCP）");
            Console.WriteLine("  " + new string('=', 54));

            bool installed = TaskExists();
            bool running = IsListening(DefaultPort);
            if (installed && running) Say("  状态：已安装，代理正在运行（127.0.0.1:" + DefaultPort + "）");
            else if (installed) Say("  状态：已安装，但代理没在运行（可重新安装）");
            else Say("  状态：未安装");

            if (!admin) Say("  权限：普通用户（选项 1 / 3 会弹 UAC 提权）");
            Say("  日志： " + (_logPath == null ? "(不可写)" : _logPath));
            Console.WriteLine();
            Say("    1   安装并启用");
            Say("    2   检查状态（只读）");
            Say("    3   卸载并恢复网络设置");
            Say("    0   退出");
            Console.WriteLine();
            Console.Write("  请选择 [1/2/3/0]: ");

            string line;
            try { line = Console.ReadLine(); } catch { return 0; }
            if (line == null) return 0;
            line = line.Trim().ToLowerInvariant();

            if (line == "0" || line == "") return 0;

            if (line == "1")
            {
                if (admin) DoInstall();
                else return RequireAdmin("install", DoInstall);
            }
            else if (line == "2")
            {
                DoStatus();
            }
            else if (line == "3")
            {
                if (admin) DoUninstall();
                else return RequireAdmin("uninstall", DoUninstall);
            }
            else
            {
                Say("  无效输入，请按 1 / 2 / 3 / 0。");
            }

            Console.WriteLine();
            Console.Write("  按回车返回菜单 ...");
            try { if (Console.ReadLine() == null) return 0; } catch { return 0; }
        }
    }

    static int InteractiveInstall()
    {
        if (Console.IsInputRedirected) { PrintHelp(); return 0; }

        Console.WriteLine("DNSTCPProxy " + Version + " - 用 DNS over TCP 绕过 UDP 53 投毒");
        Console.WriteLine();
        Console.WriteLine("即将安装，会做这几件事：");
        Console.WriteLine("  · 代理监听 127.0.0.1:53，查询经 TCP 53 转发到 " + DefaultUpstream + ":53");
        Console.WriteLine("  · 把网卡 DNS 改为 127.0.0.1，备用 " + FallbackDns);
        Console.WriteLine("  · 创建开机自启计划任务 " + TaskName + "（SYSTEM，最高权限）");
        Console.WriteLine("  · 需要管理员权限，下一步会弹 UAC");
        Console.WriteLine();
        Console.WriteLine("随时可运行  DNSTCPProxy.exe uninstall  完全撤销。");
        Console.WriteLine();
        Console.Write("开始安装？[Y/n] ");

        bool yes;
        try
        {
            var k = Console.ReadKey(true);
            Console.WriteLine();
            yes = k.Key == ConsoleKey.Enter || k.KeyChar == 'y' || k.KeyChar == 'Y';
        }
        catch { Console.WriteLine(); yes = false; }

        if (yes) return RequireAdmin("install", DoInstall);

        Console.WriteLine("已取消，没有改动系统。下面是可以用的命令：");
        Console.WriteLine();
        PrintHelp();
        return 0;
    }

    static int ParseIntOr(string s, int d)
    {
        int v;
        return int.TryParse(s, out v) && v > 0 && v < 65536 ? v : d;
    }

    static void PrintHelp()
    {
        Console.WriteLine("DNSTCPProxy " + Version + " - 用 DNS over TCP 绕过 UDP 53 投毒");
        Console.WriteLine();
        Console.WriteLine("  DNSTCPProxy.exe install            安装并启用（需要管理员，会自动提权）");
        Console.WriteLine("  DNSTCPProxy.exe status             只读体检：任务 / 端口 / 网卡 DNS / 解析结果");
        Console.WriteLine("  DNSTCPProxy.exe uninstall          卸载并把网卡 DNS 恢复为自动获取（需要管理员）");
        Console.WriteLine("  DNSTCPProxy.exe selftest [上游]    测试上游 TCP 53 是否可用，默认 " + DefaultUpstream);
        Console.WriteLine("  DNSTCPProxy.exe run [端口] [上游]  前台运行代理（计划任务用的就是它），默认 53 / " + DefaultUpstream);
        Console.WriteLine();
        Console.WriteLine("安装后：代理监听 127.0.0.1:53，网卡 DNS 指向它，查询经 TCP 53 转发到上游。");
        Console.WriteLine("日志： " + LogFile);
        Console.WriteLine();
        Console.WriteLine("提示：直接双击本程序（不带参数）= 运行 install，会先问一句再开始。");
    }

    // ---------------------------------------------------------------- 权限

    static bool IsAdmin()
    {
        try
        {
            using (var id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    static int RequireAdmin(string cmd, Func<int> action)
    {
        if (IsAdmin()) return action();
        try
        {
            var self = Process.GetCurrentProcess().MainModule.FileName;
            var psi = new ProcessStartInfo(self, cmd + " --pause");
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            var p = Process.Start(psi);
            if (p != null) p.WaitForExit();
            return p != null ? p.ExitCode : 1;
        }
        catch
        {
            Console.WriteLine("[!] 需要管理员权限：请右键本程序 -> 以管理员身份运行");
            return 1;
        }
    }

    // ---------------------------------------------------------------- 输出 / 日志

    static void Say(string s) { Console.WriteLine(s); }

    static void Log(string s)
    {
        var line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + s;
        lock (LogLock)
        {
            if (_logPath != null)
            {
                try
                {
                    var fi = new FileInfo(_logPath);
                    if (fi.Exists && fi.Length > 4 * 1024 * 1024)
                    {
                        var bak = _logPath + ".1";
                        try { if (File.Exists(bak)) File.Delete(bak); File.Move(_logPath, bak); } catch { }
                    }
                    File.AppendAllText(_logPath, line + Environment.NewLine, new UTF8Encoding(false));
                }
                catch { }
            }
            if (RunningAsServiceLike) { }
            try { Console.WriteLine(line); } catch { }
        }
    }

    // ---------------------------------------------------------------- 代理

    static int RunProxy(int port, string upstream)
    {
        RunningAsServiceLike = true;
        EnsureLog();

        var udpThread = new Thread(delegate () { UdpLoop(port, upstream); });
        udpThread.IsBackground = true;
        udpThread.Start();

        var tcpThread = new Thread(delegate () { TcpLoop(port, upstream); });
        tcpThread.IsBackground = true;
        tcpThread.Start();

        Log("proxy start  port=" + port + "  upstream=TCP " + upstream + ":53  version=" + Version);
        while (true) Thread.Sleep(1000);
    }

    static void UdpLoop(int port, string upstream)
    {
        UdpClient udp = null;
        try
        {
            udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, port));
            while (true)
            {
                var remote = new IPEndPoint(IPAddress.Any, 0);
                var query = udp.Receive(ref remote);
                var client = remote;
                ThreadPool.QueueUserWorkItem(delegate (object state)
                {
                    var t0 = Environment.TickCount;
                    try
                    {
                        var resp = Forward(upstream, query);
                        lock (LogLock) { try { udp.Send(resp, resp.Length, client); } catch { } }
                        LogQuery("UDP", query, resp, upstream, Environment.TickCount - t0);
                    }
                    catch (Exception ex) { Log("[!] UDP 转发失败 " + ex.Message); }
                }, null);
            }
        }
        catch (Exception ex)
        {
            Log("[!] UDP " + port + " 监听失败：" + ex.Message);
        }
    }

    static void TcpLoop(int port, string upstream)
    {
        TcpListener listener = null;
        try
        {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start(64);
            while (true)
            {
                var client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(delegate (object state)
                {
                    var c = (TcpClient)state;
                    var t0 = Environment.TickCount;
                    try
                    {
                        using (c)
                        {
                            var ns = c.GetStream();
                            ns.ReadTimeout = 5000;
                            var hdr = ReadExact(ns, 2);
                            int n = (hdr[0] << 8) | hdr[1];
                            if (n <= 0) return;
                            var query = ReadExact(ns, n);
                            var resp = Forward(upstream, query);
                            var outBuf = new byte[resp.Length + 2];
                            outBuf[0] = (byte)(resp.Length >> 8);
                            outBuf[1] = (byte)(resp.Length & 0xFF);
                            Array.Copy(resp, 0, outBuf, 2, resp.Length);
                            ns.Write(outBuf, 0, outBuf.Length);
                            ns.Flush();
                            LogQuery("TCP", query, resp, upstream, Environment.TickCount - t0);
                        }
                    }
                    catch (Exception ex) { Log("[!] TCP 会话失败 " + ex.Message); }
                }, client);
            }
        }
        catch (Exception ex)
        {
            Log("[!] TCP " + port + " 监听失败：" + ex.Message);
        }
    }

    static byte[] Forward(string upstream, byte[] query)
    {
        return QueryTcp(upstream, query, 4000);
    }

    static void LogQuery(string proto, byte[] query, byte[] resp, string upstream, int ms)
    {
        try
        {
            var q = Dns.Question(query);
            var a = Dns.Answers(resp);
            Log(proto + "<- " + q + "  " + ms + "ms  via TCP " + upstream + "  -> " + (a.Count == 0 ? "(无应答记录)" : string.Join(",", a.ToArray())));
        }
        catch { }
    }

    // ---------------------------------------------------------------- 上游测试

    static int SelfTest(string upstream)
    {
        Say("自检：直接对上游 " + upstream + ":53 做 TCP 查询（不经过本地端口）");
        Say("");
        var names = new[] { "www.baidu.com", "www.google.com" };
        int bad = 0;
        foreach (var name in names)
        {
            var q = Dns.BuildQuery(name, 1);
            var t0 = Environment.TickCount;
            try
            {
                var resp = QueryTcp(upstream, q, 5000);
                var ms = Environment.TickCount - t0;
                var ips = Dns.Answers(resp);
                var rcode = resp.Length > 3 ? (resp[3] & 0x0F) : -1;
                if (rcode != 0 || ips.Count == 0)
                {
                    bad++;
                    Say("  " + name + "  失败  " + ms + "ms  rcode=" + rcode + "  记录=" + ips.Count);
                }
                else
                {
                    Say("  " + name + "  成功  " + ms + "ms  -> " + string.Join(",", ips.ToArray()));
                }
            }
            catch (Exception ex)
            {
                bad++;
                Say("  " + name + "  失败  " + ex.Message);
            }
        }
        Say("");
        if (bad == 0) { Say("SELFTEST_RESULT=OK"); Say("上游可用。"); return 0; }
        Say("SELFTEST_RESULT=FAIL");
        Say("上游不可用：TCP 53 到 " + upstream + " 拿不到应答，换一个网络环境再试。");
        return 1;
    }

    static byte[] QueryTcp(string upstream, byte[] query, int timeoutMs)
    {
        using (var cli = new TcpClient())
        {
            var ar = cli.BeginConnect(upstream, 53, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs))
            {
                try { cli.Close(); } catch { }
                throw new TimeoutException("连不上 " + upstream + ":53");
            }
            cli.EndConnect(ar);
            cli.NoDelay = true;

            var ns = cli.GetStream();
            ns.ReadTimeout = timeoutMs;
            ns.WriteTimeout = timeoutMs;

            var all = new byte[query.Length + 2];
            all[0] = (byte)(query.Length >> 8);
            all[1] = (byte)(query.Length & 0xFF);
            Array.Copy(query, 0, all, 2, query.Length);
            ns.Write(all, 0, all.Length);
            ns.Flush();

            var hdr = ReadExact(ns, 2);
            int n = (hdr[0] << 8) | hdr[1];
            if (n <= 0 || n > 65535) throw new Exception("应答长度异常: " + n);
            return ReadExact(ns, n);
        }
    }

    static byte[] ReadExact(Stream s, int count)
    {
        var buf = new byte[count];
        int got = 0;
        while (got < count)
        {
            int r = s.Read(buf, got, count - got);
            if (r <= 0) throw new IOException("连接被提前关闭");
            got += r;
        }
        return buf;
    }

    // ---------------------------------------------------------------- 安装

    static int DoInstall()
    {
        Say("DNSTCPProxy " + Version + "  安装（DNS over TCP 代理）");
        Say("");

        Say("[1/5] 上游 TCP 53 自检 ...");
        if (SelfTestQuiet(DefaultUpstream) != 0)
        {
            Say("  自检未通过：走 TCP 到 " + DefaultUpstream + " 拿不到应答。已中止，未改动任何设置。");
            return 1;
        }
        Say("  自检通过");

        Say("");
        Say("[2/5] 清理旧任务与旧进程 ...");
        Run("schtasks.exe", "/delete /tn " + TaskName + " /f", true);
        KillByPort(DefaultPort);
        KillByName("DNSTCPProxy");

        Say("");
        Say("[3/5] 部署并注册开机任务 ...");
        try { Directory.CreateDirectory(DataDir); }
        catch (Exception ex) { Say("  创建 " + DataDir + " 失败：" + ex.Message + "（请以管理员身份运行）"); return 1; }
        var self = Process.GetCurrentProcess().MainModule.FileName;
        if (!string.Equals(self, InstalledExe, StringComparison.OrdinalIgnoreCase))
        {
            try { File.Copy(self, InstalledExe, true); }
            catch (Exception ex) { Say("  复制到 " + InstalledExe + " 失败：" + ex.Message); return 1; }
        }
        Say("  程序: " + InstalledExe);

        // 路径 C:\ProgramData\ 不含空格，整条命令行用一对引号包住最稳
        var create = Run("schtasks.exe",
            "/create /tn " + TaskName + " /tr \"" + InstalledExe + " run\" /sc onstart /ru SYSTEM /rl HIGHEST /f", false);
        if (create.ExitCode != 0)
        {
            Say("  创建计划任务失败：");
            Say(create.Output);
            return 1;
        }
        Say("  任务: " + TaskName + "（开机 / SYSTEM / 最高权限）");

        Run("schtasks.exe", "/run /tn " + TaskName, true);
        Say("  已启动，等待本地端口应答 ...");

        bool ready = false;
        for (int i = 0; i < 10; i++)
        {
            Thread.Sleep(1000);
            if (LocalResolve("www.baidu.com").Count > 0) { ready = true; break; }
        }
        if (!ready)
        {
            Say("  [x] 任务启动了但 127.0.0.1:" + DefaultPort + " 无应答，已删除任务。");
            Say("      排查：" + LogFile);
            Run("schtasks.exe", "/delete /tn " + TaskName + " /f", true);
            return 1;
        }
        Say("  本地代理应答正常");

        Say("");
        Say("[4/5] 设置网卡 DNS ...");
        var adapters = UpAdapters();
        if (adapters.Count == 0) { Say("  [!] 没找到已连接的网卡"); }
        var changed = new List<string>();
        foreach (var ns in adapters)
        {
            var r1 = Run("netsh.exe", "interface ipv4 set dns name=\"" + ns + "\" static 127.0.0.1 primary", true);
            if (r1.ExitCode == 0)
            {
                Run("netsh.exe", "interface ipv4 add dns name=\"" + ns + "\" " + FallbackDns + " index=2", true);
                changed.Add(ns);
                Say("  " + ns + " -> 127.0.0.1 (备用 " + FallbackDns + ")");
            }
            else Say("  " + ns + " 设置失败：" + Short(r1.Output));
        }
        Run("ipconfig.exe", "/flushdns", true);

        Say("");
        Say("[5/5] 验收 ...");
        var check = LocalResolve("www.baidu.com");
        if (check.Count == 0)
        {
            Say("  [x] 验收失败，正在回滚网卡 DNS ...");
            foreach (var ns in changed) RestoreDhcp(ns);
            Run("schtasks.exe", "/delete /tn " + TaskName + " /f", true);
            Say("  已回滚为自动获取。");
            return 1;
        }
        Say("  经代理解析 www.baidu.com -> " + string.Join(",", check.ToArray()));
        Say("");
        Say("安装完成。");
        Say("  - 代理:  " + InstalledExe + " run");
        Say("  - 日志:  " + LogFile);
        Say("  - 体检:  DNSTCPProxy.exe status");
        Say("  - 卸载:  DNSTCPProxy.exe uninstall");
        Say("");
        Say("提示：浏览器自带的 Secure DNS 会绕过系统 DNS，请关闭；网卡“DNS 服务器加密”请设为“仅未加密”。");
        return 0;
    }

    static int SelfTestQuiet(string upstream)
    {
        try
        {
            var resp = QueryTcp(upstream, Dns.BuildQuery("www.baidu.com", 1), 5000);
            return (resp.Length > 3 && (resp[3] & 0x0F) == 0 && Dns.Answers(resp).Count > 0) ? 0 : 1;
        }
        catch { return 1; }
    }

    // ---------------------------------------------------------------- 卸载

    static int DoUninstall()
    {
        Say("DNSTCPProxy " + Version + "  卸载");
        Say("");
        Say("[1/4] 删除计划任务 ...");
        Run("schtasks.exe", "/delete /tn " + TaskName + " /f", true);
        Say("  完成");

        Say("");
        Say("[2/4] 结束代理进程 ...");
        int killed = KillByPort(DefaultPort) + KillByName("DNSTCPProxy");
        Say("  结束 " + killed + " 个进程");

        Say("");
        Say("[3/4] 恢复网卡 DNS 为自动获取 ...");
        var targets = new List<string>();
        foreach (var ns in UpAdapters()) targets.Add(ns);
        foreach (var ns in AdaptersWithLoopbackDns()) if (!targets.Contains(ns)) targets.Add(ns);
        if (targets.Count == 0) Say("  (没有需要恢复的网卡)");
        foreach (var ns in targets)
        {
            RestoreDhcp(ns);
            Say("  " + ns + " -> 自动获取");
        }
        Run("ipconfig.exe", "/flushdns", true);

        Say("");
        Say("[4/4] 清理部署目录 ...");
        try
        {
            foreach (var f in Directory.GetFiles(DataDir))
            {
                if (string.Equals(f, Process.GetCurrentProcess().MainModule.FileName, StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(f); } catch { }
            }
            Say("  " + DataDir + " 已清理（正在运行的本程序保留）");
        }
        catch { Say("  目录不存在，跳过"); }

        Say("");
        Say("卸载完成，网络设置已恢复为自动获取。");
        return 0;
    }

    static void RestoreDhcp(string nic)
    {
        Run("netsh.exe", "interface ipv4 set dnsservers name=\"" + nic + "\" source=dhcp", true);
        Run("netsh.exe", "interface ipv6 set dnsservers name=\"" + nic + "\" source=dhcp", true);
    }

    // ---------------------------------------------------------------- 体检

    static int DoStatus()
    {
        Say("DNSTCPProxy " + Version + "  状态体检");
        Say(new string('-', 52));

        Say("[1/5] 计划任务");
        var q = Run("schtasks.exe", "/query /tn " + TaskName + " /v /fo LIST", true);
        if (q.ExitCode == 0) Say("  " + FirstUseful(q.Output));
        else Say("  查不到任务（未安装，或当前窗口权限不足）");

        Say("");
        Say("[2/5] 本地 53 端口");
        bool listening = false;
        var netstat = Run("netstat.exe", "-ano -p UDP", true);
        foreach (var line in netstat.Output.Split('\n'))
        {
            var t = line.Trim();
            if (t.StartsWith("UDP") && (t.Contains("127.0.0.1:53 ") || t.EndsWith("127.0.0.1:53")))
            {
                listening = true;
                Say("  正在监听: " + t);
            }
        }
        if (!listening) Say("  没有程序监听 127.0.0.1:53");

        Say("");
        Say("[3/5] 网卡 DNS");
        foreach (var ns in UpAdapters())
        {
            var d = Run("netsh.exe", "interface ipv4 show dnsservers name=\"" + ns + "\"", true);
            var vals = ExtractIps(d.Output);
            Say("  " + ns + ": " + (vals.Count == 0 ? "(自动获取)" : string.Join(", ", vals.ToArray())));
        }

        Say("");
        Say("[4/5] 解析测试");
        var sysB = SystemResolve("www.baidu.com");
        var sysG = SystemResolve("www.google.com");
        var viaB = LocalResolve("www.baidu.com");
        var viaG = LocalResolve("www.google.com");
        Say("  系统默认  www.baidu.com  -> " + (sysB.Count == 0 ? "失败" : string.Join(",", sysB.ToArray())));
        Say("  系统默认  www.google.com -> " + (sysG.Count == 0 ? "失败" : string.Join(",", sysG.ToArray())) + PoisonNote(sysG));
        Say("  经代理    www.baidu.com  -> " + (viaB.Count == 0 ? "失败" : string.Join(",", viaB.ToArray())));
        Say("  经代理    www.google.com -> " + (viaG.Count == 0 ? "失败" : string.Join(",", viaG.ToArray())) + PoisonNote(viaG));

        Say("");
        Say("[5/5] 代理日志");
        if (File.Exists(LogFile))
        {
            var fi = new FileInfo(LogFile);
            Say("  最后写入: " + fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") + "  (" + (fi.Length / 1024) + " KB)");
            var lines = File.ReadAllLines(LogFile, Encoding.UTF8);
            int from = Math.Max(0, lines.Length - 5);
            for (int i = from; i < lines.Length; i++) Say("  " + lines[i]);
        }
        else Say("  还没有日志（代理没启动过）");

        Say("");
        Say(new string('-', 52));
        if (listening && viaG.Count > 0) Say("结论：一切正常（代理在跑，经代理解析干净）。");
        else if (!listening && sysG.Count > 0) Say("结论：代理没在跑，当前用系统 DNS —— 解析可能仍被污染。");
        else Say("结论：有问题，建议重新运行 install。");
        return 0;
    }

    static List<string> SystemResolve(string name)
    {
        var list = new List<string>();
        try
        {
            foreach (var a in System.Net.Dns.GetHostAddresses(name))
                if (a.AddressFamily == AddressFamily.InterNetwork && a.ToString() != "0.0.0.0") list.Add(a.ToString());
        }
        catch { }
        return list;
    }

    static string PoisonNote(List<string> ips)
    {
        var bad = ips.Where(ip => ip.StartsWith("185.45.5.35") || ip.StartsWith("69.171.") || ip.StartsWith("104.244.") || ip.StartsWith("0.0.0.0")).ToList();
        return bad.Count > 0 ? "  << 疑似仍被污染" : "";
    }

    static string FirstUseful(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            var t = line.Trim();
            if (t.Length > 0) return t;
        }
        return "(空)";
    }

    // ---------------------------------------------------------------- 网卡

    static List<string> UpAdapters()
    {
        var list = new List<string>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.Description.IndexOf("Loopback", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                list.Add(ni.Name);
            }
        }
        catch { }
        return list;
    }

    static List<string> AdaptersWithLoopbackDns()
    {
        var list = new List<string>();
        try
        {
            var all = Run("netsh.exe", "interface ipv4 show dnsservers", true);
            var lines = all.Output.Split('\n');
            string cur = null;
            foreach (var raw in lines)
            {
                var line = raw.Trim();
                int idx = line.IndexOf("Configuration for interface \"", StringComparison.OrdinalIgnoreCase);
                if (idx >= 0)
                {
                    var rest = line.Substring(idx + 29);
                    int end = rest.IndexOf('"');
                    cur = end > 0 ? rest.Substring(0, end) : rest;
                    continue;
                }
                idx = line.IndexOf("接口 \"");
                if (idx >= 0)
                {
                    var rest = line.Substring(idx + 4);
                    int end = rest.IndexOf('"');
                    if (end > 0) cur = rest.Substring(0, end);
                    continue;
                }
                if (cur != null && line.StartsWith("127.0.0.1"))
                {
                    if (!list.Contains(cur)) list.Add(cur);
                }
            }
        }
        catch { }
        return list;
    }

    // ---------------------------------------------------------------- 进程 / 命令

    static int KillByPort(int port)
    {
        int killed = 0;
        try
        {
            var ns = Run("netstat.exe", "-ano -p UDP", true);
            var pids = new HashSet<int>();
            foreach (var line in ns.Output.Split('\n'))
            {
                var t = line.Trim();
                if (!t.StartsWith("UDP")) continue;
                var parts = t.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 4) continue;
                if (!parts[1].EndsWith(":" + port)) continue;
                int pid;
                if (int.TryParse(parts[parts.Length - 1], out pid) && pid > 4) pids.Add(pid);
            }
            foreach (var pid in pids)
            {
                try { var p = Process.GetProcessById(pid); p.Kill(); killed++; } catch { }
            }
        }
        catch { }
        return killed;
    }

    static int KillByName(string name)
    {
        int killed = 0;
        try
        {
            foreach (var p in Process.GetProcessesByName(name))
            {
                if (p.Id == Process.GetCurrentProcess().Id) continue;
                try { p.Kill(); killed++; } catch { }
            }
        }
        catch { }
        return killed;
    }

    class CmdResult
    {
        public int ExitCode;
        public string Output = "";
    }

    static CmdResult Run(string file, string args, bool quiet)
    {
        var r = new CmdResult();
        try
        {
            var psi = new ProcessStartInfo(file, args);
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            try { psi.StandardOutputEncoding = Encoding.GetEncoding(936); psi.StandardErrorEncoding = Encoding.GetEncoding(936); }
            catch { }
            using (var p = Process.Start(psi))
            {
                var sb = new StringBuilder();
                sb.Append(p.StandardOutput.ReadToEnd());
                sb.Append(p.StandardError.ReadToEnd());
                p.WaitForExit(30000);
                r.ExitCode = p.HasExited ? p.ExitCode : -1;
                r.Output = sb.ToString();
            }
        }
        catch (Exception ex)
        {
            r.ExitCode = -1;
            r.Output = ex.Message;
        }
        if (!quiet && r.ExitCode != 0) { }
        return r;
    }

    static string Short(string s)
    {
        if (string.IsNullOrEmpty(s)) return "(无输出)";
        var t = s.Replace("\r", " ").Replace("\n", " ").Trim();
        return t.Length > 120 ? t.Substring(0, 120) + "..." : t;
    }

    static List<string> ExtractIps(string text)
    {
        var list = new List<string>();
        foreach (var m in System.Text.RegularExpressions.Regex.Matches(text, @"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"))
        {
            var ip = m.ToString();
            if (ip == "0.0.0.0") continue;
            if (!list.Contains(ip)) list.Add(ip);
        }
        return list;
    }

    // ---------------------------------------------------------------- 本地解析

    static List<string> LocalResolve(string name)
    {
        try
        {
            var q = Dns.BuildQuery(name, 1);
            using (var udp = new UdpClient())
            {
                udp.Client.ReceiveTimeout = 3000;
                var ep = new IPEndPoint(IPAddress.Loopback, DefaultPort);
                udp.Send(q, q.Length, ep);
                var remote = new IPEndPoint(IPAddress.Any, 0);
                var resp = udp.Receive(ref remote);
                return Dns.Answers(resp);
            }
        }
        catch { return new List<string>(); }
    }
}

// ---------------------------------------------------------------- DNS 报文

static class Dns
{
    public static byte[] BuildQuery(string name, ushort qtype)
    {
        var parts = name.Split(new[] { '.' }, StringSplitOptions.RemoveEmptyEntries);
        int size = 12 + parts.Sum(p => 1 + p.Length) + 1 + 4;
        var buf = new byte[size];
        buf[0] = 0x12; buf[1] = 0x34;
        buf[2] = 0x01; buf[3] = 0x00;   // RD
        buf[4] = 0x00; buf[5] = 0x01;   // QDCOUNT
        int off = 12;
        foreach (var p in parts)
        {
            buf[off++] = (byte)p.Length;
            var b = Encoding.ASCII.GetBytes(p);
            Array.Copy(b, 0, buf, off, b.Length);
            off += b.Length;
        }
        buf[off++] = 0;
        buf[off++] = (byte)(qtype >> 8); buf[off++] = (byte)(qtype & 0xFF);
        buf[off++] = 0x00; buf[off++] = 0x01;
        return buf;
    }

    public static string Question(byte[] msg)
    {
        int pos = 12;
        var name = ReadName(msg, ref pos);
        if (pos + 3 < msg.Length)
        {
            int t = (msg[pos] << 8) | msg[pos + 1];
            var tn = t == 1 ? "A" : t == 28 ? "AAAA" : t == 5 ? "CNAME" : t == 12 ? "PTR" : t == 16 ? "TXT" : "type" + t;
            return name + " (" + tn + ")";
        }
        return name;
    }

    public static List<string> Answers(byte[] msg)
    {
        var list = new List<string>();
        if (msg.Length < 12) return list;
        int ancount = (msg[6] << 8) | msg[7];
        int off = 12;
        try
        {
            int p = off;
            ReadName(msg, ref p);
            off = p + 4;
            for (int i = 0; i < ancount && off + 10 < msg.Length; i++)
            {
                off = SkipName(msg, off);
                int type = (msg[off] << 8) | msg[off + 1];
                int rdlen = (msg[off + 8] << 8) | msg[off + 9];
                off += 10;
                if (type == 1 && rdlen == 4)
                {
                    list.Add(msg[off] + "." + msg[off + 1] + "." + msg[off + 2] + "." + msg[off + 3]);
                }
                off += rdlen;
            }
        }
        catch { }
        return list;
    }

    static string ReadName(byte[] msg, int start)
    {
        var p = start;
        return ReadName(msg, ref p);
    }

    static string ReadName(byte[] msg, ref int pos)
    {
        var sb = new StringBuilder();
        int off = pos;
        int guard = 0;
        while (off < msg.Length && guard++ < 128)
        {
            int len = msg[off];
            if (len == 0) { off++; break; }
            if ((len & 0xC0) == 0xC0) { off += 2; break; }
            off++;
            if (off + len > msg.Length) break;
            sb.Append(Encoding.ASCII.GetString(msg, off, len)).Append('.');
            off += len;
        }
        pos = off;
        return sb.ToString().TrimEnd('.');
    }

    static int SkipName(byte[] msg, int off)
    {
        int guard = 0;
        while (off < msg.Length && guard++ < 128)
        {
            int len = msg[off];
            if (len == 0) return off + 1;
            if ((len & 0xC0) == 0xC0) return off + 2;
            off += 1 + len;
        }
        return off;
    }
}
