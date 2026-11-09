# own/: our own step text

Put short step lines in our own words here, one file per storyline: `own/<storyline>.lua`, for example `own/chains-of-promathia.lua`.
Each is laid over the skeleton at load; a mission listed here takes these steps. Write only what you have seen yourself in the game (a place you went,
who you spoke to, what the game said), keep each line short, and do not copy or reword any website. Missions not listed keep "No step text yet".

```lua
return {
  ["Promathia Mission 1-1"] = {
    parts = {{steps = {
      {text = "Talk to the NPC in town.", depth = 1, optional = false, ki = {}, key = "o1"},
      {text = "Zone out and back in for the scene.", depth = 1, optional = false, ki = {"Key Item Name"}, key = "o2"},
    }}},
  },
}
```

The mission id is the one in `skeleton/<storyline>.lua`. `key` must be unique inside the mission and stay the same once a player has ticked the step.
`ki` names a key item whose arrival ticks the step by itself (its name as in Windower's `res/key_items.lua`).

## Fields a step may carry

| Field | Meaning |
|---|---|
| `text` | the one target line: GO / TALK / INTERACT / FIGHT, the place, and the done-when (for example "Talk to Name in Zone (G-8): cutscene") |
| `depth`, `optional`, `ki`, `key` | as above |
| `modern` | an optional short note on a shortcut that exists in the retail game today (home point, survival guide, Unity warp, waypoint, trusts, level sync or capped fights). Information only, never an extra step. Write it only where it was confirmed in game |
| `verified` | the date (YYYY-MM-DD) someone last did this step in the retail game, for example `verified = "2026-11-02"`. A step without it counts as **unverified** |
| `unverified` | `true` marks a line written from a capture or a log that nobody has walked through yet. Shown to players as unverified once the add-on renders it |
| `flag` | `"check at 119"` when the step may no longer apply to the game at level 119 (old level-synced groups, slow travel, old requirements). Flagged steps go to the owner before they are used |

Today the add-on keeps these extra fields with the step and does not draw them yet; they are for the review below and for a later display. Unknown fields are harmless.

## Retail game at level 119

Write for the retail game as it plays now, with a level 119 character. Do not copy private-server (Horizon-style) behaviour, and do not assume the 75-era game: many old walkthrough steps assume level-synced groups, slow travel and old requirements. If a step cannot be checked in the retail game, mark it `unverified` and leave the guess out.

## Review checklist (per mission, before a mission file is committed)

1. **Readable in one pass** by a brand-new player: plain words, nothing unexplained, no jargon without its meaning.
2. **One target per step** (GO / TALK / INTERACT / FIGHT) with the place and the done-when. Anything else is a Details note, not a step.
3. **Modern shortcuts as information, not steps** (`modern`): home points, survival guides, Unity warp, waypoints, trusts, level sync and capped fights. Only where confirmed in game.
4. **Anything unverified is marked** `unverified` (or has no `verified` date). Never fill the gap with a guess.
5. **Steps that no longer apply at 119** carry `flag = "check at 119"` and go to the owner.
6. **Sources:** own words, from play, captures or game data. Nothing copied or reworded from a website.
7. **Keys:** each `key` is unique inside the mission and never changes once a player could have ticked it.

## Tips and advice

Decision 2026-10-31 (owner): **tips, warnings and travel advice are dropped from anything that ships until they come from the owner's own play.** The roughly 278 tip lines in the local curated overlays stay local and are never copied here.

A tip line (`tip = true`) enters a mission file only with a `from_play` note: the date and what showed it, for example `from_play = "2026-11-02, bridge capture: Home Point was 12 yalms from the NPC"`. A tip with no `from_play` is rejected at review. Do not carry anything over from the curated overlays or from any website.

## The 110 curated missions

The curated overlays (`curated/`, local only) hold target lines for 110 missions. They stay local, and those missions stay **skeleton-only in the release**, until each mission has been re-confirmed by a play pass (the owner plays it at 119 with the bridge on, and the lines are written from what the game showed), or BG Wiki gives a written OK. Only then is a mission added to `own/<storyline>.lua`.
