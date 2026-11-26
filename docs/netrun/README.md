# NETRUN — документация

Эта папка — точка входа. Канонические документы NETRUN лежат в репозитории `netDM-core` (C#-слой); этот файл объясняет, что из них относится к DM-стороне, и фиксирует локальные факты.

## Где что лежит

| Документ | Где | О чём |
|---|---|---|
| Аудит обоих репозиториев | `netDM-core/docs/netrun/t0-audit.md` | карта решения, модель потоков, очереди, IPC, инвентарь DM-устройств, baseline |
| Матрица миграции | `netDM-core/docs/netrun/migration-matrix.md` | reuse / adapt / replace / remove / defer по каждому механизму |
| Целевая архитектура | `netDM-core/docs/netrun/architecture.md` | слои, владение состоянием, конвейер действия, ресурсы, права |
| Решения | `netDM-core/docs/netrun/adr/` | ADR-0001…0006 |
| План и gates | `netDM-core/docs/netrun/roadmap.md` | этапы N0…N9 |
| Состояние реализации | `netDM-core/docs/netrun/status.md` | что сделано, что проверено, что осталось |

## Что в этом репозитории важно знать

1. Здесь живёт **DM-адаптер** и физический мир. Игровое состояние, питание, повреждения, mind и персонаж принадлежат DM; сетевые факты — NETDM; цифровое состояние — NETRUN.
2. `code/modules/netdm/netdm_bridge.dm` — вендоренная копия `netDM-core/dm/netdm_bridge.dm`. При изменении протокола обновляются обе копии согласованно, версия моста и хоста проверяется вместе (§18.1).
3. `code/modules/netdm/netdm_services.dm` содержит локальные расширения относительно ядра (слабые ссылки реестра и обработка событий без зарегистрированного обработчика). Это единственное место расхождения, оно описано в аудите §4.2.
4. Живой мир **проверяется**: мост `netdm_byond.dll` собирается MinGW-тулчейном (`native/byond/build.ps1`), герметичный профиль компилируется и запускает набор из 24 тестов в `dd.exe`. Текущий результат — 23 из 24, единственное падение `door_station` (в герметичном мире нет кнопок blast-дверей). Docker на стенде не используется.

## Команды

```powershell
# C#: сборка и домен NETRUN
dotnet build src/NetDM.Host -c Release            # в netDM-core
dotnet run --project tests/NetRun.Tests -c Release   # 479 утверждений

# Живой Host через IPC (без BYOND)
pwsh -NoProfile -File tests/host-ipc.ps1         # ожидается NETDM_IPC_PASS

# DM: компиляция герметичного мира
pwsh -File scripts/Export-Source.ps1 -Destination <dir>
pwsh -File scripts/build-bluemoon-unit-dmb.ps1 -GameRepository <этот репозиторий> -BuildDirectory <dir>

# DM: живой мир (мост собран, 23 из 24)
pwsh -File scripts/test-bluemoon-unit.ps1 -BuildDirectory <dir> -BridgeDll <dll> -TestList scripts/bluemoon-netdm-tests.txt
```
