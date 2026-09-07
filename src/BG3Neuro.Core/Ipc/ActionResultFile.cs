using System.Text.Json;

namespace BG3Neuro.Core.Ipc;

public sealed class ActionExecutionResult
{
    public bool Success { get; init; }
    public bool? Running { get; init; }

    [System.Text.Json.Serialization.JsonPropertyName("error_code")]
    public string? ErrorCode { get; init; }

    [System.Text.Json.Serialization.JsonPropertyName("error_detail")]
    public string? ErrorDetail { get; init; }
}

public static class ActionResultFile
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public static ActionExecutionResult? TryRead(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var content = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(content))
            {
                return null;
            }

            return JsonSerializer.Deserialize<ActionExecutionResult>(content, Options);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }
}