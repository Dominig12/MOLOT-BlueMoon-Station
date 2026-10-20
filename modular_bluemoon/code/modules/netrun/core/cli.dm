// MARK: Командная строка терминала
//
// Каждая команда CLI - датум /datum/netrun_cli_command (синглтон в SSnetrun.cli_commands).
// HELP и автодополнение строятся рефлексией по реестру: перебор датумов, чтение их полей
// и вызов их же методов (usage/detailed_help). Новая команда = новый подтип, ничего больше.

/datum/netrun_cli_command
	/// Имя команды (первое слово ввода)
	var/id
	/// Подсказка по аргументам, например "<адрес>"
	var/args = ""
	/// Короткое описание (одна строка, для общего help)
	var/desc = ""
	/// Раздел в справке
	var/category = "Общие"

/// Подробная справка - список строк. По умолчанию из desc + usage; команды могут дополнять.
/datum/netrun_cli_command/proc/detailed_help(datum/netrun_console/console)
	. = list("[id] [args]", desc)

/// Выполнить. words - все слова ввода (words[1] = id), raw - исходная строка
/datum/netrun_cli_command/proc/execute(datum/netrun_console/console, list/words, raw)
	return

/// Варианты автодополнения для аргумента (адреса, коды сетей, имена файлов...)
/datum/netrun_cli_command/proc/completions(datum/netrun_console/console, partial)
	return list()

// MARK: Реестр и диспетчер

/datum/controller/subsystem/netrun/var/list/cli_commands

/datum/controller/subsystem/netrun/proc/get_cli_commands()
	if(!cli_commands)
		cli_commands = list()
		for(var/datum/netrun_cli_command/path as anything in subtypesof(/datum/netrun_cli_command))
			if(!initial(path.id))
				continue
			var/datum/netrun_cli_command/command = new path
			cli_commands[command.id] = command
	return cli_commands

/datum/netrun_console/proc/cli(text)
	text = trim(copytext_char("[text]", 1, 200))
	if(!length(text))
		return
	log_line("$ [text]", "label")
	var/list/words = splittext(text, " ")
	var/verb_name = lowertext(words[1])
	var/list/registry = SSnetrun.get_cli_commands()
	var/datum/netrun_cli_command/command = registry[verb_name]
	if(!command)
		log_line("Неизвестная команда «[verb_name]». help — список команд.", "bad")
		return
	command.execute(src, words, text)

/// Список команд для автодополнения в tgui
/datum/netrun_console/proc/cli_verbs()
	. = list()
	for(var/verb_name in SSnetrun.get_cli_commands())
		var/datum/netrun_cli_command/command = SSnetrun.cli_commands[verb_name]
		. += list(list("id" = command.id, "args" = command.args, "desc" = command.desc))

// MARK: help

/datum/netrun_cli_command/help
	id = "help"
	args = "\[команда\]"
	desc = "Список команд или подробная справка по одной."

/datum/netrun_cli_command/help/detailed_help(datum/netrun_console/console)
	return list("help \[команда\]", "Без аргумента - все команды по разделам. С аргументом - подробно об одной.")

/datum/netrun_cli_command/help/execute(datum/netrun_console/console, list/words, raw)
	var/list/registry = SSnetrun.get_cli_commands()
	if(length(words) > 1)
		var/datum/netrun_cli_command/target = registry[lowertext(words[2])]
		if(!target)
			console.log_line("Нет такой команды.", "bad")
			return
		for(var/line in target.detailed_help(console))
			console.log_line(line)
		return
	// Автогенерация: группировка по разделам
	var/list/by_cat = list()
	for(var/verb_name in registry)
		var/datum/netrun_cli_command/command = registry[verb_name]
		LAZYADD(by_cat[command.category], command)
	for(var/category in by_cat)
		console.log_line("── [category]", "label")
		for(var/datum/netrun_cli_command/command as anything in by_cat[category])
			console.log_line("  [command.id] [command.args] — [command.desc]")
	console.log_line("help <команда> — подробно.", "label")

// MARK: Навигация

/datum/netrun_cli_command/net
	id = "net"
	args = "\[код|id\]"
	desc = "Список доступных сетей или открыть одну."
	category = "Навигация"

/datum/netrun_cli_command/net/execute(datum/netrun_console/console, list/words, raw)
	if(length(words) < 2)
		for(var/network_id in SSnetrun.networks)
			var/datum/netrun_network/network = SSnetrun.networks[network_id]
			if(console.can_reach(network))
				console.log_line("[network.code] ([network.id]) — [network.name], узлов: [length(network.nodes)], доступ: [netrun_access_name(console.network_level(network))]")
		return
	var/datum/netrun_network/network = SSnetrun.find_network(words[2])
	if(!network || !console.can_reach(network))
		console.log_line("Сеть недоступна.", "bad")
		return
	console.viewed_network_id = network.id
	console.log_line("Открыта сеть [network.code].")

/datum/netrun_cli_command/net/completions(datum/netrun_console/console, partial)
	. = list()
	for(var/network_id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[network_id]
		if(console.can_reach(network))
			. += network.code

/datum/netrun_cli_command/sel
	id = "sel"
	args = "<адрес>"
	desc = "Выбрать узел по адресу."
	category = "Навигация"

/datum/netrun_cli_command/sel/execute(datum/netrun_console/console, list/words, raw)
	var/datum/component/netrun_node/node = SSnetrun.find_node(length(words) > 1 ? words[2] : null)
	if(!node || console.node_level(node) < NETRUN_ACCESS_GUEST)
		console.log_line("Узел не найден или нет доступа.", "bad")
		return
	console.selected_address = node.address
	console.log_line("Выбран [node.get_name()] [node.address].")

/datum/netrun_cli_command/nodes
	id = "nodes"
	desc = "Список узлов текущей сети."
	category = "Навигация"

/datum/netrun_cli_command/nodes/execute(datum/netrun_console/console, list/words, raw)
	var/datum/netrun_network/network = SSnetrun.networks[console.viewed_network_id]
	if(!network || console.network_level(network) < NETRUN_ACCESS_GUEST)
		console.log_line("Нет открытой сети.", "bad")
		return
	for(var/datum/component/netrun_node/node as anything in network.nodes)
		console.log_line("[node.address] [node.get_name()] ([node.node_type], [netrun_access_name(console.node_level(node))])")

// MARK: Действия с узлами

/datum/netrun_cli_command/run
	id = "run"
	args = "<команда>"
	desc = "Выполнить команду на выбранном узле."
	category = "Действия"

/datum/netrun_cli_command/run/detailed_help(datum/netrun_console/console)
	. = list("run <команда>", "Выполнить команду на выбранном узле. Доступные команды узла:")
	var/datum/component/netrun_node/node = console.selected_node()
	if(!node)
		. += "  (узел не выбран)"
		return
	for(var/command_id in node.command_ids)
		var/datum/netrun_command/command = SSnetrun.get_command(command_id)
		if(command)
			. += "  [command.id] — [command.desc || command.name]"

/datum/netrun_cli_command/run/execute(datum/netrun_console/console, list/words, raw)
	if(length(words) < 2)
		console.log_line("Укажите команду: run <команда>.", "bad")
		return
	console.run_command(console.selected_node(), lowertext(words[2]))

/datum/netrun_cli_command/run/completions(datum/netrun_console/console, partial)
	. = list()
	var/datum/component/netrun_node/node = console.selected_node()
	for(var/command_id in node?.command_ids)
		. += command_id

/datum/netrun_cli_command/scan
	id = "scan"
	desc = "Сканировать выбранный узел."
	category = "Действия"

/datum/netrun_cli_command/scan/execute(datum/netrun_console/console, list/words, raw)
	console.run_command(console.selected_node(), "scan")

/datum/netrun_cli_command/ping
	id = "ping"
	args = "\[адрес\]"
	desc = "Задержка маршрута до узла."
	category = "Действия"

/datum/netrun_cli_command/ping/execute(datum/netrun_console/console, list/words, raw)
	var/datum/component/netrun_node/node = length(words) > 1 ? SSnetrun.find_node(words[2]) : console.selected_node()
	console.run_command(node, "ping")

/datum/netrun_cli_command/breach
	id = "breach"
	args = "\[адрес|код сети\]"
	desc = "Запустить подбор доступа."
	category = "Действия"

/datum/netrun_cli_command/breach/execute(datum/netrun_console/console, list/words, raw)
	var/token = length(words) > 1 ? words[2] : null
	var/datum/netrun_network/network = token ? SSnetrun.find_network(token) : null
	if(network)
		console.start_breach("network", network.id)
	else
		console.start_breach("node", token || console.selected_address)

// MARK: Память

/datum/netrun_cli_command/ls
	id = "ls"
	desc = "Файлы в локальном хранилище и на шарде."
	category = "Память"

/datum/netrun_cli_command/ls/execute(datum/netrun_console/console, list/words, raw)
	var/list/files = console.all_files()
	if(!length(files))
		console.log_line("Хранилище пусто.")
		return
	for(var/datum/netrun_file/file as anything in files)
		console.log_line("[file.name] — [file.kind], [file.size]")

/datum/netrun_cli_command/mem
	id = "mem"
	desc = "Занятость памяти терминала и шарда."
	category = "Память"

/datum/netrun_cli_command/mem/execute(datum/netrun_console/console, list/words, raw)
	console.log_line("Память: [netrun_storage_used(console.storage)]/[console.storage_capacity]")
	if(console.shard)
		console.log_line("Шард [console.shard.name]: [netrun_storage_used(console.shard.files)]/[console.shard.capacity]")

/datum/netrun_cli_command/rm
	id = "rm"
	args = "<имя>"
	desc = "Удалить файл из локального хранилища."
	category = "Память"

/datum/netrun_cli_command/rm/execute(datum/netrun_console/console, list/words, raw)
	if(length(words) < 2)
		console.log_line("Укажите имя файла.", "bad")
		return
	var/wanted = lowertext(words[2])
	for(var/datum/netrun_file/file as anything in console.all_files())
		if(lowertext(file.name) == wanted)
			console.delete_local_file(file)
			console.log_line("Удалён [file.name].")
			return
	console.log_line("Файл не найден.", "bad")

/datum/netrun_cli_command/rm/completions(datum/netrun_console/console, partial)
	. = list()
	for(var/datum/netrun_file/file as anything in console.all_files())
		. += file.name

// MARK: Связь

/datum/netrun_cli_command/chat
	id = "chat"
	args = "<текст>"
	desc = "Отправить сообщение в канал #noosphere."
	category = "Связь"

/datum/netrun_cli_command/chat/execute(datum/netrun_console/console, list/words, raw)
	var/message = length(words) > 1 ? copytext(raw, length(words[1]) + 2) : null
	if(!message)
		console.log_line("Пустое сообщение.", "bad")
		return
	console.chat_send(message)

// MARK: Экран

/datum/netrun_cli_command/clear
	id = "clear"
	desc = "Очистить экран терминала."
	category = "Экран"

/datum/netrun_cli_command/clear/execute(datum/netrun_console/console, list/words, raw)
	console.log.Cut()
