using System.Text.Json;
using System.Text.Json.Nodes;

namespace BG3Neuro.Core.Config;

public static class ConfigLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    public static readonly string DefaultConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Larian Studios",
        "Baldur's Gate 3",
        "Script Extender",
        "BG3Neuro");

    public static AppConfig Load(string path)
    {
        var defaults = AppConfigDefaults.Create();
        if (!File.Exists(path))
        {
            return defaults;
        }

        try
        {
            using var stream = File.OpenRead(path);
            var loaded = JsonSerializer.Deserialize<JsonNode>(stream, JsonOptions);
            NormalizeKeys(loaded);
            var defaultsNode = JsonSerializer.SerializeToNode(defaults, JsonOptions);
            MergeInto(defaultsNode, loaded);
            return defaultsNode.Deserialize<AppConfig>(JsonOptions) ?? defaults;
        }
        catch (JsonException ex)
        {
            throw new ConfigException($"Некорректный config.json: {ex.Message}", ex);
        }
        catch (IOException ex)
        {
            throw new ConfigException($"Не удалось прочитать config.json: {ex.Message}", ex);
        }
    }

    public static void MergeInto(JsonNode? target, JsonNode? overrides)
    {
        if (target is not JsonObject targetObj || overrides is not JsonObject overridesObj)
        {
            return;
        }

        foreach (var (key, value) in overridesObj)
        {
            if (value is null)
            {
                continue;
            }

            if (targetObj[key] is JsonObject nestedTarget && value is JsonObject nestedOverrides)
            {
                MergeInto(nestedTarget, nestedOverrides);
            }
            else
            {
                targetObj[key] = value.DeepClone();
            }
        }
    }

    private static void NormalizeKeys(JsonNode? node)
    {
        if (node is not JsonObject obj)
        {
            return;
        }

        var entries = obj.ToList();
        obj.Clear();
        foreach (var (key, value) in entries)
        {
            obj[ToSnakeCase(key)] = value;
            NormalizeKeys(value);
        }
    }

    public static string ToSnakeCase(string input)
    {
        var sb = new System.Text.StringBuilder(input.Length + 4);
        for (var i = 0; i < input.Length; i++)
        {
            var c = input[i];
            if (char.IsUpper(c) && sb.Length > 0 && !char.IsUpper(input[i - 1]))
            {
                sb.Append('_');
            }

            sb.Append(char.ToLowerInvariant(c));
        }

        return sb.ToString();
    }
}

public static class AppConfigDefaults
{
    public static AppConfig Create() => new();
}

public sealed class ConfigException : Exception
{
    public ConfigException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}