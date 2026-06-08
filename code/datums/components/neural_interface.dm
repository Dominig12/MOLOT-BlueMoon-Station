/datum/log_entry
	var/plain
	var/color
	var/char_index
	var/char_speed
	var/size

/datum/log_entry/proc/get_line()
	if(char_index < length(plain))
		char_index = min(char_index + char_speed, length(plain)+1)

	var/revealed_text = copytext(plain, 1, char_index)

	return {"<span style='font-family: \"TinyUnicode\"; color: [color]; font-size: [size]pt; line-height: 0.8;-dm-text-outline: 1px black;'>[revealed_text]</span>"}

/datum/component/neural_interface
	var/list/logs = list()
	var/list/data = list()
	var/max_logs = 3
	var/atom/movable/screen/text/logs_view
	var/char_reveal_speed = 10
	var/mob/living/host_mob

/datum/component/neural_interface/Initialize(mob/user)
	if(!isliving(parent))
		return COMPONENT_INCOMPATIBLE

	host_mob = parent
	logs_view = ScreenText(null, "Initialize", "CENTER-6,CENTER-4", 450, 250)
	host_mob.client.screen += get_view()

/datum/component/neural_interface/Destroy(force, silent)
	delete_user()

	return ..()

/datum/component/neural_interface/UnregisterFromParent()
	delete_user()

	return ..()

/datum/component/neural_interface/proc/delete_user()
	if(host_mob)
		host_mob.client.screen -= get_view()
		host_mob = null

/datum/component/neural_interface/proc/get_view()
	return logs_view

/datum/component/neural_interface/proc/write_data(key, value)
	LAZYINITLIST(data)

	data[key] = value
	return TRUE

/datum/component/neural_interface/proc/write_log(text, key="LOG", color="#4ad1fa86", size=12)
	LAZYINITLIST(logs)

	var/list/log_categories = list(
		"SYSTEM" = "#4ad1fa86",
		"WARNING" = "#f59e0bff",
		"ERROR" = "#ef4444ff",
		"INFO" = "#10b981ff",
		"DATA" = "#8b5cf6ff",
		"SYNC" = "#06b6d4ff",
		"HEALTH" = "#f472b6ff",
		"MODULE" = "#a78bffff",
		"ALERT" = "#ff0000ff"
	)

	var/list/log_speed = list(
		"SYSTEM" = 15,
		"WARNING" = 15,
		"ERROR" = 30,
		"INFO" = 15,
		"DATA" = 15,
		"SYNC" = 15,
		"HEALTH" = 30,
		"MODULE" = 15,
		"ALERT" = 30
	)

	if(log_categories[key])
		color = log_categories[key]

	var/plain_text = "\[[key]\] - [text]"

	if(logs.len >= max_logs)
		logs.Splice(1, 2)

	var/datum/log_entry/log = new()

	log.plain = plain_text
	log.color = color
	log.char_index = 1
	log.char_speed = char_reveal_speed
	log.size = size

	if(log_speed[key])
		log.char_speed = log_speed[key]

	logs += log

	return TRUE

/datum/component/neural_interface/proc/compile_log()

	var/write = {"<span style='font-family: \"TinyUnicode\"; font-size: 12pt; color: #4ad1fa86; line-height: 0.8; -dm-text-outline: 1px black;'>── SYSTEM MODULE ──</span><br>"}
	write += {"<span style='font-family: \"TinyUnicode\"; font-size: 12pt; color: #6b7280; line-height: 0.8;-dm-text-outline: 1px black;'>─────────────────────────</span><br>"}

	if(logs.len > 0)
		write += {"<span style='font-family: \"TinyUnicode\"; font-size: 12pt; color: #6b7280; line-height: 0.8;-dm-text-outline: 1px black;'>├─ LOG STREAM</span><br>"}
		for(var/datum/log_entry/log_entry in logs)
			write += "└ [log_entry.get_line()]<br>"

	if(data.len > 0)
		write += {"<span style='font-family: \"TinyUnicode\"; font-size: 12pt; color: #6b7280; line-height: 0.8;-dm-text-outline: 1px black;'>├─ DATA</span><br>"}
		for(var/key in data)
			write += "[MAPTEXT_TINY_UNICODE("└ [key]: [data[key]]")]<br>"

	logs_view.maptext = write
