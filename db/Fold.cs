using System.Globalization;
using System.Reflection;
using System.Text;

namespace Omanotes.Db;

/// <summary>
/// The search fold of ADR-0012 as data. Schema/search_map.tsv has one line per
/// UTF-16 unit the old searchChar changed: the unit, a tab, and the code points
/// it folds to, all in hex (2299 lines, sha256 406fc008..., equal to the
/// search_map of the live database). The same table fills search_map, so the
/// text this binary folds and the text the SQL triggers fold agree. It never
/// calls .NET's case or normalization code (BannedSymbols.txt): a runtime
/// update cannot fold new rows differently from the rows already stored.
/// </summary>
internal static class Fold
{
    public static readonly IReadOnlyList<(char Unit, string Folded)> Rows = Load();

    private static readonly Dictionary<char, string> Map = ToMap(Rows);

    /// <summary>One unit at a time; a unit outside the table, a surrogate included, stays as it is.</summary>
    public static string Text(string text)
    {
        StringBuilder? sb = null;
        for (int i = 0; i < text.Length; i++)
        {
            if (!Map.TryGetValue(text[i], out string? folded))
            {
                _ = sb?.Append(text[i]);
                continue;
            }

            sb ??= new StringBuilder(text.Length).Append(text, 0, i);
            _ = sb.Append(folded);
        }

        return sb?.ToString() ?? text;
    }

    /// <summary>For LIKE ... ESCAPE '\': the backslash first, so it cannot swallow the wildcards.</summary>
    public static string LikeEscape(string s) =>
        s.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal).Replace("_", "\\_", StringComparison.Ordinal);

    private static List<(char, string)> Load()
    {
        using Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("search_map.tsv")
            ?? throw new OpException(ErrorCode.Internal, "search_map.tsv is not embedded");
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true));
        var rows = new List<(char, string)>(2299);
        while (reader.ReadLine() is string line)
        {
            int tab = line.IndexOf('\t', StringComparison.Ordinal);
            var folded = new StringBuilder();
            foreach (string point in line[(tab + 1)..].Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                _ = folded.Append(char.ConvertFromUtf32(Hex(point)));
            }

            rows.Add(((char)Hex(line[..tab]), folded.ToString()));
        }

        return rows;
    }

    private static Dictionary<char, string> ToMap(IReadOnlyList<(char Unit, string Folded)> rows)
    {
        var map = new Dictionary<char, string>(rows.Count);
        foreach ((char unit, string folded) in rows)
        {
            map.Add(unit, folded);
        }

        return map;
    }

    private static int Hex(string s)
    {
        int n = 0;
        foreach (char c in s)
        {
            n = checked((n * 16) + (c is >= '0' and <= '9' ? c - '0' : c is >= 'a' and <= 'f' ? c - 'a' + 10 : throw new OpException(ErrorCode.Internal, "search_map.tsv is not hex")));
        }

        return n;
    }
}
