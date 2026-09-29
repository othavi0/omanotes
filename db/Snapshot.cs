using System.Buffers.Binary;
using System.Text.Json;

namespace Omanotes.Db;

/// <summary>
/// Every read of a reload in one read transaction: the settings row, the
/// counts, every item, the history, the alarms and the ids each search
/// matched. The rows are the rows data/Db.js read (same SQL), and each cell is
/// raw, in the storage class `sqlite3 -json` printed, so the JS coercion that
/// reads them today reads them unchanged.
/// </summary>
internal static class Snapshot
{
    public static void Write(Conn db, SyncReq req, Utf8JsonWriter w)
    {
        using Conn.Tx tx = db.Read();

        // A deferred BEGIN takes no lock until the first read. With the SHARED
        // lock held no writer can commit, so the stamp and the rows agree.
        _ = db.Scalar($"SELECT count(*) FROM sqlite_schema");
        long stamp = Stamp(db);
        bool unchanged = stamp >= 0 && stamp == req.Since;
        w.WriteStartObject();
        w.WriteNumber("stamp", stamp);
        w.WriteBoolean("unchanged", unchanged);
        if (!unchanged)
        {
            w.WritePropertyName("settings");
            db.WriteRow($"SELECT s.*, pc.page_count * ps.page_size AS db_bytes FROM pragma_page_count pc, pragma_page_size ps LEFT JOIN settings s ON s.id = 1", w);
            w.WritePropertyName("counts");
            db.WriteRow($"SELECT (SELECT COUNT(*) FROM items WHERE type = 'note' AND status = 0) AS unreadNotes, (SELECT COUNT(*) FROM items WHERE type = 'todo' AND status = 0) AS pendingTodos, (SELECT COUNT(*) FROM items WHERE type = 'note') AS notes, (SELECT COUNT(*) FROM items WHERE type = 'todo') AS todos, (SELECT COUNT(*) FROM history) AS history, (SELECT COALESCE(MIN(ts), 0) FROM history) AS oldest", w);
            w.WritePropertyName("items");
            db.WriteRows($"SELECT id, type, title, body, status, created_at, updated_at FROM items ORDER BY status ASC, position ASC, id DESC", w);
            w.WritePropertyName("history");
            db.WriteRows($"SELECT id, type, title, action, ts FROM history ORDER BY ts DESC, id DESC LIMIT 500", w);
            w.WritePropertyName("alarms");
            db.WriteRows($"SELECT id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes, snoozed_until_ms, last_fired_at_ms, armed_at_ms, auto_snoozes FROM alarms ORDER BY hour, minute, id", w);
            w.WriteStartObject("matches");
            foreach (View v in req.Views)
            {
                // The query comes trimmed by String.prototype.trim and folds as the stored copies did (ADR-0012).
                string needle = Fold.Text(v.Query);
                w.WritePropertyName(v.Key);
                db.WriteColumn(
                    $"SELECT id FROM items WHERE (?1 IS NULL OR type = ?1) AND (?2 = '' OR search_title LIKE ?3 ESCAPE '\\' OR search_body LIKE ?3 ESCAPE '\\') ORDER BY status ASC, position ASC, id DESC",
                    w,
                    Value.Of(v.Type),
                    Value.Of(needle),
                    Value.Of("%" + Fold.LikeEscape(needle) + "%"));
            }

            w.WriteEndObject();
        }

        w.WriteEndObject();
        tx.Commit();
    }

    /// <summary>
    /// The file change counter (header bytes 24..27) in rollback-journal mode,
    /// which every commit moves; -1 in WAL, where it does not move, so a stamp
    /// of -1 never skips a read.
    /// </summary>
    private static long Stamp(Conn db)
    {
        Span<byte> header = stackalloc byte[100];
        return db.ReadHeader(header) && header[18] == 1 && header[19] == 1
            ? BinaryPrimitives.ReadUInt32BigEndian(header[24..28])
            : -1;
    }
}
