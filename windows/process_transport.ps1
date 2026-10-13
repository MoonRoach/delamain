# Raw child-process transport for PowerShell 5.1 and 7. stdout never enters the
# PowerShell error-record pipeline; WSL startup stderr may use UTF-16LE while the
# Linux child uses UTF-8. Decode each stderr line independently, hiding no errors.
if (-not ('Delamain.ProcessTransport' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
namespace Delamain {
    public sealed class ProcessResult {
        public int ExitCode;
        public string Output;
    }
    public sealed class ProcessOutput : IDisposable {
        Process process;
        StreamReader reader;
        Thread stderr;
        Exception stderrError;
        internal ProcessOutput(string executable, string[] arguments, bool redirectInput, bool rawInput, string input) {
            process = Process.Start(ProcessTransport.Info(executable, arguments, redirectInput));
            reader = new StreamReader(process.StandardOutput.BaseStream, new UTF8Encoding(false), false);
            stderr = new Thread(delegate() {
                try { ProcessTransport.Errors(process.StandardError.BaseStream); }
                catch (Exception e) { stderrError = e; }
            });
            stderr.IsBackground = true; stderr.Start();
            if (redirectInput) ProcessTransport.Input(process, rawInput, input);
        }
        public string ReadLine() { return reader.ReadLine(); }
        public int Complete() {
            process.WaitForExit(); stderr.Join();
            if (stderrError != null) throw stderrError;
            return process.ExitCode;
        }
        public void Dispose() { reader.Dispose(); process.Dispose(); }
    }
    public static class ProcessTransport {
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
            info.FileName = executable;
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
            using (Process process = Process.Start(Info(executable, arguments, redirectInput))) {
                MemoryStream buffer = capture ? new MemoryStream() : null;
                Stream output = capture ? (Stream)buffer : Console.OpenStandardOutput();
                Exception outputError = null;
                Thread stdout = new Thread(delegate() {
                    try { process.StandardOutput.BaseStream.CopyTo(output); output.Flush(); }
                    catch (Exception e) { outputError = e; }
                });
                Exception errorError = null;
                Thread stderr = new Thread(delegate() {
                    try { Errors(process.StandardError.BaseStream); }
                    catch (Exception e) { errorError = e; }
                });
                stdout.IsBackground = true; stderr.IsBackground = true;
                stdout.Start(); stderr.Start();
                if (redirectInput) Input(process, rawInput, input);
                process.WaitForExit(); stdout.Join(); stderr.Join();
                if (outputError != null) throw outputError;
                if (errorError != null) throw errorError;
                ProcessResult result = new ProcessResult(); result.ExitCode = process.ExitCode;
                if (capture) { result.Output = new UTF8Encoding(false).GetString(buffer.ToArray()); buffer.Dispose(); }
                return result;
            }
        }
    }
}
'@
}

function Invoke-DelamainWsl([string[]]$Arguments, [switch]$Capture, [switch]$RedirectInput, [AllowNull()][object]$InputText) {
    if ($Capture) {
        return [Delamain.ProcessTransport]::Run('wsl.exe', $Arguments, $true,
            $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    }
    $child = [Delamain.ProcessTransport]::Start('wsl.exe', $Arguments,
        $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    try {
        # Strings are already scalar pipeline objects. -NoEnumerate wraps them
        # on PowerShell 7 and breaks a direct ConvertFrom-Json consumer.
        while ($null -ne ($line = $child.ReadLine())) { Write-Output $line }
        $global:LASTEXITCODE = $child.Complete()
    } finally { $child.Dispose() }
}
