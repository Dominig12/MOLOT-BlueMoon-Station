/**
 * Взлом в духе Breach Protocol.
 *
 * Матрица size x size с кодами. Первый выбор - в верхней строке, дальше выбор
 * чередуется: столбец последнего выбора, затем его строка и так далее.
 * Выбранные коды падают в буфер; демон считается собранным, если его
 * последовательность целиком встречается в буфере подряд.
 *
 * Матрица всегда решаема: сначала строится допустимый путь длиной в буфер,
 * а последовательности демонов нарезаются из кодов на этом пути.
 */
/datum/netrun_breach
	var/datum/netrun_console/console
	/// "node" или "network"
	var/target_kind
	/// Адрес узла или id сети
	var/target_id
	var/datum/netrun_network/target_network
	var/target_name
	var/security = 1
	var/size = 5
	var/list/matrix
	var/list/used
	var/buffer_size = 4
	var/list/buffer = list()
	/// TRUE - следующий выбор в строке current_line, FALSE - в столбце
	var/pick_row = TRUE
	var/current_line = 1
	/// list(list("name", "reward", "sequence" = list(), "done"))
	var/list/daemons = list()
	var/deadline = 0
	var/finished = FALSE

/datum/netrun_breach/New(datum/netrun_console/console, target_kind, target_id, target_name, security)
	src.console = console
	src.target_kind = target_kind
	src.target_id = target_id
	src.target_name = target_name
	src.security = clamp(security - console.daemon_bonus("icepick"), 1, 5)
	size = 5 + (src.security >= 3) + (src.security >= 5)
	buffer_size = 4 + round(src.security / 2) + console.buffer_bonus + console.daemon_bonus("buffer")
	buffer_size = min(buffer_size, size * 2)
	deadline = world.time + (45 SECONDS) - (src.security * 4 SECONDS) + (console.daemon_bonus("extend") * (10 SECONDS))
	if(target_kind == "network")
		size++
		deadline -= 5 SECONDS
	generate()

/datum/netrun_breach/Destroy()
	console = null
	target_network = null
	return ..()

/datum/netrun_breach/proc/valid_target()
	if(!console || console.is_locked())
		return FALSE
	if(target_kind == "network")
		return console.can_reach(SSnetrun.networks[target_id])
	var/datum/component/netrun_node/node = SSnetrun.find_node(target_id)
	if(!node)
		return FALSE
	node.join_network()
	return node.network == target_network && console.can_route(node) && node.is_online(node != console.jack) && console.node_level(node) >= NETRUN_ACCESS_GUEST

/datum/netrun_breach/proc/cell(row, col)
	return (row - 1) * size + col

/datum/netrun_breach/proc/row_of(index)
	return round((index - 1) / size) + 1

/datum/netrun_breach/proc/col_of(index)
	return ((index - 1) % size) + 1

/datum/netrun_breach/proc/generate()
	var/list/codes = NETRUN_BREACH_CODES
	matrix = list()
	used = list()
	daemons = list()
	buffer = list()
	for(var/i in 1 to size * size)
		matrix += pick(codes)
		used += FALSE

	// Строим допустимый путь: верхняя строка, затем чередуем столбец/строку
	var/list/path = list()
	var/row = 1
	var/col = rand(1, size)
	path += cell(row, col)
	var/by_column = TRUE
	while(length(path) < buffer_size)
		var/list/options = list()
		for(var/i in 1 to size)
			var/index = by_column ? cell(i, col) : cell(row, i)
			if(!(index in path))
				options += index
		if(!length(options))
			break
		var/next = pick(options)
		path += next
		row = row_of(next)
		col = col_of(next)
		by_column = !by_column
	buffer_size = length(path)

	var/list/path_codes = list()
	for(var/index in path)
		path_codes += matrix[index]

	// Демоны - отрезки пути. Длины растут с защитой
	var/list/lengths = list(2, security >= 2 ? 3 : 2, security >= 4 ? 4 : 3)
	if(target_kind == "network")
		lengths = list(min(5, buffer_size), min(6, buffer_size), min(5, buffer_size))
	var/list/names = list("ДОСТУП", "ROOT", "ЗАМЕСТИ СЛЕДЫ")
	var/list/rewards = list(NETRUN_ACCESS_USER, NETRUN_ACCESS_ROOT, 0)
	if(target_kind == "node" && console.daemon_bonus("skeleton"))
		names = list("ОТМЫЧКА", "ROOT", "ЗАМЕСТИ СЛЕДЫ")
		rewards = list(NETRUN_ACCESS_ROOT, NETRUN_ACCESS_ROOT, 0)
	for(var/i in 1 to 3)
		var/len = min(lengths[i], buffer_size)
		var/start = rand(1, buffer_size - len + 1)
		daemons += list(list(
			"name" = names[i],
			"reward" = rewards[i],
			"sequence" = path_codes.Copy(start, start + len),
			"done" = FALSE,
		))

/datum/netrun_breach/proc/choose(index)
	if(finished || index < 1 || index > length(matrix) || used[index])
		return FALSE
	if(pick_row ? row_of(index) != current_line : col_of(index) != current_line)
		return FALSE
	used[index] = TRUE
	buffer += matrix[index]
	if(pick_row)
		current_line = col_of(index)
	else
		current_line = row_of(index)
	pick_row = !pick_row
	check_daemons()
	if(length(buffer) >= buffer_size || all_done())
		finish()
	return TRUE

/datum/netrun_breach/proc/check_daemons()
	var/joined = " [jointext(buffer, " ")] "
	for(var/list/daemon as anything in daemons)
		if(daemon["done"])
			continue
		if(findtext(joined, " [jointext(daemon["sequence"], " ")] "))
			daemon["done"] = TRUE

/datum/netrun_breach/proc/all_done()
	for(var/list/daemon as anything in daemons)
		if(!daemon["done"])
			return FALSE
	return TRUE

/datum/netrun_breach/proc/time_left()
	return max(0, deadline - world.time)

/datum/netrun_breach/proc/finish()
	if(finished)
		return
	finished = TRUE
	console.breach_finished(src)

/datum/netrun_breach/proc/ui_payload()
	var/list/cells = list()
	for(var/i in 1 to length(matrix))
		cells += list(list(
			"code" = used[i] ? null : matrix[i],
			"active" = !used[i] && (pick_row ? row_of(i) == current_line : col_of(i) == current_line),
		))
	return list(
		"target" = target_name,
		"security" = security,
		"size" = size,
		"cells" = cells,
		"buffer" = buffer,
		"buffer_size" = buffer_size,
		"daemons" = daemons,
		"time_left" = round(time_left() / (1 SECONDS)),
		"pick_row" = pick_row,
	)
