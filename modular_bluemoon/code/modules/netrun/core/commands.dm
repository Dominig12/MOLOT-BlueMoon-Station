/// Команда, которую узел принимает по сети. Экземпляры - синглтоны в SSnetrun.commands
/datum/netrun_command
	var/id
	var/name = "команда"
	var/desc = ""
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

/// Выполнить команду. Возвращает текст результата или null при неудаче (причину пишет в консоль сам)
/datum/netrun_command/proc/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg)
	return

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
		"icon" = icon,
		"danger" = danger,
		"access" = access,
		"allowed" = level >= access,
		"illegal" = legit < access,
		"trace" = legit < access ? round(trace * node.get_security() * console.effective_trace_mult()) : 0,
	)

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
	if(!length(node.entities))
		return "Посторонних процессов не найдено."
	for(var/mob/camera/netrun_entity/entity as anything in node.entities.Copy())
		if(entity.console == console)
			continue
		entity.take_integrity(35, "очистка памяти узла")
	return "Очистка выполнена: задето процессов - [length(node.entities)]."

/datum/netrun_command/issue_key
	id = "issue_key"
	name = "Выпустить ключ ЛВС"
	desc = "Записать в локальное хранилище ключ, дающий доступ пользователя ко всей ЛВС (для автоматики)."
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
