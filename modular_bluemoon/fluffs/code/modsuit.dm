/obj/item/mod/control/pre_equipped/anomalous_archeotech
	desc = "Высокотехнологичный MOD костюм, который встраивается напрямую в тело, невидимое энергетическое поле, защищает владельца от давления извне. \
	Управление происходит через специальный интерфейс мозг компьютер, который подключается не инвазивно. \
	Встроенные ядра аномалий, обеспечивают стабильность работы и работу энергетического поля"
	alternate_worn_layer = BACK_LAYER
	theme = /datum/mod_theme/anomalous_archeotech
	initial_modules = list(
		/obj/item/mod/module/storage,
		/obj/item/mod/module/dna_lock
	)

/obj/item/mod/construction/armor/anomalous_archeotech
	theme = /datum/mod_theme/anomalous_archeotech

/datum/mod_theme/anomalous_archeotech
	name = "anomalous archeotech"
	default_skin = "anom_arch"
	armor = list(MELEE = 15, BULLET = 5, LASER = 5, ENERGY = 10, BOMB = 30, BIO = 100, FIRE = 100, ACID = 100, WOUND = 15, RAD = 50)
	resistance_flags = FIRE_PROOF|ACID_PROOF
	max_heat_protection_temperature = FIRE_SUIT_MAX_TEMP_PROTECT
	cell_drain = DEFAULT_CHARGE_DRAIN * 2
	complexity_max = DEFAULT_MAX_COMPLEXITY + 5
	siemens_coefficient = 0
	ui_theme = "hackerman"
	skins = list(
		"anom_arch" = list(
			HELMET_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE|ALLOWINTERNALS,
				UNSEALED_INVISIBILITY = HIDEFACIALHAIR|HIDEEARS|HIDEHAIR|HIDESNOUT,
				SEALED_INVISIBILITY = HIDEEYES|HIDEFACE,
				SEALED_COVER = HEADCOVERSMOUTH|HEADCOVERSEYES,
			),
			CHESTPLATE_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE,
				SEALED_INVISIBILITY = null
			),
			GAUNTLETS_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE,
			),
			BOOTS_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE,
			),
			CONTROL_LAYER = BACK_LAYER
		),
	)
