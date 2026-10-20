/datum/techweb_node/netrunning
	id = "netrunning"
	display_name = "Сетевая инфраструктура"
	description = "Проводные терминалы, серверы данных и инструменты для работы с локальными сетями станции."
	prereq_ids = list("comptech", "datatheory")
	design_ids = list("netrun_terminal", "netrun_server", "netrun_shard", "netrun_deck")
	research_costs = list(TECHWEB_POINT_TYPE_GENERIC = 2000)

/datum/techweb_node/netrunning_neural
	id = "netrunning_neural"
	display_name = "Нейросетевые интерфейсы"
	description = "Прямое подключение нервной системы к сети и выращивание самообучающихся сетевых процессов."
	prereq_ids = list("netrunning", "cyber_implants")
	design_ids = list("ci-netlink", "netrun_seed", "netrun_deck_advanced")
	research_costs = list(TECHWEB_POINT_TYPE_GENERIC = 4000)

/datum/design/board/netrun_terminal
	name = "Computer Design (Network Terminal)"
	desc = "Плата проводного терминала локальной сети."
	id = "netrun_terminal"
	build_path = /obj/item/circuitboard/computer/netrun_terminal
	category = list("Computer Boards")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE

/datum/design/board/netrun_server
	name = "Machine Design (Data Server)"
	desc = "Плата стойки хранения данных."
	id = "netrun_server"
	build_path = /obj/item/circuitboard/machine/netrun_server
	category = list("Research Machinery")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE

/datum/design/netrun_shard
	name = "Data Shard"
	desc = "Переносной носитель для сетевых файлов."
	id = "netrun_shard"
	build_type = PROTOLATHE
	materials = list(/datum/material/glass = 300, /datum/material/silver = 100)
	build_path = /obj/item/netrun_shard
	category = list("Computer Parts")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE

/datum/design/netrun_deck
	name = "Cyberdeck"
	desc = "Переносной терминал с кабелем прямого подключения."
	id = "netrun_deck"
	build_type = PROTOLATHE
	materials = list(/datum/material/iron = 1500, /datum/material/glass = 1000, /datum/material/gold = 300)
	build_path = /obj/item/netrun_deck
	category = list("Computer Parts")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE

/datum/design/netrun_deck_advanced
	name = "Military Cyberdeck"
	desc = "Дека с расширенным буфером и памятью."
	id = "netrun_deck_advanced"
	build_type = PROTOLATHE
	materials = list(/datum/material/iron = 2000, /datum/material/glass = 1500, /datum/material/gold = 600, /datum/material/diamond = 200)
	build_path = /obj/item/netrun_deck/advanced
	category = list("Computer Parts")
	departmental_flags = DEPARTMENTAL_FLAG_SCIENCE

/datum/design/cyberimp_netlink
	name = "Neural Netlink Implant"
	desc = "Имплант прямого подключения к сети."
	id = "ci-netlink"
	build_type = PROTOLATHE | MECHFAB
	construction_time = 60
	materials = list(/datum/material/iron = 600, /datum/material/glass = 600, /datum/material/silver = 500, /datum/material/gold = 500)
	build_path = /obj/item/organ/cyberimp/brain/netlink
	category = list("Implants")
	departmental_flags = DEPARTMENTAL_FLAG_MEDICAL | DEPARTMENTAL_FLAG_SCIENCE

/datum/design/netrun_seed
	name = "AI Seed Shard"
	desc = "Кристалл с зачатком самообучающегося сетевого процесса."
	id = "netrun_seed"
	build_type = PROTOLATHE
	materials = list(/datum/material/glass = 1000, /datum/material/gold = 1000, /datum/material/diamond = 500, /datum/material/bluespace = 500)
	build_path = /obj/item/netrun_seed
	category = list("Computer Parts")
	departmental_flags = DEPARTMENTAL_FLAG_SCIENCE
