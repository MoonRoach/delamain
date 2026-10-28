# hub-viz: Delamain live

A live night city over the hub home, as a web page and a native macOS screen saver. The map shows what runs, like
agent-top: a worker while its process lives, a stage hub while it runs. Read-only over `AGENT_HUB_HOME` (default
`~/agent-hub`).

- **The city** is procedural and deterministic: a coastal megacity with a bay to the west and desert all round, nine
  districts (CORE, FOUNDRY, DOCKS, BAZAAR, HEIGHTS, SPRAWL, SMELTER, RIVIERA, WASTES), each with its own street grid
  angle and block size, a ring road, curved radial highways and a coast road. Blocks are neon schematics in the
  district's colour with a few image landmarks, each district cycling through its own buildings (megamall and data centre
  in the core, power plants in the foundry and the smelter, a container ship and an oil rig in the bay off the docks, a
  monorail station on the ring, a slum, a temple and a stadium in the sprawl, water towers in the wastes); ground traffic is
  ambient. Landmarks are drawn fainter than the towers and cabs: they are scenery, not something that runs.
- **A repository is a district** (`claude-agent-hub` the core, `santinel` the foundry, others take free districts; a
  stage with no repository sits in the wastes).
- **A stage hub is a tower** on a lot of its district, one of seven designs by the hash of the stage's name, with its
  name as a neon sign.
  An open stage has one while it has live workers, its hub wrote to the journal within 30 min, or some process names
  the hub's session. **The owner** is the megatower in the core, and it is the plan-limits gauge: its left face is lit
  amber by what Claude's plan has left, its right face cyan by Codex's, each from the crown down, so spending darkens it
  from the foot up; an engine with no sample stays dark, and hovering the tower gives the numbers. The share is the
  smallest remaining over the engine's windows (5h, 7d), read like `bin/limit_pace.py` from the last `rate_limit_event`
  of recent headless Claude agent logs in the hub home and the `token_count` rate limits of recent Codex rollouts, once
  a minute; a window past its reset counts as full. `/state` carries it as `limits` (`{"claude": {"left": 17, "window":
  "7d"}, …}`).
  A tower grows with its hub session's context: 0.75x when fresh, 1.5x at 350k tokens (the handoff threshold); `/state`
  carries it as `hub.ctx` (the last usage of the session's Claude transcript, else the context-budget hook's last
  recorded count, else 0) and the page's tooltip shows it as `ctx 212k`.
  While its stage has owner questions open (`Q-…` entries with status `open` in `<stage>/questions.md`, the `ask`
  register; `/state` carries the count as `questions`) the tower's beacon and sign flash gold once a second, and the
  page's tooltip says how many.
- **A worker is a flying cab** roaming the city. Its flyer shows the model's tier: a limo for Fable or Astra, a sports flyer
  for Opus, the plain flyer for Sonnet or Sol, a bike for Haiku or Luna, a van for a service tool (`pace`, `watchdog`).
  Its neon trail, the last 1.3 s of flight fading to the tail, is in the model's colour (Fable violet, Opus magenta,
  Sonnet amber, Haiku lime, Astra red, Sol cyan, Luna blue); its glow is amber for Claude, cyan for Codex, grey for a service tool; a busy one (log grew in the last 10 min) flies a little faster with a pulsing glow.
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
last `hours` after N seconds without a live line; off by default: live only), `hours=24`, `speed=120`, `follow=0|1`
(whether the camera flies to each line; overrides the last toggle), `ui=1.6` (text over the map that much larger, for a projector), `lang=en|ru` (else the browser's languages; English is the fallback; journal text is shown as
written). Keys: `r` replay, `l` back to live, `f` follow on or off, `c` or `Esc` camera back to the overview (release a
pinned object, end a manual view). Hover a tower or a cab for its title.

- **Follow.** The `◉ follow` control under the mode, top right, switches the camera's flights to each journal line on
  and off (as `f` does). Its state comes from `follow=`, else the last toggle in this browser (`localStorage`), else on.
- **Pan and zoom.** Drag the map with the mouse or one finger to pan; the wheel, a trackpad pinch or a two-finger pinch
  zooms around the cursor or the pinch's centre, from 0.7x to 6x of the overview; the view's centre stays over the map.
  A hand pan or zoom makes the view manual: the camera no longer flies to lines nor drifts back to the overview, and an
  `⌖ overview` control appears beside `follow`; it, `c` or `Esc` returns to the overview and the follow setting. A hand
  gesture also switches `follow` off for this view (the saved setting stays); switching it on ends the manual view. A press
  that has not moved a few pixels is still a click or a tap. The page itself does not scroll or zoom over the map.

- **The roster** on the left, under the HUD, lists the owner, each hub tower (its stage, `ctx 212k` when known, a gold
  `?N` while it has open owner questions, dimmed when closed) and under it its cabs (a dot in the model's colour, the
  role, the short model name; a busy cab's dot pulses). It is rebuilt about once a second; hovering a row highlights its
  object on the map. With several machines (`src=`), a hub whose stage name appears on two of them shows its machine.
- **Pinning.** Clicking a roster row, a tower or a cab pins the camera to it: the camera follows it, zoomed in, and a
  journal line no longer pulls it away; the pinned row and a cyan ring on the map mark it. A pin outranks a manual view;
  the wheel or a pinch changes its zoom and keeps it, a drag releases it into a manual view. Clicking it again, clicking
  empty map, `Esc` or `c` releases it; it is released by itself when the object leaves the map (a cab landed, a hub gone).
- **On a phone** (at most 700 px wide, or at most 500 px tall) the roster folds into a button under the HUD
  (`☰ 3 hubs · 5 cabs`, the HUD's own count, plus the pinned object) that opens it as a sheet; the legend hides, the ticker spans the screen
  and keeps three lines. A tap pins like a click and shows the tooltip for 2.5 s. In portrait the map fits the city,
  not the desert roads, and lets the sides run past the screen's edges. The canvas renders at most at 2x.

## Screen saver

`DelamainLive.saver` draws the same city natively (Swift, Core Graphics and Core Animation; no WebKit, whose views
the screen saver host neither composites nor ticks faster than about 1 Hz). `saver/CityModel.swift` ports the page's
city generator value for value, so both draw the same city; `saver/Feed.swift` reads `/state` and `/events`, so the
server must be running. The static city is a bitmap at the screen's backing resolution for the camera's resting view;
everything that moves is a layer. The roster is drawn as on the page, without pinning or hover: the saver is not
interactive. While it runs, the saver keeps the display awake.

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

The images in `assets/` are original artwork generated for this page (the Antigravity CLI's image generator and the
owner's own generations; no game assets); their black background is keyed to transparency at load. Towers are 768×1024,
buildings 512×512, flyers 384×384. A landmark's sprite and its scale live in `LANDMARKS` and `LANDMARK_SCALE` in both
`viz.html` and the saver; a new name goes into `SPRITES` / `SPRITE_NAMES` too, and the choice must use no random draws, or
the page and the saver stop drawing the same city.
