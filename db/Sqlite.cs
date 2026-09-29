using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]

namespace Omanotes.Db;

/// <summary>
/// SQL is text this source wrote, never text a request wrote. Sql is an
/// interpolated string handler that takes literal text and refuses every hole
/// at compile time (CS0619), and Conn takes nothing else, so a value reaches
/// SQLite only as a bound Value. The one identifier from outside a literal is a
/// column name that pragma_table_info returned (Conn.RowOf).
/// </summary>
[InterpolatedStringHandler]
internal readonly struct Sql
{
    private readonly StringBuilder _text;

    public Sql(int literalLength, int formattedCount)
    {
        _ = formattedCount;
        _text = new StringBuilder(literalLength);
    }

    public void AppendLiteral(string s) => _text.Append(s);

    [Obsolete("SQL takes no interpolation: bind the value", error: true)]
    public void AppendFormatted<T>(T value) => throw new NotSupportedException();

    public override string ToString() => _text.ToString();
}

internal enum ValueKind
{
    Null,
    Integer,
    Text,
}

/// <summary>What a statement binds: an integer, a text or NULL, and nothing else.</summary>
internal readonly struct Value
{
    private Value(ValueKind kind, long number, string? text)
    {
        Kind = kind;
        Number = number;
        Text = text;
    }

    public static Value Null => default;

    public ValueKind Kind { get; }

    public long Number { get; }

    public string? Text { get; }

    public static Value Of(long number) => new(ValueKind.Integer, number, null);

    public static Value Of(string? text) => text is null ? Null : new(ValueKind.Text, 0, text);
}

/// <summary>The tables whose writes name their columns (ADR-0015, ADR-0016).</summary>
internal enum RowTable
{
    Settings,
    Alarms,
}

/// <summary>
/// The one owner of libsqlite3.so.0: Native is private here. One connection per
/// process, busy timeout 5 s, journal_mode never touched (the watcher of
/// ADR-0004 needs the rollback journal, and this binary does not write the
/// user's file unasked).
/// </summary>
internal sealed partial class Conn : IDisposable
{
    public const int BusyTimeoutMs = 5000;

    /// <summary>group_concat(... ORDER BY) in migration 2 and the search triggers came in 3.44.0 (sqlite.org/releaselog/3_44_0.html).</summary>
    public const int MinVersion = 3_044_000;

    public const string MinVersionText = "3.44.0";

    private static readonly UTF8Encoding Utf8 = new(false, false);

    private readonly DbHandle _db;

    private Conn(DbHandle db, string path)
    {
        _db = db;
        Path = path;
    }

    /// <summary>The file this connection opened; a backup goes beside it.</summary>
    public string Path { get; }

    public static Conn Open(string path)
    {
        if (Native.sqlite3_libversion_number() < MinVersion)
        {
            throw new OpException(ErrorCode.SqliteTooOld, "libsqlite3 " + LibraryVersion() + " is older than " + MinVersionText);
        }

        int rc = Native.sqlite3_open_v2(path, out DbHandle handle, Native.OpenReadWrite | Native.OpenCreate, null);
        var conn = new Conn(handle, path);
        try
        {
            if (rc != Native.Ok)
            {
                throw conn.Failure(rc);
            }

            _ = Native.sqlite3_busy_timeout(handle, BusyTimeoutMs);

            // A spawn reads each page once; a bigger cache only raises its peak RSS (measured: 128 KiB takes 0.4 MB off a full snapshot, at the same speed).
            _ = conn.Run($"PRAGMA cache_size = -128");
            return conn;
        }
        catch (OpException)
        {
            conn.Dispose();
            throw;
        }
    }

    public static unsafe string LibraryVersion() => Marshal.PtrToStringUTF8((nint)Native.sqlite3_libversion()) ?? "?";

    public void Dispose() => _db.Dispose();

    /// <summary>Runs one statement to its end and returns sqlite3_changes().</summary>
    public long Run(Sql sql, params ReadOnlySpan<Value> args)
    {
        using Stmt st = Prepare(sql.ToString(), args);
        while (st.Step())
        {
        }

        return Native.sqlite3_changes(_db);
    }

    /// <summary>Runs one INSERT and returns its rowid.</summary>
    public long Insert(Sql sql, params ReadOnlySpan<Value> args)
    {
        _ = Run(sql, args);
        return Native.sqlite3_last_insert_rowid(_db);
    }

    /// <summary>The first column of the first row as an integer, 0 without a row.</summary>
    public long Scalar(Sql sql, params ReadOnlySpan<Value> args)
    {
        using Stmt st = Prepare(sql.ToString(), args);
        return st.Step() ? Native.sqlite3_column_int64(st.Handle, 0) : 0;
    }

    /// <summary>Each row as a JSON object keyed by column name, every cell as `sqlite3 -json` prints its storage class.</summary>
    public void WriteRows(Sql sql, Utf8JsonWriter w, params ReadOnlySpan<Value> args)
    {
        using Stmt st = Prepare(sql.ToString(), args);
        w.WriteStartArray();
        while (st.Step())
        {
            st.WriteRow(w);
        }

        w.WriteEndArray();
    }

    /// <summary>The first row as a JSON object, or null without one.</summary>
    public void WriteRow(Sql sql, Utf8JsonWriter w)
    {
        using Stmt st = Prepare(sql.ToString(), []);
        if (st.Step())
        {
            st.WriteRow(w);
        }
        else
        {
            w.WriteNullValue();
        }
    }

    /// <summary>The first column of each row as an integer, read whole before any of it is written, so a statement that fails part way writes nothing.</summary>
    public List<long> Ids(Sql sql, params ReadOnlySpan<Value> args)
    {
        using Stmt st = Prepare(sql.ToString(), args);
        var ids = new List<long>();
        while (st.Step())
        {
            ids.Add(Native.sqlite3_column_int64(st.Handle, 0));
        }

        return ids;
    }

    /// <summary>BEGIN IMMEDIATE takes the write lock up front. Dispose without Commit rolls back.</summary>
    public Tx Immediate()
    {
        _ = Run($"BEGIN IMMEDIATE");
        return new Tx(this);
    }

    /// <summary>A read transaction: every read inside it sees one state of the file.</summary>
    public Tx Read()
    {
        _ = Run($"BEGIN");
        return new Tx(this);
    }

    /// <summary>
    /// The first bytes of the database file, read through SQLite's own file
    /// handle; false when the file is shorter. A second descriptor would not
    /// do: closing it drops every POSIX lock this process holds on the file
    /// (fcntl(2)), the SHARED lock of a read transaction included, and the
    /// reads after it run unlocked (sqlite.org/howtocorrupt.html, 2.2).
    /// </summary>
    public unsafe bool ReadHeader(Span<byte> header)
    {
        if (Native.sqlite3_file_control(_db, "main", Native.FcntlFilePointer, out Native.SqliteFile* file) != Native.Ok || file == null || file->Methods == null)
        {
            throw new OpException(ErrorCode.Io, "cannot read the database header");
        }

        int rc;
        fixed (byte* p = header)
        {
            rc = file->Methods->Read(file, p, header.Length, 0);
        }

        return rc switch
        {
            Native.Ok => true,
            Native.IoErrShortRead => false,
            _ => throw new OpException(ErrorCode.Io, "cannot read the database header"),
        };
    }

    /// <summary>PRAGMA takes no bound value, so this is the one statement built from a number, and the number is Schema.Current.</summary>
    public void SetUserVersion(int version)
    {
        using Stmt st = Prepare("PRAGMA user_version = " + version.ToString(System.Globalization.CultureInfo.InvariantCulture), []);
        _ = st.Step();
    }

    public Row RowOf(RowTable table, IEnumerable<(string Name, Value Value)> named) => Row.Of(this, table, named);

    /// <summary>INSERT of the row's cells; returns the new rowid.</summary>
    public long InsertRow(Row row)
    {
        var sql = new StringBuilder("INSERT INTO ").Append(row.TableName).Append(" (");
        AppendEach(sql, row, (column, _) => column);
        _ = sql.Append(") VALUES (");
        AppendEach(sql, row, (_, param) => param);
        _ = sql.Append(')');
        using Stmt st = Prepare(sql.ToString(), row.Values());
        _ = st.Step();
        return Native.sqlite3_last_insert_rowid(_db);
    }

    /// <summary>UPDATE of the row's cells where id matches; returns sqlite3_changes().</summary>
    public long UpdateRow(Row row, long id)
    {
        var sql = new StringBuilder("UPDATE ").Append(row.TableName).Append(" SET ");
        AppendEach(sql, row, (column, param) => column + " = " + param);
        _ = sql.Append(" WHERE id = ").Append(Param(row.Cells.Count + 1));
        using Stmt st = Prepare(sql.ToString(), [.. row.Values(), Value.Of(id)]);
        _ = st.Step();
        return Native.sqlite3_changes(_db);
    }

    /// <summary>One upsert of only these cells into row `id`; the other columns keep their value, or their DEFAULT in a new row.</summary>
    public void UpsertRow(Row row, long id)
    {
        var sql = new StringBuilder("INSERT INTO ").Append(row.TableName).Append(" (id, ");
        AppendEach(sql, row, (column, _) => column);
        _ = sql.Append(") VALUES (").Append(Param(row.Cells.Count + 1)).Append(", ");
        AppendEach(sql, row, (_, param) => param);
        _ = sql.Append(") ON CONFLICT(id) DO UPDATE SET ");
        AppendEach(sql, row, (column, _) => column + " = excluded." + column);
        using Stmt st = Prepare(sql.ToString(), [.. row.Values(), Value.Of(id)]);
        _ = st.Step();
    }

    /// <summary>Each cell through `part` (its quoted column, its parameter), comma separated.</summary>
    private static void AppendEach(StringBuilder sql, Row row, Func<string, string, string> part)
    {
        for (int i = 0; i < row.Cells.Count; i++)
        {
            string quoted = "\"" + row.Cells[i].Column.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
            _ = sql.Append(i == 0 ? string.Empty : ", ").Append(part(quoted, Param(i + 1)));
        }
    }

    private static string Param(int n) => "?" + n.ToString(System.Globalization.CultureInfo.InvariantCulture);

    private unsafe Stmt Prepare(string text, ReadOnlySpan<Value> args)
    {
        byte[] bytes = Utf8.GetBytes(text);
        StmtHandle handle;
        fixed (byte* p = bytes)
        {
            byte* tail = null;
            int rc = Native.sqlite3_prepare_v2(_db, p, bytes.Length, out handle, &tail);
            if (rc != Native.Ok)
            {
                handle.Dispose();
                throw Failure(rc);
            }

            // prepare_v2 compiles only the first statement; the rest would be dropped without a word.
            for (byte* q = tail; q < p + bytes.Length; q++)
            {
                if (*q is not ((byte)' ' or (byte)'\n' or (byte)'\t' or (byte)'\r' or (byte)';'))
                {
                    handle.Dispose();
                    throw new OpException(ErrorCode.Internal, "more than one statement in a prepare");
                }
            }
        }

        var st = new Stmt(this, handle);
        try
        {
            for (int i = 0; i < args.Length; i++)
            {
                st.Bind(i + 1, args[i]);
            }

            return st;
        }
        catch (OpException)
        {
            st.Dispose();
            throw;
        }
    }

    private bool InAutocommit => Native.sqlite3_get_autocommit(_db) != 0;

    private unsafe OpException Failure(int rc)
    {
        byte* msg = Native.sqlite3_errmsg(_db);
        string detail = (msg == null ? null : Marshal.PtrToStringUTF8((nint)msg)) ?? "sqlite error";
        ErrorCode code = (rc & 0xff) switch
        {
            Native.Busy or Native.Locked => ErrorCode.Busy,
            Native.Constraint => ErrorCode.Refused,
            Native.ReadOnly or Native.IoErr or Native.CantOpen or Native.Full or Native.Perm => ErrorCode.Io,
            Native.Corrupt or Native.NotADb => ErrorCode.Corrupt,
            _ => ErrorCode.Sqlite,
        };
        return new OpException(code, detail);
    }

    /// <summary>
    /// Cells for one row of a RowTable. Of checks each name against the
    /// writable columns pragma_table_info lists for the table, and the
    /// constructor is private, so no Row exists unchecked: SQL built from one
    /// names columns the schema has, in the schema's own spelling.
    /// </summary>
    internal sealed class Row
    {
        private Row(RowTable table, List<(string Column, Value Value)> cells)
        {
            TableName = Name(table);
            Cells = cells;
        }

        public IReadOnlyList<(string Column, Value Value)> Cells { get; }

        internal string TableName { get; }

        /// <summary>An unknown or repeated name is `bad_request`.</summary>
        public static Row Of(Conn db, RowTable table, IEnumerable<(string Name, Value Value)> named)
        {
            var columns = new Dictionary<string, string>(StringComparer.Ordinal);
            using (Stmt st = db.Prepare("SELECT name FROM pragma_table_info(?1) WHERE pk = 0", [Value.Of(Name(table))]))
            {
                while (st.Step())
                {
                    string name = st.Text(0);
                    columns[name] = name;
                }
            }

            var cells = new List<(string, Value)>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach ((string name, Value value) in named)
            {
                if (!columns.TryGetValue(name, out string? column) || !seen.Add(column))
                {
                    throw new OpException(ErrorCode.BadRequest, "unknown or repeated column");
                }

                cells.Add((column, value));
            }

            return new Row(table, cells);
        }

        internal Value[] Values()
        {
            var values = new Value[Cells.Count];
            for (int i = 0; i < values.Length; i++)
            {
                values[i] = Cells[i].Value;
            }

            return values;
        }

        private static string Name(RowTable table) => table switch
        {
            RowTable.Settings => "settings",
            RowTable.Alarms => "alarms",
            _ => throw new OpException(ErrorCode.Internal, "unknown table"),
        };
    }

    /// <summary>
    /// A transaction that ends one way only: Commit commits, and leaving the
    /// scope any other way rolls back. A rollback that leaves the connection
    /// inside a transaction is `internal`, so the next write of a request
    /// never runs inside a leaked one.
    /// </summary>
    internal sealed class Tx : IDisposable
    {
        private readonly Conn _db;
        private bool _done;

        internal Tx(Conn db)
        {
            _db = db;
        }

        public void Commit()
        {
            _ = _db.Run($"COMMIT");
            _done = true;
        }

        public void Dispose()
        {
            if (_done)
            {
                return;
            }

            _done = true;
            try
            {
                _ = _db.Run($"ROLLBACK");
            }
            catch (OpException)
            {
                // Judged by the autocommit check below.
            }

            if (!_db.InAutocommit)
            {
                throw new OpException(ErrorCode.Internal, "transaction left open");
            }
        }
    }

    /// <summary>
    /// A prepared statement. Text binds as UTF-8 with SQLITE_TRANSIENT, so
    /// SQLite copies it before the pin ends; column text is consumed before
    /// the next step, while its pointer is valid.
    /// </summary>
    private sealed class Stmt : IDisposable
    {
        private const int ColInteger = 1;
        private const int ColFloat = 2;
        private const int ColText = 3;
        private const int ColBlob = 4;
        private static readonly nint Transient = -1;

        private readonly Conn _conn;

        public Stmt(Conn conn, StmtHandle handle)
        {
            _conn = conn;
            Handle = handle;
        }

        public StmtHandle Handle { get; }

        public void Dispose() => Handle.Dispose();

        public unsafe void Bind(int index, Value value)
        {
            int rc;
            switch (value.Kind)
            {
                case ValueKind.Integer:
                    rc = Native.sqlite3_bind_int64(Handle, index, value.Number);
                    break;
                case ValueKind.Text:
                    // An empty array pins to a null pointer, and bind_text(NULL) binds NULL, not "".
                    byte[] bytes = Utf8.GetBytes(value.Text ?? string.Empty);
                    fixed (byte* p = bytes.Length == 0 ? new byte[1] : bytes)
                    {
                        rc = Native.sqlite3_bind_text(Handle, index, p, bytes.Length, Transient);
                    }

                    break;
                default:
                    rc = Native.sqlite3_bind_null(Handle, index);
                    break;
            }

            if (rc != Native.Ok)
            {
                throw _conn.Failure(rc);
            }
        }

        public bool Step()
        {
            int rc = Native.sqlite3_step(Handle);
            return rc switch
            {
                Native.Row => true,
                Native.Done => false,
                _ => throw _conn.Failure(rc),
            };
        }

        public unsafe string Text(int col)
        {
            byte* p = Native.sqlite3_column_text(Handle, col);
            return p == null ? string.Empty : Utf8.GetString(new ReadOnlySpan<byte>(p, Native.sqlite3_column_bytes(Handle, col)));
        }

        public unsafe void WriteRow(Utf8JsonWriter w)
        {
            w.WriteStartObject();
            int n = Native.sqlite3_column_count(Handle);
            for (int col = 0; col < n; col++)
            {
                byte* name = Native.sqlite3_column_name(Handle, col);
                w.WritePropertyName(MemoryMarshal.CreateReadOnlySpanFromNullTerminated(name));
                WriteCell(Handle, col, w);
            }

            w.WriteEndObject();
        }

        /// <summary>
        /// One cell as `sqlite3 -json` prints its storage class, so the JS that
        /// coerces rows today reads the same values: INTEGER exact, REAL as
        /// SQLite's own text of it (the CLI prints the same), TEXT as a string
        /// (invalid UTF-8 replaced, as the QML decoder does to the CLI's bytes;
        /// a NUL kept, where the CLI cut the text), BLOB one char per byte,
        /// NULL null. An infinite REAL, which the CLI printed as `Inf` and no
        /// JSON reader takes, is 9e999, which JSON.parse reads as Infinity.
        /// </summary>
        public static unsafe void WriteCell(StmtHandle st, int col, Utf8JsonWriter w)
        {
            switch (Native.sqlite3_column_type(st, col))
            {
                case ColInteger:
                    w.WriteNumberValue(Native.sqlite3_column_int64(st, col));
                    break;
                case ColFloat:
                    double d = Native.sqlite3_column_double(st, col);
                    if (double.IsInfinity(d))
                    {
                        w.WriteRawValue(d > 0 ? "9e999"u8 : "-9e999"u8);
                    }
                    else
                    {
                        w.WriteRawValue(new ReadOnlySpan<byte>(Native.sqlite3_column_text(st, col), Native.sqlite3_column_bytes(st, col)));
                    }

                    break;
                case ColText:
                    var text = new ReadOnlySpan<byte>(Native.sqlite3_column_text(st, col), Native.sqlite3_column_bytes(st, col));
                    if (System.Text.Unicode.Utf8.IsValid(text))
                    {
                        WriteText(text, w);
                    }
                    else
                    {
                        w.WriteStringValue(Utf8.GetString(text));
                    }

                    break;
                case ColBlob:
                    w.WriteStringValue(Encoding.Latin1.GetString(new ReadOnlySpan<byte>(Native.sqlite3_column_blob(st, col), Native.sqlite3_column_bytes(st, col))));
                    break;
                default:
                    w.WriteNullValue();
                    break;
            }
        }

        /// <summary>
        /// A long text in pieces: whole, the writer asks its output for six
        /// times the text's size, the worst case of escaping, so a note of
        /// 1 MB would cost 6 MB. The bytes written are the same.
        /// </summary>
        private static void WriteText(ReadOnlySpan<byte> text, Utf8JsonWriter w)
        {
            const int Piece = 8 * 1024;
            if (text.Length <= Piece)
            {
                w.WriteStringValue(text);
                return;
            }

            for (int at = 0; at < text.Length; at += Piece)
            {
                int n = Math.Min(Piece, text.Length - at);
                w.WriteStringValueSegment(text.Slice(at, n), at + n == text.Length);
            }
        }
    }

    private sealed class DbHandle : SafeHandle
    {
        public DbHandle()
            : base(0, true)
        {
        }

        public override bool IsInvalid => handle == 0;

        /// <summary>close_v2 waits for unfinalized statements instead of failing with BUSY.</summary>
        protected override bool ReleaseHandle() => Native.sqlite3_close_v2(handle) == Native.Ok;
    }

    private sealed class StmtHandle : SafeHandle
    {
        public StmtHandle()
            : base(0, true)
        {
        }

        public override bool IsInvalid => handle == 0;

        protected override bool ReleaseHandle() => Native.sqlite3_finalize(handle) == Native.Ok;
    }

    /// <summary>
    /// LibraryImport, not DirectPInvoke: the ELF needs only libc, libm and the
    /// loader, and a machine without libsqlite3.so.0 starts the binary and gets
    /// DllNotFoundException, which Program reports as sqlite_missing.
    /// </summary>
    private static unsafe partial class Native
    {
        public const int Ok = 0;
        public const int Perm = 3;
        public const int Busy = 5;
        public const int Locked = 6;
        public const int ReadOnly = 8;
        public const int IoErr = 10;
        public const int Corrupt = 11;
        public const int Full = 13;
        public const int CantOpen = 14;
        public const int Constraint = 19;
        public const int NotADb = 26;
        public const int Row = 100;
        public const int Done = 101;
        public const int OpenReadWrite = 2;
        public const int OpenCreate = 4;
        public const int IoErrShortRead = IoErr | (2 << 8);
        public const int FcntlFilePointer = 7;

        private const string Lib = "libsqlite3.so.0";

        [LibraryImport(Lib)]
        public static partial int sqlite3_libversion_number();

        [LibraryImport(Lib)]
        public static partial byte* sqlite3_libversion();

        [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
        public static partial int sqlite3_open_v2(string filename, out DbHandle db, int flags, string? vfs);

        [LibraryImport(Lib)]
        public static partial int sqlite3_close_v2(nint db);

        [LibraryImport(Lib)]
        public static partial int sqlite3_busy_timeout(DbHandle db, int ms);

        [LibraryImport(Lib)]
        public static partial int sqlite3_prepare_v2(DbHandle db, byte* sql, int nByte, out StmtHandle stmt, byte** tail);

        [LibraryImport(Lib)]
        public static partial int sqlite3_step(StmtHandle st);

        [LibraryImport(Lib)]
        public static partial int sqlite3_finalize(nint st);

        [LibraryImport(Lib)]
        public static partial int sqlite3_bind_text(StmtHandle st, int i, byte* text, int nBytes, nint destructor);

        [LibraryImport(Lib)]
        public static partial int sqlite3_bind_int64(StmtHandle st, int i, long value);

        [LibraryImport(Lib)]
        public static partial int sqlite3_bind_null(StmtHandle st, int i);

        [LibraryImport(Lib)]
        public static partial int sqlite3_column_count(StmtHandle st);

        [LibraryImport(Lib)]
        public static partial byte* sqlite3_column_name(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial int sqlite3_column_type(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial long sqlite3_column_int64(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial double sqlite3_column_double(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial byte* sqlite3_column_text(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial byte* sqlite3_column_blob(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial int sqlite3_column_bytes(StmtHandle st, int col);

        [LibraryImport(Lib)]
        public static partial int sqlite3_changes(DbHandle db);

        [LibraryImport(Lib)]
        public static partial long sqlite3_last_insert_rowid(DbHandle db);

        [LibraryImport(Lib)]
        public static partial int sqlite3_get_autocommit(DbHandle db);

        [LibraryImport(Lib)]
        public static partial byte* sqlite3_errmsg(DbHandle db);

        [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
        public static partial int sqlite3_file_control(DbHandle db, string dbName, int op, out SqliteFile* file);

        /// <summary>sqlite3_file: its methods come first.</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct SqliteFile
        {
            public IoMethods* Methods;
        }

        /// <summary>The head of sqlite3_io_methods, up to xRead.</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct IoMethods
        {
            public int Version;
            public delegate* unmanaged<SqliteFile*, int> Close;
            public delegate* unmanaged<SqliteFile*, byte*, int, long, int> Read;
        }
    }
}
