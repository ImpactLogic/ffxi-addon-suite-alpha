# Story Guide 0.18.1

Track your place in FFXI missions and quests. The release includes 23 storyline lists and a local progress display. Missions without original step text show their name and an empty steps view.

1. Load with `//lua l storyguide` and show the box with `//sg box on`.
2. Type `//sg list` and choose a storyline with `//sg track <name>`.
3. Check your in-game Mission menu and set that position with `//sg at <mission>`.
4. Use `//sg status` to check the saved position. When you reach a new mission, confirm it again with `//sg at`.

When a mission has step text, `//sg done <n>` and `//sg undo <n>` edit your checklist. Progress and evidence are stored in the addon’s local data folder. This build expects manual mission confirmation. It comes without walkthrough text and automatic position lookup tables.

See [original step authoring](own/README.md) for adding steps based on retail play.

<img src="brand.svg" alt="Story Guide logo" width="64">
