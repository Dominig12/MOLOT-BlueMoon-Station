/obj/item/nanite_injector
	name = "nanite injector (FOR TESTING)"
	desc = "Injects nanites into the user."
	w_class = WEIGHT_CLASS_SMALL
	icon = 'icons/obj/device.dmi'
	icon_state = "nanite_remote"

/obj/item/nanite_injector/attack_self(mob/user)
	user.AddComponent(/datum/component/nanites, 150)

/obj/item/implant/nanite_pump
	name = "nanite pump"
	desk = "This device looks like a pump with an input and output and functions as a small nanomachine factory, a filter for spent nanomachines, and a similar reprogrammer that restores damaged programs. However, without constant updates and reprocessing, these programs are short-lived."
	var/datum/component/nanites/nanite_pump/pump_nanites = null
	var/set_program_cloud = 0
	var/periodic_sync = 15 SECONDS
	var/next_sync

/obj/item/implant/nanite_pump/Initialize(mapload)
	. = ..()
	pump_nanites = AddComponent(/datum/component/nanites/nanite_pump)

/obj/item/implant/nanite_pump/implant(mob/living/target, mob/user, silent, force)
	. = ..()
	if(!.)
		return

	var/volume = 0
	if(SEND_SIGNAL(target, COMSIG_HAS_NANITES))
		volume = SEND_SIGNAL(target, COMSIG_NANITE_GET_VOLUME)
		SEND_SIGNAL(target, COMSIG_NANITE_DELETE)

	target.AddComponent(/datum/component/nanites/nanite_pump, volume)
	START_PROCESSING(SSobj, src)
	next_sync = world.time + periodic_sync

/obj/item/implant/nanite_pump/removed(mob/living/source, silent, special)
	. = ..()
	STOP_PROCESSING(SSobj, src)
	var/volume = SEND_SIGNAL(source, COMSIG_NANITE_GET_VOLUME)
	SEND_SIGNAL(source, COMSIG_NANITE_DELETE)
	source.AddComponent(/datum/component/nanites, volume)
	SEND_SIGNAL(source, COMSIG_NANITE_SET_REGEN, -50)

/obj/item/implant/nanite_pump/activate()
	. = ..()
	if(set_program_cloud)
		to_chat(imp_in, "<span class='warning'>Невозможно установить новое программное обеспечение</span>")
		return
	var/cloud_id = input("Установите облако с которого будут скачены программы в имплант. Это можно сделать ОДИН РАЗ", "ID облака") as num|null
	if(cloud_id)
		var/datum/nanite_cloud_backup/backup = SSnanites.get_cloud_backup(cloud_id)
		if(!backup)
			to_chat(imp_in, "<span class='warning'>Сервер не отвечает на запрос, попробуйте позже</span>")
			return
		set_program_cloud = cloud_id
		SEND_SIGNAL(pump_nanites, COMSIG_NANITE_SYNC, backup)

		for(var/X in actions)
			var/datum/action/A = X
			A.Remove(imp_in)

		activated = FALSE
		sync_nanites()

/obj/item/implant/nanite_pump/process(delta_time)
	if(world.time < next_sync)
		return

	next_sync = world.time + periodic_sync
	sync_nanites()

/obj/item/implant/nanite_pump/proc/sync_nanites()
	SEND_SIGNAL(imp_in, COMSIG_NANITE_SYNC, pump_nanites)

/obj/item/implantcase/nanite_pump
	name = "implant case - 'Nanite Pump'"
	desc = "A glass case containing an nanite pump implant."
	imp_type = /obj/item/implant/nanite_pump
