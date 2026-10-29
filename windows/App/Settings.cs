using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Jev;

public sealed class Settings
{
    public string Url { get; set; } = "http://127.0.0.1:20128/v1";
    public string Model { get; set; } = "";
    public bool UseJev { get; set; }
    public string RouterProtected { get; set; } = "";
    public string JevProtected { get; set; } = "";
    public PixelRegion? WindowRegion { get; set; }
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JevCompanion");
    private static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    public static bool Stored => File.Exists(FilePath);
    public static Settings Load() => File.Exists(FilePath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new() : new();
    public static string Protect(string value) => string.IsNullOrEmpty(value) ? "" : Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
    public static string Unprotect(string value) => string.IsNullOrEmpty(value) ? "" : Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));
    public Connection Connection() => new(Url, Model, Unprotect(RouterProtected), UseJev, Unprotect(JevProtected));
    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        var temp = FilePath + ".new"; File.WriteAllText(temp, JsonSerializer.Serialize(this, Contract.Json)); File.Move(temp, FilePath, true);
    }
}
