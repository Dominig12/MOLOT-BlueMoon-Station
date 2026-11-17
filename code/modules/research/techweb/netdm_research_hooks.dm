// netDM research pilot (P5): hooks into the R&D server, the R&D console and the techweb primitives.
// This file compiles after the legacy definitions, so each hook overrides them and calls the original
// with ..(). Without Observe every hook is a null check. The pilot itself is code/modules/netdm/research_shadow.dm.
//
// Shadow: the legacy techweb decides and the hooks mirror its changes into the Host ledger.
// Ledger (after authorize()): for a web with a server the Host ledger decides; the hooks turn legacy
// writes into ledger events and the legacy web is only the projection of its servers.

/obj/machinery/rnd/server/Initialize(mapload)
	. = ..()
	if(. == INITIALIZE_HINT_QDEL)
		return
	var/datum/component/netdm_node/node = netdm_make_node(src)
	if(node)
		SSnetdm_observe.research?.add_server(src, node)

/obj/machinery/rnd/server/Destroy()
	SSnetdm_observe.research?.remove_server(src)
	return ..()

/// P13: the R&D console carries the network window: the same node that carries its research traffic.
/obj/machinery/computer/rdconsole
	var/datum/netdm_terminal/local/console/netdm_window

/obj/machinery/computer/rdconsole/Initialize(mapload)
	. = ..()
	if(. == INITIALIZE_HINT_QDEL)
		return
	var/datum/component/netdm_node/node = netdm_make_node(src)
	if(node)
		SSnetdm_observe.research?.add_console(src, node)

/obj/machinery/computer/rdconsole/research_node(id, mob/user)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/datum/techweb/web = stored_research
	if(!shadow || !web)
		return ..()
	if(shadow.owns(web))
		// Only the network purchase on the bound server; the legacy web learns the node from the answer.
		if(!web.available_nodes[id] || web.researched_nodes[id])
			say("Node unlock failed: Either already researched or not available!")
			return FALSE
		return shadow.console_research(src, web, id, user)
	var/list/before = web.research_points.Copy()
	shadow.console_purchase++
	. = ..()
	shadow.console_purchase--
	shadow.console_purchased(src, web, id, ., before)

/// Disk buttons of a console under the ledger go to its bound server (P6, §13.8).
/obj/machinery/computer/rdconsole/Destroy()
	QDEL_NULL(netdm_window)
	return ..()

/obj/machinery/computer/rdconsole/proc/netdm_open_space(mob/living/user)
	if(!SSnetdm_observe?.observing() || !SSnetdm_observe.services || !isliving(user))
		return FALSE
	var/datum/component/netdm_node/node = netdm_make_node(src)
	if(!node)
		return FALSE
	SSnetdm_observe.diagnostics?.offer_shell(src)
	if(netdm_window && QDELETED(netdm_window))
		netdm_window = null
	if(!netdm_window)
		netdm_window = new(src, node, user)
	netdm_window.user_ref = WEAKREF(user)
	return netdm_window.open_space(user)

/obj/machinery/computer/rdconsole/ui_act(action, list/params)
	if(action == "open_network")
		return netdm_open_space(usr)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.owns(stored_research) && !locked && !(machine_stat & (NOPOWER|BROKEN)) && (action in list("loadTech", "uploadDisk")))
		if(shadow.console_disk(src, action, params))
			return TRUE
	return ..()

/obj/machinery/computer/rdconsole/ui_data(mob/user)
	. = ..()
	SSnetdm_observe.research?.console_ui(src, .)
	if(SSnetdm_observe?.observing() && SSnetdm_observe.services)
		.["netdmSpace"] = TRUE

/// Under the ledger each server earns its own income; webs without a server keep the legacy rules.
/datum/controller/subsystem/research/fire()
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(!shadow?.authoritative)
		return ..()
	shadow.mine_servers()

/// The multitool carries a research server's address to a console (§13.3).
/datum/component/techweb_holder/on_multitool_act(datum/source, mob/living/user, obj/item/I, list/mutable_recipes)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.authoritative && istype(I, /obj/item/multitool) && shadow.multitool(parent, user, I))
		return TRUE
	return ..()

/// Under the ledger the price never changes the shared node: the exported cost less this web's boost.
/datum/techweb_node/get_price(datum/techweb/host)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(!shadow?.owns(host))
		return ..()
	var/cost = shadow.catalog_costs[id]
	if(isnull(cost))
		return research_costs.Copy()
	var/list/boost = host.boosted_nodes[id]
	return list(TECHWEB_POINT_TYPE_GENERIC = max(0, cost - (boost ? (boost[TECHWEB_POINT_TYPE_GENERIC] || 0) : 0)))

/datum/techweb/commit_income()
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(!shadow)
		return ..()
	shadow.committing++
	. = ..()
	shadow.committing--
	shadow.legacy_income(src, .)

/datum/techweb/add_point_list(list/pointlist, income = TRUE, atom/source)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.owns(src))
		shadow.ledger_points(src, pointlist, source)
		return
	. = ..()
	if(!income)
		shadow?.legacy_points(src, pointlist)

/// Under the ledger every positive amount of a known point type reaches the ledger, with or without a
/// source: a legacy write here would be a second writer granting the same resource (§13.4, §13.10).
/// A source names the server the points belong to (ResearchEvidence); without one they are gathered for
/// the web's coordinator. Frequent producers (coils, collectors, reactions, the astro sensor) are
/// coalesced per server and sent every few seconds, so a per-tick source cannot flood the ledger.
/datum/techweb/add_point_type(type, amount, income = TRUE, atom/source)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.owns(src) && SSresearch.point_types[type] && amount > 0)
		var/list/points = list()
		points[type] = amount
		shadow.evidence_points(src, points, source)
		return TRUE
	return ..()

/datum/techweb/remove_point_list(list/pointlist)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.owns(src))
		shadow.ledger_change(src, pointlist, TRUE)
		return
	var/list/before = shadow ? research_points.Copy() : null
	. = ..()
	if(before)
		shadow.legacy_changed(src, before)

/datum/techweb/modify_point_list(list/pointlist)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	if(shadow?.owns(src))
		shadow.ledger_change(src, pointlist, FALSE)
		return
	var/list/before = shadow ? research_points.Copy() : null
	. = ..()
	if(before)
		shadow.legacy_changed(src, before)

/datum/techweb/research_node(datum/techweb_node/node, force = FALSE, auto_adjust_cost = TRUE)
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/known = istype(node) && researched_nodes[node.id]
	if(shadow?.authoritative && (force || shadow.owns(src)))
		// Under the ledger the bounty is paid once per purchase: never by a forced unlock of any web,
		// a disk, a lathe sync or a replica.
		var/pays = pays_research_bounty
		pays_research_bounty = FALSE
		. = ..()
		pays_research_bounty = pays
	else
		. = ..()
	if(. && !known && istype(node))
		shadow?.legacy_unlock(src, node.id)

/datum/techweb/boost_with_path(datum/techweb_node/N, itempath)
	. = ..()
	if(. && istype(N))
		SSnetdm_observe.research?.legacy_boost(src, N, itempath)
