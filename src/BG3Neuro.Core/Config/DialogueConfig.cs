namespace BG3Neuro.Core.Config;

public sealed class DialogueConfig
{
    /// <summary>Режим диалога: "autoselect" (подсветка + клик) или его алиас "confirm".</summary>
    public string Mode { get; set; } = "confirm";

    /// <summary>ClientAutoselectExecutor доступен: только "autoselect"/"confirm" включают клиентский скрипт (§7).</summary>
    public bool IsEnabled => Mode is "autoselect" or "confirm";
}