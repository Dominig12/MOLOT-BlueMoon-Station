/// «Семя ИИ»: вставленное в сервер данных, порождает сетевую сущность для призрака
/obj/item/netrun_seed
	name = "AI seed shard"
	desc = "Кристалл с недоразвитой нейросетевой матрицей. В сервере данных из неё может вырасти самостоятельный сетевой процесс."
	icon = 'icons/obj/module.dmi'
	icon_state = "datadisk3"
	w_class = WEIGHT_CLASS_TINY

/obj/machinery/netrun_server
	/// Сколько семян ждут призраков
	var/seeds = 0

/obj/machinery/netrun_server/attackby(obj/item/I, mob/living/user, params)
	if(istype(I, /obj/item/netrun_seed))
		if(!is_operational())
			to_chat(user, span_warning("Сервер обесточен."))
			return TRUE
		if(!user.temporarilyRemoveItemFromInventory(I))
			return TRUE
		qdel(I)
		seeds++
		to_chat(user, span_notice("Вы вставляете семя в [src]. Индикаторы начинают мерцать в неровном ритме."))
		var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
		node?.network?.add_log("На узле [node.address] запущен самообучающийся процесс.")
		notify_ghosts("В [src] ([get_area_name(src, TRUE)]) зарождается сетевая сущность.", source = src, action = NOTIFY_ATTACK, ghost_sound = 'sound/machines/chime.ogg', header = "Сетевая сущность")
		return TRUE
	return ..()

/obj/machinery/netrun_server/examine(mob/user)
	. = ..()
	if(seeds)
		. += span_notice("Индикаторы мерцают: внутри зреет сетевой процесс.")

/obj/machinery/netrun_server/attack_ghost(mob/dead/observer/user)
	. = ..()
	if(. || !seeds)
		return
	spawn_entity(user)

/obj/machinery/netrun_server/proc/spawn_entity(mob/dead/observer/user)
	if(!seeds || !is_operational() || QDELETED(user) || jobban_isbanned(user, ROLE_POSIBRAIN))
		return
	if(!user.can_reenter_round())
		return
	if(alert(user, "Стать сетевой сущностью? Вы будете жить в сети станции и сможете говорить через машины.", "Сетевая сущность", "Да", "Нет") != "Да")
		return
	if(!seeds || !is_operational() || QDELETED(user) || QDELETED(src))
		return
	var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
	if(!node)
		return
	seeds--
	var/mob/camera/netrun_entity/entity = new(get_turf(src), node)
	var/entity_name = "PROC-[uppertext(copytext(md5("[world.time][rand(1, 99999)]"), 1, 5))]"
	entity.name = entity_name
	entity.real_name = entity_name
	entity.ckey = user.ckey
	to_chat(entity, span_boldnotice("Вы — сетевая сущность, рождённая в [src]. Вы не антагонист: исследуйте, общайтесь, помогайте или торгуйтесь — \
		но помните, что экипаж может вычистить вас из любой машины. Законы сервера никто не отменял."))
	log_game("NETRUN: [key_name(entity)] стал сетевой сущностью в [AREACOORD(src)]")
	node.network?.add_log("Процесс [entity_name] вышел на связь.")
