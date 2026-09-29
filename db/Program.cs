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
///   omanotes-db PROTOCOL run DB        request JSON on stdin, response on stdout
///   omanotes-db PROTOCOL version       what this binary is, as one JSON line
///   omanotes-db PROTOCOL selftest DIR  migrate, write, read and delete a database in DIR
///
/// Protocol 2: a run's stdout is one line per write, in request order, each
/// written as soon as its write ends, then the snapshot line when the request
/// asked for one (ADR-0020). Protocol 1 gets one {"results":[...]} line after
/// every write, then the snapshot. Exit 0: every line is whole. Exit 3: the
/// results are whole and the snapshot failed, {"syncErr":{"err","detail"}} on
/// the last line of stderr. Exit 1 (a failure), 64 (another protocol or
/// command line) or 70 (a bug here): the last line of stderr is
/// {"err","detail"}. Exit 1 and 64 are raised before the first write, so no
/// result line comes before them; only exit 70 can follow the result lines of
/// the writes that ended. No user text ever travels in argv.
/// </summary>
internal static partial class Program
{
    public const int SyncFailedExit = 3;

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
        if (args.Length < 2 || Speaks(args[0]) is not int protocol)
        {
            throw new OpException(ErrorCode.Protocol, args.Length < 2 ? "usage: omanotes-db PROTOCOL run DB | version | selftest DIR" : "the caller speaks another protocol");
        }

        return args[1..] switch
        {
            ["version"] => Version(),
            ["selftest", string dir] => Selftest.Run(Absolute(dir)),
            ["run", string db] => Run(Absolute(db), protocol),
            _ => throw new OpException(ErrorCode.Protocol, "usage: omanotes-db PROTOCOL run DB | version | selftest DIR"),
        };
    }

    /// <summary>The protocol the caller named, or null. Compares text to text, so no number is parsed from argv.</summary>
    private static int? Speaks(string protocol)
    {
        for (int v = Protocol.Min; v <= Protocol.Current; v++)
        {
            if (protocol == v.ToString(CultureInfo.InvariantCulture))
            {
                return v;
            }
        }

        return null;
    }

    private static string Absolute(string path) =>
        Path.IsPathFullyQualified(path) ? path : throw new OpException(ErrorCode.Protocol, "paths are absolute");

    private static int Run(string dbPath, int protocol)
    {
        using Request req = Request.Parse(Fd.ReadStdin(Protocol.MaxRequestBytes, Protocol.StdinIdleMs));
        MakeDirectory(Path.GetDirectoryName(dbPath) ?? "/");
        using Conn db = Conn.Open(dbPath);
        int before = Schema.Migrate(db);
        if (before < Schema.Current)
        {
            Log("migrated " + before.ToString(CultureInfo.InvariantCulture) + " -> " + Schema.Current.ToString(CultureInfo.InvariantCulture));
        }

        // The results go out before the snapshot is read: what fails or dies
        // after this point never takes back a write that was committed.
        WriteResults(db, req.Writes, protocol);
        return req.Sync is SyncReq sync ? WriteSnapshot(db, sync) : 0;
    }

    /// <summary>
    /// Runs the writes in order and writes their results. Protocol 2 writes
    /// each result as one line, in one write(2) of its own buffer as soon as its
    /// write ends, so a kill during the next write never takes back a write that
    /// committed (ADR-0020); through FdWriter it would wait for the buffer to
    /// fill. Protocol 1 gets one {"results":[...]} line once every write ended,
    /// the bytes the QML of before reads between an update and the restart
    /// (ADR-0017). A lock held outside is held for the next write too, so after
    /// a `busy` the rest are refused with it: waiting 5 s again for each would
    /// hold the caller's queue N times as long.
    /// </summary>
    private static void WriteResults(Conn db, IReadOnlyList<WriteReq> writes, int protocol)
    {
        ArrayBufferWriter<byte>? oneLine = protocol == Protocol.OneResultsLine ? new() : null;
        oneLine?.Write("{\"results\":["u8);
        OpException? busy = null;
        for (int i = 0; i < writes.Count; i++)
        {
            var result = new ArrayBufferWriter<byte>();
            using (var w = new Utf8JsonWriter(result, Json))
            {
                OpException? failure = busy is null ? Writes.Run(db, writes[i], w) : Writes.Refuse(writes[i], busy, w);
                if (failure is { Code: ErrorCode.Busy })
                {
                    busy = failure;
                }
            }

            if (oneLine is null)
            {
                result.Write("\n"u8);
                Fd.Write(Fd.Stdout, result.WrittenSpan);
                continue;
            }

            if (i > 0)
            {
                oneLine.Write(","u8);
            }

            oneLine.Write(result.WrittenSpan);
        }

        if (oneLine is not null)
        {
            oneLine.Write("]}\n"u8);
            Fd.Write(Fd.Stdout, oneLine.WrittenSpan);
        }
    }

    /// <summary>
    /// The last line: the snapshot, written as it is read, so the peak does not
    /// grow with the database. A failure part way leaves the line cut: exit 3,
    /// and {"syncErr":{"err","detail"}} on the last line of stderr.
    /// </summary>
    private static int WriteSnapshot(Conn db, SyncReq sync)
    {
        try
        {
            var output = new FdWriter(Fd.Stdout, Protocol.MaxResponseBytes);
            using (var w = new Utf8JsonWriter(output, Json))
            {
                Snapshot.Write(db, sync, w);
            }

            output.Write("\n"u8);
            output.Flush();
            return 0;
        }
        catch (OpException e)
        {
            return FailSync(e);
        }
#pragma warning disable CA1031 // Only reads run here, and the results are out: any failure is the snapshot's, never a lost write.
        catch (Exception e)
#pragma warning restore CA1031
        {
            return FailSync(new OpException(ErrorCode.Internal, e.GetType().Name));
        }
    }

    private static int FailSync(OpException e)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var w = new Utf8JsonWriter(buffer, Json))
        {
            w.WriteStartObject();
            w.WriteStartObject("syncErr");
            e.WriteFields(w);
            w.WriteEndObject();
            w.WriteEndObject();
        }

        Fd.Write(Fd.Stderr, buffer.WrittenSpan);
        Fd.Write(Fd.Stderr, "\n"u8);
        return SyncFailedExit;
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
/// A descriptor behind one 64 KiB buffer, written each time it fills, so a
/// snapshot costs the buffer and not its size. A value longer than the buffer
/// gets a buffer of its own for as long as it takes. Past `max` bytes it is
/// `response_too_large`.
/// </summary>
internal sealed class FdWriter : IBufferWriter<byte>
{
    private const int BufferBytes = 64 * 1024;

    private readonly int _fd;
    private readonly long _max;
    private byte[] _buffer = GC.AllocateUninitializedArray<byte>(BufferBytes);
    private int _used;
    private long _written;

    public FdWriter(int fd, long max)
    {
        _fd = fd;
        _max = max;
    }

    public void Advance(int count) => _used += count;

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsMemory(_used);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsSpan(_used);
    }

    public void Flush()
    {
        if (_written + _used > _max)
        {
            throw new OpException(ErrorCode.ResponseTooLarge, "the snapshot is over 64 MiB");
        }

        Program.Fd.Write(_fd, _buffer.AsSpan(0, _used));
        _written += _used;
        _used = 0;
    }

    private void Ensure(int sizeHint)
    {
        int need = Math.Max(sizeHint, 1);
        if (_buffer.Length - _used >= need)
        {
            return;
        }

        Flush();
        if (need > BufferBytes || _buffer.Length > BufferBytes)
        {
            _buffer = GC.AllocateUninitializedArray<byte>(Math.Max(need, BufferBytes));
        }
    }
}
