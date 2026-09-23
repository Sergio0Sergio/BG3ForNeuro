namespace BG3Neuro.Core.State;

public sealed class CombatState
{
    public string Mode { get; set; } = "combat";
    public string? GeneratedAt { get; set; }
    public string TurnActor { get; set; } = "";
    public int TurnInitiativeIndex { get; set; }
    public int TurnInitiativeTotal { get; set; }
    public List<Combatant> Allies { get; set; } = new();
    public List<Combatant> Enemies { get; set; } = new();
    public List<SpellInfo> Spells { get; set; } = new();
    public List<string> AvailableActions { get; set; } = new();
    public List<string> Events { get; set; } = new();
    public Dialogue? Dialogue { get; set; }
    public List<ExplorationObject> Objects { get; set; } = new();
    public List<TravelLocation> Regions { get; set; } = new();
    public List<InventoryItem> Inventory { get; set; } = new();
    public bool CanRest { get; set; }
    public string? Screen { get; set; }
}

public sealed class Dialogue
{
    public string? SpeakerName { get; set; }
    public string? Line { get; set; }
    public List<DialogueOption> Options { get; set; } = new();
}

public sealed class DialogueOption
{
    public int OptionIndex { get; set; }
    public string? Text { get; set; }
}

public sealed class ExplorationObject
{
    public required string Alias { get; set; }
    public required string Name { get; set; }
    public double Distance { get; set; }
    public double? PositionX { get; set; }
    public double? PositionY { get; set; }
    public double? PositionZ { get; set; }
    public string? Region { get; set; }
    public string? Type { get; set; }
    public string? Status { get; set; }
    public List<string> Interactions { get; set; } = new();
    public bool Lootable { get; set; }
}

public sealed class TravelLocation
{
    public required string Name { get; set; }
    public string? RegionId { get; set; }
    public double Distance { get; set; }
    public string? Region { get; set; }
}

public sealed class InventoryItem
{
    public required string Alias { get; set; }
    public required string Name { get; set; }
    public int Quantity { get; set; }
    public string? Category { get; set; }
}

public sealed class Combatant
{
    public required string Alias { get; set; }
    public required string Name { get; set; }
    public int Hp { get; set; }
    public int MaxHp { get; set; }
    public double Distance { get; set; }
    public double? PositionX { get; set; }
    public double? PositionY { get; set; }
    public double? PositionZ { get; set; }
    public string? Availability { get; set; }
    public string? Status { get; set; }
    public List<StatusCondition> Conditions { get; set; } = new();
}

public sealed class StatusCondition
{
    public required string Id { get; set; }
    public string? Name { get; set; }
    public int? TurnsLeft { get; set; }
    public double? DurationLeft { get; set; }
}

public sealed class SpellInfo
{
    public required string SpellName { get; set; }
    public string? Name { get; set; }
    public string? Cost { get; set; }
    public string? Slot { get; set; }
    public double Range { get; set; }
    public double Aoe { get; set; }
    public int? CastsLeft { get; set; }
    public bool OnCooldown { get; set; }
    public List<string> TargetsInRange { get; set; } = new();
}
