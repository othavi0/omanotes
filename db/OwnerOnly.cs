using System.Runtime.Versioning;

// tools/build.sh publishes for linux-x64 and linux-arm64 only.
[assembly: SupportedOSPlatform("linux")]

namespace Omanotes.Db;

/// <summary>
/// The notes are the user's alone, in a folder other users can list. SQLite
/// creates a database 0644 less the umask, and its -journal, -wal and -shm
/// take the mode of the database (findCreateFileMode in os_unix.c), so the
/// database is the one file to keep at 0600. The owner never changes here.
/// </summary>
internal static class OwnerOnly
{
    private const UnixFileMode Mode = UnixFileMode.UserRead | UnixFileMode.UserWrite;

    private const UnixFileMode Others =
        UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.GroupExecute |
        UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute;

    /// <summary>
    /// Creates an empty file at 0600 when nothing is at the path, so the file
    /// is never readable by others, not even empty: a descriptor opened then
    /// would read the notes written later. SQLite takes an empty file as a new
    /// database, and VACUUM INTO writes into one.
    /// </summary>
    public static void Create(string path)
    {
        try
        {
#pragma warning disable RS0030 // SQLite has not opened the file yet, so closing this descriptor drops no lock.
            File.Open(path, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, UnixCreateMode = Mode }).Dispose();
#pragma warning restore RS0030
        }
        catch (IOException)
        {
            // There already, or no folder: SQLite opens the file or says why it cannot.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Takes a file that group or others may use back to its owner's bits.</summary>
    public static void Restrict(string path)
    {
        try
        {
            UnixFileMode mode = File.GetUnixFileMode(path);
            if ((mode & Others) != 0)
            {
                File.SetUnixFileMode(path, mode & ~Others);
            }
        }
        catch (IOException)
        {
            // Missing: SQLite creates it. chmod belongs to the owner, so a file of
            // another user that this one may write keeps its mode.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
