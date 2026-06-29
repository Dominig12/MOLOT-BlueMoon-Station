# Chaos Dimension (Хаос-пространство) — Plan

## Overview

Реализация альтернативного измерения — хаотичного пространственного континуума, откуда порождаются аномалии и странные существа. Путешественники перемещаются между процедурно генерируемыми комнатами, подвергаясь искажению (distortion), которое влияет на HP, sanity и скорость. Цель — выжить, исследовать, найти артефакты, углубиться в хаос или найти выход.

## Design Decisions

### 1. Архитектура систем
- **Сабсистема `SSchaosdimension`** — управляющая подсистема (SUBSYSTEM_DEF), инициализируется после mapping (`INIT_ORDER_CHAOS_DIMENSION = 48`, между mapping=50 и timetrack=47)
- **Зеркальные комнаты** — отдельный z-level (`ZTRAIT_CHAOS_DIMENSION`) для размещения комнат
- **Персональные instances** — каждый путешественник имеет свой `datum/chaos_dimension_instance` со списком посещённых комнат и статусом

### 2. Комнаты
- **60+ шаблонов комнат** (`_maps/chaosdimension/`), каждая уникальна по layout, биому, атмосфере
- Процедурная генерация при входе каждого путешественника через `map_template` систему (как HilbertsHotel)
- Комнаты не имеют стен, но имеют невидимые границы (fog-зоны по краям)
- При достижении границы — телепорт через противоположную сторону в новую комнату
- В комнатах генерируются: сундуки, алтари, источники регенерации, ловушки, артефакты трансформации

### 3. Сущности
- **Духи (эфемерные)** — `/datum/chaos_entity/ethereal/ghost`, `/datum/chaos_entity/ethereal/shadow`, `/datum/chaos_entity/ethereal/wisp`
  - Влияют на sanity через `COMSIG_MODIFY_SANITY`
  - Вызывают hallucinations
  - Могут давать баффы/дебаффы через mood events
- **Материальные монстры** — `/datum/chaos_entity/material/beast`, `/datum/chaos_entity/material/aberration`
  - HP, физический урон, атаки
  - Разные типы: ближний бой, дальнобойный, AoE
  - Боссы каждые 10-15 комнат

### 4. Система искажения (Distortion)
- Персональный `datum/chaos_distortion` для каждого путешественника
- Счётчик distortion: 0–100, растёт со временем и событиями
- Влияние:
  - 0–25: лёгкие hallucinations, замедление регенерации
  - 25–50: заметные hallucinations, дебафф к speed/actionspeed
  - 50–75: сильные hallucinations, sanity drain, movement speed debuff
  - 75–90: критические hallucinations, sanity rapid drain, skill modifier malus
  - 90–100: maximum distortion, transformation в аномалию
- Восстановление через предметы/объекты в комнатах

### 5. Вход и выход
- **Вход**: `/obj/machinery/chaos_gate` — устройство на станции для входа в хаос
- **Выход**: `/obj/item/chaos_compass` — предмет для возврата на станцию
- **Трансформация**: при distortion ≥ 100 — mob становится `/datum/chaos_entity/transformed` (аномальная сущность)
- **Buffs**: сущности хаоса могут призываться как минор-антаг или спавниться в комнатах

### 6. Предметы и интерактивные объекты
- **Регенерация**: /obj/item/chaos_regen_potion, /obj/structure/chaos_altar
- **Усиление искажения**: /obj/item/chaos_artifact (повышает distortion, даёт уникальные баффы)
- **Компас**: /obj/item/chaos_compass (выход из хаоса)
- **Артефакты трансформации**: /obj/item/chaos_core (при использовании — mob становится сущностью)
- **Ловушки**: /obj/effect/chaos_trap (урон, sanity drain, distortion increase)

## File Structure

```
code/
  __DEFINES/
    chaos_dimension.dm          # defines: CHAOS_DISTANTION_*, CHAOS_ROOM_TRAITS_*
  controllers/
    subsystem/
      chaos_dimension.dm        # SSchaosdimension — управляющая сабсистема
  datums/
    chaos_dimension/
      chaos_dimension.dm        # базовые типы
      chaos_distortion.dm       # datum/chaos_distortion — персональное искажение
      chaos_instance.dm         # datum/chaos_instance — instance путешественника
      chaos_room.dm             # datum/chaos_room — описание комнаты
    chaos_entity/
      chaos_entity.dm           # базовый класс сущности
      ethereal/ethereal.dm      # эфемерные сущности
      material/material.dm      # материальные сущности
  game/
    machinery/
      chaos_gate.dm             # /obj/machinery/chaos_gate — устройство входа
    items/
      chaos_compass.dm          # /obj/item/chaos_compass — устройство выхода
      chaos_artifacts.dm        # артефакты трансформации
    structures/
      chaos_altar.dm            # /obj/structure/chaos_altar — регенерация
    effects/
      chaos_traps.dm            # /obj/effect/chaos_trap — ловушки
      chaos_fog.dm              # /obj/effect/chaos_fog — визуальная граница
  modules/
    chaos_dimension/
      chaos_loot.dm             # таблицы лута для комнат
      chaos_room_templates.dm   # регистрация шаблонов комнат
      chaos_whisper_events.dm   # случайные события в комнатах

_maps/
  chaosdimension/
    room_01.dmm                 # шаблоны комнат (60+)
    room_02.dmm
    ...
    room_60.dmm
    boss_room_01.dmm            # босс-комнаты
    boss_room_02.dmm
```

## Implementation Tasks

### Phase 1: Core Architecture
1. **`code/__DEFINES/chaos_dimension.dm`** — определить константы и дефайны
2. **`code/controllers/subsystem/chaos_dimension.dm`** — SSchaosdimension сабсистема
3. **`code/datums/chaos_dimension/chaos_distortion.dm`** — система персонального искажения
4. **`code/datums/chaos_dimension/chaos_instance.dm`** — instance путешественника

### Phase 2: Room System
5. **`code/modules/chaos_dimension/chaos_room_templates.dm`** — система шаблонов комнат
6. **`code/datums/chaos_dimension/chaos_room.dm`** — класс описания комнаты
7. **Procedural room generation** — генерация комнат при входе путешественника
8. **Fog boundaries** — визуальные/незримые границы комнат

### Phase 3: Room Templates
9. **60+ room templates** в `_maps/chaosdimension/` — создавать по категориям:
   - 15 холодных/мрачных комнат
   - 15 тёплых/туманных комнат
   - 15 пустых/разрушенных комнат
   - 15 босс-комнат / особых комнат
10. **Map config** — регистрация шаблонов в системе маппинга

### Phase 4: Entities
11. **Эфемерные сущности** — ethereal ghosts, shadows, wisps
12. **Материальные сущности** — beasts, aberrations, bosses
13. **Спавн-система** — controlled спавн сущностей в комнатах

### Phase 5: Items & Interactives
14. **Chaos Gate** — устройство входа на станцию
15. **Chaos Compass** — устройство выхода
16. **Artifacts** — предметы усиления искажения и трансформации
17. **Altars & Regeneration** — структуры для восстановления
18. **Traps** — ловушки в комнатах

### Phase 6: Integration
19. **Loot tables** — интеграция с системой лута
20. **Event system** — случайные события в комнатах
21. **Transformation** — mob → chaos entity
22. **Admin tools** — команды для входа/выхода/телепорта
23. **UI/HUD** — отображение distortion на HUD

## Affected Boundaries
- **Зависит от**: map_template system, teleport system, mood/sanity system, hallucination system, subsystem framework
- **Интегрируется с**: cargo (через chaos gate), events (chaos dimension events), antag (chaos entities as minor antags), research (chaos entities as researchable)

## Data Flow
1. Путник активирует chaos gate → создается `datum/chaos_instance` для него
2. Instance создаёт первую комнату через `map_template` → путник телепортируется
3. Каждый процесс-цикл instance обновляет distortion → применяет эффекты
4. Путник движется по комнате → при достижении границы → телепорт в новую комнату
5. В комнатах спавнятся сущности и предметы → путник взаимодействует с ними
6. При distortion ≥ 100 → моб трансформируется в chaos entity
7. Путник использует chaos compass → телепорт обратно на станцию

## Failure Modes
- **Комната не генерируется** — fallback на random room from pool
- **Нет свободной комнаты** — instance получает последнюю посещённую
- **Сущность не спавнится** — room process skip spawn для этого цикла
- **Teleport fails** — mob возвращается на стартовую позицию комнаты

## Validation
- Комнаты загружаются корректно через map_template
- Teleport между комнатами работает без races
- Distortion meter обновляется и влияет на mob
- Сущности спавнятся и удаляются корректно
- Трансформация mob → entity работает
- Chaos compass возвращает на станцию