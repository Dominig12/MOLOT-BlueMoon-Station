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
#define NETRUN_NODE_TURRET "turret"
#define NETRUN_NODE_VENDOR "vendor"
#define NETRUN_NODE_TERMINAL "terminal"
#define NETRUN_NODE_SERVER "server"
#define NETRUN_NODE_CIRCUIT "circuit"
#define NETRUN_NODE_INTERCOM "intercom"
#define NETRUN_NODE_IMPLANT "implant"
#define NETRUN_NODE_BORG "borg"
#define NETRUN_NODE_AI "ai"

// Точки подключения консоли
#define NETRUN_ORIGIN_TERMINAL "terminal"
#define NETRUN_ORIGIN_DECK "deck"
#define NETRUN_ORIGIN_IMPLANT "implant"
#define NETRUN_ORIGIN_NTOS "ntos"
#define NETRUN_ORIGIN_ENTITY "entity"
#define NETRUN_ORIGIN_CIRCUIT "circuit"

// Сети
#define NETRUN_GLOBAL_ID "ntnet"
#define NETRUN_LAN_PUBLIC "pub"
#define NETRUN_LAN_ENGINEERING "eng"
#define NETRUN_LAN_MEDICAL "med"
#define NETRUN_LAN_SCIENCE "sci"
#define NETRUN_LAN_CARGO "cargo"
#define NETRUN_LAN_SECURITY "sec"
#define NETRUN_LAN_COMMAND "cmd"

// Типы файлов
#define NETRUN_FILE_TEXT "text"
#define NETRUN_FILE_KEY "key"
#define NETRUN_FILE_DAEMON "daemon"
#define NETRUN_FILE_SEED "seed"
#define NETRUN_FILE_TECHWEB "techweb"

#define NETRUN_TRACE_MAX 100
/// Сколько трассировки спадает за секунду простоя
#define NETRUN_TRACE_DECAY 0.5
/// Блокировка точки подключения после полной трассировки
#define NETRUN_TRACE_LOCKOUT (1 MINUTES)

#define NETRUN_MAX_LOG 60
#define NETRUN_MAX_CONSOLE_LOG 40

/// Коды матрицы взлома
#define NETRUN_BREACH_CODES list("1C", "55", "BD", "E9", "7A", "FF")
