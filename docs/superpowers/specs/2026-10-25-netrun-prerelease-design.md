# NetRun prerelease hardening

## Intent and scope

Prepare the existing `net-feature` implementation for a large station with many moving endpoints and simultaneous players. The user's 25 October request supplies the behavioral requirements below. Keep the existing DM subsystem, packet scheduler, React/TGUI and retained PixiJS renderer.

## Approach

Extend the existing owners and queues. Separate movement from credential invalidation, preserve incremental map updates, and remove synchronous expensive work from movement signal handlers. Keep live authorization and path validation at delivery. Merely spawning the current expensive work would still consume the same server tick; replacing the scheduler or renderer would duplicate existing infrastructure.

Use authoritative research memory owned only by physical servers. Clients retain only disposable presentation data and request operations from a reachable server. Independent servers do not silently replicate each other. The user's 26 October instruction requires explicit server linking: linked physical servers share one authoritative database and all online members generate points. Losing one member retains data on survivors; losing the last member deletes the database. Network partitions do not fork linked memory into divergent replicas.

## Required behavior

1. Same-floor movement with unchanged credentials and APC attachment updates changed markers/edges without rebuilding the permitted map or clearing unrelated routing caches. Area/sector, credentials and topology changes must still refresh visibility correctly.
2. Requests enter bounded existing queues; native yielding actions cannot block the worker. Measure routing, serialization and repeated-movement work with reproducible load tests.
3. Research console snapshots include all researched, visible and available nodes, with correct tiers. A real prerequisite chain must remain researchable through delivered requests.
4. Each standalone research server or explicitly linked server group owns its authoritative techweb. Console and fabrication caches are invalidated on final authority loss. Power loss prevents requests through that member but preserves memory; destruction of the last physical owner loses it. Building another standalone server starts fresh. A mutation is sent to one reachable owner, including cold DNS discovery.
5. A broken neural body link immediately returns the client to the original body, applies one brain injury using the existing native harm mechanism, and deletes the network entity and its pending actions. Forced organ removal and node/route deletion follow the same path. Ordinary voluntary exit remains safe.
6. Every machine node has an in-world `readme.txt` explaining its role, legitimate access, connection and native services/commands. Generate from machine/provider contracts, with useful type-specific instructions, without exhausting existing disks or overwriting user files.
7. Roundstart DNS and information servers are placed on valid free tiles in telecommunications. Never replace mapped machinery.
8. Communication packets may use working native telecommunications relays. This does not grant general NetRun, research or atmos traffic a new route. Native relay power, enabled state, level and range rules remain authoritative.
9. Vents and scrubbers with no registered air alarm in their area retry registration at a bounded cadence until a real controller accepts the status. Late construction, outage recovery and deleted controllers must work without perpetual spam after success.
10. Initial topology and useful infrastructure routing are prepared after subsystem initialization and before the round starts; lobby work uses bounded queues and is refreshed if the pregame topology changes.
11. PDA delivery status fits inside its fixed messenger window. Review native node panels, research and messenger in a browser using the actual production TGUI bundle, including compact sizes and long content.

## Constraints and validation

- Preserve `net-feature` and the user's existing commits; no reset, merge, push or publication.
- Run one DM compiler/test world at a time in this checkout.
- Prefer regression tests that reproduce observed behavior. Run the complete NetRun DM and frontend suites, TypeScript, relevant lint and production builds, then independent review.
- Load tests must report workload size, measurements and assertions. Automated synthetic clients are evidence about server work, not proof of live multiplayer latency.
- Record which interfaces and real-client scenarios were actually verified, plus remaining limits. Do not call this release-ready if a required check cannot run or a material failure remains.

## 26 October continuation

The user explicitly authorized larger routing caches and more MC time for the task worker, and reported machine tasks accumulating without draining. Raise the default CPU budget from2to6ms (pressure minimum0.30to1ms), the per-pass ceiling from48to192, and retain UI route trees for30seconds instead of2. Keep hard limits, live route invalidation and fair service. Diagnose and remove traffic feedback loops, coalesce replaceable queued snapshots without merging real commands/outcomes, and verify a sustained burst fully drains after producers stop.

## Builder decisions

Brain damage uses existing native helpers and a bounded nonfatal default; exact severity is an implementation choice to document. Research power loss retains data; physical server destruction is the data-loss event. Telecommunications forwarding is restricted to communication service identifiers. Target load sizes should be chosen from existing stress fixtures and reported explicitly.

The user approved the full design in chat: «Да, реализуй весь план». Builder review added these implementation decisions: default research consumers select a deterministic live station server; deleting that owner clears the binding and never silently restores an old client snapshot. An already paid physical fabrication may finish, while unstarted queue items require a fresh server query before material debit. Existing physical research disks remain explicit backup media. Communication policy accompanies DNS query/reply and all cache keys. Neural node/implant deletion acts immediately; route availability changes enqueue checks for the next tick without station-wide searches in movement handlers. Atmos registration targets every compatible local alarm, with acknowledgement only after delivery. Load checks assert bounded caches/queues, drainage, no full map rebuild on ordinary movement and no infrastructure tree rebuild on leaf motion.
