/// Команда, которую узел принимает по сети. Экземпляры - синглтоны в SSnetrun.commands
/datum/netrun_command
	var/id
	var/name = "команда"
	var/desc = ""
	/// Дополнительная справка команды; общие правила выводятся автоматически.
	var/help = ""
	/// Минимальный уровень доступа
	var/access = NETRUN_ACCESS_USER
	/// Трассировка за нелегальный вызов (умножается на защиту узла)
	var/trace = 6
	/// Иконка FontAwesome для кнопки
	var/icon = "terminal"
	/// Подсветить как опасную
	var/danger = FALSE
	/// Работает даже когда узел офлайн (например, диагностика)
	var/works_offline = FALSE
	/// Выполняется без задержки маршрута (ping сам измеряет задержку)
	var/ignores_latency = FALSE

/// Выполнить команду. Возвращает текст результата или null при неудаче (причину пишет в консоль сам)
/datum/netrun_command/proc/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg, datum/netrun_request/request)
	return

/// Неизменяемые параметры конкретного пакета, отдельные от текущего выбора интерфейса.
/datum/netrun_request
	var/file_uid

/datum/netrun_request/New(file_uid)
	src.file_uid = file_uid

/// Подпись кнопки - команды органов добавляют имя органа
/datum/netrun_command/proc/display_name(datum/component/netrun_node/node, arg)
	return name

/datum/netrun_command/proc/ui_entry(datum/component/netrun_node/node, datum/netrun_console/console, full_id)
	var/level = console.node_level(node)
	var/legit = console.legit_node_level(node)
	return list(
		"id" = full_id || id,
		"name" = display_name(node, netrun_command_arg(full_id)),
		"desc" = desc,
		"help" = help_text(node, console, full_id),
		"icon" = icon,
		"danger" = danger,
		"access" = access,
		"allowed" = level >= access && console.can_route(node) && (works_offline || node.is_online(node != console.jack)) && !console.is_locked(),
		"illegal" = legit < access,
		"trace" = legit < access ? round(trace * node.get_security() * console.effective_trace_mult()) : 0,
	)

/datum/netrun_command/proc/help_text(datum/component/netrun_node/node, datum/netrun_console/console, full_id)
	var/list/lines = list("[full_id || id] — [name]", desc, "Доступ: [netrun_access_name(access)].")
	if(length(help))
		lines += help
	if(node && console)
		lines += "Трассировка без авторизации: +[round(trace * node.get_security() * console.effective_trace_mult(), 0.1)]%."
		lines += ignores_latency ? "Выполняется без задержки маршрута." : "Доставка запроса: ~[console.latency_to(node) * 100] мс; маршрут и доступ проверяются при доставке."
	lines += works_offline ? "Допускается запрос к отключённому узлу." : "Требуется работающий узел."
	return jointext(lines, "\n")

/datum/netrun_command/node_log
	id = "node_log"
	name = "Журнал узла"
	desc = "Прочитать последние сетевые события этой машины."
	help = "Журнал следует за устройством при смене отсека. Содержит подключения, запросы, файловые операции и события защиты."
	access = NETRUN_ACCESS_USER
	trace = 2
	icon = "list"
	works_offline = TRUE

/datum/netrun_command/node_log/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	return length(node.logs) ? jointext(node.logs, "\n") : "Журнал пуст."

/datum/netrun_command/firmware
	id = "firmware"
	name = "Обход ограничений"
	desc = "Запустить отдельный сложный взлом защиты прошивки устройства."
	help = "Нужны ROOT, icepick.exe и второй Breach Protocol повышенной сложности. Только собранный демон ROOT применяет штатный emag_act машины; доступ ROOT сам по себе ограничений не снимает. Неудача оставляет следы."
	access = NETRUN_ACCESS_ROOT
	trace = 0
	icon = "microchip"
	danger = TRUE

/datum/netrun_command/firmware/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	if(!console.daemon_bonus("icepick"))
		return "Для атаки прошивки нужен icepick.exe в памяти."
	if(!console.start_breach("firmware", node.address))
		return "Нельзя начать взлом прошивки: проверьте соединение и активный взлом."
	return "Запущен подбор защиты прошивки."

// MARK: Общие команды

/datum/netrun_command/scan
	id = "scan"
	name = "Сканировать"
	desc = "Снять состояние узла."
	access = NETRUN_ACCESS_GUEST
	trace = 0
	icon = "magnifying-glass"
	works_offline = TRUE

/datum/netrun_command/scan/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/atom/A = node.parent
	var/list/lines = list("[node.get_name()] [node.address] — [node.is_online() ? "в сети" : "НЕ ОТВЕЧАЕТ"], защита [node.get_security()]")
	lines += A.netrun_status()
	if(length(node.entities) && console.node_level(node) >= NETRUN_ACCESS_USER)
		lines += "Обнаружены резидентные процессы: [length(node.entities)]"
	return jointext(lines, "\n")

/datum/netrun_command/ping
	id = "ping"
	name = "Ping"
	desc = "Измерить задержку маршрута до узла."
	access = NETRUN_ACCESS_GUEST
	trace = 0
	icon = "stopwatch"
	works_offline = TRUE
	ignores_latency = TRUE

/datum/netrun_command/ping/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg)
	if(!console.can_route(node))
		return "[node.address]: нет маршрута."
	var/datum/netrun_route/route = console.route_to(node)
	var/lat = route.latency
	var/route_name = route.name
	console.ping_route = route.hops.Copy()
	var/hops = max(0, length(route.hops) - 1)
	qdel(route)
	console.ping_at = world.time
	if(lat <= 0)
		return "[node.address]: 0мс ([route_name])"
	// Ответ приходит после того, как пакет дойдёт и вернётся
	addtimer(CALLBACK(console, TYPE_PROC_REF(/datum/netrun_console, ping_reply), node.address, lat, route_name), lat * 2)
	return "[node.address]: пакет отправлен, [hops] прыжков…"

/datum/netrun_command/reboot
	id = "reboot"
	name = "Перезагрузить"
	desc = "Отправить узел в перезагрузку на 20 секунд."
	access = NETRUN_ACCESS_ROOT
	trace = 4
	icon = "power-off"
	danger = TRUE

/datum/netrun_command/reboot/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	node.offline_until = world.time + 20 SECONDS
	return "Узел уходит в перезагрузку."

/datum/netrun_command/purge
	id = "purge"
	name = "Очистка"
	desc = "Вычистить резидентные процессы из памяти узла. Бьёт по сетевым сущностям внутри."
	access = NETRUN_ACCESS_ROOT
	trace = 3
	icon = "broom"
	danger = TRUE

/datum/netrun_command/purge/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	if(!LAZYLEN(node.entities))
		return "Посторонних процессов не найдено."
	var/hit = 0
	for(var/mob/camera/netrun_entity/entity as anything in node.entities.Copy())
		if(entity.console == console)
			continue
		hit++
		entity.take_integrity(45, "очистка памяти узла")
		if(!QDELETED(entity) && entity.host_node == node)
			entity.eject_from_node()
	if(!hit)
		return "Посторонних процессов не найдено."
	return "Очистка выполнена: вычищено процессов - [hit]."

/datum/netrun_command/issue_key
	id = "issue_key"
	name = "Выпустить ключ ЛВС"
	desc = "Записать ключ гостевого входа и перемещения сущности внутри ЛВС."
	help = "Ключ открывает обнаружение и переходы по соседним узлам этой ЛВС. Управление машинами по-прежнему требует подходящих ID-доступов или взлома конкретного узла."
	access = NETRUN_ACCESS_ROOT
	trace = 5
	icon = "key"

/datum/netrun_command/issue_key/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/datum/netrun_network/network = node.network
	if(!network)
		return
	var/datum/netrun_file/key = new("[network.id].key", NETRUN_FILE_KEY, network.passcode, 1, network.id)
	if(!console.store_file(key))
		qdel(key)
		console.log_line("Нет места в локальном хранилище.", "bad")
		return
	return "Ключ [network.short_name] записан в локальное хранилище."
