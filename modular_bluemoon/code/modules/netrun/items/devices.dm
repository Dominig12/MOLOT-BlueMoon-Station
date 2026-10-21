// MARK: Кибердека

/// Переносной терминал нетраннера. Работает по NTnet или проводом, воткнутым в машину рядом.
/obj/item/netrun_deck
	name = "cyberdeck"
	desc = "Плоский переносной терминал с выдвижным кабелем. Воткните кабель в машину рядом, чтобы подключиться к её локальной сети напрямую."
	icon = 'icons/obj/device.dmi'
	icon_state = "hand_tele"
	w_class = WEIGHT_CLASS_SMALL
	slot_flags = ITEM_SLOT_BELT
	var/datum/netrun_console/console
	var/buffer_bonus = 0
	var/storage_capacity = 8
	/// Дека перегорела от ответного удара и до этого времени не работает
	var/burnt_until = 0

/obj/item/netrun_deck/Initialize(mapload)
	. = ..()
	console = new(src, NETRUN_ORIGIN_DECK)
	console.connection.wireless = TRUE
	console.intrusion.buffer_bonus = buffer_bonus
	console.inventory.local_store.capacity = storage_capacity
	console.tgui_title = "Кибердека"
	AddComponent(/datum/component/netrun_access_device, console, NETRUN_NODE_DECK)

/obj/item/netrun_deck/Destroy()
	QDEL_NULL(console)
	return ..()

/obj/item/netrun_deck/examine(mob/user)
	. = ..()
	if(world.time < burnt_until)
		. += span_warning("Из корпуса тянет горелой изоляцией. Ещё [round((burnt_until - world.time) / (1 SECONDS))] сек.")
	if(console?.connection.jack)
		. += span_notice("Кабель подключён к [console.connection.jack.get_name()].")
	. += span_notice("Буфер взлома: +[buffer_bonus]. Память: [console ? netrun_storage_used(console.inventory.local_store.files) : 0]/[storage_capacity].")

/obj/item/netrun_deck/attack_self(mob/user)
	if(world.time < burnt_until)
		to_chat(user, span_warning("[src] не включается."))
		return
	console.ui_interact(user)

/obj/item/netrun_deck/attackby(obj/item/I, mob/living/user, params)
	if(istype(I, /obj/item/netrun_shard))
		console.insert_shard(I, user)
		return TRUE
	return ..()

/obj/item/netrun_deck/afterattack(atom/target, mob/user, proximity_flag, click_parameters)
	. = ..()
	if(!proximity_flag || world.time < burnt_until)
		return
	var/datum/component/netrun_node/node = netrun_find_node(target)
	if(!node)
		return
	if(console.connection.jack == node)
		console.set_jack(null)
		to_chat(user, span_notice("Вы выдёргиваете кабель из [target]."))
		return
	to_chat(user, span_notice("Вы ищете сервисный порт на [target]..."))
	if(!do_after(user, 3 SECONDS, target = target))
		return
	console.set_jack(node)
	console.log_line("Кабель подключён: [node.get_name()] [node.address].", "good")
	to_chat(user, span_notice("Кабель [src] входит в порт [target]."))
	playsound(target, 'sound/machines/click.ogg', 40, TRUE)
	console.ui_interact(user)

/obj/item/netrun_deck/netrun_traced(datum/netrun_console/traced)
	burnt_until = world.time + NETRUN_TRACE_LOCKOUT
	console.set_jack(null)
	do_sparks(3, TRUE, src)
	var/mob/living/holder = loc
	if(istype(holder))
		to_chat(holder, span_danger("[src] искрит и обжигает пальцы!"))
		holder.adjustFireLoss(5)
	SStgui.close_uis(console)

/obj/item/netrun_deck/advanced
	name = "military cyberdeck"
	desc = "Деку в армированном корпусе явно делали не для бухгалтерии. Больше памяти, шире буфер."
	icon_state = "hand_tele"
	color = "#7fbfff"
	buffer_bonus = 1
	storage_capacity = 16

// MARK: Нейролинк

/// Имплант прямого подключения: беспроводной доступ к сети из головы и погружение
/obj/item/organ/cyberimp/brain/netlink
	name = "neural netlink implant"
	desc = "Нейроинтерфейс прямого подключения к сети. Позволяет работать с сетью без терминала и полностью погружаться в неё."
	icon_state = "brain_implant"
	implant_color = "#4a9eff"
	slot = "brain_netlink"
	actions_types = list(/datum/action/item_action/organ_action/netrun_console, /datum/action/item_action/organ_action/netrun_dive)
	var/datum/netrun_console/console

/obj/item/organ/cyberimp/brain/netlink/Initialize(mapload)
	. = ..()
	console = new(src, NETRUN_ORIGIN_IMPLANT)
	console.connection.wireless = TRUE
	console.inventory.local_store.capacity = 6
	console.state_override = GLOB.conscious_state
	console.tgui_title = "Нейролинк"
	AddComponent(/datum/component/netrun_access_device, console, NETRUN_NODE_IMPLANT)

/obj/item/organ/cyberimp/brain/netlink/Destroy()
	QDEL_NULL(console)
	return ..()

/obj/item/organ/cyberimp/brain/netlink/Remove(special = FALSE)
	if(console)
		SStgui.close_uis(console)
	return ..()

/obj/item/organ/cyberimp/brain/netlink/ui_action_click(mob/user, actiontype)
	if(!owner || owner != user)
		return
	if(istype(actiontype, /datum/action/item_action/organ_action/netrun_dive) || ispath(actiontype, /datum/action/item_action/organ_action/netrun_dive))
		try_dive()
		return
	console.ui_interact(owner)

/obj/item/organ/cyberimp/brain/netlink/proc/try_dive()
	var/datum/component/netrun_node/node = console.selected_node()
	if(!node)
		to_chat(owner, span_warning("Выберите узел для погружения в интерфейсе нейролинка."))
		return
	if(!node.is_online() || console.node_level(node) < NETRUN_ACCESS_USER)
		to_chat(owner, span_warning("Для погружения нужен доступ пользователя к узлу [node.address]."))
		return
	if(owner.stat != CONSCIOUS)
		return
	to_chat(owner, span_notice("Вы закрываете глаза и проваливаетесь в сеть..."))
	if(!do_after(owner, 3 SECONDS, target = owner))
		return
	if(!node.is_online() || console.node_level(node) < NETRUN_ACCESS_USER)
		return
	var/mob/camera/netrun_entity/entity = netrun_start_dive(owner, node)
	if(entity)
		// Доступы, добытые нейролинком, переходят в погружение
		entity.console.access_session.node_access = console.access_session.node_access.Copy()
		entity.console.access_session.network_access = console.access_session.network_access.Copy()

/obj/item/organ/cyberimp/brain/netlink/netrun_traced(datum/netrun_console/traced)
	if(!owner)
		return
	to_chat(owner, span_userdanger("Ответный импульс системы защиты прошивает нейролинк!"))
	owner.adjustOrganLoss(ORGAN_SLOT_BRAIN, 15)
	owner.Paralyze(4 SECONDS)
	owner.emote("scream")
	SStgui.close_uis(console)

/datum/action/item_action/organ_action/netrun_console
	name = "Нейролинк"
	desc = "Открыть интерфейс сети."

/datum/action/item_action/organ_action/netrun_dive
	name = "Погружение"
	desc = "Оставить тело и уйти в выбранный узел сети."
