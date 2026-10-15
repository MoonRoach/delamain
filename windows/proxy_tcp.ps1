param([switch]$Discover, [string]$ProxyHost, [int]$ProxyPort, [switch]$Multiplex)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    if ($Discover) {
        # Read only: never alter the user's proxy, credentials or network setup.
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        @{ enabled = ($settings.ProxyEnable -eq 1); server = [string]$settings.ProxyServer;
           bypass = [string]$settings.ProxyOverride } | ConvertTo-Json -Compress
        exit 0
    }
    if (-not $ProxyHost -or $ProxyPort -lt 1 -or $ProxyPort -gt 65535) { throw 'Invalid proxy endpoint.' }
    # Explicit multiplex mode compiles once in one process per new Linux worker.
    # stdout carries frames in that mode or raw bytes for legacy callers;
    # diagnostics go exclusively to stderr.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
namespace Delamain {
    public sealed class ProxyTcp {
        const int Window = 65536, Chunk = 32768;
        const byte Ready = 1, Open = 2, Data = 3, Fin = 4, Close = 5, Credit = 6;
        readonly object outputLock = new object(), connectionsLock = new object();
        readonly Dictionary<uint, Connection> connections = new Dictionary<uint, Connection>();
        readonly Stream output = Console.OpenStandardOutput();
        readonly string host;
        readonly int port;
        volatile bool stopped;
        ProxyTcp(string host, int port) { this.host = host; this.port = port; }
        static uint Number(byte[] b, int at) {
            return (uint)b[at] | ((uint)b[at + 1] << 8) | ((uint)b[at + 2] << 16) | ((uint)b[at + 3] << 24);
        }
        static void Number(byte[] b, int at, uint value) {
            for (int i = 0; i < 4; i++) b[at + i] = (byte)(value >> (8 * i));
        }
        void Send(byte kind, uint id, byte[] data, int size) {
            byte[] header = new byte[9]; header[0] = kind;
            Number(header, 1, id); Number(header, 5, (uint)size);
            lock (outputLock) {
                if (stopped) return;
                output.Write(header, 0, header.Length);
                if (size != 0) output.Write(data, 0, size);
                output.Flush();
            }
        }
        void Grant(uint id, int count) {
            byte[] data = new byte[4]; Number(data, 0, (uint)count); Send(Credit, id, data, 4);
        }
        void Remove(Connection c, bool notify) {
            lock (connectionsLock) {
                Connection current;
                if (!connections.TryGetValue(c.id, out current) || current != c) return;
                connections.Remove(c.id);
            }
            c.Dispose();
            if (notify) Send(Close, c.id, null, 0);
        }
        sealed class Connection {
            internal readonly uint id;
            readonly ProxyTcp relay;
            readonly object gate = new object();
            readonly Queue<byte[]> input = new Queue<byte[]>();
            readonly TcpClient client = new TcpClient();
            int queued, credit = Window;
            bool ended, disposed;
            internal Connection(ProxyTcp relay, uint id) { this.relay = relay; this.id = id; }
            internal void Start() {
                Thread writer = new Thread(Write); writer.IsBackground = true; writer.Start();
            }
            internal void Receive(byte kind, byte[] data) {
                lock (gate) {
                    if (disposed) return;
                    if (kind == Data && !ended && data.Length > 0 && queued + data.Length <= Window) {
                        input.Enqueue(data); queued += data.Length;
                    } else if (kind == Fin && data.Length == 0 && !ended) ended = true;
                    else if (kind == Credit && data.Length == 4) {
                        uint count = Number(data, 0);
                        if (count == 0 || count > Window || credit + count > Window) throw new IOException("Invalid credit.");
                        credit += (int)count;
                    } else throw new IOException("Invalid connection frame.");
                    Monitor.PulseAll(gate);
                }
            }
            internal void Dispose() {
                lock (gate) {
                    disposed = true; input.Clear(); Monitor.PulseAll(gate);
                }
                client.Close();
            }
            void Write() {
                try {
                    IAsyncResult connect = client.BeginConnect(relay.host, relay.port, null, null);
                    using (connect.AsyncWaitHandle) {
                        if (!connect.AsyncWaitHandle.WaitOne(10000)) throw new IOException("Connect timed out.");
                        client.EndConnect(connect);
                    }
                    client.NoDelay = true;
                    NetworkStream network = client.GetStream();
                    Thread reader = new Thread(delegate() { Read(network); }); reader.IsBackground = true; reader.Start();
                    while (true) {
                        byte[] data;
                        lock (gate) {
                            while (!disposed && input.Count == 0 && !ended) Monitor.Wait(gate);
                            if (disposed) return;
                            if (input.Count == 0) break;
                            // queued includes the in-flight write until consumed.
                            data = input.Dequeue();
                        }
                        network.Write(data, 0, data.Length);
                        lock (gate) { queued -= data.Length; }
                        relay.Grant(id, data.Length);
                    }
                    client.Client.Shutdown(SocketShutdown.Send);
                } catch (Exception) { relay.Remove(this, true); }
            }
            void Read(NetworkStream network) {
                try {
                    byte[] data = new byte[Chunk];
                    while (true) {
                        int allowed;
                        lock (gate) {
                            while (!disposed && credit == 0) Monitor.Wait(gate);
                            if (disposed) return;
                            allowed = Math.Min(Chunk, credit);
                        }
                        int count = network.Read(data, 0, allowed);
                        if (count == 0) { relay.Send(Fin, id, null, 0); return; }
                        lock (gate) { credit -= count; }
                        relay.Send(Data, id, data, count);
                    }
                } catch (Exception) { relay.Remove(this, true); }
            }
        }
        static bool Exact(Stream input, byte[] data) {
            int at = 0;
            while (at < data.Length) {
                int count = input.Read(data, at, data.Length - at);
                if (count == 0) {
                    if (at != 0) throw new IOException("Truncated frame.");
                    return false;
                }
                at += count;
            }
            return true;
        }
        void Loop() {
            Stream input = Console.OpenStandardInput();
            try {
                Send(Ready, 0, null, 0);
                byte[] header = new byte[9];
                while (Exact(input, header)) {
                    byte kind = header[0]; uint id = Number(header, 1), size = Number(header, 5);
                    if (id == 0 || size > Chunk) throw new IOException("Invalid frame header.");
                    byte[] data = new byte[(int)size];
                    if (!Exact(input, data)) throw new IOException("Truncated frame.");
                    Connection c;
                    lock (connectionsLock) {
                        if (kind == Open) {
                            if (size != 0 || connections.Count >= 32 || connections.ContainsKey(id)) throw new IOException("Invalid open.");
                            c = new Connection(this, id); connections.Add(id, c); c.Start(); continue;
                        }
                        if (!connections.TryGetValue(id, out c)) continue;
                    }
                    if (kind == Close && size == 0) Remove(c, false);
                    else c.Receive(kind, data);
                }
            } finally {
                // EOF belongs to this worker. Closing sockets and waking all
                // background threads never waits for a peer or stdout lock.
                stopped = true;
                lock (connectionsLock) {
                    foreach (Connection c in connections.Values) c.Dispose();
                    connections.Clear();
                }
            }
        }
        // Compatibility for already-running Linux relays opening this path
        // after a backed-up package update. New workers select -Multiplex.
        public static void RunRaw(string host, int port) {
            using (TcpClient client = new TcpClient()) {
                IAsyncResult connect = client.BeginConnect(host, port, null, null);
                if (!connect.AsyncWaitHandle.WaitOne(10000)) throw new IOException("Proxy TCP connect timed out.");
                client.EndConnect(connect); client.NoDelay = true;
                using (NetworkStream network = client.GetStream()) {
                    network.ReadTimeout = 1000;
                    long inputEnded = 0;
                    Thread input = new Thread(delegate() {
                        try {
                            Console.OpenStandardInput().CopyTo(network, 32768);
                            client.Client.Shutdown(SocketShutdown.Send);
                        } catch (IOException) { } catch (SocketException) { } catch (ObjectDisposedException) { }
                        finally { Interlocked.Exchange(ref inputEnded, DateTime.UtcNow.Ticks); }
                    });
                    input.IsBackground = true; input.Start();
                    Stream output = Console.OpenStandardOutput();
                    byte[] bytes = new byte[32768];
                    int count;
                    while (true) {
                        // EOF on the interop pipe bounds helper lifetime even if
                        // the upstream CONNECT peer never closes its socket.
                        long ended = Interlocked.Read(ref inputEnded);
                        if (ended != 0 && DateTime.UtcNow.Ticks - ended > TimeSpan.FromSeconds(5).Ticks) break;
                        try { count = network.Read(bytes, 0, bytes.Length); }
                        catch (IOException e) {
                            SocketException socketError = e.InnerException as SocketException;
                            if (socketError != null && socketError.SocketErrorCode == SocketError.TimedOut) continue;
                            throw;
                        }
                        if (count == 0) break;
                        output.Write(bytes, 0, count); output.Flush();
                    }
                }
            }
        }
        public static void Run(string host, int port) { new ProxyTcp(host, port).Loop(); }
    }
}
'@
    if ($Multiplex) { [Delamain.ProxyTcp]::Run($ProxyHost, $ProxyPort) }
    else { [Delamain.ProxyTcp]::RunRaw($ProxyHost, $ProxyPort) }
    exit 0
} catch {
    # Never print endpoint strings, frames, HTTP headers or authentication state.
    [Console]::Error.WriteLine('delamain worker proxy: Windows TCP relay failed; check the configured system HTTP proxy and WSL interoperability.')
    exit 1
}
