/// Build a real, separately reserved floor scene; no renderer or visibility stubs.
/datum/unit_test/proc/netrun_photo_scene(side)
	var/datum/turf_reservation/scene = SSmapping.RequestBlockReservation(side + 2, side + 2, border_type_override = /turf/closed/wall)
	allocated += scene
	for(var/turf/T as anything in scene.reserved_turfs.Copy())
		if(T.x == scene.bottom_left_coords[1] || T.y == scene.bottom_left_coords[2] || T.x == scene.top_right_coords[1] || T.y == scene.top_right_coords[2])
			continue
		T.ChangeTurf(/turf/open/floor/plasteel)
	return scene

/datum/unit_test/proc/netrun_photo_color_icon(color)
	var/icon/tile = icon('icons/effects/effects.dmi', "nothing")
	tile.DrawBox(color, 1, 1, world.icon_size, world.icon_size)
	return tile

/// Distinct real appearances must not share a recycled temporary appearance-ref cache slot.
/datum/unit_test/netrun_photo_distinct_scene_pixels/Run()
	var/datum/turf_reservation/scene = netrun_photo_scene(3)
	var/turf/center = locate(scene.bottom_left_coords[1] + 2, scene.bottom_left_coords[2] + 2, scene.bottom_left_coords[3])
	var/list/turfs = list()
	var/list/expected = list()
	var/index = 0
	for(var/dy = -1 to 1)
		for(var/dx = -1 to 1)
			index++
			var/turf/T = locate(center.x + dx, center.y + dy, center.z)
			var/icon/tile = netrun_photo_color_icon(rgb(20 + index * 20, 30 + (index % 3) * 55, 200 - index * 12))
			T.icon = tile
			T.icon_state = ""
			T.color = null
			T.overlays.Cut()
			T.underlays.Cut()
			turfs += T
			expected[T] = tile.GetPixel(16, 16)
			// Mix floors and solid objects: the original bug duplicated both kinds.
			if(index == 3 || index == 7)
				var/obj/item/marker = allocate(/obj/item, T)
				var/icon/marker_icon = netrun_photo_color_icon(index == 3 ? "#ff22cc" : "#22ddff")
				marker.icon = marker_icon
				marker.icon_state = ""
				marker.pixel_x = 0
				marker.pixel_y = 0
				expected[T] = marker_icon.GetPixel(16, 16)
	var/obj/item/camera/netrun_capture/capture = allocate(/obj/item/camera/netrun_capture, center)
	var/datum/turf_reservation/clones = SSmapping.RequestBlockReservation(3, 3)
	allocated += clones
	var/side = 3 * world.icon_size
	var/icon/cloned = capture.camera_get_icon(turfs, center, side, side, clones, 1, 1, 3, 3)
	var/icon/direct = capture.camera_get_icon(turfs, center, side, side, null, 1, 1, 3, 3)
	TEST_ASSERT_NOTNULL(cloned, "The real clone capture must produce an image")
	TEST_ASSERT_NOTNULL(direct, "The direct capture must produce an image")
	var/list/distinct = list()
	for(var/turf/T as anything in turfs)
		var/px = (T.x - center.x + 1) * world.icon_size + 16
		var/py = (T.y - center.y + 1) * world.icon_size + 16
		TEST_ASSERT_EQUAL(cloned.GetPixel(px, py), expected[T], "Clone capture duplicated another appearance at tile [T.x - center.x],[T.y - center.y]")
		TEST_ASSERT_EQUAL(direct.GetPixel(px, py), expected[T], "Direct capture duplicated another appearance at tile [T.x - center.x],[T.y - center.y]")
		distinct[cloned.GetPixel(px, py)] = TRUE
	TEST_ASSERT_EQUAL(length(distinct), 9, "Nine deliberately different scene tiles must remain nine different pixel samples")

/// The configured camera range determines real pixels, file capacity and the printed photo.
/datum/unit_test/netrun_photo_full_range_file_and_print/Run()
	var/datum/turf_reservation/scene = netrun_photo_scene(19)
	var/turf/center = locate(scene.bottom_left_coords[1] + 10, scene.bottom_left_coords[2] + 10, scene.bottom_left_coords[3])
	var/obj/machinery/camera/camera = allocate(/obj/machinery/camera, center)
	camera.set_machine_stat(0)
	camera.status = TRUE
	camera.view_range = 7
	camera.mark_visibility_dirty()
	var/turf/far_turf = locate(center.x + 6, center.y, center.z)
	var/obj/item/marker = allocate(/obj/item, far_turf)
	var/icon/marker_icon = netrun_photo_color_icon("#ff22cc")
	marker.icon = marker_icon
	marker.icon_state = ""
	marker.pixel_x = 0
	marker.pixel_y = 0
	var/obj/item/host = allocate(/obj/item, center)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/component/netrun_node/node = camera.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_NOTNULL(node, "The security camera must be a real network node")
	TEST_ASSERT(far_turf in camera.get_visible_turfs(), "The distant marker must be in the camera's actual view")
	var/datum/netrun_command/command = SSnetrun.get_command("cam_photo")
	console.inventory.local_store.capacity = 3
	command.execute(node, console)
	TEST_ASSERT_EQUAL(length(console.inventory.local_store.files), 0, "A full-range frame must not bypass its calculated memory requirement")
	TEST_ASSERT(!camera.netrun_photographing && camera.netrun_next_photo == 0, "Insufficient memory must fail before exposing a frame or starting cooldown")
	console.inventory.local_store.capacity = 4
	command.execute(node, console)
	var/datum/netrun_file/file = console.selected_local_file(NETRUN_FILE_PHOTO)
	TEST_ASSERT_NOTNULL(file, "Capturing a working camera must produce a selected photo file")
	TEST_ASSERT_NOTNULL(file.picture, "The photo file must own a real picture datum")
	TEST_ASSERT_EQUAL(file.picture.psize_x, 15 * world.icon_size, "Radius seven means fifteen turfs, not seven or three")
	TEST_ASSERT_EQUAL(file.picture.psize_y, 15 * world.icon_size, "The full configured vertical range must be retained")
	TEST_ASSERT_EQUAL(file.picture.picture_image.Width(), file.picture.psize_x, "Stored pixel width must match the declared full-size frame")
	TEST_ASSERT_EQUAL(file.picture.picture_image.Height(), file.picture.psize_y, "Stored pixel height must match the declared full-size frame")
	TEST_ASSERT_EQUAL(file.size, 4, "A 225-turf frame must account for four 64-turf memory cells")
	var/px = (7 + 6) * world.icon_size + 16
	var/py = 7 * world.icon_size + 16
	TEST_ASSERT_EQUAL(file.picture.picture_image.GetPixel(px, py), marker_icon.GetPixel(16, 16), "A visible object six turfs away must appear in the saved image")

	var/obj/item/modular_computer/laptop/computer = allocate(/obj/item/modular_computer/laptop, center)
	computer.enabled = TRUE
	var/obj/item/computer_hardware/printer/printer = allocate(/obj/item/computer_hardware/printer, center)
	computer.install_component(printer)
	TEST_ASSERT_EQUAL(printer.holder, computer, "The printer must be installed through the real hardware system")
	var/paper_before = printer.stored_paper
	var/datum/component/netrun_node/computer_node = computer.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_command/print_command = SSnetrun.get_command("pc_print")
	print_command.execute(computer_node, console)
	TEST_ASSERT_EQUAL(printer.stored_paper, paper_before - 1, "Printing the selected photograph must consume real paper")
	var/obj/item/photo/printed = locate(/obj/item/photo) in center
	TEST_ASSERT_NOTNULL(printed, "The hardware printer must produce an actual photo item")
	TEST_ASSERT_NOTEQUAL(printed.picture, file.picture, "A printed photo must have independent picture ownership")
	TEST_ASSERT_EQUAL(printed.picture.picture_image.GetPixel(px, py), marker_icon.GetPixel(16, 16), "Printing must preserve the distant marker's real pixels")
	console.delete_local_file(file)
	TEST_ASSERT(!QDELETED(printed.picture), "Deleting the saved file must not invalidate the physical photograph")
	TEST_ASSERT_EQUAL(printed.picture.picture_image.Width(), 15 * world.icon_size, "The printed full-size photograph must survive removal of its source file")

/// Capture uses the source camera's normal/XRay visibility instead of a temporary item's view.
/datum/unit_test/netrun_photo_camera_visibility/Run()
	var/datum/turf_reservation/scene = netrun_photo_scene(7)
	var/turf/center = locate(scene.bottom_left_coords[1] + 4, scene.bottom_left_coords[2] + 4, scene.bottom_left_coords[3])
	for(var/dy = -3 to 3)
		var/turf/occluder = locate(center.x + 1, center.y + dy, center.z)
		occluder.ChangeTurf(/turf/closed/wall)
	var/obj/machinery/camera/camera = allocate(/obj/machinery/camera, center)
	camera.set_machine_stat(0)
	camera.status = TRUE
	camera.view_range = 2
	camera.mark_visibility_dirty()
	var/turf/behind_wall = locate(center.x + 2, center.y, center.z)
	var/obj/item/marker = allocate(/obj/item, behind_wall)
	var/icon/marker_icon = netrun_photo_color_icon("#ff22cc")
	marker.icon = marker_icon
	marker.icon_state = ""
	marker.pixel_x = 0
	marker.pixel_y = 0
	TEST_ASSERT(!(behind_wall in camera.get_visible_turfs()), "An ordinary camera must not see through the separating wall")
	var/obj/item/camera/netrun_capture/normal = allocate(/obj/item/camera/netrun_capture, center)
	normal.captureimage(camera, null, FALSE, camera.netrun_photo_radius(), camera.netrun_photo_radius(), camera.get_visible_turfs().Copy())
	TEST_ASSERT_NOTNULL(normal.result, "Normal camera capture must produce a real picture")
	TEST_ASSERT_EQUAL(normal.result.picture_image.Width(), 5 * world.icon_size, "A deliberately reduced radius two must produce a five-turf frame")
	var/px = 4 * world.icon_size + 16
	var/py = 2 * world.icon_size + 16
	TEST_ASSERT_NOTEQUAL(normal.result.picture_image.GetPixel(px, py), marker_icon.GetPixel(16, 16), "An occluded marker must not leak into the normal camera snapshot")
	camera.upgradeXRay()
	TEST_ASSERT(behind_wall in camera.get_visible_turfs(), "The real XRay upgrade must expose the previously hidden tile")
	var/obj/item/camera/netrun_capture/xray = allocate(/obj/item/camera/netrun_capture, center)
	xray.captureimage(camera, null, FALSE, camera.netrun_photo_radius(), camera.netrun_photo_radius(), camera.get_visible_turfs().Copy())
	TEST_ASSERT_NOTNULL(xray.result, "XRay camera capture must produce a real picture")
	TEST_ASSERT_EQUAL(xray.result.picture_image.GetPixel(px, py), marker_icon.GetPixel(16, 16), "An XRay camera must preserve its own visible pixels beyond the wall")
	camera.view_range = 100
	TEST_ASSERT_EQUAL(camera.netrun_photo_radius(), 10, "Oversized camera ranges must respect the rendering work cap")
	TEST_ASSERT_EQUAL(camera.netrun_photo_storage_size(), 7, "The capped frame must still be charged for its actual area")
