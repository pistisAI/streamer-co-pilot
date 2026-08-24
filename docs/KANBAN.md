# Streamer Co-Pilot — Kanban

This is the versioned working board for the project. It tracks work that has a
GitHub issue; source code, tests, and CI remain the authority for completion.

**Board rules**

- Create a GitHub issue before changing a discovered TODO, placeholder, or gap.
- Move a card to **In progress** only when implementation has started.
- Move a card to **Done** only after the change is committed, pushed, and CI is green.
- Do not use the board to claim unsupported platform functionality as complete.

## In progress

_No active work._

## Ready

_No verified, issue-backed work is queued._

## Blocked

_No active blockers._

## Done

- [x] [#12 — Correct stale YouTube moderation documentation](https://github.com/pistisAI/streamer-co-pilot/issues/12)
  - Replaced the obsolete “not implemented” statement with the supported
    moderation operations and explicit chat-mode limitation.
- [x] **Phase 1 — Foundation:** StreamPlatform abstraction, OBS controller,
  AgentServer, architecture cleanup and documentation.
- [x] **Phase 2 — Platform layer:** Twitch OAuth/IRC/Helix/EventSub, YouTube
  chat and moderation, Kick chat/status, and multi-platform aggregation.
- [x] **Phase 3 — OBS integration:** connection, scene/source controls,
  streaming/recording controls, auto-detection, setup guidance, and status UI.
- [x] **Phase 4 — Application wiring:** server/OBS startup, platform settings,
  OAuth callback, and dashboard state/chat.
- [x] **Phase 5 — Agent integration:** AgentClient/DecisionLoop, REST and
  event-driven control paths, EventSub alerts, and dashboard alert overlay.
- [x] **Phase 6 — Polish and release:** unit/widget/integration coverage,
  Windows installer, Linux AppImage, macOS DMG, and tag-driven release workflow.

## Verification baseline

- Roadmap authority: [`BUILD-PLAN.md`](BUILD-PLAN.md)
- Latest roadmap-completion documentation commit: `a945fca`
- Add current test/analyzer/CI evidence to the issue or commit that closes a card.
