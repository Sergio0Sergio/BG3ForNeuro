namespace BG3Neuro.Core.Config;

public sealed class StateConfig
{
    public CombatStateConfig Combat { get; set; } = new();
    public DialogueStateConfig Dialogue { get; set; } = new();
    public ExplorationStateConfig Exploration { get; set; } = new();
}

public sealed class CombatStateConfig
{
    public bool ShowQuestMarker { get; set; } = false;
}

public sealed class DialogueStateConfig
{
}

public sealed class ExplorationStateConfig
{
    public bool ShowQuestMarker { get; set; } = true;
    public int MaxVisibleObjects { get; set; } = 20;
    public ObjectInfoConfig ObjectInfo { get; set; } = new();
    public string DistanceFormat { get; set; } = "hybrid";
    public bool ShowPosition { get; set; } = false;
}

public sealed class ObjectInfoConfig
{
    public bool Visible { get; set; } = true;
    public bool SkillRequirements { get; set; } = false;
}