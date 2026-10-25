# NetRun Prerelease Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. Track completed work here and in `tmp/netrun-prerelease-progress.md`; do not repeat completed tasks.

**Goal:** Implement and verify the user's complete prerelease hardening request.

**Architecture:** Existing DM objects remain the state owners. Reuse bounded NetRun delivery and maintenance queues, incremental map projections and retained Pixi objects. Research authority belongs to a physical server; client caches cannot become authorities.

**Tech Stack:** BYOND 516, DM, React/TGUI, TypeScript, PixiJS 8, Jest, real browser layout checks.

**Spec:** `docs/superpowers/specs/2026-10-25-netrun-prerelease-design.md` (approved by the user in chat).

## Global Constraints

- Work in the user's existing `net-feature` checkout; preserve existing commits.
- One DM compiler/world at a time, coordinated by root. Do not push or merge.
- Server authorization, native machine checks, route validity and cancellation remain authoritative at delivery.
- Only communication traffic gains telecommunications forwarding.
- Independent changes may proceed concurrently in disjoint files; root owns shared manifests and performance changes in `core/node.dm` and `core/console_ui.dm`.
- All required tasks continue without intermediate permission prompts.

## Review Focus

- Same-floor movement must preserve projection while changed credentials/sector still revoke visibility.
- Server deletion during pending research/printing must not revive cached data or apply a stale reply.
- Simultaneous disconnect triggers must return the neural user once, apply damage once and leave no entity.
- Native telecomms relay outages/frequency changes must revoke communication paths without adding general network access.
- Atmos controllers created after roundstart must eventually list idle devices, then stop retrying.

### Task 1: Moving endpoints and requests

**Files:** `core/node.dm`, `core/console_ui.dm`, `core/map_view.dm`, existing refresh/map/routing/delivery tests.
**Interfaces:** movement notifications queue endpoint work, while route consumers reconcile current binding before authorizing; context invalidation distinguishes credentials from turf changes.
- [ ] Add regression for unchanged-permission movement retaining projection/static revision and cached route table.
- [ ] Observe failure, fix movement/context invalidation, verify crossing an area/sector and ID loss still update correctly.
- [ ] Exercise repeated movement with many endpoints and request bursts; record workload, full rebuild counts and timing.

### Task 2: Research authority and console

**Files:** `integration/machine_research.dm`, `integration/research.dm`, `integration/techweb.dm`, research subsystem/server/console/production, `techweb_holder.dm`, research tests.
**Interfaces:** authoritative techweb has physical owner; clients resolve that owner for operations and disposable snapshots carry available nodes and binding generation.
- [ ] Regression for `datatheory` then `comptech`, exact point debit, authority deletion, disconnected fabrication, new server reset and stale reply after rebind.
- [ ] Run RED through root, implement server ownership and null rebinding, run targeted GREEN and full suite.

### Task 3: Bootstrap, communication forwarding and atmos registration

**Files:** `core/subsystem.dm` (coordinate root), `core/machine_transport.dm`, `integration/machine_telecomms.dm`, `integration/machine_atmos.dm`, `entity/spawner.dm`, existing transport tests.
**Interfaces:** bootstrap completes after all subsystem initialization; queued bounded root-route prewarming; communication-specific path policy is separate from general graph; atmos service owns acknowledged registration/retry lifecycle.
- [ ] Add tests for communications crossing real telecomms relays with no NTnet relay, negative research/atmos routes, native relay outage, late airalarm, controller deletion and bounded retries.
- [ ] Test telecommunications placement and pregame bootstrap ordering; implement; targeted RED/GREEN via root.

### Task 4: Neural lifecycle, documentation and PDA

**Files:** `entity/dive_link.dm`, neural integration, `items/devices.dm`, new machine manual hook (root integrates `node.dm`), `NtosMessenger.js`, relevant DM/Jest tests.
**Interfaces:** idempotent emergency return removes network entity and pending work; machine manual hook provisions useful per-machine `readme.txt`; messenger has one bounded flex layout.
- [ ] Regress unplug, route/node loss, implant removal, repeated disconnect and voluntary exit; fix and verify.
- [ ] Provision machine-specific manuals without overwriting files or exhausting payload storage; test representative node classes and all registered providers.
- [ ] Regress status row rendering and inspect actual production layout at compact sizes, long messages and pending/success/error statuses.

### Task 5: Integration and release evidence

- [ ] Independent review of each task's changes and requirements; repair material findings.
- [ ] Run full NetRun DM and frontend suites, runner self-tests, TypeScript, relevant ESLint and production DM/TGUI builds.
- [ ] Run synthetic station load scenarios, actual browser interactions and geometry checks for node panels/PDA/research; record evidence and limitations in a tracked validation report.
- [ ] Review final diff and summarize concrete changes, checks, measurements and remaining release risks.
