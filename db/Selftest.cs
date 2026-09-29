using System.Text.Json;

namespace Omanotes.Db;

/// <summary>
/// `selftest DIR`: what an update runs on the new version before it merges,
/// on the machine that will run it. It proves this file starts here (the
/// architecture, the executable bit, libsqlite3 present and new enough), that
/// the embedded fold table is the one the source shipped, and that a database
/// on disk in DIR migrates, takes a write, reads it back and goes away.
/// </summary>
internal static class Selftest
{
    public static int Run(string dir)
    {
        var failed = new List<string>();
        Check(failed, "fold table", Fold.Rows.Count == 2299);
        Check(failed, "fold", Fold.Text("CAFÉ Ação ΣΑΣ") == "cafe acao σασ");
        Check(failed, "fold keeps surrogates", Fold.Text("\U0001F600") == "\U0001F600");

        try
        {
            _ = Directory.CreateDirectory(dir);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new OpException(ErrorCode.Io, "cannot create the selftest folder");
        }

        string path = Path.Combine(dir, "omanotes-selftest.db");
        Remove(path);
        try
        {
            using (Conn db = Conn.Open(path))
            {
                Check(failed, "migrated from 0", Schema.Migrate(db) == 0 && Schema.Version(db) == Schema.Current);
                Check(failed, "search_map", db.Scalar($"SELECT count(*) FROM search_map") == 2299);
                Check(failed, "settings row", db.Scalar($"SELECT count(*) FROM settings") == 1);
                Check(failed, "empty text is not NULL", db.Scalar($"SELECT ?1 IS NULL", Value.Of(string.Empty)) == 0);
                Check(failed, "one statement per prepare", Refused(db));
                Check(failed, "write and read back", RoundTrip(db));
            }
        }
        finally
        {
            Remove(path);
        }

        if (failed.Count > 0)
        {
            throw new OpException(ErrorCode.Selftest, string.Join(", ", failed));
        }

        Program.Fd.Write(Program.Fd.Stdout, "{\"ok\":true}\n"u8);
        return 0;
    }

    private static void Check(List<string> failed, string name, bool ok)
    {
        if (!ok)
        {
            failed.Add(name);
        }
    }

    private static bool Refused(Conn db)
    {
        try
        {
            _ = db.Run($"SELECT 1; SELECT 2");
            return false;
        }
        catch (OpException)
        {
            return true;
        }
    }

    /// <summary>An add through the write table, then a snapshot whose item, search copy and search match are that add's.</summary>
    private static bool RoundTrip(Conn db)
    {
        using Request req = Request.Parse("""{"writes":[{"id":1,"by":"widget","op":"item.add","at":1700000000,"args":{"type":"note","title":"Café","body":"Ação"}}],"sync":{"views":[{"key":"v","filter":"all","query":"acao"}]}}"""u8.ToArray());
        var results = new Chunks(1 << 16);
        using (var w = new Utf8JsonWriter(results, Program.Json))
        {
            Writes.Run(db, req.Writes[0], w);
        }

        var snapshot = new Chunks(1 << 16);
        using (var w = new Utf8JsonWriter(snapshot, Program.Json))
        {
            Snapshot.Write(db, req.Sync!, w);
        }

        using JsonDocument result = JsonDocument.Parse(results.ToArray());
        using JsonDocument snap = JsonDocument.Parse(snapshot.ToArray());
        JsonElement item = snap.RootElement.GetProperty("items")[0];
        return result.RootElement.GetProperty("value").GetInt64() == 1
            && item.GetProperty("title").GetString() == "Café"
            && item.GetProperty("body").GetString() == "Ação"
            && snap.RootElement.GetProperty("matches").GetProperty("v")[0].GetInt64() == 1
            && db.Scalar($"SELECT count(*) FROM items WHERE search_title = 'cafe' AND search_body = 'acao'") == 1;
    }

    private static void Remove(string path)
    {
        try
        {
            File.Delete(path);
            File.Delete(path + "-journal");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new OpException(ErrorCode.Io, "cannot remove the selftest database");
        }
    }
}
