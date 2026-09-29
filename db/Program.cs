using System.Buffers;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Omanotes.Db;

/// <summary>
/// omanotes-db: one process, one request, one response, no clock and no
/// environment.
///
///   omanotes-db PROTOCOL run DB        request JSON on stdin, response JSON on stdout
///   omanotes-db PROTOCOL version       what this binary is, as one JSON line
///   omanotes-db PROTOCOL selftest DIR  migrate, write, read and delete a database in DIR
///
/// stdout carries a whole response and only with exit 0. On exit 1 (a failure),
/// 64 (another protocol or command line) or 70 (a bug here) the last line of
/// stderr is {"err","detail"}. No user text ever travels in argv.
/// </summary>
internal static partial class Program
{
    public static readonly JsonWriterOptions Json = new()
    {
        // Notes are mostly non-ASCII: the default encoder would escape every accent. This is not HTML.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static int Main(string[] args)
    {
        try
        {
            return Dispatch(args);
        }
        catch (OpException e)
        {
            return Fail(e);
        }
        catch (DllNotFoundException)
        {
            return Fail(new OpException(ErrorCode.SqliteMissing, "libsqlite3.so.0 is not installed"));
        }
#pragma warning disable CA1031 // The one catch-all: an unhandled exception would abort and dump core with the notes in it.
        catch (Exception e)
#pragma warning restore CA1031
        {
            return Fail(new OpException(ErrorCode.Internal, e.GetType().Name));
        }
    }

    public static void Log(string line) => Fd.Write(Fd.Stderr, System.Text.Encoding.UTF8.GetBytes("omanotes-db: " + line + "\n"));

    private static int Dispatch(string[] args)
    {
        if (args.Length < 2 || !Speaks(args[0]))
        {
            throw new OpException(ErrorCode.Protocol, args.Length < 2 ? "usage: omanotes-db PROTOCOL run DB | version | selftest DIR" : "the caller speaks another protocol");
        }

        return args[1..] switch
        {
            ["version"] => Version(),
            ["selftest", string dir] => Selftest.Run(Absolute(dir)),
            ["run", string db] => Run(Absolute(db)),
            _ => throw new OpException(ErrorCode.Protocol, "usage: omanotes-db PROTOCOL run DB | version | selftest DIR"),
        };
    }

    /// <summary>Compares text to text, so no number is parsed from argv.</summary>
    private static bool Speaks(string protocol)
    {
        for (int v = Protocol.Min; v <= Protocol.Current; v++)
        {
            if (protocol == v.ToString(CultureInfo.InvariantCulture))
            {
                return true;
            }
        }

        return false;
    }

    private static string Absolute(string path) =>
        Path.IsPathFullyQualified(path) ? path : throw new OpException(ErrorCode.Protocol, "paths are absolute");

    private static int Run(string dbPath)
    {
        using Request req = Request.Parse(Fd.ReadStdin(Protocol.MaxRequestBytes, Protocol.StdinIdleMs));
        MakeDirectory(Path.GetDirectoryName(dbPath) ?? "/");
        using Conn db = Conn.Open(dbPath);
        int before = Schema.Migrate(db);
        if (before < Schema.Current)
        {
            Log("migrated " + before.ToString(CultureInfo.InvariantCulture) + " -> " + Schema.Current.ToString(CultureInfo.InvariantCulture));
        }

        var results = new ArrayBufferWriter<byte>();
        using (var w = new Utf8JsonWriter(results, Json))
        {
            w.WriteStartArray();
            foreach (WriteReq write in req.Writes)
            {
                Writes.Run(db, write, w);
            }

            w.WriteEndArray();
        }

        Chunks? snapshot = null;
        OpException? syncErr = null;
        if (req.Sync is SyncReq sync)
        {
            try
            {
                snapshot = new Chunks(Protocol.MaxResponseBytes);
                using var w = new Utf8JsonWriter(snapshot, Json);
                Snapshot.Write(db, sync, w);
            }
            catch (OpException e)
            {
                // The writes above are committed, so their results still go out.
                (snapshot, syncErr) = (null, e);
            }
        }

        // Everything is decided: only now does a byte reach stdout.
        Fd.Write(Fd.Stdout, "{\"results\":"u8);
        Fd.Write(Fd.Stdout, results.WrittenSpan);
        if (snapshot is not null)
        {
            Fd.Write(Fd.Stdout, ",\"snapshot\":"u8);
            snapshot.WriteTo(Fd.Stdout);
        }
        else if (syncErr is not null)
        {
            Fd.Write(Fd.Stdout, ",\"syncErr\":"u8);
            Fd.Write(Fd.Stdout, ErrorObject(syncErr));
        }

        Fd.Write(Fd.Stdout, "}\n"u8);
        return 0;
    }

    private static void MakeDirectory(string dir)
    {
        try
        {
            _ = Directory.CreateDirectory(dir);
        }
        catch (IOException)
        {
            throw new OpException(ErrorCode.Io, "cannot create the database folder");
        }
        catch (UnauthorizedAccessException)
        {
            throw new OpException(ErrorCode.Io, "cannot create the database folder");
        }
    }

    private static int Version()
    {
        string source = "unknown";
        foreach (AssemblyMetadataAttribute a in Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>())
        {
            if (a.Key == "source" && !string.IsNullOrEmpty(a.Value))
            {
                source = a.Value;
            }
        }

        var buffer = new ArrayBufferWriter<byte>();
        using (var w = new Utf8JsonWriter(buffer, Json))
        {
            w.WriteStartObject();
            w.WriteStartArray("protocol");
            w.WriteNumberValue(Protocol.Min);
            w.WriteNumberValue(Protocol.Current);
            w.WriteEndArray();
            w.WriteNumber("schema", Schema.Current);
            w.WriteString("source", source);
            w.WriteString("arch", RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X64 => "x86_64",
                Architecture.Arm64 => "aarch64",
                _ => "other",
            });
            w.WriteString("sqlite", Conn.LibraryVersion());
            w.WriteString("sqliteMin", Conn.MinVersionText);
            w.WriteStartArray("errors");
            foreach (ErrorCode code in Enum.GetValues<ErrorCode>())
            {
                w.WriteStringValue(OpException.Wire(code));
            }

            w.WriteEndArray();
            w.WriteEndObject();
        }

        Fd.Write(Fd.Stdout, buffer.WrittenSpan);
        Fd.Write(Fd.Stdout, "\n"u8);
        return 0;
    }

    private static int Fail(OpException e)
    {
        byte[] line = ErrorObject(e);
        Fd.Write(Fd.Stderr, line);
        Fd.Write(Fd.Stderr, "\n"u8);
        return e.Exit;
    }

    private static byte[] ErrorObject(OpException e)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var w = new Utf8JsonWriter(buffer, Json))
        {
            w.WriteStartObject();
            e.WriteFields(w);
            w.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    /// <summary>
    /// The three descriptors, through libc. Console follows LANG and its stdin
    /// has no timeout; a caller that never closes stdin would hold this process,
    /// and the caller's queue with it, forever.
    /// </summary>
    internal static unsafe partial class Fd
    {
        public const int Stdout = 1;
        public const int Stderr = 2;

        private const int Stdin = 0;
        private const short PollIn = 1;
        private const int EIntr = 4;
        private const int EAgain = 11;
        private const string Libc = "libc.so.6";

        /// <summary>Bytes until end of file. `timeout` when `idleMs` pass with neither a byte nor the end, `too_large` past `max`.</summary>
        public static byte[] ReadStdin(int max, int idleMs)
        {
            byte[] buffer = new byte[64 * 1024];
            int used = 0;
            while (true)
            {
                var fds = new PollFd { Fd = Stdin, Events = PollIn };
                int ready = poll(ref fds, 1, idleMs);
                if (ready == 0)
                {
                    throw new OpException(ErrorCode.Timeout, "stdin did not close");
                }

                if (ready < 0)
                {
                    RetryOrThrow("cannot wait on stdin");
                    continue;
                }

                if (used == buffer.Length)
                {
                    Array.Resize(ref buffer, Math.Min(buffer.Length * 4, max + 1));
                }

                nint n;
                fixed (byte* p = buffer)
                {
                    n = read(Stdin, p + used, (nuint)(buffer.Length - used));
                }

                if (n < 0)
                {
                    RetryOrThrow("cannot read stdin");
                    continue;
                }

                if (n == 0)
                {
                    return buffer[..used];
                }

                used += (int)n;
                if (used > max)
                {
                    throw new OpException(ErrorCode.TooLarge, "the request is over 1 MiB");
                }
            }
        }

        /// <summary>All of `bytes`, however many writes that takes. A reader that went away is an IOException, which reads as a crash.</summary>
        public static void Write(int fd, ReadOnlySpan<byte> bytes)
        {
            fixed (byte* p = bytes)
            {
                int done = 0;
                while (done < bytes.Length)
                {
                    nint n = write(fd, p + done, (nuint)(bytes.Length - done));
                    if (n < 0)
                    {
                        int errno = Marshal.GetLastPInvokeError();
                        if (errno is EIntr or EAgain)
                        {
                            continue;
                        }

                        throw new IOException("write failed");
                    }

                    done += (int)n;
                }
            }
        }

        private static void RetryOrThrow(string detail)
        {
            if (Marshal.GetLastPInvokeError() is not (EIntr or EAgain))
            {
                throw new OpException(ErrorCode.Io, detail);
            }
        }

        [LibraryImport(Libc, SetLastError = true)]
        private static partial int poll(ref PollFd fds, nuint nfds, int timeout);

        [LibraryImport(Libc, SetLastError = true)]
        private static partial nint read(int fd, byte* buf, nuint count);

        [LibraryImport(Libc, SetLastError = true)]
        private static partial nint write(int fd, byte* buf, nuint count);

        [StructLayout(LayoutKind.Sequential)]
        private struct PollFd
        {
            public int Fd;
            public short Events;
            public short Revents;
        }
    }
}

/// <summary>
/// The snapshot, held whole before any of it is written, in 64 KiB chunks so
/// no array is copied as it grows. Past `max` it is `too_large`.
/// </summary>
internal sealed class Chunks : IBufferWriter<byte>
{
    private const int ChunkBytes = 64 * 1024;

    private readonly long _max;
    private readonly List<(byte[] Bytes, int Used)> _full = [];
    private byte[] _current = [];
    private int _used;
    private long _total;

    public Chunks(long max)
    {
        _max = max;
    }

    public void Advance(int count)
    {
        _used += count;
        _total += count;
    }

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _current.AsMemory(_used);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _current.AsSpan(_used);
    }

    public void WriteTo(int fd)
    {
        foreach ((byte[] bytes, int used) in _full)
        {
            Program.Fd.Write(fd, bytes.AsSpan(0, used));
        }

        Program.Fd.Write(fd, _current.AsSpan(0, _used));
    }

    public byte[] ToArray()
    {
        var all = new byte[_total];
        int at = 0;
        foreach ((byte[] bytes, int used) in _full)
        {
            bytes.AsSpan(0, used).CopyTo(all.AsSpan(at));
            at += used;
        }

        _current.AsSpan(0, _used).CopyTo(all.AsSpan(at));
        return all;
    }

    private void Ensure(int sizeHint)
    {
        int need = Math.Max(sizeHint, 1);
        if (_current.Length - _used >= need)
        {
            return;
        }

        if (_total + need > _max)
        {
            throw new OpException(ErrorCode.TooLarge, "the response is over 64 MiB");
        }

        if (_used > 0)
        {
            _full.Add((_current, _used));
        }

        _current = new byte[Math.Max(ChunkBytes, need)];
        _used = 0;
    }
}
