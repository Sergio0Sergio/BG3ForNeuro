namespace BG3Neuro.Core.State;

/// <summary>Единый словарь error_code (§6.5): код + actionable-сообщение + канал доставки.</summary>
public static class ErrorMapper
{
    /// <summary>Канал доставки кода ошибки (§6.5, review D).</summary>
    public enum Channel
    {
        /// <summary>Через <c>action/result</c> сразу после валидации (до игры).</summary>
        A,

        /// <summary>Только через следующий state + context (провал исполнения), никогда поздним action/result.</summary>
        B,
    }

    /// <summary>Коды, которые физически доходят до Neuro через <c>action/result</c> (валидация до игры).</summary>
    private static readonly ErrorCode[] ChannelACodes =
    {
        ErrorCode.TargetMissing,
        ErrorCode.NotInCombat,
        ErrorCode.NoSpell,
        ErrorCode.NoCamp,
        ErrorCode.NotSupported,
        ErrorCode.TargetNotInRange,
        ErrorCode.InvalidParameters,
        ErrorCode.WrongPhase,
        ErrorCode.NotYourCharacter,
        ErrorCode.DialogueClosed,
        ErrorCode.ModUnavailable,
    };

    /// <summary>Коды, которые доходят только через следующий state + context (провалы исполнения).</summary>
    private static readonly ErrorCode[] ChannelBCodes =
    {
        ErrorCode.ActionFailed,
    };

    /// <summary>Все коды словаря §6.5 (для проверки полноты).</summary>
    public static IReadOnlyList<ErrorCode> AllCodes { get; } = Enum.GetValues<ErrorCode>()
        .Where(c => c != ErrorCode.None)
        .ToArray();

    /// <summary>Для кода: Канал A или B. Тайминг mod_unavailable здесь — «на момент валидации» (§6.5).</summary>
    public static Channel ToChannel(ErrorCode code) =>
        ChannelBCodes.Contains(code) ? Channel.B : Channel.A;

    /// <summary>Может ли код вообще быть результатом валидации (Канал A). Провалы исполнения — нет.</summary>
    public static bool IsValidationResult(ErrorCode code) => ToChannel(code) == Channel.A;

    public static string ToMessage(ErrorCode code, string? detail) =>
        string.IsNullOrWhiteSpace(detail) ? DefaultMessage(code) : detail.Trim();

    /// <summary>Actionable-сообщение по умолчанию: что не так + как исправить.</summary>
    public static string DefaultMessage(ErrorCode code) => code switch
    {
        ErrorCode.TargetMissing =>
            "Target not found in the perceived state. You can only act on entities the mod currently reports (party, objects, combatants) - they are exactly what you can see. The target may be out of view, behind terrain, or gone; re-check the state instead of guessing.",
        ErrorCode.NotInCombat =>
            "This action requires combat, but no combat is running. Wait for combat to start (combat state will appear with a controlled character's turn).",
        ErrorCode.NoSpell =>
            "Spell unavailable: not in the spellbook, on cooldown, or no resources left. Pick a spell from the Spells section of the state.",
        ErrorCode.NoCamp =>
            "Cannot rest: no camp or valid rest point nearby. Move to a rest point and try again.",
        ErrorCode.NotSupported =>
            "Action not supported in v1. Pick one of the actions from the Available Actions section of the state.",
        ErrorCode.TargetNotInRange =>
            "Target out of range. Choose a target listed in the state as reachable (within range/coverage).",
        ErrorCode.InvalidParameters =>
            "Invalid action parameters. Check the required fields and allowed values in the action schema.",
        ErrorCode.WrongPhase =>
            "It is not your turn yet. Wait for a controlled character's turn (the message will say whose turn it is).",
        ErrorCode.NotYourCharacter =>
            "That character belongs to another agent. You are playing your own character only - pick an actor from your own (owned) character.",
        ErrorCode.DialogueClosed =>
            "No active dialogue: the dialogue window closed. Start the dialogue again and repeat your choice.",
        ErrorCode.ModUnavailable =>
            "Mod unavailable (heartbeat is stale). Wait for the mod to recover and repeat the action.",
        ErrorCode.ActionFailed =>
            "Action failed while executing in the game. Details are in error_detail; the world state is in the next state.",
        _ => "Unknown error.",
    };
}