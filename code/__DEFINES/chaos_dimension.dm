// Chaos Dimension (Хаос-пространство) defines

// z-level for chaos dimension
#define ZTRAIT_CHAOS_DIMENSION TRAIT_CHAOS_DIMENSION

// Subsystem init order
#define INIT_ORDER_CHAOS_DIMENSION 48

// Distortion levels
#define CHAOS_DISTORTION_LEVEL_1 0
#define CHAOS_DISTORTION_LEVEL_2 25
#define CHAOS_DISTORTION_LEVEL_3 50
#define CHAOS_DISTORTION_LEVEL_4 75
#define CHAOS_DISTORTION_LEVEL_5 90
#define CHAOS_DISTORTION_MAX 100

// Distortion effects
#define CHAOS_DISTORTION_HALLUCINATION_LIGHT "chaos_hallucination_light"
#define CHAOS_DISTORTION_HALLUCINATION_MODERATE "chaos_hallucination_moderate"
#define CHAOS_DISTORTION_HALLUCINATION_STRONG "chaos_hallucination_strong"
#define CHAOS_DISTORTION_HALLUCINATION_CRITICAL "chaos_hallucination_critical"
#define CHAOS_DISTORTION_HALLUCINATION_MAXIMUM "chaos_hallucination_maximum"

// Room traits
#define CHAOS_ROOM_TRAIT_COLD "chaos_room_cold"
#define CHAOS_ROOM_TRAIT_WARM "chaos_room_warm"
#define CHAOS_ROOM_TRAIT_EMPTY "chaos_room_empty"
#define CHAOS_ROOM_TRAIT_BOSS "chaos_room_boss"
#define CHAOS_ROOM_TRAIT_FOG "chaos_room_fog"
#define CHAOS_ROOM_TRAIT_RUINED "chaos_room_ruined"

// Room categories count
#define CHAOS_ROOM_COUNT_COLD 15
#define CHAOS_ROOM_COUNT_WARM 15
#define CHAOS_ROOM_COUNT_EMPTY 15
#define CHAOS_ROOM_COUNT_BOSS 15
#define CHAOS_ROOM_TOTAL_MIN 60

// Boss spawn interval (rooms between bosses)
#define CHAOS_BOSS_INTERVAL_MIN 10
#define CHAOS_BOSS_INTERVAL_MAX 15

// Chaos dimension instance states
#define CHAOS_INSTANCE_STATE_ACTIVE 0
#define CHAOS_INSTANCE_STATE_TRANSFORMED 1
#define CHAOS_INSTANCE_STATE_EXITED 2

// Chaos entity types
#define CHAOS_ENTITY_TYPE_ETHEREAL 0
#define CHAOS_ENTITY_TYPE_MATERIAL 1
#define CHAOS_ENTITY_TYPE_TRANSFORMED 2

// Chaos entity subtypes
#define CHAOS_ENTITY_SUBTYPE_GHOST "ghost"
#define CHAOS_ENTITY_SUBTYPE_SHADOW "shadow"
#define CHAOS_ENTITY_SUBTYPE_WISP "wisp"
#define CHAOS_ENTITY_SUBTYPE_BEAST "beast"
#define CHAOS_ENTITY_SUBTYPE_ABERRATION "aberration"
#define CHAOS_ENTITY_SUBTYPE_BOSS "boss"

// Chaos damage types
#define CHAOS_DAMAGE_TYPE_MELEE 0
#define CHAOS_DAMAGE_TYPE_RANGED 1
#define CHAOS_DAMAGE_TYPE_AOE 2
#define CHAOS_DAMAGE_TYPE_SANITY 3
#define CHAOS_DAMAGE_TYPE_DISTORTION 4

// Chaos loot tables
#define CHAOS_LOOT_TABLE_REGEN "chaos_regen"
#define CHAOS_LOOT_TABLE_ARTIFACT "chaos_artifact"
#define CHAOS_LOOT_TABLE_CORE "chaos_core"
#define CHAOS_LOOT_TABLE_COMPASS "chaos_compass"
#define CHAOS_LOOT_TABLE_POTION "chaos_potion"

// Chaos signal names
#define CHAOS_SIG_MODIFY_SANITY "chaos_modify_sanity"
#define CHAOS_SIG_MODIFY_DISTORTION "chaos_modify_distortion"
#define CHAOS_SIG_HALLUCINATION "chaos_hallucination"
#define CHAOS_SIG_MODIFY_SPEED "chaos_modify_speed"
#define CHAOS_SIG_MODIFY_ACTIONSPEED "chaos_modify_actionspeed"
#define CHAOS_SIG_MODIFY_REGEN "chaos_modify_regen"
#define CHAOS_SIG_MODIFY_SKILL "chaos_modify_skill"

// Chaos room spawn rates
#define CHAOS_ROOM_SPAWN_ENTITY_INTERVAL 30
#define CHAOS_ROOM_SPAWN_LOOT_INTERVAL 60
#define CHAOS_ROOM_SPAWN_TRAP_INTERVAL 90
#define CHAOS_ROOM_SPAWN_WHISPER_INTERVAL 120

// Chaos whisper types
#define CHAOS_WHISPER_TYPE_Eerie 0
#define CHAOS_WHISPER_TYPE_Vision 1
#define CHAOS_WHISPER_TYPE_Voice 2
#define CHAOS_WHISPER_TYPE_Shadow 3

// Chaos artifact buff types
#define CHAOS_ARTIFACT_BUFF_SPEED "chaos_speed_buff"
#define CHAOS_ARTIFACT_BUFF_DAMAGERESIST "chaos_damageresist_buff"
#define CHAOS_ARTIFACT_BUFF_SANITY "chaos_sanity_buff"
#define CHAOS_ARTIFACT_BUFF_DISTORTION "chaos_distortion_buff"
#define CHAOS_ARTIFACT_BUFF_REGEN "chaos_regen_buff"

// Chaos transformation
#define CHAOS_TRANSFORM_ANOMALY "chaos_anomaly"

// Chaos gate states
#define CHAOS_GATE_STATE_IDLE 0
#define CHAOS_GATE_STATE_ACTIVE 1
#define CHAOS_GATE_STATE_OVERHEAT 2

// Chaos compass cooldown
#define CHAOS_COMPASS_COOLDOWN 10 SECONDS

// Chaos altar regen rate
#define CHAOS_ALTAR_REGEN_RATE 2
#define CHAOS_ALTAR_SANITY_REGEN_RATE 0.5

// Chaos distortion tick interval
#define CHAOS_DISTORTION_TICK_INTERVAL 5 SECONDS
#define CHAOS_DISTORTION_TIME_PASSIVE_RATE 1
#define CHAOS_DISTORTION_EVENT_ACTIVE_RATE 5
#define CHAOS_DISTORTION_EVENT_BOSS_RATE 15

// Chaos fog boundary
#define CHAOS_FOG_ZOOM_THRESHOLD 0.8
#define CHAOS_FOG_TELEPORT_COOLDOWN 2 SECONDS

// Chaos entity health
#define CHAOS_ENTITY_HEALTH_NORMAL 50
#define CHAOS_ENTITY_HEALTH_BOSS 200
#define CHAOS_ENTITY_DAMAGE_NORMAL 10
#define CHAOS_ENTITY_DAMAGE_BOSS 30

// Chaos sanity modification rates
#define CHAOS_SANITY_MOD_LIGHT 0.1
#define CHAOS_SANITY_MOD_MODERATE 0.5
#define CHAOS_SANITY_MOD_STRONG 1.0
#define CHAOS_SANITY_MOD_CRITICAL 2.0
#define CHAOS_SANITY_MOD_MAXIMUM 5.0

// Chaos speed modifier rates
#define CHAOS_SPEED_MOD_LIGHT 0.9
#define CHAOS_SPEED_MOD_MODERATE 0.8
#define CHAOS_SPEED_MOD_STRONG 0.6
#define CHAOS_SPEED_MOD_CRITICAL 0.4
#define CHAOS_SPEED_MOD_MAXIMUM 0.2

// Chaos UI colors
#define CHAOS_UI_COLOR_DISTORTION "#8B00FF"
#define CHAOS_UI_COLOR_SANITY "#00CED1"
#define CHAOS_UI_COLOR_HEALTH "#DC143C"

// Chaos dimension name
#define CHAOS_DIMENSION_NAME "Chaos Dimension"
#define CHAOS_DIMENSION_NAME_RU "Хаос-пространство"