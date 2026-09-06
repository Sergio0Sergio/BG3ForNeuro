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
            "Цель не найдена. Укажи target_id одного из персонажей из раздела «Враги»/«Контролируемые персонажи» state.",
        ErrorCode.NotInCombat =>
            "Действие требует боя, но бой не идёт. Дождись начала боя (появится боевой state с ходом контролируемого).",
        ErrorCode.NoSpell =>
            "Заклинание недоступно: его нет в SpellBook, на кулдауне или нет ресурсов. Выбери заклинание из раздела «Заклинания» state.",
        ErrorCode.NoCamp =>
            "Нельзя отдохнуть: нет лагеря или валидной точки отдыха. Подойди к точке отдыха и повтори.",
        ErrorCode.NotSupported =>
            "Действие не поддерживается в v1. Выбери одно из действий из списка «Доступные действия» state.",
        ErrorCode.TargetNotInRange =>
            "Цель вне радиуса действия. Выбери цель, перечисленную в state как достижимая (в радиусе/покрытии).",
        ErrorCode.InvalidParameters =>
            "Некорректные параметры действия. Проверь обязательные поля и допустимые значения согласно схеме действия.",
        ErrorCode.WrongPhase =>
            "Сейчас не твой ход. Дождись хода контролируемого персонажа (сообщение укажет, чей ход).",
        ErrorCode.DialogueClosed =>
            "Нет активного диалога: окно диалога закрылось. Начни диалог снова и повтори выбор варианта.",
        ErrorCode.ModUnavailable =>
            "Мод недоступен (heartbeat устарел). Подожди восстановления мода и повтори действие.",
        ErrorCode.ActionFailed =>
            "Действие провалилось при исполнении в игре. Что именно — в error_detail; картина мира — в следующем state.",
        _ => "Неизвестная ошибка.",
    };
}