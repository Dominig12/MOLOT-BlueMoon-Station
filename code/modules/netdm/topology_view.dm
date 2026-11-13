/**
 * Admin diagnostic screen of the netDM graph, drawn with PixiJS in TGUI.
 *
 * Read-only: it shows what the Host built from world facts for one level. The view is a
 * shadow of the network, so it is limited to admins; players get their own scoped screens later.
 * Data is pushed only when the Host reports a new version; the screen does not autoupdate.
 */
/datum/netdm_topology_view
	/// Level being viewed.
	var/z = 1
	/// Renderer reports accepted from this screen; init and drawn per renderer instance are expected.
	var/reports = 0

/datum/netdm_topology_view/New(mob/user)
	var/turf/position = get_turf(user)
	z = position?.z || 1
	SSnetdm_observe.add_viewer(src)

/datum/netdm_topology_view/Destroy()
	SSnetdm_observe.remove_viewer(src)
	return ..()

/datum/netdm_topology_view/ui_state(mob/user)
	return GLOB.admin_state

/datum/netdm_topology_view/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetdmTopology")
		ui.set_autoupdate(FALSE)
		ui.open()

/datum/netdm_topology_view/ui_close(mob/user)
	qdel(src)

/datum/netdm_topology_view/ui_static_data(mob/user)
	var/list/levels = list()
	for(var/level in 1 to world.maxz)
		var/datum/space_level/space = level <= length(SSmapping.z_list) ? SSmapping.z_list[level] : null
		levels += list(list("z" = level, "name" = space?.name || "Z[level]"))
	return list("levels" = levels)

/datum/netdm_topology_view/ui_data(mob/user)
	var/list/view = SSnetdm_observe.views["[z]"]
	return list(
		"z" = z,
		"observing" = SSnetdm_observe.observing(),
		"published" = SSnetdm_observe.published,
		"state" = SSnetdm_observe.observe_state(),
		"version" = view?["version"],
		"age" = view ? round((world.time - view["received"]) / 10, 0.1) : null,
		"error" = view?["error"],
		"truncated" = !!view?["truncated"],
		"nodes" = view?["nodes"] || list(),
		"edges" = view?["edges"] || list(),
		"radio" = view?["radio"] || list(),
		"down" = view?["down"] || list(),
	)

/datum/netdm_topology_view/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	if(!check_rights(R_DEBUG))
		return
	switch(action)
		if("set_z")
			var/level = text2num(params["z"])
			if(!isnum(level) || level < 1 || level > world.maxz)
				return
			z = round(level)
			SSnetdm_observe.next_view_poll = 0
			return TRUE
		if("refresh")
			SSnetdm_observe.views -= "[z]"
			SSnetdm_observe.next_view_poll = 0
			return TRUE
		if("renderer")
			// What the client renderer did in the real BYOND browser. Bounded: a retry sends another.
			if(++reports > 8)
				return
			// "init" when the renderer starts or fails, "drawn" when it first holds a non-empty level.
			var/list/report = list(
				"event" = params["event"] == "drawn" ? "drawn" : "init",
				"backend" = copytext("[params["backend"]]", 1, 16),
				"failure" = copytext("[params["failure"]]", 1, 120),
				"initMs" = text2num(params["initMs"]),
				"nodes" = text2num(params["nodes"]),
				"links" = text2num(params["links"]),
				"level" = copytext("[params["level"]]", 1, 16),
				"updateMs" = text2num(params["updateMs"]),
				"dpr" = text2num(params["dpr"]),
				"agent" = replacetext(copytext("[params["agent"]]", 1, 200), "\n", " "),
				"user" = key_name(usr),
			)
			SSnetdm_observe.last_renderer_report = report
			log_world("netDM topology renderer: [json_encode(report)]")

/client/proc/netdm_topology()
	set category = "Debug"
	set name = "netDM Topology"
	if(!check_rights(R_DEBUG))
		return
	if(!SSnetdm_observe.observing())
		to_chat(usr, span_warning("netDM Observe is disabled on this server."))
		return
	var/datum/netdm_topology_view/view = new(usr)
	view.ui_interact(usr)
