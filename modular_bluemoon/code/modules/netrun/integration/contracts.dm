/// Export receipts are server-owned capabilities. Text, names and disk UIDs are not proof.
/datum/netrun_data_receipt
	var/datum/weakref/issuer_ref
	var/category
	var/list/values
	var/redeemed = FALSE

/datum/netrun_data_receipt/New(datum/mind/issuer, category, list/values)
	issuer_ref = WEAKREF(issuer)
	src.category = category
	src.values = values.Copy()

/datum/netrun_file
	/// Copies share this exact receipt, including its spent state.
	var/datum/netrun_data_receipt/data_receipt

/datum/component/netrun_broker_account
	var/list/technologies = list()
	var/list/accesses = list()
	var/research_points = 0
	var/paid_tc = 0
	var/list/original_access = list()
	var/list/own_card_refs = list()
	var/identity_name

/datum/component/netrun_broker_account/Initialize()
	if(!istype(parent, /datum/mind))
		return COMPONENT_INCOMPATIBLE
	var/datum/mind/principal = parent
	identity_name = principal.name || principal.current?.real_name
	if(principal.current)
		original_access = netrun_mob_access(principal.current).Copy()
		var/obj/item/card/id/card = principal.current.get_idcard(FALSE)
		if(card)
			own_card_refs += WEAKREF(card)

/datum/component/netrun_broker_account/proc/owns_card(obj/item/card/id/card)
	if(identity_name && card.registered_name == identity_name)
		return TRUE
	for(var/datum/weakref/reference as anything in own_card_refs)
		if(reference.resolve() == card)
			return TRUE
	return FALSE

/datum/component/netrun_broker_account/proc/units(category)
	switch(category)
		if("technology")
			return length(technologies)
		if("access")
			return length(accesses)
		if("research")
			return research_points
	return 0

/datum/netrun_console/proc/broker_mind()
	var/datum/mind/principal = personal_faction_principal()
	return istype(principal) && !QDELETED(principal) ? principal : null

/// Remember pre-contract identity: taking off an ID cannot turn its rights into foreign loot.
/datum/netrun_console/proc/broker_foreign_access(datum/component/netrun_node/node, list/values)
	var/datum/mind/principal = broker_mind()
	var/datum/component/netrun_broker_account/account = principal?.LoadComponent(/datum/component/netrun_broker_account)
	var/list/eligible = values.Copy()
	eligible -= user_access(TRUE)
	eligible -= account?.original_access
	var/atom/source = node.parent
	for(var/obj/item/card/id/card as anything in source.netrun_credential_cards())
		if(account?.owns_card(card))
			eligible -= card.GetAccess()
	return eligible

/// Only actual unauthorized exports from station equipment can carry a receipt.
/datum/netrun_console/proc/stamp_data_export(datum/netrun_file/file, datum/component/netrun_node/node, category, list/values)
	var/datum/mind/issuer = broker_mind()
	var/turf/location = node?.physical_turf()
	if(!issuer || !location || !is_station_level(location.z) || compute_legit_node_level(node, TRUE) >= NETRUN_ACCESS_USER)
		return
	var/list/eligible = values.Copy()
	if(category == "access")
		var/mob/living/carbon/victim = node.parent
		if(istype(node.parent, /obj/effect/netrun_endpoint/neural))
			var/obj/effect/netrun_endpoint/neural/endpoint = node.parent
			victim = endpoint.interface?.host_mob
		if(istype(victim) && victim.netrun_personal_principal() == issuer)
			return
		eligible = broker_foreign_access(node, values)
	else
		var/obj/machinery/rnd/server/server = node.parent
		if(!istype(server) || !server.netrun_mapped_server || server.research_network_id() != RND_NETWORK_STATION)
			return
	if(length(eligible))
		file.data_receipt = new(issuer, category, eligible)

/// No sleeps: validation, spending the receipt/payload and crediting the uplink are atomic.
/datum/netrun_console/proc/broker_sell()
	var/datum/mind/seller = broker_mind()
	var/datum/antagonist/traitor/role = seller?.has_antag_datum(/datum/antagonist/traitor)
	if(!role || QDELETED(role.uplink) || QDELETED(role.uplink.parent) || role.uplink.owner != seller.key)
		return "Брокер: нужен действующий контракт трейтора и его аплинк."
	if(is_locked() || !has_uplink())
		return "Брокер недоступен: восстановите соединение с NTnet."
	var/datum/netrun_file/file = selected_local_file()
	var/datum/netrun_data_receipt/receipt = file?.data_receipt
	if(!receipt || receipt.redeemed || receipt.issuer_ref?.resolve() != seller)
		return "Выберите собственную ещё не сданную выгрузку: rnd_grab, rnd_siphon или extract_credentials. Подделки и повторная сдача не принимаются."
	var/datum/component/netrun_broker_account/account = seller.LoadComponent(/datum/component/netrun_broker_account)
	var/list/novel = list()
	var/points = 0
	switch(receipt.category)
		if("technology")
			for(var/id in receipt.values)
				if(!(id in account.technologies))
					novel |= id
		if("access")
			for(var/id in receipt.values)
				if(!(id in account.accesses))
					novel |= id
		if("research")
			var/datum/netrun_file/research_points/data = file
			if(!istype(data) || !length(data.payload?.points))
				return "Эта выгрузка очков уже погашена."
			for(var/id in data.payload.points)
				points += data.payload.points[id]
	if(!length(novel) && !points)
		return "Брокер уже получил эти технологии или доступы. Нужны новые данные."
	if(points)
		var/datum/netrun_file/research_points/data = file
		data.payload.consume()
		account.research_points += points
	else if(receipt.category == "technology")
		account.technologies |= novel
	else
		account.accesses |= novel
	receipt.redeemed = TRUE
	// A round cap bounds passive R&D harvesting; novelty is shared across every source and copy.
	var/earned = min(6, FLOOR(length(account.technologies) / 3, 1) + FLOOR(length(account.accesses) / 5, 1) + FLOOR(account.research_points / 1000, 1))
	var/reward = max(0, earned - account.paid_tc)
	account.paid_tc += reward
	role.uplink.telecrystals += reward
	SStgui.update_uis(role.uplink)
	log_game("NETRUN BROKER: [key_name(seller.current)] submitted [receipt.category], received [reward] TC (round total [account.paid_tc]).")
	return "Брокер принял данные. Выплата: [reward] TC; всего [account.paid_tc]/6 TC. Новые технологии: [length(account.technologies)], доступы: [length(account.accesses)], очки: [account.research_points]."

/datum/netrun_cli_command/broker
	id = "broker"
	args = "status|sell"
	desc = "Контрактный брокер: статус или сдача выбранной выгрузки в аплинк трейтора."
	category = "Файлы"

/datum/netrun_cli_command/broker/execute(datum/netrun_console/console, list/words, raw)
	if(words[2] == "sell")
		console.log_line(console.broker_sell())
		return
	var/datum/mind/principal = console.broker_mind()
	var/datum/component/netrun_broker_account/account = principal?.GetComponent(/datum/component/netrun_broker_account)
	console.log_line("Брокер: выберите выгрузку в памяти/на шарде, затем broker sell. За 3 новые технологии, 5 новых чужих доступов или 1000 изъятых очков — 1 TC; максимум 6 TC за раунд. Получено: [account?.paid_tc || 0]/6 TC.")
	console.log_line("Принято: [length(account?.technologies)] технологий, [length(account?.accesses)] доступов, [account?.research_points || 0] очков исследований.")

/obj/item/netrun_deck/contract
	name = "contract cyberdeck"

/obj/item/netrun_deck/contract/Initialize(mapload)
	. = ..()
	for(var/id in list("autobreach", "icepick", "cloak"))
		console.store_file(netrun_daemon_file(id))
	console.store_file(new /datum/netrun_file("contract.txt", NETRUN_FILE_TEXT, "Ваша цель указана в задачах трейтора. Взломайте научный сервер либо чужой источник ID-данных. rnd_grab копирует технологии, rnd_siphon изымает очки, extract_credentials копирует ID. Выберите выгрузку в памяти и выполните broker sell при рабочем NTnet. Повторные копии не оплачиваются. Способности взлома не дают разрешения игнорировать остальные задачи."))

/datum/objective/netrun_exfiltrate
	name = "netrun data exfiltration"
	var/category = "research"
	target_amount = 1000
	var/list/special_items_given = list()

/datum/objective/netrun_exfiltrate/New()
	. = ..()
	configure(category, target_amount)

/datum/objective/netrun_exfiltrate/proc/configure(new_category, amount)
	category = new_category
	target_amount = amount
	var/label = category == "technology" ? "различные технологии" : category == "access" ? "различных чужих ID-доступов" : "очков исследований"
	explanation_text = "Взломайте оборудование станции и сдайте контрактному брокеру [target_amount] [label]. Выберите выгрузку в памяти кибердеки и выполните broker sell при рабочем NTnet. Стартовая дека выдана; сдача копий и собственных доступов не засчитывается."

/datum/objective/netrun_exfiltrate/check_completion()
	var/datum/component/netrun_broker_account/account = owner?.GetComponent(/datum/component/netrun_broker_account)
	return completed || (account && account.units(category) >= target_amount)

/datum/objective/netrun_exfiltrate/admin_edit(mob/admin)
	var/choice = tgui_input_list(admin, "Вид добычи", "Сетевая эксфильтрация", list("research", "technology", "access"))
	if(!choice)
		return
	configure(choice, choice == "research" ? 1000 : choice == "technology" ? 3 : 5)
	if(!length(special_items_given))
		special_items_given = give_special_equipment(list(/obj/item/netrun_deck/contract))

/datum/objective/netrun_exfiltrate/Destroy(force, ...)
	QDEL_LIST(special_items_given)
	return ..()

/// Normal human traitors only, at most one objective and only with a real station source.
/datum/traitor_class/proc/try_forge_netrun_objective(datum/antagonist/traitor/role)
	if(!role.should_equip || !ishuman(role.owner?.current) || (locate(/datum/objective/netrun_exfiltrate) in role.objectives) || (role.owner.assigned_role in list("Research Director", "Scientist", "Roboticist")))
		return FALSE
	var/found = FALSE
	var/relay_found = FALSE
	var/list/categories = list()
	var/datum/netrun_console/probe = new(role.owner.current)
	probe.operator = role.owner.current
	role.owner.LoadComponent(/datum/component/netrun_broker_account)
	for(var/address in SSnetrun.nodes_by_address)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		var/obj/machinery/rnd/server/server = node.parent
		var/turf/location = node.physical_turf()
		if(istype(node.parent, /obj/machinery/ntnet_relay) && location && is_station_level(location.z) && node.is_online())
			relay_found = TRUE
		if(probe.compute_legit_node_level(node, TRUE) >= NETRUN_ACCESS_USER)
			continue
		if(istype(server) && server.netrun_mapped_server && server.stored_research && server.research_network_id() == RND_NETWORK_STATION && location && is_station_level(location.z))
			found = TRUE
			categories |= "research"
			if(length(server.stored_research.researched_nodes) >= 3)
				categories |= "technology"
		else if(location && is_station_level(location.z))
			var/atom/source = node.parent
			var/list/foreign = source.netrun_credential_access()
			if(length(foreign))
				foreign = probe.broker_foreign_access(node, foreign)
				if(length(foreign) >= 5)
					found = TRUE
					categories |= "access"
	qdel(probe)
	if(!found || !relay_found)
		return FALSE
	var/datum/objective/netrun_exfiltrate/objective = new
	objective.owner = role.owner
	var/category = pick(categories)
	objective.configure(category, category == "research" ? 1000 : category == "technology" ? 3 : 5)
	role.add_objective(objective)
	objective.special_items_given = objective.give_special_equipment(list(/obj/item/netrun_deck/contract))
	return TRUE
