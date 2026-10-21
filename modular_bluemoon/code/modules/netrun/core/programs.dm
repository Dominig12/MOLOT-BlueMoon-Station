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
	)

// MARK: Реестр

/datum/controller/subsystem/netrun
	var/list/datum/netrun_program/programs

/datum/controller/subsystem/netrun/proc/get_program(id)
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
	power = 11
	cooldown = 2.5 SECONDS
	size = 0
	trace = 2
	icon = "hand-fist"

/// Встроенная защита процесса: всегда доступна, слабее печатных щитов, не теряется.
/datum/netrun_program/shell
	id = "shell"
	name = "shell"
	desc = "Встроенный защитный контур: входящий урон меньше на треть на 5 секунд."
	role = NETRUN_PROGRAM_SHIELD
	power = 35
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
	power = 18
	cooldown = 2 SECONDS
	size = 2
	trace = 3
	icon = "bolt"

/datum/netrun_program/assault
	id = "assault"
	name = "assault.exe"
	desc = "Тяжёлый эксплойт: много урона, но долгая перезарядка и заметный след."
	role = NETRUN_PROGRAM_ATTACK
	power = 36
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
	cooldown = 1 SECONDS
	size = 3
	consumable = TRUE
	trace = 10
	icon = "bomb"

// MARK: Поддержка

/datum/netrun_program/blackout
	id = "blackout"
	name = "blackout.exe"
	desc = "Глушит цель: на несколько секунд она не может атаковать и не преследует."
	role = NETRUN_PROGRAM_STUN
	power = 4 SECONDS
	cooldown = 8 SECONDS
	size = 3
	trace = 4
	icon = "ban"

/datum/netrun_program/barrier
	id = "barrier"
	name = "barrier.exe"
	desc = "Поднимает защитный контур: входящий урон вдвое меньше на 5 секунд."
	role = NETRUN_PROGRAM_SHIELD
	power = 50
	cooldown = 10 SECONDS
	size = 3
	needs_target = FALSE
	trace = 2
	icon = "shield-halved"

/datum/netrun_program/patch
	id = "patch"
	name = "patch.exe"
	desc = "Восстанавливает часть собственной целостности."
	role = NETRUN_PROGRAM_REPAIR
	power = 30
	cooldown = 8 SECONDS
	size = 2
	needs_target = FALSE
	trace = 1
	icon = "briefcase-medical"

// MARK: Печатаемые/добываемые шарды с программами

/obj/item/netrun_shard/strike
	name = "data shard (strike.exe)"
	desc = "Шард с базовой атакующей программой для сетевого боя."
	icon_state = "datadisk2"
	preload_programs = list("strike")

/obj/item/netrun_shard/combat
	name = "data shard (combat suite)"
	desc = "Боевой набор сетевика: удар, щит и патч."
	icon_state = "datadisk3"
	preload_programs = list("strike", "barrier", "patch")

/obj/item/netrun_shard/assault
	name = "data shard (assault.exe)"
	desc = "Шард с тяжёлой атакующей программой."
	icon_state = "datadisk2"
	preload_programs = list("assault")

/obj/item/netrun_shard/logic_bomb
	name = "data shard (logic_bomb.card)"
	desc = "Шард с одноразовой логической бомбой. Военного образца."
	icon_state = "datadisk3"
	preload_programs = list("logic_bomb")

/obj/item/netrun_shard/blackout
	name = "data shard (blackout.exe)"
	icon_state = "datadisk2"
	preload_programs = list("blackout")
