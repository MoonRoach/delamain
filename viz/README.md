# hub-viz: Delamain live

A live night city over the hub home, as a web page and a native macOS screen saver. The map shows what runs, like
agent-top: a worker while its process lives, a stage hub while it runs. Read-only over `AGENT_HUB_HOME` (default
`~/agent-hub`).

- **The city** is procedural and deterministic: a coastal megacity with a bay to the west and desert all round, nine
  districts (CORE, FOUNDRY, DOCKS, BAZAAR, HEIGHTS, SPRAWL, SMELTER, RIVIERA, WASTES), each with its own street grid
  angle and block size, a ring road, curved radial highways and a coast road. Blocks are neon schematics in the
  district's colour with a few image landmarks; ground traffic is ambient.
- **A repository is a district** (`claude-agent-hub` the core, `santinel` the foundry, others take free districts; a
  stage with no repository sits in the wastes).
- **A stage hub is a tower** on a lot of its district (violet, cyan or red by machine) with its name as a neon sign.
  An open stage has one while it has live workers, its hub wrote to the journal within 30 min, or some process names
  the hub's session. **The owner** is the gold megatower in the core.
  A tower grows with its hub session's context: 0.75x when fresh, 1.5x at 350k tokens (the handoff threshold); `/state`
  carries it as `hub.ctx` (the last usage of the session's Claude transcript, else the context-budget hook's last
  recorded count, else 0) and the page's tooltip shows it as `ctx 212k`.
- **A worker is a flying cab** roaming the city, amber for Claude, cyan for Codex, grey for a service tool (`pace`,
  `watchdog`); a busy one (log grew in the last 10 min) flies a little faster with a pulsing glow.
- **Every journal line is a beam**: from a spire down to a cab, from a cab up to its addressee (`@role`, `@hub <stage>`,
  `@owner`; an unaddressed line goes to the stage's hub), or between spires; the camera flies to where it happened.

## Server and page

```bash
./build.sh                  # needs go and swiftc; writes build/hub-viz and build/DelamainLive.saver
build/hub-viz               # http://127.0.0.1:8765/
```

`hub-viz` flags: `-addr 127.0.0.1:8765` (listen address), `-allow-origin http://a:8765,http://b:8765` (page origins that
may read this server from another origin; none by default, so no CORS header is sent), `-v` (log every request but
assets, with its user agent; off by default). `-addr 0.0.0.0:…` publishes the journals, unauthenticated, to the whole
network: use it only on a network you trust. A page that reads several machines (`src=`) needs `-allow-origin <the
page's origin>` on each of the others (the page itself is served by the first). Endpoints: `/` the page, `/state`,
`/history?hours=N`, `/events` (SSE: `state` every 5 s, `line` per journal line), `/assets/`.

Page parameters: `src=http://a:8765,http://b:8765` (several machines, each running `hub-viz`), `quiet=N` (replay the
last `hours` after N seconds without a live line; off by default: live only), `hours=24`, `speed=120`, `follow=0`
(keep the overview), `lang=en|ru` (else the browser's languages; English is the fallback; journal text is shown as
written). Keys: `r` replay, `l` back to live, `c` camera back to the overview. Hover a tower or a cab for its title.

## Screen saver

`DelamainLive.saver` draws the same city natively (Swift, Core Graphics and Core Animation; no WebKit, whose views
the screen saver host neither composites nor ticks faster than about 1 Hz). `saver/CityModel.swift` ports the page's
city generator value for value, so both draw the same city; `saver/Feed.swift` reads `/state` and `/events`, so the
server must be running. The static city is a bitmap at the screen's backing resolution for the camera's resting view;
everything that moves is a layer. While it runs, the saver keeps the display awake.

Settings, all in the `dev.delamain.saver` defaults suite (`defaults write dev.delamain.saver <key> …`):

| Key | Type, default | Meaning |
|---|---|---|
| `server` | string, `http://127.0.0.1:8765` | the hub-viz server |
| `follow` | bool, `true` | the camera flies to each line |
| `replayAfter` | int seconds, unset | replay the last 24 h after this much silence; unset: live only |
| `lang` | `en` or `ru`, unset | interface language; unset: the system's preferred languages, English fallback |
| `diagnostics` | bool, `false` | report fps and layout with each `/state` poll, and write one frame to `$TMPDIR/delamain-frame.png` 20 s after start |

`legacyScreenSaver` is sandboxed, so the saver reads the suite and, failing that, `~/Library/Preferences/dev.delamain.saver.plist`
directly. If a setting still does not arrive, write it into the host's container instead:
`defaults write ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/dev.delamain.saver <key> <value>`.
The host's App Transport Security applies to `server` (a bundle cannot relax it): a non-local `http://` server may be blocked.

Install:

1. `cp -R build/DelamainLive.saver ~/Library/Screen\ Savers/` and pick it in System Settings → Screen Saver.
   A new build is picked up only by a new `legacyScreenSaver` process: quit System Settings and kill the running
   `legacyScreenSaver.appex` processes by pid.
2. Keep the server up with launchd: copy `saver/dev.delamain.hub-viz.plist` to `~/Library/LaunchAgents/`, replace
   `HUB_VIZ_BIN` with the absolute path of `build/hub-viz`, then
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.delamain.hub-viz.plist`.
   Its log is `/tmp/hub-viz.log`; to see the saver's diagnostics there, add `-v` to `ProgramArguments`.

The saver must be built as a loadable bundle (`MH_BUNDLE`, as `build.sh` does): System Settings silently skips a dylib.
The lock screen itself shows the wallpaper; the saver appears over it only after the idle time set in System Settings.
The screen saver host makes two full-screen views per process, and both animate.

## Assets

The images in `assets/` were generated for this page with the Antigravity CLI's image generator (original artwork, no
game assets); their black background is keyed to transparency at load. `residential-block`, `luxury-block` and
`hub-tower-red` are not generated yet: the page and the saver stand in other blocks and a hue-shifted tower for them
(the page's console shows three 404s for them).
