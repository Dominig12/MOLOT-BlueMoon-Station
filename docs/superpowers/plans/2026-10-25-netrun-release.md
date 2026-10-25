# NetRun First Release Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task. Resume from the plan-scoped ledger; do not repeat completed work.

**Goal:** Finish the seven user-approved NetRun improvements in order and verify them in the existing feature checkout.

**Architecture:** DM datums/components own mutable network, operation, command and gameplay state. React subscribes to authorized backend slices; one retained Pixi scene owns the map. Shared delivery metadata does not replace service-specific authorization.

**Tech Stack:** BYOND 516, DM, React/TGUI, TypeScript, PixiJS 8, Jest and the existing hermetic NetRun test runner.

**Spec:** `docs/superpowers/specs/2026-10-25-netrun-release-design.md`

## Global Constraints

All constraints in the accepted spec apply. Work remains in `net-feature`; preserve existing user commits. Keep one compiler/world at a time. Never infer command success from `input_ack`. Preserve physical routes, native access checks and cancellation. Do not publish message bodies in journals. Integration occurs in task order; independent drafts stay in ignored staging directories until their task begins.

## Review Focus

- CSS zoom changes during an active drag: no jump or hit-test drift.
- Late completion after another action or deleted endpoint: correct immutable metadata and terminal state.
- Yielding native actions and a large telemetry burst: scheduler remains responsive and fair.
- Failed DNS query/reply and a stale callback: bounded failover, one data execution.
- Unauthorized UI calls, edited evidence and repeated rewards: no privilege bypass or duplicate result.

### Task 1: Map coordinates

**Files:** `viewportCoordinates.ts`, `viewportController.ts`, related tests in `NetrunTerminal/`.
**Interfaces:** `ViewportCoordinates.point()` and `.delta()` convert client pixels to layout pixels.
- [x] Implement and test 75/100/125% scales, hover/hit, wheel anchor and camera changes during drag.
- [x] Verify actual Chrome/WebGL mouse input; evidence in `tmp/netrun-zoom-native-final.log`.

### Task 2: Delivery operations and history

**Files:** `core/packet_context.dm`, `requests.dm`, `machine_transport.dm`, node/console APIs and `OperationsPanel.tsx`.
**Interfaces:** `netrun_packet_context` owns scalar metadata and immutable route snapshots; `operations` contains at most 32 value snapshots. Phases: queued/running/completed/rejected/cancelled. `nonce` is passed explicitly.
- [x] Journal command/file/window/remote/entity and machine/DNS packets without body contents.
- [x] Add UI history, filters, status outcomes and confirmed map Locate.
- [x] Verify prior stage-2 state: 229 DM tests, 185 UI tests, production TGUI build and native history QA. Later small status tests are also green; the final suite must include them.

### Task 3: Budgeted delivery and DNS failover

**Files:** `core/delivery_tasks.dm`, `requests.dm`, `machine_transport.dm`, defines and new DM tests.
**Interfaces:** `send()` admits/schedules; `queue_delivery()` enqueues one task per packet; `deliver()` is a nonblocking trusted execution boundary. DNS attempts use a generation and shared deadline.
- [ ] Complete deterministic tests for fairness, capacity, yielding, cleanup, alternative resolvers and stale callbacks.
- [ ] Fix findings against the committed draft in `d69bef5312` without replacing the user's commit.
- [ ] Run the full NetRun DM suite; Expected: every selected test passes, no runtime failures.

### Task 4: Map tools and packet inspection

**Files:** `NetworkMap.tsx`, `NetworkViewport.tsx`, controller/Pixi layers, `PacketJournal.tsx`, node/window payloads.
**Interfaces:** explicit target address for quick actions; view modes access/activity/threat; immutable recorded packet routes filtered through authorized visibility.
- [ ] Review and finish `tmp/netrun-map-stage` drafts after Task 3.
- [ ] Test quick-action selection races, double click, mode switching without context replacement, packet filters and stale/hidden route segments.
- [ ] Run relevant/full frontend tests, TypeScript, ESLint, build and native browser checks.

### Task 5: Schema-driven terminal commands

**Files:** `core/cli.dm`, terminal input helpers, `TerminalConsole.tsx`, related DM/Jest tests.
**Interfaces:** registry verbs expose argument type/source/required/options metadata; frontend completion and palette consume it.
- [ ] Add tests for renamed files, second arguments, quoted names, required/enumerated values and palette insertion.
- [ ] Implement shared schemas and inline help/validation without changing server access rules.
- [ ] Run DM CLI and frontend suites plus TS/lint/build checks.

### Task 6: Network content

**Files:** binding policy, file evidence, work orders, content integration, ruin DMMs and tests prepared in `tmp/netrun-content-stage`.
**Interfaces:** polymorphic direct-only stash binding; native ruin power; owned work orders validate provenance and atomically archive evidence/reward once.
- [ ] Review staged changes and merge only against matching bases; preserve changed include manifests.
- [ ] Test isolation, actual DMM power/placement, fresh photo/diagnostic evidence, tampering, operator changes, capacity and repeat submissions.
- [ ] Run full NetRun DM tests and map validation.

### Task 7: ICE and network defence

**Files:** new awareness/defence components, ICE/reaction integration, network credential/access hooks, tests.
**Interfaces:** awareness owns last observed location and search deadline; defence validates legitimate administrative access at execution and owns finite maintenance resources.
- [ ] Add tests for unseen movement, remembered trails, bounded search/decoys, real-link/LAN restrictions, key revocation, quarantine expiry and concurrent patrol restoration.
- [ ] Implement small OO services on existing transport/provider contracts.
- [ ] Run full DM/frontend checks, production builds and a final independent review.
