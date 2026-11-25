/// The Host ledger keeps milli-points; DM numbers are 32-bit floats, so amounts travel as text.
#define NETDM_RESEARCH_MILLI 1000
/// Mirror events kept until the Host confirms them; a full outbox coalesces income.
#define NETDM_RESEARCH_OUTBOX 512
/// Budget of one encoded catalog chunk; a frame holds 48 KiB with its envelope.
#define NETDM_RESEARCH_CHUNK_BYTES 30000
/// Cadence of the balance comparison between a legacy web and its treasury storage.
#define NETDM_RESEARCH_COMPARE (15 SECONDS)
/// A mirrored purchase without an answer by then counts as unanswered.
#define NETDM_RESEARCH_ANSWER_TIMEOUT (20 SECONDS)
/// Pause after the Host could not take a research request (no ledger, a failed journal).
#define NETDM_RESEARCH_RETRY (5 SECONDS)
/// Cadence of the legacy web's projection of its servers' wallets under the ledger.
#define NETDM_RESEARCH_PROJECTION (10 SECONDS)
/// Cadence of a console's status round trip to its server.
#define NETDM_RESEARCH_STATUS (10 SECONDS)
/// Cadence of the knowledge pull between two peers of a domain.
#define NETDM_RESEARCH_SYNC (15 SECONDS)
/// Cadence of asking the ledger's outbox while nothing is known to wait; a settlement or a lost answer asks at once.
#define NETDM_RESEARCH_EFFECTS (5 SECONDS)
/// Purchases without an answer remembered for a late effect.
#define NETDM_RESEARCH_UNANSWERED 64
/// Settlements reported in one request (the Host takes at most 64).
#define NETDM_RESEARCH_SETTLE_BATCH 32
/// Records of a server's knowledge log asked in one request (the Host gives at most 64).
#define NETDM_RESEARCH_KNOWLEDGE_PAGE 64
/// A catalogue search can restart once if the Host invalidates its cursor.
#define NETDM_RESEARCH_SERVER_SEARCH_TIMEOUT (2 MINUTES)

/**
 * research.server pilot in Shadow mode (P5).
 *
 * The legacy techweb keeps deciding everything players see. Every R&D server becomes a netDM node
 * with its own storage in the Host ledger, and the R&D console a node that buys over the network.
 * The first server of a legacy web is that web's treasury: the shadow seeds it with the web's points
 * and knowledge and then mirrors every change made through the techweb primitives — committed income,
 * direct grants, penalties, forced unlocks and boosts. A console purchase that the legacy web made is
 * sent as research.server/research to the treasury over the simulated network, and the Host ledger
 * decides it on its own: same price, same prerequisites, enough points. Answers are compared with
 * the legacy outcome, and the treasury balance is compared with the web's points.
 *
 * Per-server wallets, the target of the design, are not compared here: the treasury mirrors the
 * shared legacy pool, so differences show defects and unmirrored writers, not the planned change.
 * A mismatching purchase is aligned afterwards (import of the node and a debit of the legacy price),
 * so one root cause is counted once instead of cascading into every later purchase.
 */
/datum/netdm_research_shadow
	parent_type = /datum/netdm_integration
	/// Catalog payloads, built once per round from pristine node data; resent after every new session.
	var/list/catalog_chunks
	var/catalog_next = 1
	var/catalog_ready = FALSE
	var/catalog_hash
	var/catalog_error
	/// Ordered mirror events waiting for the Host: list("op", "payload", "what").
	var/list/outbox = list()
	/// The request in flight, if any; at most one keeps the order of the mirror.
	var/list/sending
	var/next_send = 0
	/// Server weakref -> storage ID; storage ID -> server weakref.
	var/list/servers = list()
	var/list/storages = list()
	/// Console weakrefs with a node.
	var/list/consoles = list()
	/// "[REF(web)]" -> treasury storage ID; storage ID -> "[REF(web)]".
	var/list/treasuries = list()
	var/list/treasury_web = list()
	var/serial = 0
	/// Depth of a console purchase in progress: its spend and unlock are mirrored as the purchase itself.
	var/console_purchase = 0
	/// Depth of commit_income: its internal add_point_list is part of the committed income.
	var/committing = 0
	/// Mirror events get a sequence; the Host confirms them in order up to confirmed_seq.
	var/event_seq = 0
	var/confirmed_seq = 0
	/// Purchases waiting for the mirror to confirm every event made before them: the legacy web
	/// had those points when it bought, so the treasury must have them before the purchase arrives.
	var/list/waiting = list()
	/// Idempotency key -> purchase record; operation ID -> idempotency key.
	var/list/purchases = list()
	var/list/purchase_keys = list()
	var/list/latencies = list()
	var/next_compare = 0
	var/compare_inflight = FALSE
	/// Mirror events counted when the comparison was asked; any newer one makes its answer inconclusive.
	var/compare_events = 0
	var/last_drift
	var/max_drift = 0
	var/list/counters = list("events" = 0, "confirmed" = 0, "rejected" = 0, "coalesced" = 0, "dropped" = 0,
		"unmirrored" = 0, "purchases" = 0, "matched" = 0, "mismatched" = 0, "unanswered" = 0, "refused" = 0,
		"legacy_refused" = 0, "aligned" = 0, "compares" = 0, "drifts" = 0, "knowledge_drifts" = 0, "treasuries" = 0,
		"projected" = 0, "server_queries" = 0, "server_by_query" = 0)
	var/list/mismatch_reasons = list()
	var/list/notes = list()
	/// A mirror event of a web the ledger will take over was refused or lost. The mirror is then
	/// incomplete and authority must not switch this round: the projection would erase points it never
	/// received (§13.10, §18.1). Only an operator decision can clear it.
	var/mirror_lost = FALSE
	var/mirror_lost_reported = FALSE
	/// TRUE after the migration (P5 canary): the Host ledger decides research, the legacy web is its projection.
	var/authoritative = FALSE
	/// NETDM_RESEARCH_MODE=authoritative switches over as soon as the mirror is synchronized.
	var/authority_requested = FALSE
	/// Catalog costs as exported, before legacy get_price could change them: node ID -> whole points.
	var/list/catalog_costs = list()
	/// storage -> list(node ID -> whole discount), as sent to the ledger; the console's quote uses it.
	var/list/storage_boosts = list()
	/// storage -> per-second income of the server, for display.
	var/list/server_rates = list()
	/// Console weakref -> its server binding (see bind_server).
	var/list/bindings = list()
	/// Operation ID -> console weakref, for status answers.
	var/list/status_keys = list()
	/// Multitool weakref -> storage of the server it touched last.
	var/list/multitool_servers = list()
	/// Ledger effect ID -> how this world settled it. A purchase changes the world once for the round,
	/// however often its answer or the ledger's outbox delivers it.
	var/list/settled_effects = list()
	/// Settlements the Host has not recorded yet: list(list("id", "result")).
	var/list/effect_acks = list()
	/// Purchases that ended without an answer: key -> purchase, so a late effect still names its console and user.
	var/list/unanswered = list()
	var/effects_inflight = FALSE
	var/next_effects = 0
	/// storage -> "[REF(web)]" of the web it was registered for; it outlives the server.
	var/list/storage_webs = list()
	var/list/effect_counters = list("applied" = 0, "recovered" = 0, "reported_again" = 0)
	var/last_mine
	/// Depth of a projection update: the unlock came from the ledger and is not mirrored back.
	var/applying_projection = 0
	/// storage -> research domain it was registered with: the web it served then (§13.4, §13.6).
	var/list/storage_domains = list()
	/// "dest<-source" -> list("watermark", "next", "busy"): the knowledge sync between two peers.
	var/list/sync_pairs = list()
	/// Console weakref -> TRUE while its query for reachable research servers is in flight.
	var/list/server_queries = list()
	/// Disk operation key -> list("console", "disk", "action").
	var/list/disk_ops = list()
	/// storage -> last record of its knowledge log that its legacy web already holds (§13.6, §13.8).
	var/list/knowledge_upto = list()
	/// Storages whose log has records after that, in the order they were noticed.
	var/list/knowledge_due = list()
	var/knowledge_inflight = FALSE
	var/next_knowledge = 0
	/// ResearchEvidence: power zone ref -> list("storage", "web", "until") of the server it reaches closest.
	var/list/evidence_zones = list()
	/// Zone ref -> TRUE while its query for reachable servers is in flight.
	var/list/evidence_queries = list()
	/// storage -> points from frequent sources (coils, collectors) waiting for the next grant.
	var/list/evidence_pending = list()
	var/next_evidence = 0

/datum/netdm_research_shadow/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_result("research", new /datum/netdm_effect_handler/research_answer)
	lane.dispatcher.allow_result("status", new /datum/netdm_effect_handler/research_status)
	lane.dispatcher.allow_result("sync", new /datum/netdm_effect_handler/research_sync)
	lane.dispatcher.allow_result("backup", new /datum/netdm_effect_handler/research_disk)
	lane.dispatcher.allow_result("restore", new /datum/netdm_effect_handler/research_disk)
	authority_requested = TRUE // The Host ledger is the only authority after initial synchronization.

/// A new Host session: the catalog is installed again and every storage registered again (both duplicates
/// for the same round); unconfirmed mirror events stay in order and are sent again.
/datum/netdm_research_shadow/reset_session()
	catalog_ready = FALSE
	catalog_next = 1
	if(sending)
		outbox.Insert(1, list(sending))
		sending = null
	compare_inflight = FALSE
	// This runs every fire while there is no session (a Host restart): each storage is queued once,
	// or minutes without a Host would fill the outbox with registrations and push income out of it.
	var/list/queued_registers = list()
	for(var/list/queued in outbox)
		if(queued["what"] == "register")
			queued_registers[queued["payload"]["storage"]] = TRUE
	for(var/storage in storage_domains)
		if(!queued_registers[storage])
			outbox.Insert(1, list(register_entry(storage)))
	for(var/pair in sync_pairs)
		var/list/sync = sync_pairs[pair]
		sync["busy"] = FALSE
	for(var/key in purchases)
		var/list/purchase = purchases[key]
		counters["unanswered"]++
		note("purchase [purchase["node"]] lost with the session")
		if(purchase["authoritative"])
			finish_purchase(purchase, "no_answer", null, key)
	purchases.Cut()
	purchase_keys.Cut()
	status_keys.Cut()
	// The settlements of a request in flight are lost with it; the ledger delivers those effects again
	// and they are reported again (effects_answered). What this world already settled stays settled.
	effects_inflight = FALSE
	next_effects = 0
	// A page in flight is asked again; what the webs already hold stays (the log keeps its numbers).
	knowledge_inflight = FALSE
	next_knowledge = 0
	server_queries.Cut()
	// Bindings are confirmed again by a status round trip in the new session.
	for(var/console_ref in bindings)
		var/list/binding = bindings[console_ref]
		binding["bound"] = FALSE
		binding["next_status"] = 0

// ---- Devices ---------------------------------------------------------------------------------

/datum/netdm_research_shadow/proc/add_server(obj/machinery/rnd/server/server, datum/component/netdm_node/node)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane?.endpoint_for(node)
	if(!endpoint)
		return
	var/storage = "srv-[endpoint.id]"
	var/datum/weakref/server_ref = WEAKREF(server)
	servers[server_ref] = storage
	storages[storage] = server_ref
	lane.offer(node, "research.[storage]", "research.server", "research.status", 1)
	// The storage is registered once its web is known (LateInitialize): the web is its domain.

/datum/netdm_research_shadow/proc/remove_server(obj/machinery/rnd/server/server)
	var/datum/weakref/server_ref = WEAKREF(server)
	var/storage = servers[server_ref]
	if(!storage)
		return
	servers -= server_ref
	storages -= storage
	knowledge_due -= storage
	knowledge_upto -= storage
	for(var/pair in sync_pairs.Copy())
		var/list/sync = sync_pairs[pair]
		if(sync["source"] == storage || sync["destination"] == storage)
			sync_pairs -= pair
	var/web_key = treasury_web[storage]
	if(web_key)
		treasury_web -= storage
		treasuries -= web_key
		note("treasury [storage] destroyed; the next server of the web takes over")
	// A storage the Host never registered has nothing to destroy; a destroyed one is not registered again.
	if(storage_domains[storage])
		storage_domains -= storage
		enqueue(list("op" = "research_storage", "payload" = list("storage" = storage, "generation" = 1, "action" = "destroy"), "what" = "destroy"))

/datum/netdm_research_shadow/proc/add_console(obj/machinery/computer/rdconsole/console, datum/component/netdm_node/node)
	// An endpoint lets the console invoke; it offers and wants nothing.
	if(SSnetdm_observe.services?.endpoint_for(node))
		consoles[WEAKREF(console)] = TRUE

/datum/netdm_research_shadow/proc/register_entry(storage)
	return list("op" = "research_storage", "payload" = list("storage" = storage, "generation" = 1, "domain" = storage_domains[storage],
		"action" = "register"), "what" = "register")

/// A research domain is the web a server serves: the station web, or one isolated or faction web.
/datum/netdm_research_shadow/proc/domain_of(datum/techweb/web)
	return web == SSresearch.science_tech ? "station" : "web-[copytext(md5("[REF(web)]"), 1, 13)]"

/// Registers the storages whose server now knows its web; the domain stays for the storage's life.
/datum/netdm_research_shadow/proc/register_pending()
	for(var/datum/weakref/server_ref as anything in servers)
		var/storage = servers[server_ref]
		if(storage_domains[storage])
			continue
		var/obj/machinery/rnd/server/server = server_ref.resolve()
		if(!server?.stored_research)
			continue
		storage_domains[storage] = domain_of(server.stored_research)
		storage_webs[storage] = "[REF(server.stored_research)]"
		enqueue(register_entry(storage))

/// Picks a treasury for each legacy web that has a server and none yet, and seeds it once.
/datum/netdm_research_shadow/proc/assign_treasuries()
	for(var/datum/weakref/server_ref as anything in servers)
		var/obj/machinery/rnd/server/server = server_ref.resolve()
		var/datum/techweb/web = server?.stored_research
		if(!web)
			continue
		var/web_key = "[REF(web)]"
		var/storage = servers[server_ref]
		var/current = treasuries[web_key]
		if(current)
			continue
		// A server that moved to another web stops being the treasury of the old one.
		var/old_key = treasury_web[storage]
		if(old_key && old_key != web_key)
			treasuries -= old_key
		treasuries[web_key] = storage
		treasury_web[storage] = web_key
		counters["treasuries"]++
		// Under the ledger a new coordinator starts with its own wallet: nothing is copied (§13.9).
		if(!authoritative)
			seed(storage, web)

/// The treasury starts from what the legacy web already has: points, knowledge and boosts.
/datum/netdm_research_shadow/proc/seed(storage, datum/techweb/web)
	var/list/points = milli_points(web.research_points)
	if(length(points))
		enqueue(list("op" = "research_grant", "payload" = list("storage" = storage, "generation" = 1, "source" = "seed-[storage]",
			"kind" = "migration", "points" = points), "what" = "seed"))
	var/list/nodes = list()
	for(var/id in web.researched_nodes)
		nodes += id
	if(length(nodes))
		enqueue(list("op" = "research_import", "payload" = list("storage" = storage, "generation" = 1, "source" = "seed-[storage]",
			"nodes" = nodes), "what" = "seed"))
	for(var/id in web.boosted_nodes)
		send_boost(storage, id, "seed-[id]", whole_points(web.boosted_nodes[id]), "seed")

/// Sends a boost to the ledger and remembers it: the console quotes the price the ledger will charge.
/datum/netdm_research_shadow/proc/send_boost(storage, node_id, evidence, list/discount, what)
	if(!length(discount))
		return
	var/list/known = storage_boosts[storage]
	if(!known)
		known = list()
		storage_boosts[storage] = known
	known[node_id] = max(known[node_id] || 0, discount[TECHWEB_POINT_TYPE_GENERIC] || 0)
	enqueue(list("op" = "research_boost", "payload" = list("storage" = storage, "generation" = 1, "node" = node_id,
		"evidence" = evidence, "discount" = discount), "what" = what))

/datum/netdm_research_shadow/proc/treasury_of(datum/techweb/web)
	return web ? treasuries["[REF(web)]"] : null

// ---- Legacy writers --------------------------------------------------------------------------

/// commit_income: passive income and everything that waited in next_income, once per research fire.
/datum/netdm_research_shadow/proc/legacy_income(datum/techweb/web, list/income)
	if(owns(web))
		return // Under the ledger each server earns its own income (mine_servers).
	var/storage = treasury_of(web)
	var/list/points = milli_points(income)
	if(!length(points))
		return
	if(!storage)
		counters["unmirrored"]++
		return
	enqueue(list("op" = "research_income", "payload" = list("interval" = num2text(netdm_tick_of(world.time), 16),
		"grants" = list(list("storage" = storage, "generation" = 1, "points" = points))), "what" = "income", "storage" = storage))

/// Points written straight to the balance (income = FALSE).
/datum/netdm_research_shadow/proc/legacy_points(datum/techweb/web, list/pointlist)
	if(committing)
		return
	var/storage = treasury_of(web)
	var/list/points = milli_points(pointlist)
	if(!length(points))
		return
	if(!storage)
		counters["unmirrored"]++
		return
	enqueue(list("op" = "research_grant", "payload" = list("storage" = storage, "generation" = 1, "source" = "lp-[++serial]",
		"kind" = "legacy", "points" = points), "what" = "grant"))

/// remove_point_list and modify_point_list: what actually changed, both ways.
/datum/netdm_research_shadow/proc/legacy_changed(datum/techweb/web, list/before)
	if(console_purchase)
		return
	var/storage = treasury_of(web)
	if(!storage)
		return
	var/list/gained = list()
	var/list/lost = list()
	for(var/type in SSresearch.point_types)
		var/delta = (web.research_points[type] || 0) - (before[type] || 0)
		if(delta > 0)
			gained[type] = delta
		else if(delta < 0)
			lost[type] = -delta
	if(length(gained))
		enqueue(list("op" = "research_grant", "payload" = list("storage" = storage, "generation" = 1, "source" = "lc-[++serial]",
			"kind" = "legacy", "points" = milli_points(gained)), "what" = "grant"))
	if(length(lost))
		enqueue(list("op" = "research_debit", "payload" = list("storage" = storage, "generation" = 1, "source" = "ld-[++serial]",
			"kind" = "legacy", "points" = milli_points(lost)), "what" = "debit"))

/// A node unlocked outside a console purchase: forced research, disks, admin.
/datum/netdm_research_shadow/proc/legacy_unlock(datum/techweb/web, node_id)
	if(console_purchase || applying_projection)
		return
	var/storage = treasury_of(web)
	if(!storage)
		return
	enqueue(list("op" = "research_import", "payload" = list("storage" = storage, "generation" = 1, "source" = "li-[++serial]",
		"nodes" = list(node_id)), "what" = "import"))

/datum/netdm_research_shadow/proc/legacy_boost(datum/techweb/web, datum/techweb_node/node, itempath)
	var/storage = treasury_of(web)
	if(storage)
		send_boost(storage, node.id, "b-[copytext(md5("[itempath]"), 1, 13)]", whole_points(node.boost_item_paths[itempath]), "boost")

/// The legacy console finished a purchase attempt; a successful one is repeated over netDM.
/datum/netdm_research_shadow/proc/console_purchased(obj/machinery/computer/rdconsole/console, datum/techweb/web, node_id, success, list/before)
	if(!success)
		counters["legacy_refused"]++
		return
	counters["purchases"]++
	var/type = TECHWEB_POINT_TYPE_GENERIC
	// What the legacy web actually deducted: get_price changes node costs as a side effect, so it is not asked again.
	var/price = max(0, round((before[type] || 0) - (web.research_points[type] || 0)))
	var/storage = treasury_of(web)
	var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
	if(!storage || !node || !consoles[WEAKREF(console)])
		counters["unmirrored"]++
		note("purchase [node_id]: [storage ? "console has no node" : "web has no treasury"]")
		return
	var/key = "rc-[++serial]"
	waiting[key] = list("node" = node_id, "price" = price, "storage" = storage, "queued_us" = netdm_now_us(),
		"created" = world.time, "barrier" = event_seq, "console" = WEAKREF(console))

/// Sends the purchases whose earlier mirror events the Host has confirmed.
/datum/netdm_research_shadow/proc/send_purchases()
	for(var/key in waiting)
		var/list/purchase = waiting[key]
		if(purchase["barrier"] > confirmed_seq)
			break
		waiting -= key
		var/datum/weakref/console_ref = purchase["console"]
		var/obj/machinery/computer/rdconsole/console = console_ref.resolve()
		var/datum/component/netdm_node/node = console?.GetComponent(/datum/component/netdm_node)
		var/list/entry = node && SSnetdm_observe.services.invoke(node, "research.[purchase["storage"]]", "research", key,
			list("node" = purchase["node"], "quote" = purchase["price"]), CALLBACK(src, PROC_REF(purchase_accepted), key))
		if(!entry)
			counters["unmirrored"]++
			lost_mirror("purchase [purchase["node"]]: console not attached")
			note("purchase [purchase["node"]]: console not attached")
			continue
		purchases[key] = purchase

/datum/netdm_research_shadow/proc/purchase_accepted(key, list/entry, list/reply)
	var/list/purchase = purchases[key]
	if(!purchase)
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	var/operation = islist(value) ? value["operationId"] : null
	if(!reply["ok"] || isnull(operation))
		purchases -= key
		counters["refused"]++
		if(purchase["authoritative"])
			finish_purchase(purchase, "host_[reply["error"] || "refused"]", null, key)
		else
			mismatch(purchase, "host_[reply["error"] || "refused"]", key)
		return
	purchase_keys["[operation]"] = key

/// The server's answer reached the console over the network.
/datum/netdm_research_shadow/proc/purchase_answered(obj/machinery/computer/rdconsole/console, list/item)
	var/key = purchase_keys["[item["operationId"]]"]
	var/list/purchase = key ? purchases[key] : null
	if(!purchase)
		return TRUE
	purchase_keys -= "[item["operationId"]]"
	purchases -= key
	var/list/payload = item["payload"]
	var/outcome = islist(payload) ? payload["outcome"] : (item["outcome"] || "no_result")
	push(latencies, netdm_now_us() - purchase["queued_us"])
	if(purchase["authoritative"])
		finish_purchase(purchase, outcome, payload, key)
		return TRUE
	if(outcome == "researched")
		counters["matched"]++
		return TRUE
	mismatch(purchase, outcome, key, islist(payload) ? payload["price"] : null)
	return TRUE

/// Counts a purchase the Host decided differently, then aligns the treasury with the legacy web.
/datum/netdm_research_shadow/proc/mismatch(list/purchase, reason, key, core_price)
	counters["mismatched"]++
	mismatch_reasons[reason]++
	note("purchase [purchase["node"]] for [purchase["price"]]: [reason][isnull(core_price) ? "" : " (ledger price [core_price])"]")
	var/storage = purchase["storage"]
	if(!storages[storage] || reason == "already_researched")
		return
	counters["aligned"]++
	enqueue(list("op" = "research_import", "payload" = list("storage" = storage, "generation" = 1, "source" = "align-[key]",
		"nodes" = list(purchase["node"])), "what" = "align"))
	if(purchase["price"] > 0)
		enqueue(list("op" = "research_debit", "payload" = list("storage" = storage, "generation" = 1, "source" = "align-[key]",
			"kind" = "legacy", "points" = milli_points(list(TECHWEB_POINT_TYPE_GENERIC = purchase["price"]))), "what" = "align"))

// ---- Sending ---------------------------------------------------------------------------------

/datum/netdm_research_shadow/proc/enqueue(list/entry)
	counters["events"]++
	if(length(outbox) < NETDM_RESEARCH_OUTBOX)
		entry["seq"] = ++event_seq
		outbox += list(entry)
		return
	// A full outbox folds income into the newest income of the same storage; other events are lost.
	if(entry["what"] == "income" && entry["storage"])
		for(var/i in length(outbox) to 1 step -1)
			var/list/queued = outbox[i]
			if(queued["what"] == "income" && queued["storage"] == entry["storage"])
				var/list/target = queued["payload"]["grants"][1]["points"]
				var/list/extra = entry["payload"]["grants"][1]["points"]
				for(var/type in extra)
					target[type] = num2text(text2num(target[type] || "0") + text2num(extra[type]), 16)
				counters["coalesced"]++
				return
	counters["dropped"]++
	if(event_storage(entry))
		lost_mirror("outbox full: [entry["what"]] dropped")
	note("outbox full: [entry["what"]] dropped")

/// The storage a mirror event belongs to, when the ledger will take its web over.
/datum/netdm_research_shadow/proc/event_storage(list/entry)
	var/list/payload = entry?["payload"]
	var/storage = islist(payload) ? payload["storage"] : null
	return storage && storages[storage] ? storage : null

/// Records that the mirror can no longer be complete for a web the ledger would take over.
/datum/netdm_research_shadow/proc/lost_mirror(text)
	if(!mirror_lost)
		log_world("netDM research: the mirror is incomplete, the ledger will not take over this round ([text]).")
	mirror_lost = TRUE
	note(text)

/// Called every fire after the service lane: one request in flight keeps the mirror in order.
/datum/netdm_research_shadow/tick()
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane || !SSresearch.initialized)
		return
	if(isnull(catalog_chunks))
		build_catalog()
	register_pending()
	assign_treasuries()
	send_purchases()
	expire_purchases()
	if(authority_requested && !authoritative)
		if(!authorize() && mirror_lost && !mirror_lost_reported)
			mirror_lost_reported = TRUE
			log_world("netDM research: authority stays off for this round, the mirror is incomplete ([jointext(notes, "; ")]).")
	if(authoritative)
		refresh_bindings()
		schedule_sync()
		pump_knowledge(lane)
		flush_evidence()
	pump_effects(lane)
	if(sending || world.time < next_send || catalog_error)
		return
	if(!catalog_ready)
		var/list/chunk = catalog_chunks[catalog_next]
		sending = list("op" = "research_catalog", "payload" = chunk, "what" = "catalog")
	else if(length(outbox))
		sending = outbox[1]
		outbox.Cut(1, 2)
	else if(world.time >= next_compare && !compare_inflight && length(treasuries) && (authoritative || (!length(waiting) && !length(purchases))))
		// Shadow: compare the treasury with the web. Ledger: project the server wallets onto the legacy web.
		next_compare = world.time + (authoritative ? NETDM_RESEARCH_PROJECTION : NETDM_RESEARCH_COMPARE)
		compare_inflight = TRUE
		compare_events = counters["events"]
		var/datum/callback/on_state = authoritative ? CALLBACK(src, PROC_REF(projected)) : CALLBACK(src, PROC_REF(compared))
		if(!lane.control("research_state", list("scope" = "all"), on_state))
			compare_inflight = FALSE
		return
	else
		return
	if(!lane.control(sending["op"], sending["payload"], CALLBACK(src, PROC_REF(answered), sending)))
		if(sending["what"] != "catalog")
			outbox.Insert(1, list(sending))
		sending = null

/datum/netdm_research_shadow/proc/answered(list/entry, list/reply)
	if(sending != entry)
		return // A new session re-queued it already.
	sending = null
	var/list/result = reply["result"]
	var/error = reply["error"]
	if(entry["what"] == "catalog")
		if(reply["ok"])
			catalog_next++
			if(catalog_next > length(catalog_chunks))
				catalog_ready = TRUE
				catalog_hash = islist(result) ? result["hash"] : null
		else
			// The content is wrong or another catalog is recorded for this round: research stays legacy-only.
			catalog_error = "[error]: [islist(result) ? result["error"] : ""]"
			log_world("netDM research: the Host refused the catalog ([catalog_error]).")
		return
	if(error == "research_unavailable" || error == "journal_failed")
		outbox.Insert(1, list(entry))
		next_send = world.time + NETDM_RESEARCH_RETRY
		return
	if(error == "catalog_unavailable")
		outbox.Insert(1, list(entry))
		catalog_ready = FALSE
		catalog_next = 1
		return
	var/list/statuses = islist(result) ? result["statuses"] : null
	var/status = length(statuses) ? statuses[1] : (islist(result) ? result["status"] : null)
	if(entry["what"] == "replicate")
		replicated(entry, reply)
	if(reply["ok"] && (status == "ok" || status == "duplicate" || isnull(status)))
		// A refused event does not confirm the barrier: purchases behind it wait instead of overtaking it.
		confirmed_seq = max(confirmed_seq, entry["seq"] || 0)
		counters["confirmed"]++
		return
	counters["rejected"]++
	if(event_storage(entry))
		lost_mirror("[entry["what"]] refused: [error || status]")
	note("[entry["what"]] refused: [error || status]")

/// Balance and knowledge of each treasury against its legacy web, while nothing is waiting to be mirrored.
/datum/netdm_research_shadow/proc/compared(list/reply)
	compare_inflight = FALSE
	var/list/result = reply["result"]
	var/list/rows = islist(result) ? result["storages"] : null
	// A purchase in flight is spent in the web and not yet in the treasury: no verdict then either.
	if(!reply["ok"] || !islist(rows) || length(outbox) || sending || counters["events"] != compare_events || length(waiting) || length(purchases))
		// The legacy web changed while the answer travelled; ask again soon.
		next_compare = min(next_compare, world.time + 1 SECONDS)
		return
	counters["compares"]++
	var/drift = 0
	for(var/list/row in rows)
		var/web_key = treasury_web[row["storage"]]
		if(!web_key)
			continue
		var/datum/techweb/web = locate(web_key)
		if(!istype(web))
			continue
		var/list/available = row["availableMilli"]
		var/legacy = web.research_points[TECHWEB_POINT_TYPE_GENERIC] || 0
		// Milli-points arrive as text (DM numbers are 32-bit floats); whole points would be truncated.
		var/core = netdm_number(islist(available) ? available[TECHWEB_POINT_TYPE_GENERIC] : 0) / NETDM_RESEARCH_MILLI
		drift = max(drift, abs(legacy - core))
		// The legacy balance is a 32-bit float summed thousands of times: its own error grows with it.
		if(abs(legacy - core) > max(0.1, abs(legacy) * 0.0001))
			counters["drifts"]++
			note("treasury [row["storage"]] holds [core], the web [round(legacy, 0.01)]")
		if(netdm_number(row["unlocked"]) != length(web.researched_nodes))
			counters["knowledge_drifts"]++
			note("treasury [row["storage"]] knows [row["unlocked"]] nodes, the web [length(web.researched_nodes)]")
	last_drift = drift
	max_drift = max(max_drift, drift)

/datum/netdm_research_shadow/proc/expire_purchases()
	for(var/key in waiting)
		var/list/held = waiting[key]
		if(world.time < held["created"] + NETDM_RESEARCH_ANSWER_TIMEOUT)
			break
		waiting -= key
		counters["unanswered"]++
		mismatch(held, "mirror_behind", key)
	for(var/key in purchases)
		var/list/purchase = purchases[key]
		if(world.time < purchase["created"] + NETDM_RESEARCH_ANSWER_TIMEOUT)
			continue
		purchases -= key
		counters["unanswered"]++
		if(purchase["authoritative"])
			finish_purchase(purchase, "no_answer", null, key)
		else
			mismatch(purchase, "no_answer", key)

// ---- Ledger authority (P5 canary) ------------------------------------------------------------
//
// After authorize() the Host ledger decides research for every legacy web that has a server:
// - each server earns its own passive income, with diminishing returns counted per domain (its web);
// - points from every other source and every boost go to the web's coordinator server (its treasury);
//   the legacy balance is only the projection of the servers' wallets and is never spent;
// - a console buys on the server it is bound to, over the network, at the ledger's price;
// - the research bounty is paid once per purchase; forced unlocks and lathe syncs pay none.
// The legacy web keeps the union of the servers' knowledge, so lathes and fabricators keep working.

/// The web is under the ledger: authority switched and the web has a coordinator server.
/datum/netdm_research_shadow/proc/owns(datum/techweb/web)
	return authoritative && web && treasuries["[REF(web)]"]

/**
 * Migration (§13.11). The mirror is synchronized, so each treasury already holds its web's pool.
 * Other servers of a web receive its knowledge, never a copy of its balance; income that waited in
 * next_income goes to the treasury once. From now on the legacy web is a projection.
 */
/datum/netdm_research_shadow/proc/authorize()
	if(authoritative)
		return TRUE
	if(!synchronized() || length(waiting) || length(purchases) || !length(treasuries))
		return FALSE
	authoritative = TRUE
	last_mine = world.time
	for(var/datum/weakref/server_ref as anything in servers)
		var/obj/machinery/rnd/server/server = server_ref.resolve()
		var/datum/techweb/web = server?.stored_research
		var/storage = servers[server_ref]
		if(web && treasuries["[REF(web)]"] != storage)
			import_knowledge(storage, web, "migration-[storage]")
	for(var/web_key in treasuries)
		var/datum/techweb/web = locate(web_key)
		if(!istype(web))
			continue
		var/list/pending = milli_points(web.next_income)
		if(length(pending))
			enqueue(list("op" = "research_grant", "payload" = list("storage" = treasuries[web_key], "generation" = 1,
				"source" = "migration-pending-[treasuries[web_key]]", "kind" = "migration", "points" = pending), "what" = "migration"))
		for(var/type in web.next_income)
			web.next_income[type] = 0
	for(var/datum/weakref/console_ref as anything in consoles)
		var/obj/machinery/computer/rdconsole/console = console_ref.resolve()
		if(console && owns(console.stored_research))
			bind_nearest(console)
	log_world("netDM research: the Host ledger is authoritative for [length(treasuries)] research network(s).")
	return TRUE

/// Knowledge without a balance: the web's nodes and boosts, once per source.
/datum/netdm_research_shadow/proc/import_knowledge(storage, datum/techweb/web, source)
	var/list/nodes = list()
	for(var/id in web.researched_nodes)
		nodes += id
	if(length(nodes))
		enqueue(list("op" = "research_import", "payload" = list("storage" = storage, "generation" = 1, "source" = source,
			"nodes" = nodes), "what" = "migration"))
	for(var/id in web.boosted_nodes)
		send_boost(storage, id, "[source]-[id]", whole_points(web.boosted_nodes[id]), "migration")

/**
 * Points from any legacy source under the ledger; the legacy balance stays. With a source (ResearchEvidence,
 * decision of 14.11.2026) they go to the source's server: the server its console is bound to, or the
 * server of the same web its zone reaches closest over the network. Without a source, or before that
 * server is known, the web's coordinator gets them as before.
 */
/datum/netdm_research_shadow/proc/ledger_points(datum/techweb/web, list/pointlist, atom/source)
	var/list/points = milli_points(pointlist)
	if(!length(points))
		return
	var/storage = source ? source_storage(web, source) : null
	counters[storage ? "evidence_server" : "evidence_coordinator"]++
	enqueue(list("op" = "research_grant", "payload" = list("storage" = storage || treasury_of(web), "generation" = 1,
		"source" = "[storage ? "ev" : "lp"]-[++serial]", "kind" = storage ? "evidence" : "legacy", "points" = points), "what" = "grant"))

/// Frequent sources (coils, collectors, the doppler array, gas reactions, the astro sensor): gathered per
/// server and sent by flush_evidence. Without a source the points are gathered for the web's coordinator.
/datum/netdm_research_shadow/proc/evidence_points(datum/techweb/web, list/pointlist, atom/source)
	var/storage = (source ? source_storage(web, source) : null) || treasury_of(web)
	if(!storage)
		return
	var/list/pending = evidence_pending[storage]
	if(!pending)
		pending = evidence_pending[storage] = list()
	for(var/type in pointlist)
		pending[type] = (pending[type] || 0) + pointlist[type]

/datum/netdm_research_shadow/proc/flush_evidence()
	if(world.time < next_evidence || !length(evidence_pending))
		return
	next_evidence = world.time + 5 SECONDS
	for(var/storage in evidence_pending)
		var/list/points = milli_points(evidence_pending[storage])
		if(length(points) && storages[storage])
			counters["evidence_grants"]++
			enqueue(list("op" = "research_grant", "payload" = list("storage" = storage, "generation" = 1,
				"source" = "eg-[++serial]", "kind" = "evidence", "points" = points), "what" = "grant"))
	evidence_pending.Cut()

/// The research server a source of points belongs to, or null while it is not known.
/datum/netdm_research_shadow/proc/source_storage(datum/techweb/web, atom/source)
	if(QDELETED(source) || !web)
		return null
	var/obj/machinery/computer/rdconsole/console
	if(istype(source, /obj/machinery/rnd/destructive_analyzer))
		var/obj/machinery/rnd/destructive_analyzer/analyzer = source
		console = analyzer.linked_console
	else if(istype(source, /obj/machinery/rnd/experimentor))
		var/obj/machinery/rnd/experimentor/experimentor = source
		console = experimentor.linked_console
	var/list/binding = console ? bindings[WEAKREF(console)] : null
	if(binding?["bound"] && server_of_web(binding["storage"], web))
		return binding["storage"]
	var/area/zone = netdm_power_area(get_area(source))
	if(!zone)
		return null
	var/zone_key = REF(zone)
	var/list/known = evidence_zones[zone_key]
	if(known && known["web"] == REF(web) && world.time < known["until"] && server_of_web(known["storage"], web))
		return known["storage"]
	var/obj/machinery/power/apc/apc = zone.power_apc
	if(!evidence_queries[zone_key] && apc && SSnetdm_observe.diagnostics?.query_services(apc, apc, "research.server",
		CALLBACK(src, PROC_REF(evidence_servers_found), zone_key, WEAKREF(web)), 16))
		evidence_queries[zone_key] = TRUE
	return null

/datum/netdm_research_shadow/proc/server_of_web(storage, datum/techweb/web)
	var/datum/weakref/server_ref = storages[storage]
	var/obj/machinery/rnd/server/server = server_ref?.resolve()
	return server && server.stored_research == web

/// The closest server of the web that the zone's APC reaches; kept for a minute. Only the first page is read.
/datum/netdm_research_shadow/proc/evidence_servers_found(zone_key, datum/weakref/web_ref, list/page)
	evidence_queries -= zone_key
	var/datum/techweb/web = web_ref.resolve()
	if(!web)
		return
	var/list/search = list("best_hops" = INFINITY)
	consider_server_page(search, page, web)
	if(search["best"])
		evidence_zones[zone_key] = list("storage" = search["best"], "web" = REF(web), "until" = world.time + 60 SECONDS)
	else
		evidence_zones -= zone_key

/// remove_point_list (all amounts taken) or modify_point_list (signed amounts) under the ledger.
/datum/netdm_research_shadow/proc/ledger_change(datum/techweb/web, list/pointlist, removing)
	var/list/gained = list()
	var/list/lost = list()
	for(var/type in pointlist)
		var/amount = pointlist[type]
		if(!SSresearch.point_types[type] || !isnum(amount) || !amount)
			continue
		if(removing || amount < 0)
			lost[type] = abs(amount)
		else
			gained[type] = amount
	var/storage = treasury_of(web)
	if(length(gained))
		enqueue(list("op" = "research_grant", "payload" = list("storage" = storage, "generation" = 1, "source" = "lc-[++serial]",
			"kind" = "legacy", "points" = milli_points(gained)), "what" = "grant"))
	if(length(lost))
		enqueue(list("op" = "research_debit", "payload" = list("storage" = storage, "generation" = 1, "source" = "ld-[++serial]",
			"kind" = "legacy", "points" = milli_points(lost)), "what" = "debit"))

/**
 * Passive income under the ledger, called instead of the legacy research fire: each working server
 * earns into its own wallet. Diminishing returns count the working servers of its domain, the web it
 * belongs to, which only a deliberate relink changes; cutting the network never raises the total.
 */
/datum/netdm_research_shadow/proc/mine_servers()
	var/elapsed = world.time - (isnull(last_mine) ? world.time : last_mine)
	last_mine = world.time
	if(elapsed <= 0)
		return
	var/list/counts = list()
	for(var/obj/machinery/rnd/server/miner as anything in SSresearch.servers)
		if(miner.working && miner.stored_research)
			counts["[REF(miner.stored_research)]"]++
	var/list/grants = list()
	var/list/web_rates = list()
	for(var/obj/machinery/rnd/server/miner as anything in SSresearch.servers)
		var/storage = servers[WEAKREF(miner)]
		if(!storage || !miner.working || !miner.stored_research)
			server_rates -= storage
			continue
		var/web_key = "[REF(miner.stored_research)]"
		var/coefficient = SSresearch.calculate_server_coefficient(counts[web_key]) || 0
		var/list/mined = miner.mine()
		var/list/rate = list()
		var/list/amount = list()
		for(var/type in mined)
			rate[type] = mined[type] * coefficient
			amount[type] = rate[type] * elapsed / 10
			var/list/total = web_rates[web_key] || list()
			total[type] = (total[type] || 0) + rate[type]
			web_rates[web_key] = total
		server_rates[storage] = rate
		var/list/points = milli_points(amount)
		if(length(points))
			grants += list(list("storage" = storage, "generation" = 1, "points" = points))
	for(var/web_key in web_rates)
		var/datum/techweb/web = locate(web_key)
		if(istype(web))
			web.last_bitcoins = web_rates[web_key]
	if(length(grants))
		enqueue(list("op" = "research_income", "payload" = list("interval" = num2text(netdm_tick_of(world.time), 16), "grants" = grants),
			"what" = "income"))

// ---- Console bindings -------------------------------------------------------------------------

/**
 * The console works with the nearest server of its web until a multitool binds another one. "Nearest" is
 * what the network says (design 13.3, 14.5): the console asks the APC of its zone which research servers
 * it reaches, and takes the one of its own web with the fewest hops. A server the network does not reach
 * is not offered, however close it stands. Without an APC to ask, or without an answer, the console falls
 * back to the distance on the map; the binding is confirmed by a status round trip either way.
 * Returns a truthy value while a server is chosen or being looked for.
 */
/datum/netdm_research_shadow/proc/bind_nearest(obj/machinery/computer/rdconsole/console)
	var/datum/weakref/console_ref = WEAKREF(console)
	if(server_queries[console_ref])
		return TRUE
	var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
	var/area/zone = netdm_power_area(get_area(console))
	var/obj/machinery/power/apc/apc = zone?.power_apc
	if(node && apc && console.stored_research)
		var/list/search = list("node" = WEAKREF(node), "apc" = WEAKREF(apc), "web" = WEAKREF(console.stored_research),
			"best_hops" = INFINITY, "started" = world.realtime)
		if(request_server_page(console_ref, search, node, apc))
			server_queries[console_ref] = search
			counters["server_queries"]++
			return TRUE
	// Discovery must be answered by the network, never inferred from map distance.
	mark_no_server(console_ref, bindings[console_ref])
	return FALSE

/datum/netdm_research_shadow/proc/request_server_page(datum/weakref/console_ref, list/search, datum/component/netdm_node/node, obj/machinery/power/apc/apc, cursor)
	return SSnetdm_observe.diagnostics?.query_services(node, apc, "research.server",
		CALLBACK(src, PROC_REF(servers_found), console_ref, search), 16, cursor)

/// Keep the closest eligible server until the last page. A manual binding or a newer search takes precedence.
/datum/netdm_research_shadow/proc/servers_found(datum/weakref/console_ref, list/search, list/page)
	if(server_queries[console_ref] != search)
		return
	var/obj/machinery/computer/rdconsole/console = console_ref.resolve()
	if(QDELETED(console))
		server_queries -= console_ref
		return
	var/list/binding = bindings[console_ref]
	if(binding && storages[binding["storage"]])
		server_queries -= console_ref
		return
	var/datum/weakref/node_ref = search["node"]
	var/datum/weakref/apc_ref = search["apc"]
	var/datum/weakref/web_ref = search["web"]
	var/datum/component/netdm_node/node = node_ref.resolve()
	var/obj/machinery/power/apc/apc = apc_ref.resolve()
	var/area/zone = netdm_power_area(get_area(console))
	if(!node || node != console.GetComponent(/datum/component/netdm_node) || !apc || apc != zone?.power_apc || web_ref.resolve() != console.stored_research)
		server_queries -= console_ref
		bind_nearest(console)
		return
	var/status = page?["status"]
	if(world.realtime - search["started"] < NETDM_RESEARCH_SERVER_SEARCH_TIMEOUT)
		if(status == "partial" || status == "complete" || status == "empty")
			consider_server_page(search, page, console.stored_research)
		if(status == "partial" && page["cursor"] && page["cursor"] != search["cursor"])
			search["cursor"] = page["cursor"]
			if(request_server_page(console_ref, search, node, apc, page["cursor"]))
				return
		if((status == "snapshot_expired" || status == "invalid_cursor") && !search["restarted"])
			search["restarted"] = TRUE
			search["best"] = null
			search["best_hops"] = INFINITY
			search["cursor"] = null
			if(request_server_page(console_ref, search, node, apc))
				return
		if(status == "complete" || status == "empty")
			server_queries -= console_ref
			var/best = search["best"]
			var/datum/weakref/server_ref = storages[best]
			var/obj/machinery/rnd/server/server = server_ref?.resolve()
			if(server && server.stored_research == console.stored_research)
				counters["server_by_query"]++
				bind_server(console, best)
				return
			// An answered search found no usable server. It can be retried when the network changes.
			mark_no_server(console_ref, binding)
			return
	server_queries -= console_ref
	// An incomplete network directory is not a route. Fail closed and retry discovery later.
	mark_no_server(console_ref, binding)

/datum/netdm_research_shadow/proc/consider_server_page(list/search, list/page, datum/techweb/web)
	for(var/list/row in page?["items"])
		var/instance = row["instance"]
		if(copytext(instance, 1, 10) != "research.")
			continue
		var/storage = copytext(instance, 10)
		var/datum/weakref/server_ref = storages[storage]
		var/obj/machinery/rnd/server/server = server_ref?.resolve()
		if(!server || server.stored_research != web)
			continue
		if(row["hops"] < search["best_hops"])
			search["best_hops"] = row["hops"]
			search["best"] = storage

/datum/netdm_research_shadow/proc/mark_no_server(datum/weakref/console_ref, list/binding)
	if(!binding)
		binding = list()
		bindings[console_ref] = binding
	binding["state"] = "no_server"
	binding["bound"] = FALSE
	binding["next_status"] = world.time + 3 SECONDS

/datum/netdm_research_shadow/proc/bind_by_distance(obj/machinery/computer/rdconsole/console)
	var/best
	var/best_distance = INFINITY
	for(var/datum/weakref/server_ref as anything in servers)
		var/obj/machinery/rnd/server/server = server_ref.resolve()
		if(!server || server.stored_research != console.stored_research)
			continue
		var/distance = get_dist(console, server) + (server.z == console.z ? 0 : 1000)
		if(distance < best_distance)
			best_distance = distance
			best = servers[server_ref]
	if(best)
		bind_server(console, best)
	return best

/**
 * Binds a console to a server. The binding is confirmed only by a status round trip over the network:
 * copying a server's address gives no rights and reaches nothing by itself.
 */
/datum/netdm_research_shadow/proc/bind_server(obj/machinery/computer/rdconsole/console, storage)
	bindings[WEAKREF(console)] = list("storage" = storage, "bound" = FALSE, "state" = "connecting", "available" = 0,
		"revision" = 0, "unlocked" = 0, "updated" = null, "next_status" = 0, "busy" = null)

/// Sends the due status round trips; a console without an answer for a while shows the link as lost.
/datum/netdm_research_shadow/proc/refresh_bindings()
	for(var/datum/weakref/console_ref as anything in bindings)
		var/obj/machinery/computer/rdconsole/console = console_ref.resolve()
		var/list/binding = bindings[console_ref]
		if(QDELETED(console))
			bindings -= console_ref
			continue
		if(world.time < binding["next_status"])
			continue
		if(!storages[binding["storage"]])
			// The server is gone: its wallet is lost, the console looks for another server of its web.
			if(!bind_nearest(console))
				mark_no_server(console_ref, binding)
			continue
		binding["next_status"] = world.time + (binding["bound"] ? NETDM_RESEARCH_STATUS : 3 SECONDS)
		if(!isnull(binding["updated"]) && world.time > binding["updated"] + 3 * NETDM_RESEARCH_STATUS)
			binding["state"] = "no_answer"
		var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
		var/list/entry = node && SSnetdm_observe.services.invoke(node, "research.[binding["storage"]]", "status", "st-[++serial]",
			list("reason" = binding["bound"] ? "refresh" : "open"), CALLBACK(src, PROC_REF(status_accepted), console_ref))
		if(!entry && !binding["bound"])
			binding["state"] = "no_link"

/datum/netdm_research_shadow/proc/status_accepted(datum/weakref/console_ref, list/entry, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		status_keys["[value["operationId"]]"] = console_ref
	else
		var/list/binding = bindings[console_ref]
		if(binding && !binding["bound"])
			binding["state"] = "host_[reply["error"] || "refused"]"

/// A status answer crossed the network back: the binding is confirmed and the console shows fresh data.
/datum/netdm_research_shadow/proc/status_answered(obj/machinery/computer/rdconsole/console, list/item)
	var/datum/weakref/console_ref = status_keys["[item["operationId"]]"]
	status_keys -= "[item["operationId"]]"
	var/list/binding = console_ref ? bindings[console_ref] : null
	var/list/payload = item["payload"]
	if(!binding || !islist(payload))
		return TRUE
	binding["bound"] = TRUE
	binding["state"] = payload["state"]
	binding["available"] = netdm_number(payload["available"])
	binding["revision"] = netdm_number(payload["revision"])
	binding["unlocked"] = netdm_number(payload["unlocked"])
	binding["updated"] = world.time
	return TRUE

/// The multitool carries a server's address from the server to a console of the same web.
/datum/netdm_research_shadow/proc/multitool(atom/parent, mob/user, obj/item/multitool/tool)
	if(istype(parent, /obj/machinery/rnd/server))
		var/storage = servers[WEAKREF(parent)]
		if(storage)
			multitool_servers[WEAKREF(tool)] = storage
		return FALSE // The legacy buffer copy still happens.
	var/obj/machinery/computer/rdconsole/console = parent
	if(!istype(console) || !owns(console.stored_research))
		return FALSE
	var/storage = multitool_servers[WEAKREF(tool)]
	var/datum/weakref/server_ref = storage ? storages[storage] : null
	var/obj/machinery/rnd/server/server = server_ref?.resolve()
	if(!server || server.stored_research != console.stored_research)
		return FALSE
	bind_server(console, storage)
	to_chat(user, span_notice("Консоль подключается к серверу [uppertext(server.server_id)]: ждёт ответа по сети."))
	return TRUE

// ---- Purchases under the ledger ---------------------------------------------------------------

/// The ledger's price on a storage: the exported cost less the best boost sent there, never below zero.
/datum/netdm_research_shadow/proc/price_of(storage, node_id)
	if(isnull(catalog_costs[node_id]))
		return null
	var/list/known = storage ? storage_boosts[storage] : null
	return max(0, catalog_costs[node_id] - (known ? (known[node_id] || 0) : 0))

/// The console buys on its bound server; the answer arrives over the network later.
/datum/netdm_research_shadow/proc/console_research(obj/machinery/computer/rdconsole/console, datum/techweb/web, node_id, mob/user)
	var/list/binding = bindings[WEAKREF(console)]
	if(!binding)
		bind_nearest(console)
		binding = bindings[WEAKREF(console)]
	if(!binding || !binding["bound"])
		console.say("Нет связи с R&D-сервером: консоль ждёт ответа сервера по сети.")
		return FALSE
	if(binding["busy"])
		console.say("Сервер ещё обрабатывает предыдущий запрос.")
		return FALSE
	var/storage = binding["storage"]
	var/price = price_of(storage, node_id)
	var/datum/techweb_node/node = SSresearch.techweb_node_by_id(node_id)
	var/datum/component/netdm_node/console_node = console.GetComponent(/datum/component/netdm_node)
	if(isnull(price) || !istype(node) || !console_node)
		console.say("Node unlock failed: Unknown error.")
		return FALSE
	var/key = "ra-[++serial]"
	var/list/entry = SSnetdm_observe.services.invoke(console_node, "research.[storage]", "research", key,
		list("node" = node_id, "quote" = price), CALLBACK(src, PROC_REF(purchase_accepted), key))
	if(!entry)
		console.say("Нет связи с R&D-сервером.")
		return FALSE
	binding["busy"] = key
	counters["purchases"]++
	purchases[key] = list("node" = node_id, "price" = price, "storage" = storage, "queued_us" = netdm_now_us(),
		"created" = world.time, "authoritative" = TRUE, "console" = WEAKREF(console), "web" = "[REF(web)]",
		"user" = key_name(user), "name" = node.display_name)
	console.say("Запрос на исследование [node.display_name] отправлен на сервер ([price] очков).")
	return TRUE

/**
 * The ledger's answer, as it reached the console over the network: it tells the player the outcome.
 * What a purchase changes in the world is its effect (settle_effect): it is applied here when the answer
 * arrives, or from the ledger's outbox when the answer was lost, and once either way.
 */
/datum/netdm_research_shadow/proc/finish_purchase(list/purchase, outcome, list/payload, key)
	var/datum/weakref/console_ref = purchase["console"]
	var/obj/machinery/computer/rdconsole/console = console_ref?.resolve()
	var/list/binding = console_ref ? bindings[console_ref] : null
	if(binding && binding["busy"] == key)
		binding["busy"] = null
	if(binding && islist(payload))
		binding["available"] = netdm_number(payload["available"])
		binding["revision"] = netdm_number(payload["revision"])
		binding["updated"] = world.time
	mismatch_reasons["ledger_[outcome]"]++
	var/datum/techweb/web = locate(purchase["web"])
	var/node_id = purchase["node"]
	switch(outcome)
		if("researched")
			counters["matched"]++
			settle_effect("[purchase["storage"]]/[key]", purchase["storage"], node_id, netdm_number(payload?["price"]), key, purchase)
			console?.say("Successfully researched [purchase["name"]].")
		if("already_researched")
			// The server knows the node from a sync, a disk or an earlier purchase: only the projection follows.
			if(istype(web) && !web.researched_nodes[node_id])
				project_node(web, node_id)
			console?.say("Сервер уже знает [purchase["name"]].")
		if("insufficient_points")
			console?.say("Недостаточно очков в сети: нужно [purchase["price"]], доступно [netdm_number(payload?["available"])].")
		if("quote_changed")
			console?.say("Цена изменилась: [netdm_number(payload?["price"])] очков. Повторите запрос.")
		if("prerequisites_missing")
			console?.say("Сервер не знает предпосылок [purchase["name"]].")
		if("no_answer")
			var/settled = settled_effects["[purchase["storage"]]/[key]"]
			if(settled && settled != "shadow")
				// The outbox was faster than the answer that then got lost: the purchase is already in the world.
				console?.say("Сервер подтвердил исследование [purchase["name"]].")
				return
			// The server may have bought it all the same: the ledger's outbox tells, and is asked at once.
			if(length(unanswered) >= NETDM_RESEARCH_UNANSWERED)
				unanswered.Cut(1, 2)
			unanswered[key] = purchase
			next_effects = 0
			console?.say("Сервер не ответил. Повторный запрос безопасен: дважды очки не спишутся.")
		else
			console?.say("Сервер недоступен ([outcome]).")

// ---- World effects of purchases (§13.5) -------------------------------------------------------
//
// A purchase and what it owes the world are one record of the Host ledger. The ledger keeps the
// obligation, across its own restarts, until this world reports how it settled it. So a lost answer
// loses neither the unlock that lathes read nor the bounty, and no delivery repeats them: an effect
// is applied by its ID once for the round.

/**
 * Applies the effect of a committed purchase unless this world already did, and queues the report.
 * Results: "paid" and "unpaid" (applied, with or without a bounty), "shadow" (the legacy web applied
 * the purchase itself), "void" (the world has no web left to apply it to) and "failed" (applying it
 * raised a runtime error).
 */
/datum/netdm_research_shadow/proc/settle_effect(id, storage, node_id, price, key, list/purchase)
	if(settled_effects[id])
		return FALSE
	// At most once: the effect is marked before it is applied. A runtime error below returns null here,
	// and the next delivery of the same effect must not pay the bounty a second time.
	settled_effects[id] = "failed"
	var/result = apply_effect(storage, node_id, price, key, purchase) || "failed"
	settled_effects[id] = result
	if(result == "failed")
		note("effect [id] failed to apply")
		log_world("netDM research: the effect [id] of a purchase raised a runtime error and is not applied again.")
	effect_acks += list(list("id" = id, "result" = result))
	next_effects = 0
	return TRUE

/datum/netdm_research_shadow/proc/apply_effect(storage, node_id, price, key, list/purchase)
	// Only a purchase this world started under the ledger ("ra-" keys) changes the world; a mirrored
	// legacy purchase ("rc-") was applied and paid by the legacy web when it was made.
	if(!authoritative || copytext("[key]", 1, 4) != "ra-")
		return "shadow"
	var/datum/techweb/web = locate(purchase ? purchase["web"] : storage_webs[storage])
	if(!istype(web))
		return "void"
	effect_counters["applied"]++
	if(!web.researched_nodes[node_id])
		project_node(web, node_id)
	var/paid = pay_bounty(web)
	var/datum/weakref/console_ref = purchase?["console"]
	var/obj/machinery/computer/rdconsole/console = console_ref?.resolve()
	var/datum/weakref/server_ref = storages[storage]
	var/atom/logger = console || server_ref?.resolve()
	var/datum/techweb_node/node = SSresearch.techweb_node_by_id(node_id)
	var/user = purchase?["user"] || "unknown"
	web.research_logs += list(list(purchase?["name"] || node?.display_name || node_id, price, user,
		console ? "[get_area(console)] ([console.x],[console.y],[console.z])" : "?"))
	logger?.investigate_log("[user] researched [node_id] for [price] on server [storage].", INVESTIGATE_RESEARCH)
	return paid ? "paid" : "unpaid"

/// The ledger's knowledge reaches the legacy web that lathes read; nothing is paid and nothing mirrored back.
/datum/netdm_research_shadow/proc/project_node(datum/techweb/web, node_id)
	applying_projection++
	web.research_node_id(node_id, TRUE, FALSE)
	applying_projection--
	SSresearch.on_node_researched(node_id, web)
	SEND_GLOBAL_SIGNAL(COMSIG_GLOB_RESEARCH_NODE_UNLOCKED, node_id)

/// The science bounty of a purchase. settle_effect is its only caller, once per effect; replication,
/// imports and syncs pay none.
/datum/netdm_research_shadow/proc/pay_bounty(datum/techweb/web)
	if(!web.pays_research_bounty)
		return FALSE
	var/datum/bank_account/account = SSeconomy.get_dep_account(ACCOUNT_SCI)
	if(!account)
		return FALSE
	account.adjust_money(SSeconomy.techweb_bounty)
	return TRUE

/// Reports settled effects and asks the ledger's outbox for those still owed: one request in flight,
/// at once while something waits and every NETDM_RESEARCH_EFFECTS otherwise.
/datum/netdm_research_shadow/proc/pump_effects(datum/netdm_service_lane/lane)
	if(effects_inflight || world.time < next_effects || (!length(storage_domains) && !length(effect_acks)))
		return
	var/list/batch = effect_acks.Copy(1, min(length(effect_acks), NETDM_RESEARCH_SETTLE_BATCH) + 1)
	if(!lane.control("research_effects", list("settle" = batch, "max" = 16), CALLBACK(src, PROC_REF(effects_answered), batch)))
		return
	effect_acks.Cut(1, length(batch) + 1)
	effects_inflight = TRUE

/datum/netdm_research_shadow/proc/effects_answered(list/batch, list/reply)
	effects_inflight = FALSE
	var/list/result = reply["result"]
	var/list/owed = islist(result) ? result["effects"] : null
	if(!reply["ok"] || !islist(owed))
		// No ledger yet or a failed journal: the settlements wait and are reported again. A Host without
		// an outbox is not asked again in this session; purchases are then settled by their answers only.
		effect_acks.Insert(1, batch)
		next_effects = world.time + NETDM_RESEARCH_RETRY
		if(reply["error"] == "Unknown operation.")
			effects_inflight = TRUE
			note("the Host has no purchase outbox: effects follow the answers only")
		return
	for(var/list/effect in owed)
		var/id = effect["id"]
		var/known = settled_effects[id]
		if(known)
			// Settled here, but the ledger does not know: the report was lost with a reply or a Host process.
			var/queued = FALSE
			for(var/list/ack in effect_acks)
				if(ack["id"] == id)
					queued = TRUE
					break
			if(!queued)
				effect_acks += list(list("id" = id, "result" = known))
				effect_counters["reported_again"]++
			continue
		var/key = effect["op"]
		var/list/lost = unanswered[key]
		if(!settle_effect(id, effect["storage"], effect["node"], netdm_number(effect["price"]), key, purchases[key] || lost))
			continue
		if(!lost)
			continue // The answer is still on its way to the console and will tell the player.
		unanswered -= key
		effect_counters["recovered"]++
		note("purchase [effect["node"]] settled from the outbox: [settled_effects[id]]")
		var/datum/weakref/console_ref = lost["console"]
		var/obj/machinery/computer/rdconsole/console = console_ref?.resolve()
		if(settled_effects[id] != "shadow")
			console?.say("Сервер подтвердил исследование [lost["name"]]: ответ был потерян, покупка учтена.")
	next_effects = (length(effect_acks) || netdm_number(result["pending"]) > length(owed)) ? 0 : world.time + NETDM_RESEARCH_EFFECTS

/// The legacy balance of each web becomes the sum of its servers' wallets: shown, never spent.
/datum/netdm_research_shadow/proc/projected(list/reply)
	compare_inflight = FALSE
	var/list/result = reply["result"]
	var/list/rows = islist(result) ? result["storages"] : null
	if(!reply["ok"] || !islist(rows))
		return
	var/list/sums = list()
	for(var/list/row in rows)
		note_knowledge(row)
		var/datum/weakref/server_ref = storages[row["storage"]]
		var/obj/machinery/rnd/server/server = server_ref?.resolve()
		if(!server?.stored_research)
			continue
		var/list/available = row["availableMilli"]
		var/web_key = "[REF(server.stored_research)]"
		sums[web_key] = (sums[web_key] || 0) + netdm_number(islist(available) ? available[TECHWEB_POINT_TYPE_GENERIC] : 0) / NETDM_RESEARCH_MILLI
	for(var/web_key in treasuries)
		var/datum/techweb/web = locate(web_key)
		if(istype(web))
			web.research_points[TECHWEB_POINT_TYPE_GENERIC] = round(sums[web_key] || 0, 0.01)

// ---- Knowledge projection (§13.6, §13.8) --------------------------------------------------------
//
// Under the ledger a server's knowledge is the ledger's, and the legacy web its machines read holds the
// union of what its servers know. A purchase tells the web through its effect. Everything else that
// teaches a server (a restored disk, a peer, an import) is read here from the server's own log. The
// answer to the console that asked is a message to the player: losing it loses no knowledge.

/// The periodic state names the last record of each storage's knowledge log; anything after what its
/// web holds is fetched. A ledger that started over (a lost journal) is read from its beginning.
/datum/netdm_research_shadow/proc/note_knowledge(list/row)
	var/storage = row["storage"]
	if(!storages[storage] || !storage_webs[storage])
		return
	var/known = netdm_number(row["knowledge"])
	var/upto = knowledge_upto[storage] || 0
	if(known == upto)
		return
	if(known < upto)
		knowledge_upto[storage] = 0
	knowledge_due |= storage

/// One request in flight: the next page of the first storage whose log is ahead of its web.
/datum/netdm_research_shadow/proc/pump_knowledge(datum/netdm_service_lane/lane)
	if(knowledge_inflight || !length(knowledge_due) || world.time < next_knowledge)
		return
	var/storage = knowledge_due[1]
	if(lane.control("research_knowledge", list("storage" = storage, "since" = num2text(knowledge_upto[storage] || 0, 16),
		"max" = NETDM_RESEARCH_KNOWLEDGE_PAGE), CALLBACK(src, PROC_REF(knowledge_answered), storage)))
		knowledge_inflight = TRUE

/datum/netdm_research_shadow/proc/knowledge_answered(storage, list/reply)
	knowledge_inflight = FALSE
	var/list/result = reply["result"]
	var/list/nodes = islist(result) ? result["nodes"] : null
	if(!reply["ok"] || !islist(nodes))
		switch(reply["error"])
			if("Unknown operation.")
				// A Host without the log is not asked again in this session: the web follows the answers only.
				knowledge_inflight = TRUE
				note("the Host has no knowledge log: the legacy web follows the answers only")
			if("storage_unavailable")
				knowledge_due -= storage // Destroyed or never registered: nothing of it is left to project.
			else
				next_knowledge = world.time + NETDM_RESEARCH_RETRY
		return
	if(!storages[storage])
		knowledge_due -= storage
		return
	var/datum/techweb/web = locate(storage_webs[storage])
	if(istype(web) && !owns(web))
		// Between coordinators: the web waits for its next server, and the other storages go first.
		knowledge_due -= storage
		knowledge_due += storage
		next_knowledge = world.time + NETDM_RESEARCH_RETRY
		return
	if(istype(web))
		for(var/node_id in nodes)
			if(web.researched_nodes[node_id] || !SSresearch.techweb_node_by_id(node_id))
				continue
			project_node(web, node_id)
			counters["projected"]++
	knowledge_upto[storage] = netdm_number(result["upto"])
	if(!result["more"])
		knowledge_due -= storage

/// The console window under the ledger: the bound server's wallet, income, freshness and prices.
/datum/netdm_research_shadow/proc/console_ui(obj/machinery/computer/rdconsole/console, list/data)
	var/datum/techweb/web = console.stored_research
	if(!owns(web))
		return
	var/list/binding = bindings[WEAKREF(console)]
	var/storage = binding?["storage"]
	var/available = binding?["available"] || 0
	var/list/rate = storage ? server_rates[storage] : null
	data["points"] = list(TECHWEB_POINT_TYPE_GENERIC = available)
	data["points_last_tick"] = list(TECHWEB_POINT_TYPE_GENERIC = round(rate ? (rate[TECHWEB_POINT_TYPE_GENERIC] || 0) : 0, 0.1))
	var/datum/weakref/server_ref = storage ? storages[storage] : null
	var/obj/machinery/rnd/server/server = server_ref?.resolve()
	var/age = isnull(binding?["updated"]) ? null : round((world.time - binding["updated"]) / 10)
	data["web_org"] = "[web.organization] · сервер [server ? uppertext(server.server_id) : "не выбран"]: [binding?["state"] || "нет связи"]\
		[isnull(age) ? "" : ", данные [age] с назад"]"
	for(var/list/row in data["nodes"])
		var/price = price_of(storage, row["id"])
		if(isnull(price))
			continue
		row["costs"] = list(TECHWEB_POINT_TYPE_GENERIC = price)
		row["can_unlock"] = binding?["bound"] && available >= price

/datum/netdm_effect_handler/research_status/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/computer/rdconsole) || !SSnetdm_observe.research)
		return "not_a_console"
	return SSnetdm_observe.research.status_answered(target, item)

// ---- Knowledge sync between servers (P6, §13.6) -------------------------------------------------
//
// Every server pulls the knowledge log of every peer of its domain over the network. The answer reaches
// the pulling server's node and is committed to its storage; points, income and charges never travel.

/// Starts the due pulls: one request per pair in flight, every NETDM_RESEARCH_SYNC or at once when more waits.
/datum/netdm_research_shadow/proc/schedule_sync()
	for(var/datum/weakref/dest_ref as anything in servers)
		var/obj/machinery/rnd/server/destination = dest_ref.resolve()
		var/dest_storage = servers[dest_ref]
		if(!destination?.stored_research || !storage_domains[dest_storage])
			continue
		for(var/datum/weakref/source_ref as anything in servers)
			var/source_storage = servers[source_ref]
			if(source_storage == dest_storage || storage_domains[source_storage] != storage_domains[dest_storage])
				continue
			var/pair = "[dest_storage]<-[source_storage]"
			var/list/sync = sync_pairs[pair]
			if(!sync)
				sync = list("source" = source_storage, "destination" = dest_storage, "watermark" = 0, "next" = 0, "busy" = FALSE)
				sync_pairs[pair] = sync
			if(sync["busy"] || world.time < sync["next"])
				continue
			sync["next"] = world.time + NETDM_RESEARCH_SYNC
			var/datum/component/netdm_node/node = destination.GetComponent(/datum/component/netdm_node)
			if(node && SSnetdm_observe.services.invoke(node, "research.[source_storage]", "sync", "sy-[++serial]",
				list("since" = sync["watermark"]), null))
				sync["busy"] = TRUE

/// A peer's knowledge reached the pulling server: commit it to that server's storage, in order.
/datum/netdm_research_shadow/proc/sync_answered(obj/machinery/rnd/server/destination, list/item)
	var/dest_storage = servers[WEAKREF(destination)]
	var/source_storage = copytext(item["instance"], length("research.") + 1)
	var/list/sync = sync_pairs["[dest_storage]<-[source_storage]"]
	var/list/payload = item["payload"]
	if(!sync || !islist(payload))
		return TRUE
	var/list/nodes = splittext(payload["nodes"], ",")
	nodes -= ""
	var/list/boosts = list()
	for(var/pair in splittext(payload["boosts"], ";"))
		var/list/parts = splittext(pair, "=")
		if(length(parts) == 2)
			boosts[parts[1]] = text2num(parts[2])
	var/list/body = list("storage" = dest_storage, "generation" = 1, "peer" = source_storage,
		"upto" = num2text(netdm_number(payload["upto"]), 16), "nodes" = nodes)
	if(length(boosts))
		body["boosts"] = boosts
	enqueue(list("op" = "research_replicate", "payload" = body, "what" = "replicate", "pair" = "[dest_storage]<-[source_storage]",
		"more" = payload["more"]))
	return TRUE

/// The ledger committed a batch: the pair moves its watermark, and pulls again at once when more waits.
/datum/netdm_research_shadow/proc/replicated(list/entry, list/reply)
	var/list/sync = sync_pairs[entry["pair"]]
	if(!sync)
		return
	sync["busy"] = FALSE
	var/list/result = reply["result"]
	if(reply["ok"] && islist(result))
		sync["watermark"] = netdm_number(result["watermark"])
		if(netdm_number(result["added"]))
			counters["replicated"] += netdm_number(result["added"])
	if(entry["more"])
		sync["next"] = 0

// ---- Shared account (decided 12.11.2026) -------------------------------------------------------
//
// A console spends the points of every server of its network that its server reaches: the Host
// passes them as payers of the purchase and answers the status with their sum. No points are moved
// by hand; a server cut off by the network, or destroyed, holds its points out of the account.

// ---- Backup disks (P6, §13.8) -----------------------------------------------------------------

/// A tech disk gets its ledger ID the first time a server writes to it.
/obj/item/disk/tech_disk
	var/netdm_disk

/**
 * Disk buttons of a console under the ledger. "loadTech" writes the bound server's knowledge to the
 * inserted disk; "uploadDisk" restores a written disk into the bound server, without points or bounty.
 * A disk never written by a server (loot, legacy) keeps the legacy path.
 *
 * What a written disk holds is what the ledger wrote on it (decision of 14.11.2026): its legacy copy is not
 * written and not read. A restore teaches the server those nodes, and the web its machines read learns
 * them from the server's knowledge log. A console outside the ledger cannot read such a disk.
 */
/datum/netdm_research_shadow/proc/console_disk(obj/machinery/computer/rdconsole/console, action, list/params)
	if(action == "uploadDisk" && params?["type"] == "tech" && !owns(console.stored_research))
		var/obj/item/disk/tech_disk/foreign_disk = console.t_disk
		if(istype(foreign_disk) && foreign_disk.netdm_disk)
			console.say("Диск записан R&D-сервером сети: загрузить его можно только через сервер сети.")
			return TRUE
		return FALSE
	if(!owns(console.stored_research) || (action != "loadTech" && !(action == "uploadDisk" && params?["type"] == "tech")))
		return FALSE
	var/obj/item/disk/tech_disk/disk = console.t_disk
	if(QDELETED(disk))
		console.say("No tech disk inserted!")
		return TRUE
	if(action == "uploadDisk" && !disk.netdm_disk)
		console.say("Диск не содержит сетевой резервной копии. Локальная загрузка в общую базу отключена.")
		return TRUE
	var/list/binding = bindings[WEAKREF(console)]
	var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
	if(!binding?["bound"] || !node)
		console.say("Нет связи с R&D-сервером.")
		return TRUE
	if(!disk.netdm_disk)
		disk.netdm_disk = "disk-[++serial]-[copytext(md5("[world.time][rand()]"), 1, 7)]"
	var/command = action == "loadTech" ? "backup" : "restore"
	var/key = "dk-[++serial]"
	if(!SSnetdm_observe.services.invoke(node, "research.[binding["storage"]]", command, key, list("disk" = disk.netdm_disk), null))
		console.say("Нет связи с R&D-сервером.")
		return TRUE
	disk_ops["[disk.netdm_disk]/[command]"] = list("console" = WEAKREF(console), "disk" = WEAKREF(disk))
	console.say(command == "backup" ? "Запись знаний сервера на диск..." : "Загрузка диска на сервер...")
	return TRUE

/datum/netdm_research_shadow/proc/disk_answered(obj/machinery/computer/rdconsole/console, list/item)
	var/list/payload = item["payload"]
	var/list/op = islist(payload) ? disk_ops["[payload["disk"]]/[item["command"]]"] : null
	if(!op)
		return TRUE
	disk_ops -= "[payload["disk"]]/[item["command"]]"
	var/state = payload["state"]
	counters["disk_[state]"]++
	switch(state)
		if("written", "unchanged")
			if(item["command"] == "backup")
				// The ledger holds what is on the disk; a legacy copy would carry the whole web's knowledge.
				console.say("Знания сервера записаны на диск ([netdm_number(payload["nodes"])] узлов).")
			else
				console.say("Диск уже загружен на этот сервер.")
		if("restored")
			// The legacy web learns exactly the disk's nodes the ledger restored, from the server's knowledge log.
			var/list/binding = bindings[WEAKREF(console)]
			var/storage = binding?["storage"]
			if(storage && storages[storage])
				knowledge_due |= storage
				next_knowledge = world.time
			console.say("Диск загружен на сервер: новых узлов [netdm_number(payload["nodes"])].")
		else
			console.say("Сервер отклонил операцию с диском ([payload["reason"] || state]).")
	return TRUE

/datum/netdm_effect_handler/research_sync/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/rnd/server) || !SSnetdm_observe.research)
		return "not_a_server"
	return SSnetdm_observe.research.sync_answered(target, item)

/datum/netdm_effect_handler/research_disk/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/computer/rdconsole) || !SSnetdm_observe.research)
		return "not_a_console"
	return SSnetdm_observe.research.disk_answered(target, item)

// ---- Catalog ---------------------------------------------------------------------------------

/// The catalog as DM defines it: prerequisites, designs and costs of every node. Built once, before
/// boosts ever ran: legacy get_price rewrites node costs in place, so later reads are not the content.
/datum/netdm_research_shadow/proc/build_catalog()
	catalog_chunks = list()
	var/list/types = list()
	for(var/type in SSresearch.point_types)
		types += type
	var/catalog_id = "cat-[copytext(md5("[world.timeofday][rand()]"), 1, 9)]"
	var/list/nodes = list()
	var/size = 0
	for(var/id in SSresearch.techweb_nodes)
		var/datum/techweb_node/node = SSresearch.techweb_nodes[id]
		var/list/prereqs = list()
		for(var/prereq in node.prereq_ids)
			prereqs += prereq
		var/list/designs = list()
		for(var/design in node.design_ids)
			designs += design
		var/list/costs = whole_points(node.research_costs)
		catalog_costs[id] = costs[TECHWEB_POINT_TYPE_GENERIC] || 0
		var/list/row = list("id" = id, "prereqs" = prereqs, "designs" = designs, "costs" = costs,
			"starting" = !!node.starting_node, "hidden" = !!(SSresearch.techweb_nodes_hidden[id]), "experimental" = !!node.experimental)
		var/row_size = length(json_encode(row))
		if(length(nodes) && size + row_size > NETDM_RESEARCH_CHUNK_BYTES)
			catalog_chunks += list(list("catalog" = catalog_id, "pointTypes" = types, "nodes" = nodes))
			nodes = list()
			size = 0
		nodes += list(row)
		size += row_size
	catalog_chunks += list(list("catalog" = catalog_id, "pointTypes" = types, "nodes" = nodes))
	for(var/i in 1 to length(catalog_chunks))
		var/list/chunk = catalog_chunks[i]
		chunk["chunk"] = i - 1
		chunk["chunks"] = length(catalog_chunks)

// ---- Helpers ---------------------------------------------------------------------------------

/// Positive amounts of known point types as milli-point text.
/datum/netdm_research_shadow/proc/milli_points(list/points)
	. = list()
	for(var/type in points)
		var/amount = points[type]
		if(SSresearch.point_types[type] && isnum(amount) && amount > 0)
			.[type] = num2text(round(amount * NETDM_RESEARCH_MILLI), 16)

/datum/netdm_research_shadow/proc/whole_points(list/points)
	. = list()
	for(var/type in points)
		var/amount = points[type]
		if(SSresearch.point_types[type] && isnum(amount) && amount > 0)
			.[type] = round(amount)

/datum/netdm_research_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > 256)
		samples.Cut(1, 2)

/datum/netdm_research_shadow/proc/note(text)
	notes += text
	if(length(notes) > 16)
		notes.Cut(1, 2)

/// Everything the Host was asked to mirror has been confirmed, the catalog is installed, and no event of
/// a web the ledger would take over was lost or refused. Authority never switches over an incomplete
/// mirror: the legacy balance would be projected away without the ledger holding its points.
/datum/netdm_research_shadow/proc/synchronized()
	return catalog_ready && !sending && !length(outbox) && !mirror_lost

/datum/netdm_research_shadow/proc/state()
	var/list/reasons = list()
	for(var/reason in mismatch_reasons)
		reasons += "[reason]:[mismatch_reasons[reason]]"
	return "research mode=[authoritative ? "ledger" : "shadow"] mirror=[mirror_lost ? "incomplete" : "complete"] \
		catalog=[catalog_error ? "refused" : (catalog_ready ? copytext(catalog_hash, 1, 13) : "[catalog_next - 1]/[length(catalog_chunks)]")] \
		storages=[length(storages)] treasuries=[length(treasuries)] outbox=[length(outbox)] events=[counters["events"]] \
		confirmed=[counters["confirmed"]] rejected=[counters["rejected"]] dropped=[counters["dropped"]] unmirrored=[counters["unmirrored"]] \
		purchases=[counters["purchases"]] matched=[counters["matched"]] mismatched=[counters["mismatched"]] unanswered=[counters["unanswered"]] \
		effects=[length(settled_effects)]/applied:[effect_counters["applied"]]/recovered:[effect_counters["recovered"]]/unreported:[length(effect_acks)] \
		knowledge=projected:[counters["projected"]]/due:[length(knowledge_due)] \
		p50=[percentile_of(0.5)]ms drift=[isnull(last_drift) ? "-" : round(last_drift, 0.01)] max_drift=[round(max_drift, 0.01)] \
		reasons=[jointext(reasons, ",")]"

/datum/netdm_research_shadow/proc/percentile_of(fraction)
	if(!length(latencies))
		return null
	var/list/sorted = sortTim(latencies.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return round(sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))] / 1000, 0.1)

/// A number from the Host: 64-bit integers arrive as decimal text.
/proc/netdm_number(value)
	if(isnum(value))
		return value
	return istext(value) ? (text2num(value) || 0) : 0

/datum/netdm_effect_handler/research_answer/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/computer/rdconsole) || !SSnetdm_observe.research)
		return "not_a_console"
	return SSnetdm_observe.research.purchase_answered(target, item)

/**
 * The runtime station has an R&D console but no server: without one the legacy web earns nothing and
 * the research pilot has no storage. Under Observe, and only on that map, a server is placed next to
 * the console so tests and the stand can check research end to end.
 */
/proc/netdm_spawn_stand_rnd_server()
	if(SSmapping.config?.map_name != "Runtime Station" || length(SSresearch.servers))
		return null
	var/obj/machinery/computer/rdconsole/console = locate(/obj/machinery/computer/rdconsole) in GLOB.machines
	if(!console)
		return null
	for(var/range in 1 to 3)
		for(var/turf/open/floor/spot in orange(range, console))
			if(spot.is_blocked_turf(TRUE))
				continue
			var/obj/machinery/rnd/server/server = new(spot)
			log_world("netDM research: R&D server placed at [spot.x],[spot.y],[spot.z] next to [console] for the runtime station.")
			return server
	return null

#undef NETDM_RESEARCH_MILLI
#undef NETDM_RESEARCH_OUTBOX
#undef NETDM_RESEARCH_CHUNK_BYTES
#undef NETDM_RESEARCH_COMPARE
#undef NETDM_RESEARCH_ANSWER_TIMEOUT
#undef NETDM_RESEARCH_RETRY
#undef NETDM_RESEARCH_PROJECTION
#undef NETDM_RESEARCH_STATUS
#undef NETDM_RESEARCH_EFFECTS
#undef NETDM_RESEARCH_UNANSWERED
#undef NETDM_RESEARCH_SETTLE_BATCH
#undef NETDM_RESEARCH_KNOWLEDGE_PAGE
#undef NETDM_RESEARCH_SERVER_SEARCH_TIMEOUT
#undef NETDM_RESEARCH_SYNC
