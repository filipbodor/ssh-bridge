// Runs as Student. Contains no Railway account credentials or Mac private keys.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

class Connector
{
    static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string LogFile = Path.Combine(Root, "connector.log");
    static readonly object LogLock = new object();

    static void Log(string message)
    {
        if (String.IsNullOrEmpty(message)) return;
        lock (LogLock)
        {
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 1048576)
            {
                if (File.Exists(LogFile + ".1")) File.Delete(LogFile + ".1");
                File.Move(LogFile, LogFile + ".1");
            }
            File.AppendAllText(LogFile, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
        }
    }

    static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0 || value.IndexOf('\n') >= 0 || value.IndexOf('\r') >= 0)
            throw new Exception("Invalid configuration value");
        return "\"" + value + "\"";
    }

    static Dictionary<string, string> Config()
    {
        var data = new Dictionary<string, string>();
        foreach (string line in File.ReadAllLines(Path.Combine(Root, "connection.ini")))
        {
            if (line.Trim().Length == 0 || line.TrimStart().StartsWith("#")) continue;
            int separator = line.IndexOf('=');
            if (separator < 1) throw new Exception("Invalid connection.ini line");
            data[line.Substring(0, separator).Trim()] = line.Substring(separator + 1).Trim();
        }
        int port;
        if (!data.ContainsKey("host") || !Regex.IsMatch(data["host"], @"^[a-zA-Z0-9][a-zA-Z0-9.-]*$"))
            throw new Exception("Missing or invalid relay host");
        if (!data.ContainsKey("port") || !Int32.TryParse(data["port"], out port) || port < 1 || port > 65535)
            throw new Exception("Missing or invalid relay port");
        return data;
    }

    static int Main(string[] args)
    {
        bool created;
        using (var mutex = new Mutex(true, @"Local\IsaacLink-" + Environment.UserName, out created))
        {
            if (!created) return 0;
            try
            {
                var config = Config();
                string ssh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\OpenSSH\ssh.exe");
                string key = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".ssh\isaac_relay_ed25519");
                string known = Path.Combine(Root, "known_hosts");
                if (!File.Exists(ssh) || !File.Exists(key) || !File.Exists(known))
                    throw new Exception("Missing SSH executable, device key or pinned relay host key");
                if (args.Length > 0 && args[0] == "--check")
                {
                    Log("Configuration validated.");
                    return 0;
                }
                Log("Connector started as " + Environment.UserName);
                while (!File.Exists(Path.Combine(Root, "stop")))
                {
                    var info = new ProcessStartInfo(ssh);
                    info.Arguments = "-N -T -p " + config["port"] + " -i " + Quote(key) +
                        " -o BatchMode=yes -o IdentitiesOnly=yes -o ForwardAgent=no" +
                        " -o StrictHostKeyChecking=yes -o HostKeyAlias=isaac-relay" +
                        " -o UserKnownHostsFile=" + Quote(known) +
                        " -o ExitOnForwardFailure=yes -o ConnectTimeout=15" +
                        " -o ServerAliveInterval=30 -o ServerAliveCountMax=3" +
                        " -R 127.0.0.1:22022:127.0.0.1:22 device@" + config["host"];
                    info.UseShellExecute = false;
                    info.CreateNoWindow = true;
                    info.RedirectStandardError = true;
                    info.RedirectStandardOutput = true;
                    using (var process = new Process())
                    {
                        process.StartInfo = info;
                        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
                        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
                        process.Start();
                        process.BeginErrorReadLine();
                        process.BeginOutputReadLine();
                        Log("Connecting to relay.");
                        while (!process.WaitForExit(1000))
                        {
                            if (File.Exists(Path.Combine(Root, "stop")))
                            {
                                process.Kill();
                                process.WaitForExit();
                                break;
                            }
                        }
                        process.WaitForExit();
                        Log("SSH exited: " + process.ExitCode);
                    }
                    for (int i = 0; i < 15 && !File.Exists(Path.Combine(Root, "stop")); i++)
                        Thread.Sleep(1000);
                }
                Log("Connector stopped.");
                return 0;
            }
            catch (Exception ex)
            {
                Log(ex.Message);
                return 1;
            }
        }
    }
}
