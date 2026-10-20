/**
 * A daemon definition describes one executable file and its passive effect.
 * Add a subtype to publish a new program; consoles resolve files through this registry.
 * Programs sharing a bonus_kind use their strongest bonus, without stacking copies.
 */
/datum/netrun_daemon
	var/id
	var/name = "daemon.exe"
	var/desc = "Программа сетевого клиента."
	var/size = 1
	var/bonus_kind
	var/bonus = 0

/datum/netrun_daemon/proc/create_file()
	return new /datum/netrun_file(name, NETRUN_FILE_DAEMON, id, size)

/datum/netrun_daemon/proc/ui_entry()
	return list("id" = id, "name" = name, "desc" = desc, "size" = size, "bonus_kind" = bonus_kind, "bonus" = bonus)

/datum/netrun_daemon/buffer
	id = "buffer"
	name = "buffer.exe"
	desc = "Увеличивает буфер протокола взлома на одну ячейку. Копии не усиливают эффект."
	size = 2
	bonus_kind = "buffer"
	bonus = 1

/datum/netrun_daemon/icepick
	id = "icepick"
	name = "icepick.exe"
	desc = "Снижает защиту цели при подборе на один уровень и позволяет атаковать поддерживаемую прошивку."
	size = 3
	bonus_kind = "icepick"
	bonus = 1

/datum/netrun_daemon/cloak
	id = "cloak"
	name = "cloak.exe"
	desc = "Снижает прирост трассировки на 30%. Копии не усиливают эффект."
	size = 3
	bonus_kind = "cloak"
	bonus = 0.3

/datum/controller/subsystem/netrun
	var/list/datum/netrun_daemon/daemons

/// Lazy construction also supports preloaded shards created during map initialization.
/datum/controller/subsystem/netrun/proc/get_daemon(id)
	if(!daemons)
		daemons = list()
		for(var/datum/netrun_daemon/path as anything in subtypesof(/datum/netrun_daemon))
			var/daemon_id = initial(path.id)
			if(!daemon_id)
				continue
			daemons[daemon_id] = new path
	return istext(id) ? daemons[lowertext(trim(id))] : null

/// Shared discovery metadata for help, CLI and future interfaces.
/datum/controller/subsystem/netrun/proc/daemon_definitions()
	get_daemon(null)
	. = list()
	for(var/id in daemons)
		var/datum/netrun_daemon/daemon = daemons[id]
		. += list(daemon.ui_entry())

// Individually printable programs, with the same file format as the existing breach suite.
/obj/item/netrun_shard/buffer
	name = "data shard (buffer.exe)"
	desc = "Шард с программой расширения буфера сетевого клиента. Вставьте в деку или терминал."
	icon_state = "datadisk2"
	preload_daemons = list("buffer")

/obj/item/netrun_shard/icepick
	name = "data shard (icepick.exe)"
	desc = "Шард с программой анализа защиты и атаки сетевых контроллеров."
	icon_state = "datadisk2"
	preload_daemons = list("icepick")

/obj/item/netrun_shard/cloak
	name = "data shard (cloak.exe)"
	desc = "Шард с программой сокрытия активности сетевого клиента от систем трассировки."
	icon_state = "datadisk2"
	preload_daemons = list("cloak")

// MARK: Расширенный пул программ

/datum/netrun_daemon/extend
	id = "extend"
	name = "extend.exe"
	desc = "Продлевает окно протокола взлома: +10 секунд на демона. Копии не усиливают эффект."
	size = 2
	bonus_kind = "extend"
	bonus = 1

/datum/netrun_daemon/overclock
	id = "overclock"
	name = "overclock.exe"
	desc = "Разгоняет сетевой стек: удалённые операции идут почти без задержки маршрута."
	size = 3
	bonus_kind = "overclock"
	bonus = 1

/datum/netrun_daemon/scrub
	id = "scrub"
	name = "scrub.exe"
	desc = "Ускоряет спад трассировки в простое вдвое. Копии не усиливают эффект."
	size = 2
	bonus_kind = "scrub"
	bonus = 1

/datum/netrun_daemon/mapper
	id = "mapper"
	name = "mapper.exe"
	desc = "Разведка топологии: на карте видны машины и за закрытыми шлюзами подсетей."
	size = 2
	bonus_kind = "mapper"
	bonus = 1

/datum/netrun_daemon/skeleton
	id = "skeleton"
	name = "skeleton.exe"
	desc = "Дорогой армейский ключ: один взлом узла сразу выдаёт ROOT вместо пользователя. Расходуется редко — держите на крайний случай."
	size = 5
	bonus_kind = "skeleton"
	bonus = 1

// Печатаемые/добываемые шарды с новыми программами
/obj/item/netrun_shard/extend
	name = "data shard (extend.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("extend")

/obj/item/netrun_shard/overclock
	name = "data shard (overclock.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("overclock")

/obj/item/netrun_shard/scrub
	name = "data shard (scrub.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("scrub")

/obj/item/netrun_shard/mapper
	name = "data shard (mapper.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("mapper")

/obj/item/netrun_shard/skeleton
	name = "data shard (skeleton.exe)"
	desc = "Шард с редкой программой-отмычкой. Военного образца."
	icon_state = "datadisk3"
	preload_daemons = list("skeleton")

/obj/item/netrun_shard/fullsuite
	name = "data shard (full breach suite)"
	desc = "Набор программ опытного сетевика: буфер, разведка, разгон и заметание следов."
	icon_state = "datadisk3"
	preload_daemons = list("buffer", "icepick", "cloak", "mapper", "overclock", "scrub")
