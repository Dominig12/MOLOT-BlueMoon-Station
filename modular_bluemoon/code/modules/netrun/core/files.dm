/// Файл в сетевом хранилище
/datum/netrun_file
	var/name = "file"
	var/kind = NETRUN_FILE_TEXT
	/// Текст, ключ ЛВС или id демона
	var/content = ""
	var/size = 1
	/// Для ключей - id сети, которую открывает ключ
	var/network_id
	var/static/next_uid = 0
	var/uid

/datum/netrun_file/New(name, kind, content, size, network_id)
	uid = "[++next_uid]"
	if(name)
		src.name = name
	if(kind)
		src.kind = kind
	if(!isnull(content))
		src.content = content
	if(size)
		src.size = size
	else if(src.kind == NETRUN_FILE_TEXT)
		src.size = max(1, round(length(src.content) / 500))
	src.network_id = network_id

/datum/netrun_file/proc/copy()
	return new /datum/netrun_file(name, kind, content, size, network_id)

/datum/netrun_file/proc/ui_entry()
	return list(
		"uid" = uid,
		"name" = name,
		"kind" = kind,
		"size" = size,
		"preview" = kind == NETRUN_FILE_TEXT ? copytext_char(content, 1, 200) : (kind == NETRUN_FILE_TECHWEB ? "дамп техвеба: [length(splittext(content, ";"))] узлов" : null),
	)

/// Программы-демоны, влияющие на взлом
/proc/netrun_daemon_file(id)
	switch(id)
		if("buffer")
			return new /datum/netrun_file("buffer.exe", NETRUN_FILE_DAEMON, "buffer", 2)
		if("icepick")
			return new /datum/netrun_file("icepick.exe", NETRUN_FILE_DAEMON, "icepick", 3)
		if("cloak")
			return new /datum/netrun_file("cloak.exe", NETRUN_FILE_DAEMON, "cloak", 3)

/// Шард данных: маленький переносной носитель
/obj/item/netrun_shard
	name = "data shard"
	desc = "Тонкая пластинка с кристаллом памяти. Вставляется в кибердеку, терминал или разъём нейролинка."
	icon = 'icons/obj/module.dmi'
	icon_state = "datadisk1"
	w_class = WEIGHT_CLASS_TINY
	var/list/datum/netrun_file/files = list()
	var/capacity = 8
	/// Что записано на шард при создании: list(тип файла = содержимое) или id демонов
	var/list/preload_daemons

/obj/item/netrun_shard/Initialize(mapload)
	. = ..()
	for(var/id in preload_daemons)
		var/datum/netrun_file/file = netrun_daemon_file(id)
		if(file)
			files += file

/obj/item/netrun_shard/Destroy()
	QDEL_LIST(files)
	return ..()

/obj/item/netrun_shard/examine(mob/user)
	. = ..()
	. += span_notice("Занято [netrun_storage_used(files)] из [capacity] ячеек.")
	for(var/datum/netrun_file/file as anything in files)
		. += span_notice("— [file.name]")

/obj/item/netrun_shard/daemons
	name = "data shard (breach suite)"
	desc = "Шард с набором демонов для взлома. Чей-то рабочий инструмент."
	icon_state = "datadisk2"
	preload_daemons = list("buffer", "icepick", "cloak")

/proc/netrun_storage_used(list/files)
	. = 0
	for(var/datum/netrun_file/file as anything in files)
		. += file.size
