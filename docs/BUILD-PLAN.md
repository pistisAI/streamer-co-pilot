# Build Plan — Streamer Co-Pilot

## Phase 1: Foundation ✅ (Done)

- [x] Remove Python `service/` directory
- [x] Remove `overlay/index.html` (now embedded in Flutter)
- [x] Archive `streamer-co-pilot-service` repo
- [x] Clean `.gitignore`, README, settings references
- [x] Define `StreamPlatform` abstract interface
- [x] Create `ObsController` provider (obs_websocket)
- [x] Create `AgentServer` provider (shelf HTTP server)
- [x] Add dependencies: `obs_websocket`, `shelf`, `shelf_router`
- [x] Write architecture docs

## Phase 2: Platform Layer ✅ (Done)

### StreamPlatform Interface ✅
Abstract contract in `lib/platforms/stream_platform.dart`. Every platform implements:
- `connect(credentials)` / `disconnect()` / `connected`
- `chatStream` / `statusStream` — real-time event streams
- `sendMessage(text)` / `fetchRecentChat(count)` / `fetchStatus()`
- Moderation: `timeoutUser`, `banUser`, `unbanUser`, `clearChat`, `setChatMode`

### TwitchPlatform ✅
| File | Purpose |
|------|---------|
| `lib/platforms/twitch_platform.dart` | Main class implementing `StreamPlatform` |
| `lib/platforms/twitch_auth.dart` | OAuth token lifecycle (generate URL, exchange code, refresh, store) |
| `lib/platforms/twitch_irc_client.dart` | IRC connection, message parsing, capability negotiation |
| `lib/platforms/twitch_helix_client.dart` | Helix REST API wrapper (status, moderation, users) |

**OAuth Flow:**
1. User clicks "Connect to Twitch" in Settings
2. App opens browser to `https://id.twitch.tv/oauth2/authorize` with scopes
3. User authorizes → Twitch redirects to `http://localhost:8511/auth/callback`
4. App exchanges code for access token + refresh token
5. Tokens stored in SharedPreferences
6. Refresh token used when access token expires (~4h lifetime)

**IRC Details:**
- Server: `irc.chat.twitch.tv:6697` (TLS)
- Auth: `PASS oauth:<token>`, `NICK <bot_username>`
- Capabilities: `twitch.tv/membership twitch.tv/tags twitch.tv/commands`
- Rate limit: 20 messages per 30 seconds

**Helix Endpoints:**
- `GET /helix/streams` — stream status (poll 30s)
- `GET /helix/users` — user ID resolution
- `POST /helix/moderation/bans` — ban
- `POST /helix/moderation/timeouts` — timeout
- `PATCH /helix/chat/settings` — slow/emote/sub-only

### YouTubePlatform & KickPlatform
Documented in `PLATFORM-INTEGRATION.md` as future work. The interface is ready — implementations come when needed.

## Phase 3: OBS Integration ✅ (Done)

- [x] Connect/disconnect via `obs-websocket`
- [x] Read scenes, sources, stream/record status
- [x] Switch scene, toggle source, start/stop stream/record
- [x] Auto-detect — try `localhost:4455` on launch, show status
- [x] Setup guide — if connection fails, show dialog with OBS WebSocket setup instructions
- [x] Test connection — button in Settings
- [x] Status indicator — Dashboard shows OBS connection at a glance

**obs-websocket is built into OBS Studio 28+** (Tools → WebSocket Server Settings). No plugin to install. The app just needs to guide the user through enabling it.

## Phase 4: Wire Everything Together ✅ (Done)

- [x] Start `AgentServer` on app launch (port 8511)
- [x] Start `ObsController` auto-connect on launch
- [x] Platform selector in Settings tab
- [x] OBS config (host, port, password) in Settings
- [x] Dashboard shows OBS state + stream status + chat
- [x] Twitch OAuth callback handler at `/auth/callback`
- [x] All providers wired in `main.dart`

## Phase 5: Agent Integration ✅ (Done)

- [x] Hermes skill for streamer-co-pilot
- [x] Decision loop: poll `/state`, decide, send `/command` (lib/agent/decision_loop.dart, lib/agent/agent_client.dart, lib/agent/agent_main.dart)
- [x] Event-driven mode (WebSocket on server at `/ws`; SSE client in AgentClient)
- [x] Alert overlay (donations, follows, subs) — subs/resubs/raids via IRC USERNOTICE; follows/cheers via Helix EventSub; all wired in `lib/widgets/alert_overlay.dart` and `lib/platforms/twitch_eventsub_client.dart`

## Phase 6: Polish & Release ✅ (Done)

- [x] Widget tests (alert_overlay, connection_indicator, error_banner, chat_tab, dashboard_tab, settings_tab)
- [x] Unit tests for Twitch IRC, Helix, OBS controller, EventSub, Auth, YouTube moderation
- [x] Integration test (OBS + Twitch end-to-end in `test/integration/obs_twitch_e2e_test.dart`)
- [x] Windows installer (Inno Setup — `scripts/packaging/build_windows_installer.ps1`, verified in CI)
- [x] Linux AppImage (`packaging/appimage/build-appimage.sh`, verified in CI)
- [x] macOS DMG (`packaging/macos/build-dmg.sh`, wired in release.yml)
- [x] CI pipeline (release workflow at `.github/workflows/release.yml`; tag push creates multi-platform release)

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Twitch OAuth complexity | High | Start with simple token, add refresh later |
| IRC rate limits (20/30s) | Medium | Message queue with rate limiter |
| obs_websocket API changes | Low | Pinned version in pubspec |
| Scope creep (too many platforms) | Medium | Twitch only for MVP |
| Hermes integration undefined | Medium | Agent interface already defined in docs |
