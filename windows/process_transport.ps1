# Raw child-process transport for PowerShell 5.1 and 7. stdout never enters the
# PowerShell error-record pipeline; WSL startup stderr may use UTF-16LE while the
# Linux child uses UTF-8. Decode each stderr line independently, hiding no errors.
if (-not ('Delamain.ProcessTransport' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace Delamain {
    public sealed class ProcessResult {
        public int ExitCode;
        public string Output;
    }
    // A Linux session leader stays unreaped until cancellation finishes, so
    // its process-group id cannot be reused while we signal owned foreground
    // children. Workers that detach into another session keep running.
    internal sealed class Foreground : IDisposable {
        internal string[] Arguments;
        string control;
        FileStream requestLease, acknowledgementLease;
        static FileStream Lease(string path) {
            // Windows closes these exact handles on owner death, including
            // TerminateProcess. DrvFS then exposes a missing request to Linux.
            // Neither a detached guardian nor a PID lookup extends ownership.
            return new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite,
                FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.DeleteOnClose);
        }
        internal Foreground(string executable, string[] arguments) {
            string trusted = ProcessTransport.WslExecutable();
            if (!String.Equals(executable, "wsl.exe", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(executable, trusted, StringComparison.OrdinalIgnoreCase)) {
                Arguments = arguments; return;
            }
            int at = Array.IndexOf(arguments, "--exec");
            if (at < 0 || at + 1 == arguments.Length)
                throw new ArgumentException("Owned WSL foreground commands require --exec and an executable.");
            control = Path.Combine(Path.GetTempPath(), "delamain-foreground-" + Guid.NewGuid().ToString("N"));
            try {
                requestLease = Lease(control);
                byte[] initial = Encoding.UTF8.GetBytes("run");
                requestLease.Write(initial, 0, initial.Length); requestLease.Flush();
                acknowledgementLease = Lease(control + ".ack");
                List<string> mapping = new List<string>();
                for (int i = 0; i <= at; i++) mapping.Add(arguments[i]);
                mapping.Add("wslpath"); mapping.Add("-a"); mapping.Add("-u"); mapping.Add(control);
                ProcessResult mapped = ProcessTransport.RunCore(trusted, mapping.ToArray(), true, true, false, "", false);
                if (mapped.ExitCode != 0 || String.IsNullOrWhiteSpace(mapped.Output))
                    throw new IOException("WSL could not resolve its private foreground cancellation path.");
                List<string> owned = new List<string>();
                for (int i = 0; i <= at; i++) owned.Add(arguments[i]);
                owned.Add("python3"); owned.Add("-I"); owned.Add("-c"); owned.Add(Guardian); owned.Add(mapped.Output.Trim());
                for (int i = at + 1; i < arguments.Length; i++) owned.Add(arguments[i]);
                Arguments = owned.ToArray();
            } catch { Dispose(); throw; }
        }
        string ReadAcknowledgement() {
            using (FileStream file = new FileStream(control + ".ack", FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(file, Encoding.UTF8)) return reader.ReadToEnd();
        }
        void Decide(string decision) {
            Stopwatch deadline = Stopwatch.StartNew();
            while (true) {
                try {
                    using (FileStream file = new FileStream(control, FileMode.Open, FileAccess.Write,
                            FileShare.ReadWrite | FileShare.Delete)) {
                        byte[] bytes = Encoding.UTF8.GetBytes(decision);
                        file.SetLength(0); file.Write(bytes, 0, bytes.Length);
                    }
                    return;
                } catch (IOException) {
                    if (deadline.ElapsedMilliseconds >= 300) throw;
                    Thread.Sleep(10);
                }
            }
        }
        internal void Complete() {
            if (control != null) Decide("complete");
        }
        internal void Cancel(Process process) {
            if (control == null) return;
            Decide("cancel");
            Stopwatch deadline = Stopwatch.StartNew();
            while (deadline.ElapsedMilliseconds < 1500) {
                try { if (ReadAcknowledgement() == "done") break; }
                catch (IOException) { }
                Thread.Sleep(20);
            }
            // If WSL has not started Python yet, removing the control below
            // also tells a late guardian to exit before launching the command.
        }
        internal void Finish() {
            if (control == null) return;
            Stopwatch deadline = Stopwatch.StartNew();
            while (deadline.ElapsedMilliseconds < 1500) {
                try { if (ReadAcknowledgement() == "done") return; }
                catch (IOException) { }
                Thread.Sleep(20);
            }
            throw new IOException("The foreground guardian did not acknowledge completion within its cleanup deadline.");
        }
        public void Dispose() {
            if (control == null) return;
            try {
                if (requestLease != null) requestLease.Dispose();
            } finally {
                try {
                    if (acknowledgementLease != null) acknowledgementLease.Dispose();
                } finally { control = null; }
            }
            // DeleteOnClose owns deletion. A Linux acknowledgement writer may
            // still hold its fd after publishing done; a second File.Delete
            // would fail on the resulting Windows delete-pending path.
        }
        const string Guardian = @"
import os,signal,subprocess,sys,time,traceback
from pathlib import Path
control=Path(sys.argv[1])
acknowledgement=Path(str(control)+'.ack')
child=None
reaped=False
requested=False
def request(signum,frame):
    global requested
    requested=True
signal.signal(signal.SIGHUP,request)
signal.signal(signal.SIGTERM,request)
def state():
    if requested: return 'cancel'
    try: return control.read_text()
    except FileNotFoundError: return 'cancel'
def exited():
    return os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT) is not None
def stop():
    # Popen's leader is still pinned, even when it has already become a zombie.
    for sig in (signal.SIGTERM,signal.SIGKILL):
        try: os.killpg(child.pid,sig)
        except ProcessLookupError: pass
        if sig == signal.SIGTERM: time.sleep(.2)
    child.wait(timeout=1)
# WSL keeps its Windows pipe handles until its entry process exits. A separate
# session owns the pinned command; this entry process returns the observed
# leader status without reaping it or releasing cancellation ownership.
status_read,status_write=os.pipe()
if os.fork():
    os.close(status_write)
    try: status=os.read(status_read,32)
    finally: os.close(status_read)
    sys.exit(int(status) if status else 1)
os.close(status_read)
os.setsid()
status=None
try:
    if state() != 'run': sys.exit(1)
    child=subprocess.Popen(sys.argv[2:],start_new_session=True)
    # Only the command and its descendants own these pipes. The guardian must
    # not hold EOF hostage while waiting for the host's completion decision.
    os.close(0); os.close(1); os.close(2)
    while True:
        decision=state()
        if decision == 'cancel':
            stop(); reaped=True; sys.exit(1)
        if status is None and exited():
            status=os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOWAIT).si_status
            os.write(status_write,str(status).encode())
            os.close(status_write); status_write=None
        if decision == 'complete' and status is not None:
            # Same-group descendants remain owned through the host decision.
            stop(); reaped=True
            sys.exit(0)
        time.sleep(.02)
except Exception:
    # Report launch failures before releasing the WSL entry status pipe.
    traceback.print_exc()
    sys.exit(1)
finally:
    if child is not None and not reaped: stop()
    if status_write is not None: os.close(status_write)
    # Acknowledgement is written only after the exact foreground has exited.
    try:
        fd=os.open(acknowledgement,os.O_WRONLY|os.O_TRUNC)
        try: os.write(fd,b'done')
        finally: os.close(fd)
    except FileNotFoundError: pass
";
    }
    public sealed class ProcessOutput : IDisposable {
        Process process;
        StreamReader reader;
        Thread stderr;
        Exception stderrError;
        bool complete;
        Foreground owner;
        internal ProcessOutput(string executable, string[] arguments, bool redirectInput, bool rawInput, string input) {
            try {
                owner = new Foreground(executable, arguments);
                process = Process.Start(ProcessTransport.Info(executable, owner.Arguments, redirectInput));
                reader = new StreamReader(process.StandardOutput.BaseStream, new UTF8Encoding(false), false);
                stderr = new Thread(delegate() {
                    try { ProcessTransport.Errors(process.StandardError.BaseStream); }
                    catch (Exception e) { stderrError = e; }
                });
                stderr.IsBackground = true; stderr.Start();
                if (redirectInput) ProcessTransport.Input(process, rawInput, input);
            } catch { Dispose(); throw; }
        }
        public string ReadLine() { return reader.ReadLine(); }
        public int Complete() {
            stderr.Join();
            if (stderrError != null) throw stderrError;
            owner.Complete();
            process.WaitForExit();
            owner.Finish();
            int code = process.ExitCode;
            complete = true;
            return code;
        }
        public void Dispose() {
            if (process == null) { if (owner != null) owner.Dispose(); return; }
            try {
                if (!complete) {
                    try { owner.Cancel(process); } finally { ProcessTransport.Stop(process); }
                }
            } finally {
                if (reader != null) reader.Dispose();
                process.StandardError.Close();
                if (stderr != null && stderr.IsAlive) stderr.Join(500);
                process.Dispose(); process = null;
                if (owner != null) owner.Dispose();
            }
        }
    }
    public static class ProcessTransport {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetWindowsDirectory(StringBuilder buffer, uint size);
        static string WindowsDirectory() {
            // Ask Windows, rather than trusting the caller's cwd, PATH or
            // SystemRoot environment variable. Sysnative bypasses WOW64 redirection.
            StringBuilder directory = new StringBuilder(32768);
            uint length = GetWindowsDirectory(directory, (uint)directory.Capacity);
            if (length == 0 || length >= directory.Capacity)
                throw new IOException("Windows could not resolve its system directory.");
            return directory.ToString();
        }
        public static string WslExecutable() {
            string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
            string executable = Path.Combine(WindowsDirectory(), system, "wsl.exe");
            if (!File.Exists(executable))
                throw new FileNotFoundException("The trusted Windows WSL executable is unavailable.", executable);
            return executable;
        }
        internal static void Stop(Process process) {
            // Process keeps the handle of the exact child; never rediscover a
            // process by name or signal unrelated/detached worker processes.
            try {
                if (!process.HasExited) process.Kill();
                if (!process.WaitForExit(2000))
                    throw new IOException("The owned Windows WSL client did not exit within the cleanup deadline.");
            } catch (InvalidOperationException) { }
        }
        static string Quote(string value) {
            bool simple = value.Length > 0;
            foreach (char c in value) if (Char.IsWhiteSpace(c) || c == '"') simple = false;
            if (simple) return value;
            StringBuilder b = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append(c); }
                else { b.Append('\\', slashes); b.Append(c); }
                slashes = 0;
            }
            b.Append('\\', slashes * 2); b.Append('"');
            return b.ToString();
        }
        static bool Unicode(List<byte> line) {
            return (line.Count > 1 && line[0] == 255 && line[1] == 254) ||
                (line.Count > 5 && line[1] == 0 && line[3] == 0 && line[5] == 0);
        }
        static void ErrorLine(List<byte> line, Decoder decoder) {
            if (line.Count == 0) return;
            byte[] bytes = line.ToArray();
            char[] chars = new char[bytes.Length + 2];
            int count = decoder.GetChars(bytes, 0, bytes.Length, chars, 0, false);
            string text = new string(chars, 0, count);
            // At a mixed-encoding boundary a UTF-16 newline's trailing NUL can
            // precede the next UTF-8 line. It is transport framing, not content.
            text = text.TrimStart('\0', '\uFEFF').TrimEnd('\0');
            // This exact WSL startup diagnostic is unrelated to the invoked
            // Linux command. All other diagnostics and child errors survive.
            if (text.TrimEnd('\r', '\n') == "wsl: A localhost proxy configuration was detected but not mirrored into WSL. WSL in NAT mode does not support localhost proxies.") return;
            Console.Error.Write(text);
        }
        internal static void Errors(Stream stream) {
            List<byte> line = new List<byte>();
            Decoder utf8 = new UTF8Encoding(false).GetDecoder();
            Decoder unicode = Encoding.Unicode.GetDecoder();
            bool unicodeLine = false;
            bool continuation = false;
            int next;
            while ((next = stream.ReadByte()) != -1) {
                line.Add((byte)next);
                if (!continuation && line.Count == 6) unicodeLine = Unicode(line);
                bool newline = next == 10;
                if (newline && unicodeLine) {
                    newline = false;
                    if (line.Count % 2 == 1) {
                        int trailing = stream.ReadByte();
                        if (trailing >= 0) line.Add((byte)trailing);
                        newline = trailing == 0;
                    }
                }
                if (newline || line.Count >= 65536) {
                    if (!continuation && line.Count < 6) unicodeLine = Unicode(line);
                    ErrorLine(line, unicodeLine ? unicode : utf8); line.Clear();
                    continuation = !newline;
                    if (!continuation) unicodeLine = false;
                }
            }
            if (!continuation && line.Count < 6) unicodeLine = Unicode(line);
            ErrorLine(line, unicodeLine ? unicode : utf8);
        }
        internal static ProcessStartInfo Info(string executable, string[] arguments, bool redirectInput) {
            ProcessStartInfo info = new ProcessStartInfo();
            string trusted = WslExecutable();
            bool wsl = String.Equals(executable, "wsl.exe", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(executable, trusted, StringComparison.OrdinalIgnoreCase);
            info.FileName = wsl ? trusted : executable;
            if (wsl) {
                // WSL itself also uses Windows system environment variables.
                // Resolve them from the same API as its absolute executable.
                info.EnvironmentVariables["SystemRoot"] = WindowsDirectory();
                info.EnvironmentVariables["WINDIR"] = WindowsDirectory();
            }
            List<string> quoted = new List<string>();
            foreach (string arg in arguments) quoted.Add(Quote(arg));
            info.Arguments = String.Join(" ", quoted.ToArray());
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            info.RedirectStandardInput = redirectInput;
            return info;
        }
        internal static void Input(Process process, bool rawInput, string input) {
            Thread stdin = new Thread(delegate() {
                try {
                    if (!rawInput) {
                        byte[] bytes = new UTF8Encoding(false).GetBytes(input);
                        process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
                    } else Console.OpenStandardInput().CopyTo(process.StandardInput.BaseStream);
                } catch (IOException) { } catch (ObjectDisposedException) { }
                finally { try { process.StandardInput.Close(); } catch (InvalidOperationException) { } }
            });
            stdin.IsBackground = true; stdin.Start();
        }
        public static ProcessOutput Start(string executable, string[] arguments,
                                          bool redirectInput, bool rawInput, string input) {
            return new ProcessOutput(executable, arguments, redirectInput, rawInput, input);
        }
        public static ProcessResult Run(string executable, string[] arguments,
                                        bool capture, bool redirectInput, bool rawInput, string input) {
            return RunCore(executable, arguments, capture, redirectInput, rawInput, input, true);
        }
        internal static ProcessResult RunCore(string executable, string[] arguments,
                                        bool capture, bool redirectInput, bool rawInput, string input, bool supervise) {
            Process process = null;
            MemoryStream buffer = capture ? new MemoryStream() : null;
            bool complete = false;
            Foreground owner = null;
            Thread stdout = null, stderr = null;
            try {
                if (supervise) owner = new Foreground(executable, arguments);
                process = Process.Start(Info(executable, owner == null ? arguments : owner.Arguments, redirectInput));
                Stream output = capture ? (Stream)buffer : Console.OpenStandardOutput();
                Exception outputError = null;
                stdout = new Thread(delegate() {
                    try { process.StandardOutput.BaseStream.CopyTo(output); output.Flush(); }
                    catch (Exception e) { Volatile.Write(ref outputError, e); }
                });
                Exception errorError = null;
                stderr = new Thread(delegate() {
                    try { Errors(process.StandardError.BaseStream); }
                    catch (Exception e) { Volatile.Write(ref errorError, e); }
                });
                stdout.IsBackground = true; stderr.IsBackground = true;
                stdout.Start(); stderr.Start();
                if (redirectInput) Input(process, rawInput, input);
                // An output failure must cancel a quiet child as well; waiting
                // for its normal exit first can otherwise block indefinitely.
                while (stdout.IsAlive || stderr.IsAlive) {
                    if (Volatile.Read(ref outputError) != null) throw outputError;
                    if (Volatile.Read(ref errorError) != null) throw errorError;
                    Thread.Sleep(20);
                }
                stdout.Join(); stderr.Join();
                if (outputError != null) throw outputError;
                if (errorError != null) throw errorError;
                if (owner != null) owner.Complete();
                process.WaitForExit();
                if (owner != null) owner.Finish();
                ProcessResult result = new ProcessResult(); result.ExitCode = process.ExitCode;
                if (capture) result.Output = new UTF8Encoding(false).GetString(buffer.ToArray());
                complete = true;
                return result;
            } finally {
                if (process != null) {
                    try { if (!complete) {
                        try { if (owner != null) owner.Cancel(process); } finally { Stop(process); }
                    } }
                    finally {
                        process.StandardOutput.Close(); process.StandardError.Close();
                        if (stdout != null && stdout.IsAlive) stdout.Join(500);
                        if (stderr != null && stderr.IsAlive) stderr.Join(500);
                        process.Dispose();
                    }
                }
                if (owner != null) owner.Dispose();
                if (buffer != null) buffer.Dispose();
            }
        }
    }
}
'@
}

function Invoke-DelamainWsl([string[]]$Arguments, [switch]$Capture, [switch]$RedirectInput, [AllowNull()][object]$InputText) {
    if ($Capture) {
        return [Delamain.ProcessTransport]::Run([Delamain.ProcessTransport]::WslExecutable(), $Arguments, $true,
            $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    }
    $child = [Delamain.ProcessTransport]::Start([Delamain.ProcessTransport]::WslExecutable(), $Arguments,
        $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    try {
        # Strings are already scalar pipeline objects. -NoEnumerate wraps them
        # on PowerShell 7 and breaks a direct ConvertFrom-Json consumer.
        while ($null -ne ($line = $child.ReadLine())) { Write-Output $line }
        $global:LASTEXITCODE = $child.Complete()
    } finally { $child.Dispose() }
}
