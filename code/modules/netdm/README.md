# NetDM module for BlueMoon SS13 (net-feature-new)

## Device topology (automatic)

The game network models **station APC areas**, not the power cable
structure. All normal /obj/machinery instances automatically get an
endpoint; embedded power terminals are skipped, since their APC is the
actual network node.

- **APC**: fixed wired endpoint, member of the sparse station backbone.
  Existing APCs connect into a deterministic (Z, Y, X)-ordered chain,
  with one or two neighboring links rather than O(N²) full-mesh wiring.
  Added/removed APCs update neighboring backbone edges dynamically.
- **Anchored machinery, including regular and modular consoles**: a
  wired endpoint with one uplink to the APC registered as
  `get_area(machine).base_area?.power_apc` (or the area's own APC).
  The link is updated when a machine moves or is reanchored.
  Machines in an area with no APC remain present but disconnected.
- **Portable modular computers**: PDA, tablet and item-based laptop
  automatically use the spatial radio medium, channel 1, range 14.
  Console-internal `/obj/item/modular_computer/processor` does **not**
  create a duplicate network node.
- **Unanchored machinery**: automatically switches to radio; when
  reanchored it reconnects to the area's APC.

Subtypes `/apc/netdm` and `/console/netdm` remain aliases for
mapping compatibility, not special opt-in devices. Other kinds of
handheld items can still explicitly call `netdm_connect()`.

The background `SSnetdm` reconciliation pass updates area membership,
position, and anchoring in bounded groups; device creation and removal
are sent incrementally with acknowledged batches. No link is inferred
from an electrical powernet or NTNet.

## Deployment

Put `netdm_byond.dll` beside DreamDaemon's `.dmb`, run the
separate x64 `NetDM.Host` locally, and start SS13. The bridge attempts
to enable automatically while the DLL is available; Host may start
later. Use `SSnetdm.disable_bridge()` to pause or
`SSnetdm.enable_bridge()` to resume.

Open `http://127.0.0.1:5087` and select **SS13 · LIVE GAME** to see
the real APC backbone, area-based wired links, radio domain cells,
and device positions, including new devices spawned during the round.

## Game payloads

An object can retrieve its component through `netdm_interface()`
and send a payload via `endpoint.send_to(target, payload)`. The
binary Host routes only packet size/metadata. DM retains the actual
bounded payload and dispatches it after a Delivered receipt through
`netdm_receive(payload, sender, request_id)`, reporting transport
state via `netdm_delivery(request_id, state, reason)`.
A transport receipt is not an application-level acknowledgement.

The Host and bridge are local trusted-development processes, not a
multi-server service. There is no automatic retry for gameplay
operations that might execute twice.
