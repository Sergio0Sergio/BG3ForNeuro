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

        Assert.Contains("## Ход: Karlach (инициатива 3/5)", md);
        Assert.Contains("## Контролируемые персонажи", md);
        Assert.Contains("Karlach: HP 45/60, distance 6м, эффекты: Rage (3 раунда)", md);
        Assert.Contains("## Враги", md);
        Assert.Contains("goblin_1 (Goblin Raider): HP 12/18, distance 6м, статус: —", md);
        Assert.Contains("## Заклинания (Karlach)", md);
        Assert.Contains("Fireball: слот 3, радиус 18м, AoE 4м → в радиусе: покрывает: [goblin_1] (1 целей)", md);
        Assert.Contains("## Доступные действия (Karlach)", md);
        Assert.Contains("- end_turn", md);
    }

    [Fact]
    public void ToMarkdown_NoSpells_OmitsSpellsSection()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Spells.Clear();
        var md = StateSerializer.ToMarkdown(state);

        Assert.DoesNotContain("## Заклинания", md);
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

        Assert.Contains("## Ход: shadowheart", md);
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

        Assert.Contains("## События", md);
        Assert.Contains("- атака цели goblin_1 нанесла 7 урона", md);
    }

    [Fact]
    public void ToMarkdown_NoEvents_OmitsEventsSection()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.DoesNotContain("## События", md);
    }

    [Fact]
    public void ToMarkdown_DistanceUsesDotDecimalSeparator()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Enemies[0].Distance = 6.5;
        state.Allies[0].Distance = 3.25;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("distance 6.5м", md);
        Assert.Contains("distance 3.25м", md);
    }

    [Fact]
    public void ToMarkdown_SpellChargesAndCooldown_AreRendered()
    {
        var state = StateSerializer.Parse(SampleJson)!;
        state.Spells[0].CastsLeft = 2;
        state.Spells[0].OnCooldown = true;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("зарядов осталось: 2", md);
        Assert.Contains("на кулдауне", md);
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

        Assert.Contains("покрывает: [goblin_1] (1 целей)", md);
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

        Assert.Contains("→ в радиусе: (нет целей в радиусе)", md);
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

        Assert.Contains("## Диалог", md);
        Assert.Contains("Собеседник: Withers", md);
        Assert.Contains("Реплика: Ты принял свою смерть?", md);
        Assert.Contains("- [1] Да, я готов.", md);
        Assert.Contains("- [2] Расскажи мне ещё.", md);
        Assert.DoesNotContain("## Контролируемые персонажи", md);
        Assert.DoesNotContain("## Ход:", md);
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
        { "alias": "tav", "name": "Tav", "hp": 43, "max_hp": 60, "distance": 0, "position_x": 2.3, "position_y": 1.8, "effects": "ходит сейчас, может действовать" },
        { "alias": "shadowheart", "name": "Shadowheart", "hp": 51, "max_hp": 51, "distance": 4.5, "position_x": 6.1, "position_y": -1.2, "effects": "может действовать" }
      ],
      "enemies": [
        { "alias": "goblin_1", "name": "Goblin Raider", "hp": 12, "max_hp": 18, "distance": 7.2, "position_x": 8.4, "position_y": 6.5, "status": null },
        { "alias": "goblin_2", "name": "Goblin Warrior", "hp": 0, "max_hp": 15, "distance": 9.1, "position_x": 10.2, "position_y": 3.3, "status": "повержен" }
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
        Assert.Equal("ходит сейчас, может действовать", state.Allies[0].Effects);
        Assert.Equal(2.3, state.Allies[0].PositionX);
        Assert.Equal(-1.2, state.Allies[1].PositionY);
        Assert.Equal(2, state.Enemies.Count);
        Assert.Null(state.Enemies[0].Status);
        Assert.Equal("повержен", state.Enemies[1].Status);
        Assert.Equal(3, state.AvailableActions.Count);
        Assert.Contains("attack_entity: [goblin_1, goblin_2]", state.AvailableActions);
    }

    [Fact]
    public void Parse_ExtractorCombatJson_ToMarkdownRendersStatusesAndActions()
    {
        var state = StateSerializer.Parse(ExtractorCombatJson)!;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Ход: Tav (инициатива 1/4)", md);
        Assert.Contains("- Tav: HP 43/60, distance 0м, эффекты: ходит сейчас, может действовать", md);
        Assert.Contains("- Shadowheart: HP 51/51, distance 4.5м, эффекты: может действовать", md);
        Assert.Contains("- goblin_1 (Goblin Raider): HP 12/18, distance 7.2м, статус: —", md);
        Assert.Contains("- goblin_2 (Goblin Warrior): HP 0/15, distance 9.1м, статус: повержен", md);
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

        Assert.Contains("## Режим: обычный", md);
        Assert.Contains("## Объекты (видит игрок, 2)", md);
        Assert.Contains("## Объекты (видит shadowheart, 1)", md);
        Assert.Contains("- wooden_door (Деревянная дверь) 3м, закрыта: [открыть, заламать, толкнуть]", md);
        Assert.Contains("область: Роща", md);
        Assert.Contains("- goblin_corpse (Труп гоблина) 5м: [забрать]", md);
        Assert.Contains("## Локации (путешествие)", md);
        Assert.Contains("- Роща (id: grove_east): 3м", md);
        Assert.Contains("- rest: [full (полный отдых), partial (лёгкий отдых)]", md);
        Assert.Contains("- move_to_entity: [wooden_door]", md);
        Assert.DoesNotContain("## Ход:", md);
    }

    [Fact]
    public void ToMarkdown_MapMode_RendersScreenMapAndLocations()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Mode = "map";
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Экран: карта", md);
        Assert.Contains("- Роща (id: grove_east): 3м", md);
        Assert.Contains("- Разрушенное селение (id: villages): область: Разрушенное селение", md);
        Assert.DoesNotContain("## Объекты", md);
    }

    [Fact]
    public void ToMarkdown_InventoryMode_RendersScreenInventoryAndItems()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Mode = "inventory";
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("## Экран: инвентарь", md);
        Assert.Contains("## Предметы", md);
        Assert.Contains("- Малый эликсир лечения (potion_healing) ×2, Зелье", md);
    }

    [Fact]
    public void ToMarkdown_ExplorationCannotRest_RendersNoCamp()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.CanRest = false;
        var md = StateSerializer.ToMarkdown(state);

        Assert.Contains("- Недоступен: нет лагеря или припасов (no_camp)", md);
    }

    [Fact]
    public void ToMarkdown_Exploration_MaxVisibleObjects_CapsAndShowsMore()
    {
        var state = StateSerializer.Parse(ExplorationJson)!;
        state.Objects.Add(new ExplorationObject { Alias = "barrel_1", Name = "Бочка", Distance = 6 });
        var md = StateSerializer.ToMarkdown(state, new ExplorationStateConfig { MaxVisibleObjects = 2 });

        Assert.Contains("- … и ещё 1", md);
        Assert.Contains("(видит игрок, 3)", md);
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
}