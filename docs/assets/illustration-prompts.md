# Delamain illustrations — generation prompts

Generated with the built-in image generator in edit mode on 2026-10-07.
These illustrations explain coordination; operational instructions remain in the linked skills and guides.

## Brand direction

Reference: [Delamain (AI), Cyberpunk Wiki](https://cyberpunk.fandom.com/wiki/Delamain_%28AI%29).
Delamain is the AI operator of a taxi fleet in Cyberpunk 2077. The project uses that reference as a metaphor:
one dispatcher, independent workers and continuity through shared records.

The visual palette is dark navy, ice blue and taxi amber. The hub is a blue Delamain display;
workers are black autonomous cabs with distinct task icons. Preserve the distinction between the hub session
and the worker processes: a fresh hub reads shared records and coordinates the same workers.

Repository About:

> An AI dispatcher for Claude Code and Codex: autonomous coding workers, shared records, resource locks, and handoffs across sessions.

## Fleet dispatch

Output: `docs/assets/delamain-fleet.png`.

Edit target: the previous `docs/assets/agent-orchestra.png`, preserved in
[the pre-rebrand revision](https://github.com/ilya-kozyrev/delamain/blob/32a90d2f1daa40fe4d55c37522ef4b5d2ce1fd4e/docs/assets/agent-orchestra.png).

Final prompt:

```text
Use case: style-transfer / illustration-story.
Asset type: project README explanatory illustration, wide landscape 2:1.
Input image: edit target, the current orchestra illustration. Rebrand its entire visual metaphor to Delamain from Cyberpunk 2077, retaining its precise meaning: one hub dispatches distinct tasks to five autonomous workers, and their results accumulate in shared records.
Replace robot orchestra, conductor baton, music desks and cream background with an elegant night-time AI taxi dispatch scene. Dominant HUB is a large luminous blue display showing Delamain's recognizable bald pale blue male face, electric blue eyes, formal dark suit, white shirt and tie, calm professional expression. Display sits above a restrained dispatch console. Exactly five autonomous black luxury cabs represent the five worker roles; each has a small amber roof light and one clear cyan task symbol: code brackets, checkmark, magnifying glass, document, assembly puzzle. Five cabs grouped in the lower left/right lanes, fully visible and visually distinct. Short orderly amber dispatch paths go from hub to fleet, cyan report paths from cabs converge on one shared journal console in foreground; shared journal is a clearly readable panel with five matching task icons and completed check marks.
Style: sophisticated crisp 16-bit pixel art, visible square pixel grid, architectural dark navy and charcoal backdrop, ice blue cyan holographic light, restrained taxi amber accents, subtle distant Night City skyline. Precise, composed, understated corporate cyberpunk; useful explanatory illustration, not a busy screenshot. Balanced spacious layout legible at GitHub README width.
Text exactly: "DELAMAIN" as main heading, "HUB" by the AI display, "WORKERS" above fleet, "SHARED JOURNAL" above the journal panel. No other letters or words.
Constraints: retain one coordinator, exactly five workers and one persistent record store. Original illustration inspired by the character; do not paste a game screenshot. No orchestra, cute robots, weapons, logos from the game publisher, watermark, confetti, excessive neon, blur, cropped vehicles or tiny decorative UI text. Solid opaque background.
```

## Coordinator handoff

Output: `docs/assets/delamain-handoff.png`.

Input 1 is the previous `docs/assets/hub-handoff-pixel.png`, preserved in
[the pre-rebrand revision](https://github.com/ilya-kozyrev/delamain/blob/32a90d2f1daa40fe4d55c37522ef4b5d2ce1fd4e/docs/assets/hub-handoff-pixel.png).
Input 2 is the generated fleet illustration above, used as a style and cast reference.

Final prompt:

```text
Use case: style-transfer / illustration-story.
Asset type: companion wide landscape 2:1 documentation illustration explaining a coordinator handoff.
Input image 1: EDIT TARGET, old pixel-art robot orchestra handoff. Retain its explicit left-to-right relationship and semantics, while replacing characters and setting entirely.
Input image 2: STYLE AND CAST REFERENCE, the new Delamain fleet illustration. Match its crisp sophisticated pixel art, dark navy Night City taxi depot, blue holographic bald Delamain in formal suit, black luxury autonomous cabs, cyan role icons and restrained amber lighting.
Primary request: one unmistakable scene explaining that the hub session changes while shared records and all five worker cabs persist. On far left, a smaller outgoing blue Delamain display is labelled exactly "OLD HUB"; it is dimming. A large amber arrow points right from the old hub toward the bright central-right incoming blue Delamain display, labelled exactly "FRESH HUB". The arrow must visually read OLD HUB -> FRESH HUB. Between the two displays on a permanent physical console sits the shared journal, with five cyan icons and completed checks, labelled exactly "SHARED JOURNAL"; a short clear cyan reading connection goes from records to fresh hub. ALL FIVE worker cabs are grouped ONLY to the right of or immediately below the fresh hub, under exactly one label "WORKERS". Cabs carry the same code brackets, checkmark, magnifier, document and assembly puzzle icons as reference. Short amber dispatch paths from fresh hub to all five cabs convey continued coordination; no cab reports to old hub. Their lane motion hints show continued work, not parked replacement machines. No interruption, erased records or new fleet.
Composition: wide clear editorial pixel scene, calm sparse skyline, comfortable spacing, smaller old hub on far left, dominant active fresh hub and five cabs toward right, fully visible cars. Keep paths tidy and meaning legible at documentation width. Portraits recognizably the same AI but different sessions; old dim, fresh bright.
Text: exactly "OLD HUB", "FRESH HUB", "WORKERS", "SHARED JOURNAL". No other words or decorative UI text.
Constraints: exactly two hub displays, one persistent journal console, exactly five autonomous cabs. No robots, musical instruments, conductor batons, cream background, extra vehicles, game screenshot, watermark, publisher logos, weapons, excessive neon or blur. Opaque background.
```

## Workflow sketch

`docs/assets/hub-workflow.svg` remains an editable vector diagram. Its labels and relationships are unchanged;
navy panels, cyan links and amber accents match the illustrations. SVG title and description retain the
literal workflow for assistive technology.
