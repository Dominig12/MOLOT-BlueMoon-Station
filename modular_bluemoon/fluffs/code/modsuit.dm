/obj/item/mod/control/pre_equipped/anomalous_archeotech
	icon = 'modular_bluemoon/fluffs/icons/obj/clothing/modsuit/mod_clothing.dmi'
	mob_overlay_icon = 'modular_bluemoon/fluffs/icons/mob/clothing/modsuit/mod_clothing.dmi'
	theme = /datum/mod_theme/anomalous_archeotech
	cell = /obj/item/stock_parts/cell/bluespace
	initial_modules = list(
		/obj/item/mod/module/storage,
		/obj/item/mod/module/jetpack
	)

/datum/mod_theme/anomalous_archeotech
	name = "anomalous archeotech"
	default_skin = "anom_arch"
	armor = list(MELEE = 10, BULLET = 5, LASER = 5, ENERGY = 10, BOMB = 30, BIO = 100, FIRE = 100, ACID = 100, WOUND = 15, RAD = 50) // BLUEMOON EDIT - was "MELEE = 20, BULLET = 15, LASER = 15, ENERGY = 15"
	resistance_flags = FIRE_PROOF|ACID_PROOF
	max_heat_protection_temperature = FIRE_SUIT_MAX_TEMP_PROTECT
	cell_drain = DEFAULT_CHARGE_DRAIN * 3
	complexity_max = DEFAULT_MAX_COMPLEXITY + 5
	slowdown_inactive = 0.75
	slowdown_active = 0.25
	siemens_coefficient = 0
	ui_theme = "hackerman"
	skins = list(
		"anom_arch" = list(
			HELMET_LAYER = null,
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
			),
			GAUNTLETS_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE,
			),
			BOOTS_FLAGS = list(
				UNSEALED_CLOTHING = THICKMATERIAL,
				SEALED_CLOTHING = STOPSPRESSUREDAMAGE,
			),
		),
	)
