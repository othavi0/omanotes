using System.Text.Json;

namespace Omanotes.Db;

/// <summary>A write: throws OpException to refuse, returns the value its result carries (a new id, a file name) or Value.Null.</summary>
internal delegate Value Handler(Conn db, Args a, long at);

internal sealed record Op(string Name, Who Allowed, Handler Run);

/// <summary>
/// The write ops, one table. Who may send each is part of its row, so ADR-0015
/// (only the service writes alarms) and ADR-0016 (only a widget writes
/// settings) are a lookup here, not a habit of the callers. Each op is one
/// BEGIN IMMEDIATE transaction, or one autocommit statement where the old SQL
/// had none, so an op that fails part way leaves the file as it found it.
/// The SQL is the SQL data/Db.js built, with bound values in place of quoting.
/// </summary>
internal static class Writes
{
    private static readonly Dictionary<string, Op> Table = Index(
        new("item.add", Who.Widget, ItemAdd),
        new("item.status", Who.Widget, ItemStatus),
        new("item.update", Who.Widget, ItemUpdate),
        new("item.convert", Who.Widget, ItemConvert),
        new("item.delete", Who.Widget, ItemDelete),
        new("item.move", Who.Widget, ItemMove),
        new("history.delete", Who.Widget, HistoryDelete),
        new("history.clear", Who.Widget, HistoryClear),
        new("history.prune", Who.Widget, HistoryPrune),
        new("settings.set", Who.Widget, SettingsSet),
        new("backup", Who.Widget, Backup),
        new("alarm.insert", Who.Service, AlarmInsert),
        new("alarm.save", Who.Service, AlarmSave),
        new("alarm.delete", Who.Service, AlarmDelete));

    /// <summary>The columns of an alarm record in protocol 1, as data/Db.js alarmCells sends them.</summary>
    private static readonly HashSet<string> AlarmColumns = new(StringComparer.Ordinal)
    {
        "hour", "minute", "label", "days", "enabled", "snooze_minutes", "ring_minutes",
        "snoozed_until_ms", "last_fired_at_ms", "armed_at_ms", "auto_snoozes",
    };

    public static Op? Find(string name) => Table.GetValueOrDefault(name);

    /// <summary>
    /// Runs one write and writes its result object; returns why it failed, or
    /// null. A failed write is its own result and does not stop the next, and
    /// an exception that is not an OpException is that write's `internal`:
    /// the writes before it are committed and their results must go out.
    /// </summary>
    public static OpException? Run(Conn db, WriteReq w, Utf8JsonWriter json)
    {
        json.WriteStartObject();
        json.WriteNumber("id", w.Id);
        OpException? failure = null;
        try
        {
            if (w.By != w.Op.Allowed)
            {
                throw new OpException(ErrorCode.Forbidden, w.Op.Name + (w.Op.Allowed == Who.Service ? " is the service's" : " is a widget's"));
            }

            Value v = w.Op.Run(db, w.Args, w.At);
            if (v.Kind == ValueKind.Integer)
            {
                json.WriteNumber("value", v.Number);
            }
            else if (v.Kind == ValueKind.Text)
            {
                json.WriteString("value", v.Text);
            }
        }
        catch (OpException e)
        {
            failure = e;
        }
#pragma warning disable CA1031 // A bug in one op must not take back the results of the writes committed before it.
        catch (Exception e)
#pragma warning restore CA1031
        {
            failure = new OpException(ErrorCode.Internal, e.GetType().Name);
        }

        failure?.WriteFields(json);
        json.WriteEndObject();
        return failure;
    }

    /// <summary>The result of a write not run, failed with `why`, which it returns.</summary>
    public static OpException Refuse(WriteReq w, OpException why, Utf8JsonWriter json)
    {
        json.WriteStartObject();
        json.WriteNumber("id", w.Id);
        why.WriteFields(json);
        json.WriteEndObject();
        return why;
    }

    private static Dictionary<string, Op> Index(params ReadOnlySpan<Op> ops)
    {
        var table = new Dictionary<string, Op>(StringComparer.Ordinal);
        foreach (Op op in ops)
        {
            table.Add(op.Name, op);
        }

        return table;
    }

    private static long Id(Args a, string name = "id") => a.Int(name, 0, long.MaxValue);

    /// <summary>Anything but note or todo is refused; the caller never sends another type.</summary>
    private static string ItemType(Args a)
    {
        string type = a.Text("type");
        return type is "note" or "todo" ? type : throw new OpException(ErrorCode.BadRequest, "type is note or todo");
    }

    /// <summary>An absent or empty body is NULL, as bodySql made it.</summary>
    private static string? Body(Args a) => a.TextOrNull("body") is { Length: > 0 } body ? body : null;

    /// <summary>A write that targets one row and found none is `not_found`, and the transaction rolls back untouched.</summary>
    private static Value Found(Conn.Tx tx, long changes)
    {
        if (changes == 0)
        {
            throw new OpException(ErrorCode.NotFound, "no such row");
        }

        tx.Commit();
        return Value.Null;
    }

    /// <summary>The history row copies the item's own type and title (ADR-0006).</summary>
    private static void HistoryOf(Conn db, long id, string action, long at) =>
        db.Run($"INSERT INTO history (type, title, action, ts) SELECT type, title, ?2, ?3 FROM items WHERE id = ?1", Value.Of(id), Value.Of(action), Value.Of(at));

    private static Value ItemAdd(Conn db, Args a, long at)
    {
        a.Only("type", "title", "body");
        string type = ItemType(a);
        string title = a.Text("title");
        string? body = Body(a);
        using Conn.Tx tx = db.Immediate();
        long id = db.Insert(
            $"INSERT INTO items (type, title, body, search_title, search_body, status, position, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 0, (SELECT COALESCE(MIN(position), 1) - 1 FROM items WHERE status = 0), ?6, ?6)",
            Value.Of(type),
            Value.Of(title),
            Value.Of(body),
            Value.Of(Fold.Text(title)),
            Value.Of(body is null ? null : Fold.Text(body)),
            Value.Of(at));
        _ = db.Run($"INSERT INTO history (type, title, action, ts) VALUES (?1, ?2, 'added', ?3)", Value.Of(type), Value.Of(title), Value.Of(at));
        tx.Commit();
        return Value.Of(id);
    }

    /// <summary>Moves the item to the top of its new block (ADR-0014). The history row goes first so it can skip an item that already has the status.</summary>
    private static Value ItemStatus(Conn db, Args a, long at)
    {
        a.Only("id", "status");
        long id = Id(a);
        long status = a.Int("status", 0, 1);
        using Conn.Tx tx = db.Immediate();
        _ = db.Run(
            $"INSERT INTO history (type, title, action, ts) SELECT type, title, ?2, ?3 FROM items WHERE id = ?1 AND status <> ?4",
            Value.Of(id),
            Value.Of(status == 1 ? "completed" : "reopened"),
            Value.Of(at),
            Value.Of(status));
        long changes = db.Run(
            $"UPDATE items SET status = ?2, position = CASE status WHEN ?2 THEN position ELSE (SELECT COALESCE(MIN(position), 1) - 1 FROM items WHERE status = ?2) END, updated_at = CASE status WHEN ?2 THEN updated_at ELSE ?3 END WHERE id = ?1",
            Value.Of(id),
            Value.Of(status),
            Value.Of(at));
        return Found(tx, changes);
    }

    private static Value ItemUpdate(Conn db, Args a, long at)
    {
        a.Only("id", "title", "body");
        long id = Id(a);
        string title = a.Text("title");
        string? body = Body(a);
        using Conn.Tx tx = db.Immediate();
        long changes = db.Run(
            $"UPDATE items SET title = ?2, body = ?3, search_title = ?4, search_body = ?5, updated_at = ?6 WHERE id = ?1",
            Value.Of(id),
            Value.Of(title),
            Value.Of(body),
            Value.Of(Fold.Text(title)),
            Value.Of(body is null ? null : Fold.Text(body)),
            Value.Of(at));
        HistoryOf(db, id, "edited", at);
        return Found(tx, changes);
    }

    private static Value ItemConvert(Conn db, Args a, long at)
    {
        a.Only("id");
        long id = Id(a);
        using Conn.Tx tx = db.Immediate();
        long changes = db.Run($"UPDATE items SET type = CASE type WHEN 'note' THEN 'todo' ELSE 'note' END, updated_at = ?2 WHERE id = ?1", Value.Of(id), Value.Of(at));
        HistoryOf(db, id, "converted", at);
        return Found(tx, changes);
    }

    private static Value ItemDelete(Conn db, Args a, long at)
    {
        a.Only("id");
        long id = Id(a);
        using Conn.Tx tx = db.Immediate();
        HistoryOf(db, id, "deleted", at);
        return Found(tx, db.Run($"DELETE FROM items WHERE id = ?1", Value.Of(id)));
    }

    /// <summary>
    /// Puts the item just before its anchor, or after it, and numbers that
    /// block 1, 2, 3 in the new order (ADR-0014). Nothing is written, and the
    /// op is `not_found`, when either id is missing, both are the same item or
    /// they sit in different blocks. A move is not an action: no history.
    /// </summary>
    private static Value ItemMove(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("id", "anchorId", "after");
        long id = Id(a);
        long anchor = Id(a, "anchorId");
        long after = a.Bool("after") ? 2 : 0;
        using Conn.Tx tx = db.Immediate();
        long changes = db.Run(
            $"UPDATE items SET position = moved.position FROM (SELECT i.id, ROW_NUMBER() OVER (ORDER BY CASE i.id WHEN ?1 THEN a.position ELSE i.position END, CASE i.id WHEN ?1 THEN a.id ELSE i.id END DESC, CASE i.id WHEN ?1 THEN ?3 ELSE 1 END) AS position FROM items i JOIN items a ON a.id = ?2 AND a.status = i.status JOIN items m ON m.id = ?1 AND m.status = a.status AND m.id <> a.id) AS moved WHERE items.id = moved.id",
            Value.Of(id),
            Value.Of(anchor),
            Value.Of(after));
        return Found(tx, changes);
    }

    private static Value HistoryDelete(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("id");
        _ = db.Run($"DELETE FROM history WHERE id = ?1", Value.Of(Id(a)));
        return Value.Null;
    }

    private static Value HistoryClear(Conn db, Args a, long at)
    {
        _ = at;
        a.Only();
        _ = db.Run($"DELETE FROM history");
        return Value.Null;
    }

    /// <summary>With no entry that old nothing is deleted, and SQLite leaves the file as it was (the watcher stays quiet).</summary>
    private static Value HistoryPrune(Conn db, Args a, long at)
    {
        a.Only("days");
        Prune(db, a.Int("days", 1, 36500), at);
        return Value.Null;
    }

    private static void Prune(Conn db, long days, long at) =>
        db.Run($"DELETE FROM history WHERE ts < ?1 - ?2 * 86400", Value.Of(at), Value.Of(days));

    /// <summary>
    /// One upsert of only the columns in `values`, so two panels writing
    /// different settings never undo each other (ADR-0016). The ranges are the
    /// CHECKs' and the caller's SETTINGS', never this binary's. A shorter Keep
    /// prunes in the same transaction, so History never shows what it drops.
    /// </summary>
    private static Value SettingsSet(Conn db, Args a, long at)
    {
        a.Only("values");
        Conn.Row row = db.RowOf(RowTable.Settings, a.Obj("values").Cells());
        if (row.Cells.Count == 0)
        {
            throw new OpException(ErrorCode.BadRequest, "no setting to write");
        }

        using Conn.Tx tx = db.Immediate();
        db.UpsertRow(row, 1);
        foreach ((string column, Value value) in row.Cells)
        {
            if (column == "history_days" && value.Kind == ValueKind.Integer && value.Number > 0)
            {
                Prune(db, value.Number, at);
            }
        }

        tx.Commit();
        return Value.Null;
    }

    /// <summary>
    /// VACUUM INTO a temporary file beside the database, then a move over the
    /// day's backup, so a VACUUM that fails leaves the earlier copy of the
    /// day. The day is the caller's local date: this binary has no zone.
    /// </summary>
    private static Value Backup(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("day");
        string day = a.Text("day");
        bool valid = day.Length == 10;
        for (int i = 0; valid && i < day.Length; i++)
        {
            valid = i is 4 or 7 ? day[i] == '-' : day[i] is >= '0' and <= '9';
        }

        if (!valid)
        {
            throw new OpException(ErrorCode.BadRequest, "day is yyyy-mm-dd");
        }

        string name = "scratchpad-" + day + ".db";
        string target = Path.Combine(Path.GetDirectoryName(db.Path) ?? "/", name);
        string temporary = target + ".tmp";
        try
        {
            File.Delete(temporary);
            OwnerOnly.Create(temporary);
            _ = db.Run($"VACUUM INTO ?1", Value.Of(temporary));
            File.Move(temporary, target, overwrite: true);
        }
        catch (IOException)
        {
            throw new OpException(ErrorCode.Io, "backup file error");
        }
        catch (UnauthorizedAccessException)
        {
            throw new OpException(ErrorCode.Io, "permission denied");
        }

        return Value.Of(name);
    }

    /// <summary>
    /// The record is absolute (ADR-0015): every column of the protocol, so
    /// sending it twice leaves the same row. The protocol fixes the columns,
    /// not the file: one the file has beyond these, from a later schema or
    /// the user, keeps its DEFAULT on insert and its value on save.
    /// </summary>
    private static Conn.Row Alarm(Conn db, Args a)
    {
        List<(string Name, Value Value)> cells = a.Obj("alarm").Cells();
        foreach ((string name, Value _) in cells)
        {
            if (!AlarmColumns.Contains(name))
            {
                throw new OpException(ErrorCode.BadRequest, "unknown or repeated column");
            }
        }

        Conn.Row row = db.RowOf(RowTable.Alarms, cells);
        return row.Cells.Count == AlarmColumns.Count ? row : throw new OpException(ErrorCode.BadRequest, "an alarm names every column");
    }

    private static Value AlarmInsert(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("alarm");
        Conn.Row row = Alarm(db, a);
        using Conn.Tx tx = db.Immediate();
        long id = db.InsertRow(row);
        tx.Commit();
        return Value.Of(id);
    }

    private static Value AlarmSave(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("id", "alarm");
        long id = Id(a);
        Conn.Row row = Alarm(db, a);
        using Conn.Tx tx = db.Immediate();
        return Found(tx, db.UpdateRow(row, id));
    }

    private static Value AlarmDelete(Conn db, Args a, long at)
    {
        _ = at;
        a.Only("id");
        long id = Id(a);
        using Conn.Tx tx = db.Immediate();
        return Found(tx, db.Run($"DELETE FROM alarms WHERE id = ?1", Value.Of(id)));
    }
}
