/datum/neural_interface_module
	var/name = "EMPTY MODULE"
	var/datum/component/neural_interface/owner
	var/visible = TRUE

/datum/neural_interface_module/New(datum/component/neural_interface/owner)
	. = ..()
	owner = owner

/datum/neural_interface_module/proc/UpdateVision(mob/user)
	return TRUE
