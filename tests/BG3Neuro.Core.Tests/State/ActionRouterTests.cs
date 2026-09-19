using BG3Neuro.Core.Config;
using BG3Neuro.Core.Ipc;
using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.State;

public class ActionRouterTests : IDisposable
{
    private readonly string _tmpDir = Path.Combine(Path.GetTempPath(), "bg3neuro-router-" + Guid.NewGuid().ToString("N"));

    public ActionRouterTests()
    {
        Directory.CreateDirectory(_tmpDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tmpDir))
        {
            Directory.Delete(_tmpDir, recursive: true);
        }
    }

    private ActionRouter CreateRouter(int partySize = 1) => new(new IpcPaths(_tmpDir), partySize);

    private static CombatState CombatWithTurn(string turnActor, params string[] allies) => new()
    {
        Mode = "combat",
        TurnActor = turnActor,
        TurnInitiativeIndex = 1,
        TurnInitiativeTotal = 2,
        Allies = allies.Select(a => new Combatant { Alias = a, Name = a.ToUpperInvariant(), PositionX = 0, PositionY = 0 }).ToList(),
        Enemies = new List<Combatant>
        {
            new() { Alias = "goblin_1", Name = "Goblin Raider", Hp = 18, MaxHp = 18, Distance = 6, PositionX = 3, PositionY = 4 },
        },
        Spells = new List<SpellInfo>
        {
            new() { SpellName = "Fireball", Slot = "3", Range = 18, Aoe = 4, CastsLeft = 2 },
        },
    };

    [Fact]
    public void EndTurn_OnControlledTurn_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void EndTurn_NotInCombat_WrongPhase()
    {
        var router = CreateRouter();

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, null, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NotInCombat, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void EndTurn_GroupCoActorCanAct_Allowed()
    {
        // v0.8.56 (тикет 19): групповое окно — со-активный союзник играет.
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");
        state.Allies.First(a => a.Alias == "shadowheart").Availability = "can act";

        var result = router.ValidateAndDispatch("act-1", "end_turn", """{"actor":"shadowheart"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
    }

    [Fact]
    public void EndTurn_GroupCoActorCannotAct_Refused()
    {
        // Ловушка подстроки: "cannot act" содержит "can act" — только exact-match.
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");
        state.Allies.First(a => a.Alias == "shadowheart").Availability = "cannot act";

        var result = router.ValidateAndDispatch("act-1", "end_turn", """{"actor":"shadowheart"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
    }

    [Fact]
    public void EndTurn_NonTurnActorWithoutAvailability_Refused()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "end_turn", """{"actor":"shadowheart"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
    }

    [Fact]
    public void EndTurn_EnemyTurn_NotDispatched()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("goblin_1", "karlach");

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
        Assert.DoesNotContain("turn now, not", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void EndTurn_OtherControlledCharacterTurn_DispatchingForWrongActor_FailsWrongPhase()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("shadowheart", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "end_turn", """{"actor":"karlach"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
        Assert.Contains("It is 'shadowheart' turn now, not 'karlach'", result.ErrorDetail);
    }

    [Fact]
    public void UnknownAction_InvalidParameters()
    {
        var router = CreateRouter();

        var result = router.ValidateAndDispatch("act-1", "no_such_action", null, null, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("Unknown action", result.ErrorDetail);
    }

    [Fact]
    public void ModUnavailable_BlocksDispatch()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, state, ModStatus.Stale);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.ModUnavailable, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void InvalidJsonData_InvalidParameters()
    {
        var router = CreateRouter();

        var result = router.ValidateAndDispatch("act-1", "end_turn", "{ not json", CombatWithTurn("karlach", "karlach"), ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
    }

    [Fact]
    public void Throw_NotSupported_EvenWhenValidPhase()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "throw", """{"item_id":"potion","target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NotSupported, result.ErrorCode);
    }

    [Fact]
    public void MultiParty_ActorRequired()
    {
        var router = CreateRouter(partySize: 2);
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("actor", result.ErrorDetail);
    }

    [Fact]
    public void MultiParty_ActorGiven_OnThatActorsTurn_Succeeds()
    {
        var router = CreateRouter(partySize: 2);
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "end_turn", """{"actor":"karlach"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void MoveToTarget_KnownTarget_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "move_to_target", """{"target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void MoveToTarget_UnknownTarget_TargetMissing()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "move_to_target", """{"target_id":"bandit_9"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetMissing, result.ErrorCode);
        Assert.Contains("bandit_9", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void MoveToTarget_MissingTargetId_InvalidParameters()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "move_to_target", "{}", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("target_id", result.ErrorDetail);
    }

    [Fact]
    public void AttackEntity_EnemyTarget_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "attack_entity", """{"target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void AttackEntity_AllyTarget_TargetMissing()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");

        var result = router.ValidateAndDispatch("act-1", "attack_entity", """{"target_id":"shadowheart"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetMissing, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void CastSpell_KnownSpellInRange_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball","target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void CastSpell_UnknownSpell_NoSpell_ListsKnown()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Wish"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NoSpell, result.ErrorCode);
        Assert.Contains("Fireball", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void CastSpell_ByFriendlyAbilityName_RewritesToEngineSpellName()
    {
        // v0.8.35 (тикет 09): Neuro зовёт способность по name ("flourish"), мод исполняет
        // по движковому stat-id (Target_OpeningAttack) — роутер подменяет spell_name.
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Target_OpeningAttack", Name = "flourish", Cost = "bonus_action", Range = 60 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"flourish","target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(node["data"]!.GetValue<string>())!;
        Assert.Equal("Target_OpeningAttack", dataNode["spell_name"]!.GetValue<string>());
    }

    [Fact]
    public void CastSpell_ByEngineSpellName_StillSucceeds()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Target_OpeningAttack", Name = "flourish", Cost = "bonus_action", Range = 60 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Target_OpeningAttack","target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
    }

    [Fact]
    public void CastSpell_AllyTarget_Succeeds_ForFriendlyBuffs()
    {
        // v0.8.56 (тикеты 16/18): friendly buffs target allies — the router must
        // accept combatant targets on both sides (honesty lives in the mod).
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach", "shadowheart");
        state.Spells.Add(new SpellInfo { SpellName = "Target_Guidance", Name = "guidance", Cost = "action", Range = 18 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"guidance","target_id":"shadowheart"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
    }

    [Fact]
    public void CastSpell_UnknownFriendlyName_ListsKnownFriendlyNames()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Target_OpeningAttack", Name = "flourish", Cost = "bonus_action", Range = 60 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"parry"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NoSpell, result.ErrorCode);
        Assert.Contains("flourish", result.ErrorDetail);
    }

    [Fact]
    public void CastSpell_AoeWithoutTarget_InjectsBestCenterPosition()
    {
        // v0.8.56 (тикет 19): AoE без цели/coverage/позиции — роутер инжектит
        // position из BestAoECenter (гоблин в (3,4) накрывается).
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Zone_Thunderwave", Name = "thunderwave", Cost = "action", Range = 18, Aoe = 4 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"thunderwave"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(node["data"]!.GetValue<string>())!;
        Assert.Equal(3.0, dataNode["position"]!["x"]!.GetValue<double>());
        Assert.Equal(4.0, dataNode["position"]!["y"]!.GetValue<double>());
    }

    [Fact]
    public void CastSpell_AoeNobodyInRange_HonestRefusal()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Zone_Thunderwave", Name = "thunderwave", Cost = "action", Range = 18, Aoe = 4 });
        state.Enemies[0].PositionX = 100;
        state.Enemies[0].PositionY = 100;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"thunderwave"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetNotInRange, result.ErrorCode);
    }

    [Fact]
    public void CastSpell_NonAoeWithoutTarget_NoPositionInjected()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Projectile_FireBolt", Name = "fire_bolt", Cost = "action", Range = 18, Aoe = 0 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"fire_bolt"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(node["data"]!.GetValue<string>())!;
        Assert.Null(dataNode["position"]);
    }

    [Fact]
    public void CastSpell_ExplicitPosition_Preserved()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells.Add(new SpellInfo { SpellName = "Zone_Thunderwave", Name = "thunderwave", Cost = "action", Range = 18, Aoe = 4 });

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"thunderwave","position":{"x":1,"y":2}}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(node["data"]!.GetValue<string>())!;
        Assert.Equal(1.0, dataNode["position"]!["x"]!.GetValue<double>());
        Assert.Equal(2.0, dataNode["position"]!["y"]!.GetValue<double>());
    }

    [Fact]
    public void CastSpell_OnCooldown_NoSpell()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells[0].OnCooldown = true;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NoSpell, result.ErrorCode);
        Assert.Contains("is on cooldown", result.ErrorDetail);
    }

    [Fact]
    public void CastSpell_NoCharges_NoSpell()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells[0].CastsLeft = 0;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NoSpell, result.ErrorCode);
        Assert.Contains("has no charges left", result.ErrorDetail);
    }

    [Fact]
    public void CastSpell_TargetOutOfRange_TargetNotInRange()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Spells[0].Range = 1;
        state.Spells[0].Aoe = 0;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball","target_id":"goblin_1"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetNotInRange, result.ErrorCode);
    }

    [Fact]
    public void CastSpell_AoeRequestedCoverageNotAchievable_TargetNotInRange()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Enemies.Add(new Combatant { Alias = "goblin_2", Name = "Goblin", Hp = 10, MaxHp = 10, PositionX = 100, PositionY = 100 });
        state.Spells[0].Aoe = 2;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball","coverage":["goblin_1","goblin_2"]}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetNotInRange, result.ErrorCode);
        Assert.Contains("goblin_2", result.ErrorDetail);
    }

    [Fact]
    public void CastSpell_AoeRequestedCoverageAchievable_Succeeds()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");
        state.Enemies.Add(new Combatant { Alias = "goblin_2", Name = "Goblin", Hp = 10, MaxHp = 10, PositionX = 4, PositionY = 4 });
        state.Spells[0].Aoe = 2;

        var result = router.ValidateAndDispatch("act-1", "cast_spell", """{"spell_name":"Fireball","coverage":["goblin_1","goblin_2"]}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    private static CombatState DialogueState() => new()
    {
        Mode = "dialogue",
        Dialogue = new Dialogue
        {
            SpeakerName = "Withers",
            Line = "Ты принял свою смерть?",
            Options = new List<DialogueOption>
            {
                new() { OptionIndex = 1, Text = "Да, я готов." },
                new() { OptionIndex = 2, Text = "Расскажи мне ещё." },
            },
        },
        AvailableActions = new List<string> { "select_dialogue_option" },
    };

    [Fact]
    public void SelectDialogueOption_ActiveDialogue_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = DialogueState();

        var result = router.ValidateAndDispatch("act-1", "select_dialogue_option", """{"option_index":1}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void SelectDialogueOption_WithOptionText_PreservesTextInActionFile()
    {
        // v0.8.27: option_text — подстраховка клиентского маппинга (Q2=б). Контракт:
        // значение пробрасывается сервером в action_*.json для client-Lua без изменений.
        var router = CreateRouter();
        var state = DialogueState();

        var result = router.ValidateAndDispatch("act-1", "select_dialogue_option",
            """{"option_index":1,"option_text":"Да, я готов."}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var data = node["data"]!.GetValue<string>();
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(data)!;
        Assert.Equal(1, dataNode["option_index"]!.GetValue<int>());
        Assert.Equal("Да, я готов.", dataNode["option_text"]!.GetValue<string>());
    }

    [Fact]
    public void SelectDialogueOption_NoActiveDialogue_DialogueClosed()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "select_dialogue_option", """{"option_index":1}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.DialogueClosed, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void SelectDialogueOption_IndexOutOfRange_InvalidParameters()
    {
        var router = CreateRouter();
        var state = DialogueState();

        var result = router.ValidateAndDispatch("act-1", "select_dialogue_option", """{"option_index":5}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("1..2", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void SelectDialogueOption_ClientScriptDisabled_NotSupported()
    {
        var router = CreateRouterWithDialogue(new DialogueConfig { Mode = "none" });
        var state = DialogueState();

        var result = router.ValidateAndDispatch("act-1", "select_dialogue_option", """{"option_index":1}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NotSupported, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    private ActionRouter CreateRouterWithDialogue(DialogueConfig dialogue) =>
        new(new IpcPaths(_tmpDir), 1, dialogue);

    private static CombatState ExplorationState() => new()
    {
        Mode = "exploration",
        Allies = new List<Combatant>
        {
            new() { Alias = "karlach", Name = "Karlach" },
        },
        Objects = new List<ExplorationObject>
        {
            new() { Alias = "wooden_door", Name = "Деревянная дверь", Distance = 3, Status = "закрыта", Interactions = new List<string> { "открыть", "заламать", "толкнуть" } },
            new() { Alias = "goblin_corpse", Name = "Труп гоблина", Distance = 5, Lootable = true },
            new() { Alias = "campfire", Name = "Костер", Distance = 2 },
        },
        Regions = new List<TravelLocation>
        {
            new() { Name = "Роща", RegionId = "grove_east", Distance = 3 },
            new() { Name = "Разрушенное селение", RegionId = "villages", Distance = 200 },
        },
        CanRest = true,
        AvailableActions = new List<string>
        {
            "move_to_entity: [wooden_door]", "interact_with: [wooden_door]", "loot: [goblin_corpse]",
            "rest: [full, partial]", "travel_to: [Роща]",
        },
    };

    [Fact]
    public void MoveToEntity_Exploration_KnownObject_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "move_to_entity", """{"target_id":"wooden_door"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void MoveToEntity_UnknownObject_TargetMissing_WithList()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "move_to_entity", """{"target_id":"ogre"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetMissing, result.ErrorCode);
        Assert.Contains("ogre", result.ErrorDetail);
        Assert.Contains("campfire", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void MoveToEntity_InCombat_WrongPhase()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "move_to_entity", """{"target_id":"wooden_door"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
        Assert.Contains("combat", result.ErrorDetail);
    }

    [Fact]
    public void InteractWith_ValidInteraction_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "interact_with", """{"target_id":"wooden_door","interaction_type":"открыть"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void InteractWith_InvalidInteraction_InvalidParameters_ListsAvailable()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "interact_with", """{"target_id":"wooden_door","interaction_type":"спрыгнуть"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("открыть", result.ErrorDetail);
        Assert.Contains("заламать", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void InteractWith_OmittedInteractionType_DefaultsToFirst_InjectsIntoFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "interact_with", """{"target_id":"wooden_door"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        var file = File.ReadAllText(Path.Combine(_tmpDir, "action_act-1.json"));
        var node = System.Text.Json.Nodes.JsonNode.Parse(file)!;
        var data = node["data"]!.GetValue<string>();
        var dataNode = System.Text.Json.Nodes.JsonNode.Parse(data)!;
        Assert.Equal("открыть", dataNode["interaction_type"]!.GetValue<string>());
    }

    [Fact]
    public void InteractWith_NoInteractions_InvalidParameters()
    {
        var router = CreateRouter();
        var state = ExplorationState();
        state.Objects.Remove(state.Objects.First(o => o.Alias == "wooden_door"));

        var result = router.ValidateAndDispatch("act-1", "interact_with", """{"target_id":"campfire","interaction_type":"подбросить дров"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
    }

    [Fact]
    public void Loot_LootableObject_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "loot", """{"target_id":"goblin_corpse"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void Loot_NonLootableObject_InvalidParameters()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "loot", """{"target_id":"wooden_door"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void Loot_UnknownObject_TargetMissing()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "loot", """{"target_id":"druegar_corpse"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.TargetMissing, result.ErrorCode);
    }

    [Fact]
    public void Rest_Full_CanRest_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "rest", """{"rest_type":"full"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void Rest_Partial_CanRest_Succeeds()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "rest", """{"rest_type":"partial"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
    }

    [Fact]
    public void Rest_NoCamp_NoCamp()
    {
        var router = CreateRouter();
        var state = ExplorationState();
        state.CanRest = false;

        var result = router.ValidateAndDispatch("act-1", "rest", """{"rest_type":"full"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NoCamp, result.ErrorCode);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void Rest_InvalidRestType_InvalidParameters()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "rest", """{"rest_type":"short"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
    }

    [Fact]
    public void TravelTo_ByName_Succeeds_AndWritesActionFile()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "travel_to", """{"destination":"Роща"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
        Assert.True(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void TravelTo_ByRegionId_Succeeds_EvenIfDestinationUnknown()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "travel_to", """{"destination":"x","region_id":"villages"}""", state, ModStatus.Alive);

        Assert.True(result.Success);
    }

    [Fact]
    public void TravelTo_UnknownDestination_InvalidParameters_ListsRegions()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "travel_to", """{"destination":"Подземелье"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("Подземелье", result.ErrorDetail);
        Assert.Contains("Роща (id: grove_east)", result.ErrorDetail);
        Assert.False(File.Exists(Path.Combine(_tmpDir, "action_act-1.json")));
    }

    [Fact]
    public void ToggleMode_Stealth_InvalidParameters()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "toggle_mode", """{"mode":"stealth"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("normal", result.ErrorDetail);
    }

    [Fact]
    public void OpenMap_InCombat_WrongPhase()
    {
        var router = CreateRouter();
        var state = CombatWithTurn("karlach", "karlach");

        var result = router.ValidateAndDispatch("act-1", "open_map", null, state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.WrongPhase, result.ErrorCode);
    }

    [Fact]
    public void ExplorationAction_NoState_InvalidParameters()
    {
        var router = CreateRouter();

        var result = router.ValidateAndDispatch("act-1", "open_map", null, null, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
    }

    [Fact]
    public void ExplorationAction_MultiParty_ActorRequired()
    {
        var router = CreateRouter(partySize: 2);
        var state = ExplorationState();
        state.Allies.Add(new Combatant { Alias = "shadowheart", Name = "Shadowheart" });

        var result = router.ValidateAndDispatch("act-1", "move_to_entity", """{"target_id":"campfire"}""", state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.InvalidParameters, result.ErrorCode);
        Assert.Contains("actor", result.ErrorDetail);
    }

    [Fact]
    public void EndTurn_ExplorationMode_NotInCombat()
    {
        var router = CreateRouter();
        var state = ExplorationState();

        var result = router.ValidateAndDispatch("act-1", "end_turn", null, state, ModStatus.Alive);

        Assert.False(result.Success);
        Assert.Equal(ErrorCode.NotInCombat, result.ErrorCode);
    }
}