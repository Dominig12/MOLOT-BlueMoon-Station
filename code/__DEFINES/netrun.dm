// Уровни доступа к узлу сети
#define NETRUN_ACCESS_NONE 0
#define NETRUN_ACCESS_GUEST 1
#define NETRUN_ACCESS_USER 2
#define NETRUN_ACCESS_ROOT 3

// Типы узлов
#define NETRUN_NODE_GATEWAY "gateway"
#define NETRUN_NODE_AIRLOCK "airlock"
#define NETRUN_NODE_APC "apc"
#define NETRUN_NODE_CAMERA "camera"
#define NETRUN_NODE_OPTIC "optic"
#define NETRUN_NODE_TURRET "turret"
#define NETRUN_NODE_VENDOR "vendor"
#define NETRUN_NODE_ATMOS "atmos"
#define NETRUN_NODE_TERMINAL "terminal"
#define NETRUN_NODE_SERVER "server"
#define NETRUN_NODE_CIRCUIT "circuit"
#define NETRUN_NODE_INTERCOM "intercom"
#define NETRUN_NODE_IMPLANT "implant"
#define NETRUN_NODE_BORG "borg"
#define NETRUN_NODE_AI "ai"
#define NETRUN_NODE_NEURAL "neural"
#define NETRUN_NODE_PAI "pai"
#define NETRUN_NODE_DECK "deck"
#define NETRUN_NODE_MODSUIT "modsuit"

// Точки подключения консоли
#define NETRUN_ORIGIN_TERMINAL "terminal"
#define NETRUN_ORIGIN_DECK "deck"
#define NETRUN_ORIGIN_IMPLANT "implant"
#define NETRUN_ORIGIN_NTOS "ntos"
#define NETRUN_ORIGIN_ENTITY "entity"
#define NETRUN_ORIGIN_CIRCUIT "circuit"
#define NETRUN_ORIGIN_PAI "pai"
#define NETRUN_ORIGIN_AI "ai"

/// Shared by scheduler implementations and unit tests included before module sources.
#define NETRUN_TASK_CRITICAL 1
#define NETRUN_TASK_NORMAL 2
#define NETRUN_TASK_BACKGROUND 3

/// Execution defaults. Times are deciseconds unless the name ends in _MS.
/// Slow maintenance cadence; admitted work and explicit input wake the bounded worker.
#define NETRUN_DEFAULT_FIRE_INTERVAL 20
#define NETRUN_DEFAULT_TASK_BUDGET_MS 6.0
#define NETRUN_DEFAULT_TASK_MIN_BUDGET_MS 1.0
#define NETRUN_DEFAULT_TASK_PRESSURE_TICK_USAGE 100
#define NETRUN_DEFAULT_TASK_MIN_PER_PASS 2
#define NETRUN_DEFAULT_TASK_MAX_PER_PASS 192
#define NETRUN_DEFAULT_INTERACTIVE_BURST 8
#define NETRUN_DEFAULT_INTERACTIVE_PRIORITY NETRUN_TASK_CRITICAL
#define NETRUN_DEFAULT_INTERACTIVE_FLUSH TRUE
#define NETRUN_INPUT_ACK_MAX_LENGTH 64
#define NETRUN_ICE_MIN_TELEGRAPH (2 SECONDS)
#define NETRUN_DEFAULT_TASK_COST_FLOOR_MS 0.05
#define NETRUN_DEFAULT_TASK_INITIAL_COST_MS 0.1
#define NETRUN_DEFAULT_TASK_COST_SMOOTHING 0.15
#define NETRUN_DEFAULT_TASK_POPULATION_INTERVAL (1 SECONDS)
#define NETRUN_DEFAULT_APC_PREBUILD_OPERATIONS 96
/// Fast registration attempts before slow backoff while a compatible controller is online.
/// Controller/device signals (power, move, config) restart the fast retry window.
#define NETRUN_ATMOS_REGISTRATION_MAX_ATTEMPTS 10
#define NETRUN_DEFAULT_ROUTE_REFRESH_INTERVAL (1 SECONDS)
#define NETRUN_DEFAULT_ROUTE_EXPIRY_INTERVAL (30 SECONDS)
#define NETRUN_DEFAULT_UI_REFRESH_INTERVAL (1 SECONDS)
#define NETRUN_DEFAULT_UI_ACTIVITY_LEASE (3 SECONDS)
#define NETRUN_DEFAULT_NODE_ACTIVITY_DURATION (5 SECONDS)
#define NETRUN_DEFAULT_NODE_POLL_INTERVAL (1 SECONDS)
#define NETRUN_DEFAULT_NODE_IDLE_POLL_INTERVAL (30 SECONDS)
#define NETRUN_DEFAULT_NODE_UPDATE_INTERVAL (10 SECONDS)
#define NETRUN_NODE_INTEREST_LEASE (3 SECONDS)
#define NETRUN_NODE_INTEREST_RADIUS 7
#define NETRUN_DEFAULT_TASK_CRITICAL_LATE_AFTER (2 SECONDS)
#define NETRUN_DEFAULT_TASK_NORMAL_LATE_AFTER (5 SECONDS)
#define NETRUN_DEFAULT_TASK_BACKGROUND_LATE_AFTER (20 SECONDS)
#define NETRUN_DEFAULT_TASK_PRIORITY_ROTATION list(NETRUN_TASK_CRITICAL, NETRUN_TASK_NORMAL, NETRUN_TASK_CRITICAL, NETRUN_TASK_BACKGROUND, NETRUN_TASK_CRITICAL, NETRUN_TASK_NORMAL, NETRUN_TASK_CRITICAL)
/// Hard validation bounds prevent malformed live configuration from disabling all progress.
#define NETRUN_EXECUTION_MIN_BUDGET_MS 0.01
#define NETRUN_EXECUTION_MAX_BUDGET_MS 50
#define NETRUN_EXECUTION_MAX_PRESSURE_TICK_USAGE 1000
#define NETRUN_EXECUTION_MAX_TASKS_PER_PASS 1024
#define NETRUN_EXECUTION_MAX_PREBUILD_OPERATIONS 4096
#define NETRUN_EXECUTION_MAX_PRIORITY_ROTATION 64
#define NETRUN_EXECUTION_MIN_INTERVAL 1
#define NETRUN_EXECUTION_MAX_INTERVAL (10 MINUTES)

// Сети
#define NETRUN_GLOBAL_ID "ntnet"
#define NETRUN_LAN_PUBLIC "pub"
#define NETRUN_LAN_ENGINEERING "eng"
#define NETRUN_LAN_MEDICAL "med"
#define NETRUN_LAN_SCIENCE "sci"
#define NETRUN_LAN_CARGO "cargo"
#define NETRUN_LAN_SECURITY "sec"
#define NETRUN_LAN_COMMAND "cmd"

/// Geographic physical links: each started block of tiles adds one decisecond.
#define NETRUN_LINK_TILES_PER_DS 15
#define NETRUN_RELAY_LATENCY 3
/// Machine I/O uses network time; runner actions retain their gameplay latency.
#define NETRUN_MACHINE_LATENCY_SCALE 0.02
#define NETRUN_MACHINE_MAX_LATENCY (0.25 SECONDS)
#define NETRUN_MAX_PACKET_LOG 100
#define NETRUN_MAX_PENDING_REQUESTS 2048
#define NETRUN_MAX_MACHINE_PACKETS 2048
#define NETRUN_APC_NEIGHBORS 3

// Типы файлов
#define NETRUN_FILE_TEXT "text"
#define NETRUN_FILE_KEY "key"
#define NETRUN_FILE_ACCESS "access"
#define NETRUN_FILE_DAEMON "daemon"
#define NETRUN_FILE_SEED "seed"
#define NETRUN_FILE_TECHWEB "techweb"
#define NETRUN_FILE_TECHWEB_LINK "techweb_link"
#define NETRUN_FILE_PHOTO "photo"
/// Активная боевая программа ("карточка"): её запускают против цели в узле
#define NETRUN_FILE_PROGRAM "program"

// Боевые роли программ
#define NETRUN_PROGRAM_ATTACK "attack"
#define NETRUN_PROGRAM_SHIELD "shield"
#define NETRUN_PROGRAM_STUN "stun"
#define NETRUN_PROGRAM_REPAIR "repair"
#define NETRUN_PROGRAM_PURGE "purge"
#define NETRUN_PROGRAM_TRACE "trace"
/// Bounded recoverable files left by defeated processes, separate from machine storage.
#define NETRUN_MAX_SALVAGE_FILES 4

// Враждебные процессы (ICE)
#define NETRUN_ICE_SENTRY "sentry"
#define NETRUN_ICE_HUNTER "hunter"
/// Сколько персистентных патрульных процессов поднимается в начале раунда
#define NETRUN_MAX_PATROLS 400
/// Сколько лорных документов раскладывается по серверам станции в начале раунда
#define NETRUN_MAX_LORE_FILES 300

/// События расширений: источник сигнала — сущность или её консоль.
#define COMSIG_NETRUN_ENTITY_NODE_CHANGED "netrun_entity_node_changed"
#define COMSIG_NETRUN_ENTITY_TICK "netrun_entity_tick"
#define COMSIG_NETRUN_ENTITY_INTEGRITY "netrun_entity_integrity"
#define COMSIG_NETRUN_CONSOLE_EVENT "netrun_console_event"
/// Нелегальный сетевой доступ к кибернетическому узлу носителя: (datum/netrun_console, datum/component/netrun_node)
#define COMSIG_NETRUN_IMPLANT_INTRUSION "netrun_implant_intrusion"

/// SSnetrun lifecycle events; callbacks only invalidate caches or enqueue tasks.
#define COMSIG_NETRUN_NODE_REGISTERED "netrun_node_registered"
#define COMSIG_NETRUN_NODE_UNREGISTERED "netrun_node_unregistered"
#define COMSIG_NETRUN_NODE_MOVED "netrun_node_moved"
#define COMSIG_NETRUN_TOPOLOGY_DIRTY "netrun_topology_dirty"
#define COMSIG_NETRUN_EVENT_POSTED "netrun_event_posted"
/// Device atom: a provider's externally visible native state changed (no arguments).
#define COMSIG_NETRUN_SERVICE_STATE_CHANGED "netrun_service_state_changed"
#define COMSIG_NETRUN_RESEARCH_CHANGED "netrun_research_changed"

/// Domain notifications. Handlers invalidate caches; they must not serialize UI.
/// Node: live gameplay change (node, changed_flags). SSnetrun: native binding/availability.
#define COMSIG_NETRUN_NODE_CHANGED "netrun_node_changed"
/// SSnetrun: one coalesced observational publication (address => changed_flags).
#define COMSIG_NETRUN_NODES_CHANGED "netrun_nodes_changed"
/// SSnetrun: (revision), after a complete structural graph commit.
#define COMSIG_NETRUN_TOPOLOGY_CHANGED "netrun_topology_changed"
/// SSnetrun: (node), before affected sessions revoke grants.
#define COMSIG_NETRUN_FIREWALL_CHANGED "netrun_firewall_changed"
/// File store / inventory: no payload; the source owns its current contents.
#define COMSIG_NETRUN_STORAGE_CHANGED "netrun_storage_changed"
#define COMSIG_NETRUN_INVENTORY_CHANGED "netrun_inventory_changed"
/// ICE and console: combat state changed.
#define COMSIG_NETRUN_COMBAT_CHANGED "netrun_combat_changed"
/// Shared UI state outside the physical map: (network), and a new channel message.
#define COMSIG_NETRUN_NETWORK_CHANGED "netrun_network_changed"
#define COMSIG_NETRUN_CHAT_CHANGED "netrun_chat_changed"
/// SSnetrun: (ice, victim), emitted only after an attack is actually queued.
#define COMSIG_NETRUN_ICE_CAST_STARTED "netrun_ice_cast_started"
/// ICE: (old_node, new_node).
#define COMSIG_NETRUN_ICE_NODE_CHANGED "netrun_ice_node_changed"
#define NETRUN_CHANGED_STATE (1<<0)
#define NETRUN_CHANGED_BINDING (1<<1)
#define NETRUN_CHANGED_OCCUPANTS (1<<2)
#define NETRUN_CHANGED_REMOVED (1<<3)
/// Journals and file contents change selected-device panels, never map markers or routing.
#define NETRUN_CHANGED_DETAILS (1<<4)

#define NETRUN_TRACE_MAX 100
/// Сколько трассировки спадает за секунду простоя
#define NETRUN_TRACE_DECAY 0.5
/// Блокировка точки подключения после полной трассировки
#define NETRUN_TRACE_LOCKOUT (1 MINUTES)
/// Окно «след потерян» после заметания следов: лёд не атакует и не перезахватывает цель
#define NETRUN_DISENGAGE_GRACE (8 SECONDS)

#define NETRUN_MAX_LOG 60
#define NETRUN_MAX_CONSOLE_LOG 40

/// Коды матрицы взлома
#define NETRUN_BREACH_CODES list("1C", "55", "BD", "E9", "7A", "FF")
