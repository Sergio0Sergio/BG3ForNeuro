using System.Text.Json.Nodes;
using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.Neuro;

namespace BG3Neuro.Core.State;

public sealed class DecisionLoop : IDisposable
{
    private static readonly string[] CombatActionNames =
    {
        "move_to_target", "attack_entity", "cast_spell", "use_item", "throw",
        "bonus_action", "set_reaction", "end_turn",
    };

    private static readonly string[] ExplorationActionNames =
    {
        "move_to_entity", "interact_with", "loot",
        "open_map", "open_inventory", "toggle_mode", "rest", "travel_to",
    };

    private readonly NeuroWebSocketClient _neuro;
    private readonly IpcClient _ipc;
    private readonly ActionRouter _router;
    private readonly ExplorationStateConfig _exploration;
    private CombatState? _combatState;
    private string? _lastForcedContent;
    private bool _connected;

    public DecisionLoop(NeuroWebSocketClient neuro, IpcClient ipc, ActionRouter router, ExplorationStateConfig? exploration = null)
    {
        _neuro = neuro;
        _ipc = ipc;
        _router = router;
        _exploration = exploration ?? new ExplorationStateConfig();
    }

    public event EventHandler<string>? DebugNote;

    public void Start()
    {
        _neuro.ActionRequested += OnActionRequested;
        _neuro.ConnectionStateChanged += OnConnectionStateChanged;
        _ipc.StateChanged += OnStateChanged;
        _ipc.HeartbeatChanged += OnHeartbeatChanged;
        RefreshState();
    }

    public void Stop()
    {
        _neuro.ActionRequested -= OnActionRequested;
        _neuro.ConnectionStateChanged -= OnConnectionStateChanged;
        _ipc.StateChanged -= OnStateChanged;
        _ipc.HeartbeatChanged -= OnHeartbeatChanged;
    }

    private void OnHeartbeatChanged(object? sender, HeartbeatChangedEventArgs e)
    {
        if (e.Previous != ModStatus.Stale || e.Current != ModStatus.Alive)
        {
            return;
        }

        // R2/R7: мод/игра вернулись после простоя — мёртвый IPC-стенд (неисполненные
        // command/action/result) вычищаем, чтобы перезапущенный Lua-мод не исполнил
        // действие погибшего процесса, и заново форсим актуальное state.
        _ipc.CleanStand();
        _lastForcedContent = null;
        RefreshState();
    }

    private void OnConnectionStateChanged(object? sender, ConnectionStateChangedEventArgs e)
    {
        _connected = e.Connected;
        if (e.Connected && _combatState is not null)
        {
            _lastForcedContent = null;
            _ = MaybeForceAsync(_combatState);
        }
    }

    private void OnStateChanged(object? sender, string content)
    {
        _combatState = StateSerializer.Parse(content);
        if (_combatState is null)
        {
            DebugNote?.Invoke(this, "state: не удалось распарсить боевой state");
            return;
        }

        _ = MaybeForceAsync(_combatState);
    }

    private async Task MaybeForceAsync(CombatState state)
    {
        if (!_connected)
        {
            return;
        }

        if (state.Mode == "dialogue" && state.Dialogue is not null)
        {
            var dialogueMarkdown = StateSerializer.ToMarkdown(state);
            if (_lastForcedContent == dialogueMarkdown)
            {
                return;
            }

            _lastForcedContent = dialogueMarkdown;
            await _neuro.SendForceAsync(dialogueMarkdown, "Идёт диалог. Выбери вариант ответа — укажи option_index.", new[] { "select_dialogue_option" });
            DebugNote?.Invoke(this, "force: диалог");
            return;
        }

        if (state.Mode is "exploration" or "map" or "inventory")
        {
            var explorationMarkdown = StateSerializer.ToMarkdown(state, _exploration);
            if (_lastForcedContent == explorationMarkdown)
            {
                return;
            }

            _lastForcedContent = explorationMarkdown;
            var explorationQuery = state.Mode switch
            {
                "map" => "Карта открыта. Выбери локацию для travel_to или закрой карту.",
                "inventory" => "Инвентарь открыт. Выбери действие.",
                _ => "Исследуй местность: перемещение, взаимодействие, лут, отдых или путешествие.",
            };
            await _neuro.SendForceAsync(explorationMarkdown, explorationQuery, ForceActions(state.AvailableActions, state.Mode));
            DebugNote?.Invoke(this, $"force: {state.Mode}");
            return;
        }

        if (string.IsNullOrEmpty(state.TurnActor))
        {
            return;
        }

        var isControlledTurn = state.Allies.Any(a => a.Alias == state.TurnActor);
        if (!isControlledTurn)
        {
            _lastForcedContent = null;
            return;
        }

        var markdown = StateSerializer.ToMarkdown(state);
        if (_lastForcedContent == markdown)
        {
            return;
        }

        _lastForcedContent = markdown;
        var controlledName = state.Allies.First(a => a.Alias == state.TurnActor).Name;
        var query = $"Сейчас твой ход ({controlledName}). Выбери действие.";
        await _neuro.SendForceAsync(markdown, query, CombatActionNames);
        DebugNote?.Invoke(this, $"force: ход {controlledName}");
    }

    private static string[] ForceActions(List<string> available, string mode)
    {
        var names = available
            .Select(a => a.Split(':', 2)[0].Trim())
            .Where(n => n.Length > 0)
            .ToArray();
        if (names.Length > 0)
        {
            return names;
        }

        return mode switch
        {
            "map" => new[] { "travel_to", "open_map", "toggle_mode" },
            "inventory" => new[] { "use_item", "open_inventory", "toggle_mode" },
            _ => ExplorationActionNames,
        };
    }

    public void RefreshState()
    {
        if (_ipc.LastStateContent is null)
        {
            _ipc.ReadState();
        }

        var content = _ipc.LastStateContent;
        if (content is null)
        {
            _combatState = null;
            return;
        }

        _combatState = StateSerializer.Parse(content);
        if (_combatState is null)
        {
            DebugNote?.Invoke(this, "state: не удалось распарсить боевой state");
            return;
        }

        _ = MaybeForceAsync(_combatState);
    }

    private void OnActionRequested(object? sender, ActionRequestedEventArgs e)
    {
        var json = e.Data ?? "{}";
        _ = DispatchAsync(e.Id, e.Name, json);
    }

    private async Task DispatchAsync(string id, string name, string dataJson)
    {
        var result = _router.ValidateAndDispatch(id, name, dataJson, _combatState, _ipc.Status);
        var message = ErrorMapper.ToMessage(result.ErrorCode, result.ErrorDetail);
        await _neuro.SendResultAsync(id, result.Success, result.Success ? null : message);
    }

    public void Dispose()
    {
        Stop();
    }
}
