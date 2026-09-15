using BG3Neuro.Core.Config;
using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.State;

public class StateSerializerTests
{
    private static readonly string SampleJson = """
    {
      "mode": "combat",
      "turn_actor": "karlach",
      "turn_initiative_index": 3,
      "turn_initiative_total": 5,
      "allies": [
        { "alias": "karlach", "name": "Karlach", "hp": 45, "max_hp": 60, "distance": 6, "effects": "Rage (3 раунда)", "position_x": 0, "position_y": 0 }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 6, "status": null, "position_x": 3, "position_y": 4 }
      ],
      "spells": [
        { "spell_name": "Fireball", "slot": "3", "range": 18, "aoe": 4, "targets_in_range": ["goblin_1"] }
      ],
      "available_actions": ["move_to_target", "attack_entity: [goblin_1]", "end_turn"]
    }
    """;

    [Fact]
    public void Parse_ValidCombatJson_ReturnsState()
    {
        var state = StateSerializer.Parse(SampleJson);

        Assert.NotNull(state);
        Assert.Equal("karlach", state!.TurnActor);
        Assert.Equal(3, state.TurnInitiativeIndex);
        Assert.Equal(5, state.TurnInitiativeTotal);
        Assert.Single(state.Allies);
        Assert.Equal("Karlach", state.Allies[0].Name);
        Assert.Equal(45, state.Allies[0].Hp);
        Assert.Single(state.Enemies);
        Assert.Equal("goblin_1", state.Enemies[0].Alias);
        Assert.Single(state.Spells);
        Assert.Equal("Fireball", state.Spells[0].SpellName);
    }

    [Fact]
    public void Parse_InvalidJson_ReturnsNull()
    {
        Assert.Null(StateSerializer.Parse("{ not json"));
    }

    [Fact]
    public void Parse_EmptyJson_ReturnsNull()
    {
        Assert.Null(StateSerializer.Parse(""));
        Assert.Null(StateSerializer.Parse("   "));
    }

    [Fact]
    public void ToMarkdown_ContainsTurnControlledEnemiesSpellsActions()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Turn: Karlach (initiative 3/5)", md);
        Assert.Contains("## Allied characters", md);
        Assert.Contains("Karlach: HP 45/60, distance 6m, effects: Rage (3 раунда)", md);
        Assert.Contains("## Enemies", md);
        Assert.Contains("goblin_1 (Goblin Raider): HP 12/18, distance 6m, status: —", md);
        Assert.Contains("## Spells (Karlach)", md);
        Assert.Contains("Fireball: slot 3, range 18m, AoE 4m → in range: covers: [goblin_1] (1 targets)", md);
        Assert.Contains("## Available actions (Karlach)", md);
        Assert.Contains("- end_turn", md);
    }

    [Fact]
    public void ToMarkdown_NoSpells_OmitsSpellsSection()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Spells.Clear();
        var md = StateSerializer.ToMarkdown(state);

        Assert.DoesNotContain("## Spells", md);
    }

    [Fact]
    public void ToMarkdown_NoAvailableActions_ListsEndTurnOnly()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.AvailableActions.Clear();
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("- end_turn", md);
    }

    [Fact]
    public void ToMarkdown_TurnActorNotInAllies_UsesAliasAsName()
    {
        var json = SampleJson.Replace("\"name\": \"Karlach\"", "\"name\": \"Karlach Ninefinger\"");
        var state = StateSerializer.Parse(json)!;
        state.Allies[0].Name = "Karlach";
        state.TurnActor = "shadowheart";
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Turn: shadowheart", md);
    }

    [Fact]
    public void Parse_WithEvents_ParsesEvents()
    {
        var json = SampleJson.Replace("\"available_actions\": [\"move_to_target\", \"attack_entity: [goblin_1]\", \"end_turn\"]",
            "\"available_actions\": [\"move_to_target\", \"attack_entity: [goblin_1]\", \"end_turn\"],\n      \"events\": [\"атака цели goblin_1 нанесла 7 урона\", \"Karlach сместилась к goblin_1\"]");

        var state = StateSerializer.Parse(json);

        Assert.NotNull(state);
        Assert.Equal(2, state!.Events.Count);
        Assert.Contains("атака цели goblin_1 нанесла 7 урона", state.Events);
        Assert.Contains("Karlach сместилась к goblin_1", state.Events);
    }

    [Fact]
    public void ToMarkdown_WithEvents_RendersEventsSection()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Events.Add("атака цели goblin_1 нанесла 7 урона");
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Events", md);
        Assert.Contains("- атака цели goblin_1 нанесла 7 урона", md);
    }

    [Fact]
    public void ToMarkdown_NoEvents_OmitsEventsSection()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.DoesNotContain("## Events", md);
    }

    [Fact]
    public void ToMarkdown_DistanceUsesDotDecimalSeparator()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Enemies[0].Distance = 6.5;
        state.Allies[0].Distance = 3.25;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("distance 6.5m", md);
        Assert.Contains("distance 3.25m", md);
    }

    [Fact]
    public void ToMarkdown_SpellChargesAndCooldown_AreRendered()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Spells[0].CastsLeft = 2;
        state.Spells[0].OnCooldown = true;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("charges left: 2", md);
        Assert.Contains("on cooldown", md);
    }

    [Fact]
    public void ToMarkdown_AoeSpell_ShowsCoverageCount()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        var karlach = state.Allies[0];
        karlach.PositionX = 0;
        karlach.PositionY = 0;
        state.Enemies[0].PositionX = 3;
        state.Enemies[0].PositionY = 4; // 5м, в AoE-радиусе 4м и range 18м

        // делаем Fireball AoE-заклинанием
        state.Spells[0].Aoe = 4;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("covers: [goblin_1] (1 targets)", md);
    }

    [Fact]
    public void ToMarkdown_SpellNoTargetsInRange_ShowsNoTargets()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        var karlach = state.Allies[0];
        karlach.PositionX = 0;
        karlach.PositionY = 0;
        state.Enemies[0].PositionX = 100;
        state.Enemies[0].PositionY = 100;

        state.Spells[0].Aoe = 0;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("→ in range: (no targets in range)", md);
    }

    [Fact]
    public void ToMarkdown_DialogueMode_RendersOptionsInUiOrder()
    {
        var state = StateSerializer.Parse("""
            {
              "mode": "dialogue",
              "available_actions": ["select_dialogue_option"],
              "dialogue": {
                "speaker_name": "Withers",
                "line": "Ты принял свою смерть?",
                "options": [
                  { "option_index": 1, "text": "Да, я готов." },
                  { "option_index": 2, "text": "Расскажи мне ещё." }
                ]
              }
            }
            """)!;

        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Dialogue", md);
        Assert.Contains("Speaker: Withers", md);
        Assert.Contains("Line: Ты принял свою смерть?", md);
        Assert.Contains("- [1] Да, я готов.", md);
        Assert.Contains("- [2] Расскажи мне ещё.", md);
        Assert.DoesNotContain("## Allied characters", md);
        Assert.DoesNotContain("## Turn:", md);
    }

    private static readonly string ExplorationJson = """
    {
      "mode": "exploration",
      "can_rest": true,
      "objects": [
        { "alias": "wooden_door", "name": "Деревянная дверь", "distance": 3, "status": "закрыта", "interactions": ["открыть", "заламать", "толкнуть"] },
        { "alias": "goblin_camp_sign", "name": "Знак лагеря гоблинов", "distance": 120, "region": "Роща", "seen_by": "shadowheart" },
        { "alias": "goblin_corpse", "name": "Труп гоблина", "distance": 5, "lootable": true }
      ],
      "regions": [
        { "name": "Роща", "region_id": "grove_east", "distance": 3 },
        { "name": "Разрушенное селение", "region_id": "villages", "distance": 200, "region": "Разрушенное селение" }
      ],
      "inventory": [
        { "alias": "potion_healing", "name": "Малый эликсир лечения", "quantity": 2, "category": "Зелье" }
      ],
      "available_actions": ["move_to_entity: [wooden_door]", "interact_with: [wooden_door]", "loot: [goblin_corpse]", "rest: [full, partial]", "travel_to: [Роща]"]
    }
    """;

    private static readonly string ExtractorCombatJson = """
    {
      "version": 2,
      "mode": "combat",
      "generated_at": "2026-09-07T12:00:00.0000000Z",
      "trigger": "TurnStarted",
      "turn_actor": "tav",
      "turn_initiative_index": 1,
      "turn_initiative_total": 4,
      "allies": [
        { "alias": "tav", "name": "Tav", "hp": 43, "max_hp": 60, "distance": 0, "position_x": 2.3, "position_y": 1.8, "effects": "acting now, can act" },
        { "alias": "shadowheart", "name": "Shadowheart", "hp": 51, "max_hp": 51, "distance": 4.5, "position_x": 6.1, "position_y": -1.2, "effects": "can act" }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 7.2, "position_x": 8.4, "position_y": 6.5, "status": null },
        { "alias": "goblin_2", "name": "Goblin Warrior", "hp": 0, "max_hp": 15, "distance": 9.1, "position_x": 10.2, "position_y": 3.3, "status": "defeated" }
      ],
      "available_actions": ["end_turn", "attack_entity: [goblin_1, goblin_2]", "move_to_target: [tav, shadowheart, goblin_1, goblin_2]"]
    }
    """;

    [Fact]
    public void Parse_ExtractorCombatJson_ParsesRealisticState()
    {
        var state = StateSerializer.Parse(ExtractorCombatJson);

        Assert.NotNull(state);
        Assert.Equal("combat", state!.Mode);
        Assert.Equal("tav", state.TurnActor);
        Assert.Equal(1, state.TurnInitiativeIndex);
        Assert.Equal(4, state.TurnInitiativeTotal);
        Assert.Equal(2, state.Allies.Count);
        Assert.Equal("acting now, can act", state.Allies[0].Effects);
        Assert.Equal(2.3, state.Allies[0].PositionX);
        Assert.Equal(-1.2, state.Allies[1].PositionY);
        Assert.Equal(2, state.Enemies.Count);
        Assert.Null(state.Enemies[0].Status);
        Assert.Equal("defeated", state.Enemies[1].Status);
        Assert.Equal(3, state.AvailableActions.Count);
        Assert.Contains("attack_entity: [goblin_1, goblin_2]", state.AvailableActions);
    }

    [Fact]
    public void Parse_ExtractorCombatJson_ToMarkdownRendersStatusesAndActions()
    {
        var state = StateSerializer.Parse(ExtractorCombatJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Turn: Tav (initiative 1/4)", md);
        Assert.Contains("- Tav: HP 43/60, distance 0m, effects: acting now, can act", md);
        Assert.Contains("- Shadowheart: HP 51/51, distance 4.5m, effects: can act", md);
        Assert.Contains("- goblin_1 (Goblin Raider): HP 12/18, distance 7.2m, status: —", md);
        Assert.Contains("- goblin_2 (Goblin Warrior): HP 0/15, distance 9.1m, status: defeated", md);
        Assert.Contains("- attack_entity: [goblin_1, goblin_2]", md);
        Assert.Contains("- move_to_target: [tav, shadowheart, goblin_1, goblin_2]", md);
        Assert.Contains("- end_turn", md);
    }

    [Fact]
    public void Parse_ExplorationJson_ParsesObjectsRegionsInventoryCanRest()
    {
        var state = StateSerializer.Parse(ExplorationJson);

        Assert.NotNull(state);
        Assert.Equal("exploration", state!.Mode);
        Assert.True(state.CanRest);
        Assert.Equal(3, state.Objects.Count);
        Assert.Equal("wooden_door", state.Objects[0].Alias);
        Assert.Equal("shadowheart", state.Objects[1].SeenBy);
        Assert.Equal("Роща", state.Objects[1].Region);
        Assert.True(state.Objects[2].Lootable);
        Assert.Equal(2, state.Regions.Count);
        Assert.Equal("villages", state.Regions[1].RegionId);
        Assert.Single(state.Inventory);
        Assert.Equal(2, state.Inventory[0].Quantity);
    }

    [Fact]
    public void ToMarkdown_ExplorationMode_RendersModeObjectsHybridDistanceRestActions()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Mode: exploration", md);
        Assert.Contains("## Objects (seen by player, 2)", md);
        Assert.Contains("## Objects (seen by shadowheart, 1)", md);
        Assert.Contains("- wooden_door (Деревянная дверь) 3m, закрыта: [открыть, заламать, толкнуть]", md);
        Assert.Contains("region: Роща", md);
        Assert.Contains("- goblin_corpse (Труп гоблина) 5m: [take]", md);
        Assert.Contains("## Locations (travel)", md);
        Assert.Contains("- Роща (id: grove_east): 3m", md);
        Assert.Contains("- rest: [full, partial]", md);
        Assert.Contains("- move_to_entity: [wooden_door]", md);
        Assert.DoesNotContain("## Turn:", md);
    }

    [Fact]
    public void ToMarkdown_MapMode_RendersScreenMapAndLocations()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Mode = "map";
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Screen: map", md);
        Assert.Contains("- Роща (id: grove_east): 3m", md);
        Assert.Contains("- Разрушенное селение (id: villages): region: Разрушенное селение", md);
        Assert.DoesNotContain("## Objects", md);
    }

    [Fact]
    public void ToMarkdown_InventoryMode_RendersScreenInventoryAndItems()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Mode = "inventory";
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Screen: inventory", md);
        Assert.Contains("## Items", md);
        Assert.Contains("- Малый эликсир лечения (potion_healing) ×2, Зелье", md);
    }

    [Fact]
    public void ToMarkdown_ExplorationCannotRest_RendersNoCamp()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.CanRest = false;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("- Unavailable: no camp or supplies (no_camp)", md);
    }

    [Fact]
    public void ToMarkdown_Exploration_MaxVisibleObjects_CapsAndShowsMore()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Objects.Add(new ExplorationObject { Alias = "barrel_1", Name = "Бочка", Distance = 6 });
        var md = StateSerializer.ToMarkdown(state, new ExplorationStateConfig { MaxVisibleObjects = 2 });

        Assert.Contains("- … and 1 more", md);
        Assert.Contains("(seen by player, 3)", md);
    }

    [Fact]
    public void ToMarkdown_Exploration_EmptyAvailableActions_UsesDefaults()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.AvailableActions.Clear();
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("- interact_with: [wooden_door]", md);
        Assert.Contains("- loot: [goblin_corpse]", md);
        Assert.Contains("- travel_to: [Роща, Разрушенное селение]", md);
        Assert.Contains("- rest: [full, partial]", md);
        Assert.Contains("open_map, open_inventory, toggle_mode: [normal]", md);
    }

    [Fact]
    public void Parse_LuaExtractorDialogueJson_EmptyOptionsFromServerContext_RendersSpeaker()
    {
        // v0.8.26: captureDialogueState (server-контекст) — варианты живут в клиентском UI,
        // поэтому options пустой; контракт с StateSerializer должен переживать пустой массив.
        var state = StateSerializer.Parse("""
            {
              "version": 2,
              "mode": "dialogue",
              "trigger": "dialog_started",
              "turn_actor": "",
              "allies": [],
              "enemies": [],
              "dialogue": { "speaker_name": "Goblin", "line": null, "options": [] },
              "available_actions": ["select_dialogue_option"],
              "events": ["Диалог открыт. Варианты ответа живут в клиентском UI (клик по option — TODO(client))."]
            }
            """)!;

        var md = StateSerializer.ToMarkdown(state);

        Assert.Equal("dialogue", state.Mode);
        Assert.NotNull(state.Dialogue);
        Assert.Equal("Goblin", state.Dialogue!.SpeakerName);
        Assert.Empty(state.Dialogue.Options);
        Assert.Contains("## Dialogue", md);
        Assert.Contains("Speaker: Goblin", md);
        Assert.Contains("- select_dialogue_option", md);
    }

    [Fact]
    public void Parse_LuaExtractorCombatJson_SpellsBlock_2DTargetsInRange()
    {
        // v0.8.26: buildCombatSpellsBlock — spell_name полным stat-именем, slot из UseCosts,
        // casts_left опущен (nil), on_cooldown всегда false; targets_in_range — 2D-дистанция.
        var state = StateSerializer.Parse("""
            {
              "version": 2,
              "mode": "combat",
              "trigger": "TurnStarted",
              "turn_actor": "tav",
              "allies": [],
              "enemies": [
                { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 7.2, "position_x": 8.4, "position_y": 6.5 }
              ],
              "spells": [
                { "spell_name": "Projectile_FireBolt", "slot": "0", "range": 18, "aoe": 0, "on_cooldown": false, "targets_in_range": ["goblin_1"] },
                { "spell_name": "Target_CureWounds", "slot": "1", "range": 1.5, "aoe": 0, "on_cooldown": false, "targets_in_range": [] }
              ],
              "available_actions": ["end_turn", "attack_entity: [goblin_1]", "move_to_target: [tav, goblin_1]"]
            }
            """)!;

        Assert.Equal(2, state.Spells.Count);
        Assert.Equal("Projectile_FireBolt", state.Spells[0].SpellName);
        Assert.Equal("0", state.Spells[0].Slot);
        Assert.Equal(18, state.Spells[0].Range);
        Assert.False(state.Spells[0].OnCooldown);
        Assert.Null(state.Spells[0].CastsLeft);
        Assert.Single(state.Spells[0].TargetsInRange);
        Assert.Equal("goblin_1", state.Spells[0].TargetsInRange[0]);
        Assert.Empty(state.Spells[1].TargetsInRange);
    }
}