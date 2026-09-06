# 05 — Dialogue Action Schemas

Type: grilling
Status: resolved
Blocked by: 01, 03
Depended by: 07

## Answer

Dialogue Action Schemas — финальные. (Доработано в диалоге.)

### Действие

**Одно действие — `select_dialogue_option`** (D1). Уходить/прерывать/пропускать — обычные варианты в state (BG3 предоставляет их в списке ответов). Никаких `skip_dialogue`/`end_dialogue`.

**Схема:**
```json
{
  "name": "select_dialogue_option",
  "description": "Выбрать один из предложенных вариантов ответа в диалоге.",
  "schema": {
    "type": "object",
    "required": ["option_index"],
    "properties": {
      "option_index": { "type": "integer", "minimum": 1 },
      "option_text":   { "type": "string" }
    }
  }
}
```

- `option_index` — **primary**: номер варианта, совпадающий с порядком в UI окна диалога BG3 (1-based, см. тикет 03 S4). Совпадает со стример-модом.
- `option_text` — fallback: если Neuro написала текст, но пропустила индекс, плагин сам матчит по тексту и подставляет индекс.

### Динамическая регистрация — PERSISTENT (D2)

`select_dialogue_option` регистрируется **один раз на старте** (вместе с боевыми и исследовательскими действиями). Никакой рега/дерега при открытии/закрытии диалога.

- Неактивный диалог → валидация возвращает failure: «Сейчас нет активного диалога.»
- Соответствует BEST_PRACTICES: "Register everything you can once at startup, and avoid rapidly registering and unregistering actions".
- Защита от гонок: диалог закрылся, Neuro с запозданием шлёт выбор → failure, а не отсутствующее действие.

### Контекст диалога (state, D5)

```markdown
## Диалог: Astarion (отношение: нейтральное)

Astarion: «Я не думаю, что нам стоит идти туда...»

## Варианты ответа
1. «Мы должны идти. Это важно.»
2. «Ты прав, отложим это.»
3. «У меня есть вопрос о Cazador.» [Persuasion]
4. [Уйти из диалога]
```

- Заголовок: с кем говорит + отношение (видимая игроку часть)
- Последняя реплика NPC
- Варианты с подсказками типов ([Persuasion] и т.д., из S4)
- Репутационные числа (математику) не показывать — только то, что игрок видит
- Номер варианта = порядок в UI окна

### Граничные случаи

**Forced dialogue (враг атакует во время диалога)** (D4):
- Диалог прерывается игрой автоматически
- DecisionLoop переключает state режима: combat > dialogue (внезапная атака)
- `select_dialogue_option` остаётся зарегистрированным (persistent), валидация вернёт failure, если нет активного диалога

### Out of scope

**Торговля (покупка/продажа)** (D3) — вне этого тикета и всей карты. «[Торговля]» в диалоге — обычный вариант; выбор открывает торговый экран — отдельный тип UI (вне scope). Отмечено в Out of scope карты.

### Формат регистрации

Как `Action` (SPECIFICATION.md): name, description (plain text), schema (JSON Schema object, type object). Требования enum/стабильности — из BEST_PRACTICES.md.
