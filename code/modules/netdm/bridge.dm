/**
 * Nonblocking BYOND adapter for the optional native Win32 netdm_byond.dll.
 * Does not load the DLL until open() is explicitly called.
 */
#define NETDM_DLL "netdm_byond.dll"

/datum/netdm_bridge
	var/active = FALSE
	var/serial = 0

/datum/netdm_bridge/proc/open()
	if(active)
		return TRUE
	active = (call_ext(NETDM_DLL, "netdm_init")() == "1")
	return active

/datum/netdm_bridge/proc/close()
	if(active)
		call_ext(NETDM_DLL, "netdm_shutdown")()
	active = FALSE

/**
 * DreamMaker encodes booleans as numeric 1/0; the x64 Host's System.Text.Json
 * expects JSON booleans for PipeRequest.Enabled. Normalize that single
 * well-defined field without changing packet class or numeric IDs.
 */
/datum/netdm_bridge/proc/serialize(list/command)
	var/raw = json_encode(command)
	if(command["op"] == "game_radio")
		if(command["enabled"])
			raw = replacetext(raw, "\"enabled\":1", "\"enabled\":true")
		else
			raw = replacetext(raw, "\"enabled\":0", "\"enabled\":false")
	return raw

/// Returns a locally enqueued command ID, not transport delivery.
/datum/netdm_bridge/proc/send(list/command)
	if(!active || !islist(command))
		return null
	serial++
	var/command_id = "netdm-[serial]"
	command["id"] = command_id
	if(call_ext(NETDM_DLL, "netdm_send")(serialize(command)) != "1")
		return null
	return command_id

/datum/netdm_bridge/proc/status()
	if(!active)
		return null
	var/raw = call_ext(NETDM_DLL, "netdm_status")()
	if(!length(raw))
		return null
	return json_decode(raw)

/// Never blocks on pipes; consumes only ready responses.
/datum/netdm_bridge/proc/read(max_messages = 64)
	var/list/messages = list()
	if(!active)
		return messages
	max_messages = min(max(round(max_messages), 1), 128)
	for(var/i = 1, i <= max_messages, i++)
		var/raw = call_ext(NETDM_DLL, "netdm_poll")()
		if(!length(raw))
			break
		var/list/entry = json_decode(raw)
		if(islist(entry))
			messages += list(entry)
	return messages

#undef NETDM_DLL
