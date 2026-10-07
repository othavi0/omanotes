using System.Runtime.InteropServices;

namespace Omanotes.Db;

/// <summary>
/// The notes are the user's alone, in a folder other users can list. Under
/// the umask every file this process creates is 0600: the database, a
/// backup's .tmp and what VACUUM INTO writes in it, and any file to come.
/// SQLite gives a -journal, -wal or -shm the mode of the database
/// (findCreateFileMode in os_unix.c). A file that is already there keeps its
/// mode, so <see cref="Restrict"/> takes the bits of group and others off the
/// ones a release before this left 0644.
/// </summary>
internal static partial class OwnerOnly
{
    private const string Libc = "libc.so.6";

    /// <summary>0o077: no bit for group or others on a file or folder created from now on.</summary>
    private const uint GroupAndOthersBits = 0x3F;

    private const UnixFileMode Others =
        UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.GroupExecute |
        UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute;

    private static readonly string[] Sidecars = ["-wal", "-shm", "-journal"];

    /// <summary>Every file and folder this process creates from here on is its owner's alone.</summary>
    public static void FromNowOn() => _ = umask(GroupAndOthersBits);

    /// <summary>
    /// The database, its -wal, -shm and -journal, and the backups of every
    /// day with their .tmp, back to their owner's bits. Runs before SQLite
    /// opens the database, so a -wal or -shm that is there is restricted
    /// before it is read.
    /// </summary>
    public static void Restrict(string dbPath)
    {
        RestrictFile(dbPath);
        foreach (string suffix in Sidecars)
        {
            RestrictFile(dbPath + suffix);
        }

        string dir = Path.GetDirectoryName(dbPath) ?? "/";
        try
        {
            // The names Writes.Backup gives; the folder is Omarchy's, and other files in it are not ours to chmod.
            foreach (string pattern in (string[])["scratchpad-*.db", "scratchpad-*.db.tmp"])
            {
                foreach (string file in Directory.EnumerateFiles(dir, pattern))
                {
                    RestrictFile(file);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Unexpected(dir, e);
        }
    }

    private static void RestrictFile(string path)
    {
        try
        {
            UnixFileMode mode = File.GetUnixFileMode(path);
            if ((mode & Others) != 0)
            {
                File.SetUnixFileMode(path, mode & ~Others);
            }
        }
        catch (FileNotFoundException)
        {
            // ENOENT: not there, or gone since the folder was listed. SQLite creates a missing one under the umask.
        }
        catch (UnauthorizedAccessException)
        {
            // EPERM: chmod is the owner's, so a file of another user that this one may write keeps its mode.
        }
        catch (IOException e)
        {
            Unexpected(path, e);
        }
    }

    /// <summary>
    /// Goes to the journal through stderr, and the request goes on: a mode
    /// bit is no reason to keep the user from the notes, and the line names
    /// the file to look at.
    /// </summary>
    private static void Unexpected(string path, Exception e) => Program.Log("cannot restrict " + path + ": " + e.GetType().Name);

    [LibraryImport(Libc)]
    private static partial uint umask(uint mask);
}
