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
	/// Zero excludes a definition from ICE salvage (e.g. test-only definitions).
	var/loot_weight = 1

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
	loot_weight = 0.2

/datum/netrun_daemon/phantom
	id = "phantom"
	name = "phantom.exe"
	desc = "Удлиняет окно «след потерян» после заметания следов: лёд дольше не перезахватывает процесс. Копии не усиливают эффект."
	size = 3
	bonus_kind = "phantom"
	bonus = 1

/datum/netrun_daemon/siphon
	id = "siphon"
	name = "siphon.exe"
	desc = "Открывает команду массового слива: за один запрос копирует все читаемые файлы узла в память."
	size = 3
	bonus_kind = "siphon"
	bonus = 1

/// Guaranteed progress replaces the puzzle, not route/access validation or ICE.
/datum/netrun_daemon/autobreach
	id = "autobreach"
	name = "autobreach.exe"
	desc = "Автовзлом без случайного провала: 14–30 секунд для узла, 22–38 для ЛВС. Даёт USER узла или гостевой вход в ЛВС; связь и программа должны сохраняться. Прошивка требует ручного взлома."
	size = 3
	bonus_kind = "autobreach"
	bonus = 1
	var/base_duration = 10 SECONDS
	var/security_duration = 4 SECONDS
	var/network_duration = 8 SECONDS

/datum/netrun_daemon/autobreach/proc/breach_duration(security, kind)
	return base_duration + clamp(security, 1, 5) * security_duration + (kind == "network" ? network_duration : 0)

/obj/item/netrun_shard/autobreach
	name = "data shard (autobreach.exe)"
	desc = "Шард с медленным детерминированным подбором сетевого доступа."
	icon_state = "datadisk2"
	preload_daemons = list("autobreach")

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

/obj/item/netrun_shard/phantom
	name = "data shard (phantom.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("phantom")

/obj/item/netrun_shard/siphon
	name = "data shard (siphon.exe)"
	icon_state = "datadisk2"
	preload_daemons = list("siphon")

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

// MARK: Лорные документы

/// Пул архивных документов, которые раскладываются по серверам станции в начале раунда.
/// Формат: list(имя_файла, текст).
/proc/netrun_lore_documents()
	return list(
		list("служебная_записка.txt", "Кому: всем отделам. От: ИТ-службы.\n\nНапоминаем: передача ключей доступа ЛВС по открытым каналам запрещена. \
			Инциденты последней недели (несанкционированные переходы в инженерной подсети) расследуются. Смените коды доступа."),
		list("инцидент_0x4F.log", "АВТО-ОТЧЁТ СИСТЕМЫ ЗАЩИТЫ\nОбнаружен резидентный процесс в сегменте связи. Трассировка прервана: цель заместила следы. \
			Патрульный процесс перенаправлен. Рекомендована ротация ключей."),
		list("заметка.txt", "Если читаешь это — значит, добрался до сервера. Не доверяй \"официальным\" логам переговоров, их чистят. \
			Настоящие копии я держу отдельно. Ищи шард с пометкой \"архив\"."),
		list("протокол_резервирования.txt", "Серверы данных реплицируют техвеб раз в смену. При потере узла восстановление — с ближайшего реле. \
			Пароль сервера сообщений хранится локально; при компрометации сбросить вручную."),
		list("черновик_приказа.txt", "ПРОЕКТ. В связи с участившимися сетевыми вторжениями ввести патрулирование подсетей автономными процессами защиты (ICE). \
			Санкционировать уничтожение неопознанных резидентных процессов."),
		list("личный_дневник.txt", "День сорок второй в сети. Тело давно остыло, а я всё ещё здесь, между узлами. \
			Говорят, если заместать следы достаточно часто, тебя перестанут искать. Пока работает."),
		list("техзаметка.txt", "ЛВС теперь кластеризованы по отделам: один ключ открывает весь отдел. \
			Удобно для нас, удобно и для них. Держите ключи при себе."),
		list("перехват.txt", "...получено с сервера сообщений...\n\[ЗАШИФРОВАНО\]\nДля расшифровки нужен пароль сервера. Без него — только метаданные."),
	)

/// Разовая раскладка лорных документов по случайным серверным/терминальным узлам.
/datum/controller/subsystem/netrun/proc/initialize_lore()
	lore_initialized = TRUE
	var/list/pool = netrun_lore_documents()
	if(!length(pool))
		return
	var/list/hosts = list()
	for(var/address in nodes_by_address)
		var/datum/component/netrun_node/node = nodes_by_address[address]
		if(QDELETED(node) || QDELETED(node.parent) || !node.file_store)
			continue
		if(node.node_type == NETRUN_NODE_SERVER || node.node_type == NETRUN_NODE_TERMINAL)
			hosts += node
	var/placed = 0
	while(placed < NETRUN_MAX_LORE_FILES && length(hosts) && length(pool))
		var/datum/component/netrun_node/node = pick_n_take(hosts)
		var/list/doc = pick_n_take(pool)
		var/datum/netrun_file/file = new(doc[1], NETRUN_FILE_TEXT, doc[2], 0)
		node.file_store.insert(file, TRUE)
		node.add_log("В хранилище обнаружен архивный документ: [doc[1]].")
		placed++
