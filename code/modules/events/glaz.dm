/datum/round_event_control/glaz
	name = "Пришествие G̴̯͊͗L̵̢̹͓̮͓̅̇̇A̴̹̖̘͗̈̃̔́Z̸͙̒"
	typepath = /datum/round_event/glaz
	weight = 1
	max_occurrences = 1
	category = EVENT_CATEGORY_APOCALYPSE
	description = "G̴̯͊͗L̵̢̹͓̮͓̅̇̇A̴̹̖̘͗̈̃̔́Z̸͙̒ обращает свой взор на эту вселенную, желая ее пожрать"
	earliest_start = 60 MINUTES
	min_players = 60
	start_when = 10 MINUTES
	end_when = 30 MINUTES

/datum/round_event/glaz/start()
	for(var/mob/M in GLOB.player_list)
		M.playsound_local(src,'sound/hallucinations/i_see_you1.ogg', 25)

/datum/round_event/glaz/tick()
	for(var/mob/M in GLOB.player_list)

/datum/round_event/glaz/proc/phase2()

/datum/round_event/glaz/proc/phase3()

