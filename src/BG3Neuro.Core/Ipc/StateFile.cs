namespace BG3Neuro.Core.Ipc;

public static class StateFile
{
    public static string? TryReadContent(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var content = File.ReadAllText(path);
            return string.IsNullOrWhiteSpace(content) ? null : content;
        }
        catch (IOException)
        {
            return null;
        }
    }
}
