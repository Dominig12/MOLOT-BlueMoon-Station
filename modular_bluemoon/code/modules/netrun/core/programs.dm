/**
 * Боевая программа ("карточка") - активный файл, который раннер запускает против
 * процесса, с которым делит узел: ICE или другой сущности. В отличие от демонов
 * (пассивные бонусы) программы применяются вручную, имеют перезарядку, а часть -
 * одноразовые (consumable): такой файл удаляется после запуска.
 *
 * Новую программу добавляет подтип - консоли находят файлы через этот реестр.
 */
/datum/netrun_program
	var/id
	var/name = "program.exe"
	var/desc = "Боевая сетевая программа."
	var/help = ""
	var/size = 2
	/// Роль: атака/щит/оглушение/ремонт/очистка
	var/role = NETRUN_PROGRAM_ATTACK
	/// Сила эффекта (урон/лечение/щит в процентах/время оглушения в децисекундах)
	var/power = 20
	/// Перезарядка на этой консоли, децисекунды
	var/cooldown = 2 SECONDS
	/// Одноразовая "карточка": файл сгорает после применения
	var/consumable = FALSE
	/// Нужна враждебная цель (FALSE - действие на себя)
	var/needs_target = TRUE
	/// Трассировка за запуск (шум боевой активности)
	var/trace = 3
	var/icon = "bolt"
	/// ICE announces this preparation period before applying the same effect.
	var/windup = 2.5 SECONDS
	/// Encounter costs are shared by players, bots and ICE; legacy clocks remain
	/// available to out-of-encounter consumers of the same ordinary program files.
	var/ap_cost = 2
	var/cooldown_turns = 0
	var/shield_turns = 1
	var/stun_turns = 1

/datum/netrun_program/proc/create_file()
	return new /datum/netrun_file(name, NETRUN_FILE_PROGRAM, id, size)

/datum/netrun_program/proc/ui_entry()
	return list(
		"id" = id,
		"name" = name,
		"desc" = desc,
		"size" = size,
		"role" = role,
		"power" = power,
		"cooldown" = round(cooldown / (1 SECONDS), 0.1),
		"consumable" = consumable,
		"needs_target" = needs_target,
		"icon" = icon,
		"windup" = windup / (1 SECONDS),
		"ap_cost" = ap_cost,
		"cooldown_turns" = cooldown_turns,
		"shield_turns" = shield_turns,
		"stun_turns" = stun_turns,
	)

// MARK: Реестр

/datum/controller/subsystem/netrun
	var/list/datum/netrun_program/programs

/datum/controller/subsystem/netrun/proc/get_program(id)
	RETURN_TYPE(/datum/netrun_program)
	if(!programs)
		programs = list()
		for(var/datum/netrun_program/path as anything in subtypesof(/datum/netrun_program))
			var/program_id = initial(path.id)
			if(!program_id)
				continue
			programs[program_id] = new path
	return istext(id) ? programs[lowertext(trim(id))] : null

/datum/controller/subsystem/netrun/proc/program_definitions()
	get_program(null)
	. = list()
	for(var/id in programs)
		var/datum/netrun_program/program = programs[id]
		. += list(program.ui_entry())

/proc/netrun_program_file(id)
	var/datum/netrun_program/program = SSnetrun.get_program(id)
	return program?.create_file()

// MARK: Атакующие программы

/// Встроенная атака процесса: слабая, но всегда доступна и не занимает память.
/// Благодаря ей сущность может повредить ICE даже с пустым хранилищем.
/datum/netrun_program/sting
	id = "sting"
	name = "sting"
	desc = "Встроенный процессорный удар. Слабый, но бесплатный и не теряется."
	role = NETRUN_PROGRAM_ATTACK
	power = 8
	ap_cost = 1
	cooldown = 2 SECONDS
	size = 0
	trace = 2
	icon = "hand-fist"

/// Встроенная защита процесса: всегда доступна, слабее печатных щитов, не теряется.
/datum/netrun_program/shell
	id = "shell"
	name = "shell"
	desc = "Встроенный защитный контур: снижает входящий урон на четверть на один ход."
	role = NETRUN_PROGRAM_SHIELD
	power = 25
	ap_cost = 1
	cooldown_turns = 1
	cooldown = 12 SECONDS
	size = 0
	needs_target = FALSE
	trace = 1
	icon = "shield"

/datum/netrun_program/strike
	id = "strike"
	name = "strike.exe"
	desc = "Короткий пакетный удар по целостности процесса. Малая перезарядка."
	role = NETRUN_PROGRAM_ATTACK
	power = 22
	cooldown = 2 SECONDS
	size = 2
	trace = 3
	icon = "bolt"

/datum/netrun_program/assault
	id = "assault"
	name = "assault.exe"
	desc = "Тяжёлый эксплойт: много урона, но долгая перезарядка и заметный след."
	role = NETRUN_PROGRAM_ATTACK
	power = 40
	ap_cost = 3
	cooldown_turns = 1
	cooldown = 5 SECONDS
	size = 4
	trace = 7
	icon = "burst"

/datum/netrun_program/logic_bomb
	id = "logic_bomb"
	name = "logic_bomb.card"
	desc = "Одноразовая логическая бомба. Огромный урон, сгорает после запуска."
	help = "Карточка расходуется при применении."
	role = NETRUN_PROGRAM_ATTACK
	power = 70
	ap_cost = 3
	cooldown = 1 SECONDS
	size = 3
	consumable = TRUE
	trace = 10
	icon = "bomb"

// MARK: Поддержка

/datum/netrun_program/blackout
	id = "blackout"
	name = "blackout.exe"
	desc = "Прерывает действия цели оглушением на один ход."
	cooldown_turns = 2
	role = NETRUN_PROGRAM_STUN
	power = 4 SECONDS
	cooldown = 8 SECONDS
	size = 3
	trace = 4
	icon = "ban"

/datum/netrun_program/emp
	id = "emp"
	name = "emp.card"
	desc = "Одноразовый ЭМИ-разряд: оглушает на два хода. Сгорает после запуска, заметный след."
	ap_cost = 3
	stun_turns = 2
	help = "Карточка расходуется при применении."
	role = NETRUN_PROGRAM_STUN
	power = 6 SECONDS
	cooldown = 1 SECONDS
	size = 3
	consumable = TRUE
	trace = 8
	icon = "bolt-lightning"

/datum/netrun_program/barrier
	id = "barrier"
	name = "barrier.exe"
	desc = "Снижает входящий урон вдвое на один ход."
	cooldown_turns = 1
	role = NETRUN_PROGRAM_SHIELD
	power = 50
	cooldown = 10 SECONDS
	size = 3
	needs_target = FALSE
	trace = 2
	icon = "shield-halved"

/datum/netrun_program/fortify
	id = "fortify"
	name = "fortify.exe"
	desc = "Тяжёлый защитный контур: снижает входящий урон на 65% на два хода."
	ap_cost = 3
	cooldown_turns = 2
	shield_turns = 2
	role = NETRUN_PROGRAM_SHIELD
	power = 65
	cooldown = 14 SECONDS
	size = 4
	needs_target = FALSE
	trace = 2
	icon = "shield"

/datum/netrun_program/patch
	id = "patch"
	name = "patch.exe"
	desc = "Восстанавливает часть собственной целостности."
	role = NETRUN_PROGRAM_REPAIR
	power = 30
	cooldown_turns = 1
	cooldown = 8 SECONDS
	size = 2
	needs_target = FALSE
	trace = 1
	icon = "briefcase-medical"

/// Counter-intrusion uses the same program/cooldown machinery as physical attacks.
/datum/netrun_program/trace
	id = "trace"
	name = "trace.exe"
	desc = "Увеличивает трассировку активного взломщика после предупреждения."
	role = NETRUN_PROGRAM_TRACE
	power = 6
	cooldown_turns = 1
	cooldown = 5 SECONDS
	windup = 3 SECONDS
	icon = "fingerprint"

// MARK: Встроенные варианты и печатная тактика

/datum/netrun_program/pulse
	id = "pulse"
	name = "pulse"
	desc = "Встроенный средний удар: 18 урона за 2 ОД. Не занимает память."
	power = 18
	size = 0
	trace = 2
	icon = "wave-square"

/datum/netrun_program/surge
	id = "surge"
	name = "surge"
	desc = "Встроенный тяжёлый удар: 28 урона за 3 ОД. Не занимает память."
	power = 28
	ap_cost = 3
	size = 0
	trace = 4
	icon = "burst"

/datum/netrun_program/mend
	id = "mend"
	name = "mend"
	desc = "Встроенное восстановление: 8 целостности за 1 ОД. Слабее файлов ремонта."
	role = NETRUN_PROGRAM_REPAIR
	power = 8
	ap_cost = 1
	cooldown_turns = 1
	cooldown = 8 SECONDS
	size = 0
	needs_target = FALSE
	trace = 0
	icon = "kit-medical"

/datum/netrun_program/needle
	id = "needle"
	name = "needle.exe"
	desc = "Компактный быстрый удар: 12 урона за 1 ОД. Оставляет действия для защиты или ремонта."
	power = 12
	ap_cost = 1
	size = 2
	cooldown = 1 SECONDS
	trace = 2
	icon = "syringe"

/datum/netrun_program/lance
	id = "lance"
	name = "lance.exe"
	desc = "Точный тяжёлый пакет: 34 урона за 2 ОД. Требует перезарядки между ходами и больше памяти, чем strike."
	power = 34
	ap_cost = 2
	cooldown_turns = 1
	cooldown = 5 SECONDS
	size = 4
	trace = 6
	icon = "crosshairs"

/datum/netrun_program/aegis
	id = "aegis"
	name = "aegis.exe"
	desc = "Дорогая оборона: снижает входящий урон на 70% на два хода, занимая все 3 ОД."
	role = NETRUN_PROGRAM_SHIELD
	power = 70
	ap_cost = 3
	shield_turns = 2
	cooldown_turns = 2
	cooldown = 16 SECONDS
	size = 5
	needs_target = FALSE
	trace = 3
	icon = "shield"

/datum/netrun_program/renew
	id = "renew"
	name = "renew.exe"
	desc = "Быстрый ремонт: восстанавливает 18 целостности за 1 ОД с перезарядкой между ходами."
	role = NETRUN_PROGRAM_REPAIR
	power = 18
	ap_cost = 1
	cooldown_turns = 1
	cooldown = 10 SECONDS
	size = 3
	needs_target = FALSE
	trace = 1
	icon = "heart-pulse"

/datum/netrun_program/jam
	id = "jam"
	name = "jam.exe"
	desc = "Экономное подавление: оглушает цель на один ход за 1 ОД, затем долго перезаряжается."
	role = NETRUN_PROGRAM_STUN
	power = 2 SECONDS
	ap_cost = 1
	stun_turns = 1
	cooldown_turns = 2
	cooldown = 12 SECONDS
	size = 3
	trace = 4
	icon = "ban"

/// Shared effect dispatcher: ICE cannot bypass entity shields with raw damage.
/// damage_scale lets ICE hit softer than a player running the same program file,
/// without weakening the player's own copy of that program.
/proc/netrun_apply_program(datum/netrun_program/program, target, datum/netrun_console/attacker, damage_scale = 1)
	switch(program.role)
		if(NETRUN_PROGRAM_ATTACK)
			netrun_combatant_hit(target, round(program.power * damage_scale), "программа [program.name]", attacker)
		if(NETRUN_PROGRAM_STUN)
			netrun_combatant_stun(target, program.power)
		if(NETRUN_PROGRAM_SHIELD)
			netrun_combatant_shield(target, program.power, 5 SECONDS)
		if(NETRUN_PROGRAM_REPAIR)
			netrun_combatant_heal(target, program.power)
		if(NETRUN_PROGRAM_TRACE)
			if(istype(target, /datum/netrun_console))
				var/datum/netrun_console/console = target
				console.add_trace(program.power)

// MARK: Печатаемые/добываемые шарды с программами

/obj/item/netrun_shard/strike
	name = "data shard (strike.exe)"
	desc = "Шард с базовой атакующей программой для сетевого боя."
	icon_state = "datadisk2"
	preload_programs = list("strike")

/obj/item/netrun_shard/combat
	name = "data shard (combat suite)"
	desc = "Боевой набор сетевика: стандартный и быстрый удары, щит и два варианта ремонта."
	icon_state = "datadisk3"
	preload_programs = list("strike", "barrier", "patch", "needle", "renew")

/obj/item/netrun_shard/assault
	name = "data shard (assault.exe)"
	desc = "Шард с тяжёлой атакующей программой."
	icon_state = "datadisk2"
	preload_programs = list("assault", "lance")

/obj/item/netrun_shard/logic_bomb
	name = "data shard (logic_bomb.card)"
	desc = "Шард с одноразовой логической бомбой. Военного образца."
	icon_state = "datadisk3"
	preload_programs = list("logic_bomb")

/obj/item/netrun_shard/blackout
	name = "data shard (blackout.exe)"
	icon_state = "datadisk2"
	preload_programs = list("blackout", "jam")

/obj/item/netrun_shard/emp
	name = "data shard (emp.card)"
	desc = "Шард с одноразовым ЭМИ-разрядом для сетевого боя."
	icon_state = "datadisk3"
	preload_programs = list("emp")

/obj/item/netrun_shard/fortify
	name = "data shard (fortify.exe)"
	desc = "Шард с тяжёлой защитной программой сетевика."
	icon_state = "datadisk2"
	preload_programs = list("fortify", "aegis")
