namespace BG3Neuro.Core.Config;

/// <summary>Автопилот: форсинг действий при отсутствии реального Neuro.
/// Отключение (enabled=false) оставляет только явные HTTP/Neuro-инжекты.</summary>
public sealed class AutopilotConfig
{
    public bool Enabled { get; set; } = true;
}