using System.Text.Json;

namespace Omanotes.Db;

/// <summary>
/// Every failure the wire names. The caller shows the words (data/Db.js keeps
/// one sentence per code); the binary sends the code and a detail that is
/// sqlite3_errmsg or a constant of this source, never user text and never
/// Exception.Message, which UseSystemResourceKeys turns into a resource id.
/// </summary>
internal enum ErrorCode
{
    Protocol,
    BadRequest,
    Timeout,
    TooLarge,
    ResponseTooLarge,
    Busy,
    NotFound,
    Refused,
    Forbidden,
    Io,
    Corrupt,
    Sqlite,
    SqliteMissing,
    SqliteTooOld,
    Selftest,
    Internal,
}

internal sealed class OpException : Exception
{
    public OpException(ErrorCode code, string detail)
        : base(Wire(code))
    {
        Code = code;
        Detail = detail;
    }

    public ErrorCode Code { get; }

    public string Detail { get; }

    /// <summary>64 is a caller that speaks another protocol or another command line; 70, a bug here, reads as a crash.</summary>
    public int Exit => Code switch
    {
        ErrorCode.Protocol => 64,
        ErrorCode.Internal => 70,
        _ => 1,
    };

    public static string Wire(ErrorCode code) => code switch
    {
        ErrorCode.Protocol => "protocol",
        ErrorCode.BadRequest => "bad_request",
        ErrorCode.Timeout => "timeout",
        ErrorCode.TooLarge => "too_large",
        ErrorCode.ResponseTooLarge => "response_too_large",
        ErrorCode.Busy => "busy",
        ErrorCode.NotFound => "not_found",
        ErrorCode.Refused => "refused",
        ErrorCode.Forbidden => "forbidden",
        ErrorCode.Io => "io",
        ErrorCode.Corrupt => "corrupt",
        ErrorCode.Sqlite => "sqlite",
        ErrorCode.SqliteMissing => "sqlite_missing",
        ErrorCode.SqliteTooOld => "sqlite_too_old",
        ErrorCode.Selftest => "selftest",
        ErrorCode.Internal => "internal",
    };

    /// <summary>{"err","detail"}: the last line of stderr on exit 1, 64 or 70, the syncErr of exit 3, and a failed write's result.</summary>
    public void WriteFields(Utf8JsonWriter w)
    {
        w.WriteString("err", Wire(Code));
        w.WriteString("detail", Detail);
    }
}

internal static class Protocol
{
    /// <summary>The newest protocol this binary speaks. argv[1] names the caller's. 2 writes one result line per write (ADR-0020).</summary>
    public const int Current = 2;

    /// <summary>
    /// The oldest one it still answers. Between an update's merge and the
    /// shell's restart the old QML runs against the new binary (ADR-0017), so
    /// a release that raises Current keeps Min = Current - 1.
    /// </summary>
    public const int Min = 1;

    /// <summary>The protocol that writes every result in one {"results":[...]} line after the last write. Its branch goes once Min passes it.</summary>
    public const int OneResultsLine = 1;

    /// <summary>A body over about 64 KB was lost in argv before (issue #55); the request now travels on stdin up to this.</summary>
    public const int MaxRequestBytes = 1 << 20;

    /// <summary>The snapshot is written as it is read; this bounds the bytes written, and so the caller's collector.</summary>
    public const int MaxResponseBytes = 64 << 20;

    /// <summary>
    /// A stdin with no byte and no end for this long is a lost write on the
    /// caller's side: give up instead of hanging its queue. Long enough that a
    /// shell busy for a few seconds between the spawn and the write of the
    /// request does not lose it.
    /// </summary>
    public const int StdinIdleMs = 30000;
}

/// <summary>Who sends a write. The op table says who may (ADR-0015: alarms are the service's; ADR-0016: settings are a widget's).</summary>
internal enum Who
{
    Widget,
    Service,
}

internal sealed record WriteReq(long Id, Who By, Op Op, long At, Args Args);

/// <summary>A search the snapshot answers with ids in list order. Type null is every type.</summary>
internal sealed record View(string Key, string? Type, string Query);

/// <summary>Since is the stamp of the snapshot the caller holds, or -1.</summary>
internal sealed record SyncReq(long Since, IReadOnlyList<View> Views);

/// <summary>
/// The request, parsed once at the boundary. A wrong shape anywhere in the
/// envelope is `bad_request` for the whole request and nothing runs; a wrong
/// shape inside one write's args is that write's `bad_request`.
/// </summary>
internal sealed class Request : IDisposable
{
    private readonly JsonDocument _doc;

    private Request(JsonDocument doc, IReadOnlyList<WriteReq> writes, SyncReq? sync)
    {
        _doc = doc;
        Writes = writes;
        Sync = sync;
    }

    public IReadOnlyList<WriteReq> Writes { get; }

    public SyncReq? Sync { get; }

    public void Dispose() => _doc.Dispose();

    public static Request Parse(ReadOnlyMemory<byte> utf8)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(utf8, new JsonDocumentOptions { MaxDepth = 8 });
        }
        catch (JsonException)
        {
            throw new OpException(ErrorCode.BadRequest, "request is not JSON");
        }

        try
        {
            var root = new Args(doc.RootElement);
            root.Only("writes", "sync");
            var writes = new List<WriteReq>();
            foreach (Args w in root.Array("writes"))
            {
                w.Only("id", "by", "op", "at", "args");
                string by = w.Text("by");
                writes.Add(new WriteReq(
                    w.Int("id", 0, long.MaxValue),
                    by == "widget" ? Who.Widget : by == "service" ? Who.Service : throw new OpException(ErrorCode.BadRequest, "by is widget or service"),
                    Omanotes.Db.Writes.Find(w.Text("op")) ?? throw new OpException(ErrorCode.BadRequest, "unknown op"),
                    w.Int("at", 0, Limits.MaxSafeInteger),
                    w.Has("args") ? w.Obj("args") : default));
            }

            SyncReq? sync = root.Has("sync") ? ParseSync(root.Obj("sync")) : null;
            if (writes.Count == 0 && sync is null)
            {
                throw new OpException(ErrorCode.BadRequest, "nothing to do");
            }

            return new Request(doc, writes, sync);
        }
        catch
        {
            doc.Dispose();
            throw;
        }
    }

    private static SyncReq ParseSync(Args s)
    {
        s.Only("since", "views");
        var views = new List<View>();
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (Args v in s.Array("views"))
        {
            v.Only("key", "filter", "query");
            string key = v.Text("key");
            if (key.Length == 0 || !keys.Add(key))
            {
                throw new OpException(ErrorCode.BadRequest, "view keys are unique and not empty");
            }

            // An unknown filter reads as all, as listSql read it.
            string filter = v.Text("filter");
            views.Add(new View(key, filter is "note" or "todo" ? filter : null, v.Text("query")));
        }

        return new SyncReq(s.Has("since") ? s.Int("since", -1, uint.MaxValue) : -1, views);
    }
}

/// <summary>
/// Typed reads over one JSON object. A missing member, a member no one asked
/// for, a wrong token type and a number outside its range are `bad_request`
/// here, so an op body never handles a wrong shape.
/// </summary>
internal readonly struct Args
{
    private readonly JsonElement _e;

    public Args(JsonElement e)
    {
        _e = e;
    }

    public bool Has(string name) => _e.ValueKind == JsonValueKind.Object && _e.TryGetProperty(name, out JsonElement v) && v.ValueKind != JsonValueKind.Null;

    public void Only(params ReadOnlySpan<string> names)
    {
        if (_e.ValueKind == JsonValueKind.Undefined)
        {
            return;
        }

        if (_e.ValueKind != JsonValueKind.Object)
        {
            throw new OpException(ErrorCode.BadRequest, "expected an object");
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty p in _e.EnumerateObject())
        {
            if (!names.Contains(p.Name))
            {
                throw new OpException(ErrorCode.BadRequest, "unknown member");
            }

            if (!seen.Add(p.Name))
            {
                throw new OpException(ErrorCode.BadRequest, "repeated member");
            }
        }
    }

    public string Text(string name) => TextOrNull(name) ?? throw new OpException(ErrorCode.BadRequest, "missing " + name);

    /// <summary>Null when absent or null.</summary>
    public string? TextOrNull(string name) => Has(name) ? AsText(_e.GetProperty(name), name) : null;

    /// <summary>A whole number in [min, max]. A fraction, a boolean or text is refused, as sqlInt refused it.</summary>
    public long Int(string name, long min, long max)
    {
        if (!Has(name) || !AsInteger(_e.GetProperty(name), out long n) || n < min || n > max)
        {
            throw new OpException(ErrorCode.BadRequest, "invalid " + name);
        }

        return n;
    }

    public bool Bool(string name) => Has(name) ? _e.GetProperty(name).ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new OpException(ErrorCode.BadRequest, name + " is true or false"),
    }
    : throw new OpException(ErrorCode.BadRequest, "missing " + name);

    public Args Obj(string name) => Has(name) && _e.GetProperty(name).ValueKind == JsonValueKind.Object
        ? new Args(_e.GetProperty(name))
        : throw new OpException(ErrorCode.BadRequest, name + " is an object");

    /// <summary>The objects of an array member; none when it is absent.</summary>
    public IEnumerable<Args> Array(string name)
    {
        if (!Has(name))
        {
            yield break;
        }

        JsonElement a = _e.GetProperty(name);
        if (a.ValueKind != JsonValueKind.Array)
        {
            throw new OpException(ErrorCode.BadRequest, name + " is an array");
        }

        foreach (JsonElement item in a.EnumerateArray())
        {
            yield return new Args(item);
        }
    }

    /// <summary>Every member as a cell to bind: a whole number or a text. Column names are checked by Conn.RowOf.</summary>
    public List<(string Name, Value Value)> Cells()
    {
        var cells = new List<(string, Value)>();
        foreach (JsonProperty p in _e.EnumerateObject())
        {
            Value v = p.Value.ValueKind == JsonValueKind.String
                ? Value.Of(AsText(p.Value, "a column"))
                : AsInteger(p.Value, out long n) ? Value.Of(n) : throw new OpException(ErrorCode.BadRequest, "a column takes a whole number or a text");
            cells.Add((p.Name, v));
        }

        return cells;
    }

    private static bool AsInteger(JsonElement e, out long n)
    {
        n = 0;
        return e.ValueKind == JsonValueKind.Number && e.TryGetInt64(out n);
    }

    private static string AsText(JsonElement e, string name)
    {
        if (e.ValueKind != JsonValueKind.String)
        {
            throw new OpException(ErrorCode.BadRequest, name + " is a text");
        }

        try
        {
            return e.GetString() ?? string.Empty;
        }
        catch (InvalidOperationException)
        {
            // An escaped lone surrogate. The caller repairs text to well-formed UTF-16 first.
            throw new OpException(ErrorCode.BadRequest, name + " holds a lone surrogate");
        }
    }
}

internal static class Limits
{
    /// <summary>Number.MAX_SAFE_INTEGER: the largest instant the caller's clock can hand over exactly.</summary>
    public const long MaxSafeInteger = 9007199254740991;
}
