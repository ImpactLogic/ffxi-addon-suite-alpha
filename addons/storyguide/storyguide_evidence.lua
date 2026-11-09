-- Observed facts about the game's mission data that the id tables (generated from XIchecklist) do not say. Numbers only; every line cites a capture.
--
-- skipped: bit keys (the index in the "completed missions" page) that a character who FINISHED the storyline never has set, so they cannot be required.
-- One character, captured 2026-10-07 (charsync progress.tsv, page 0x00D0), had all three nation tracks done through the last mission and these bits clear:
return {
    skipped = {
        ['san-d-oria'] = {[4] = true, [11] = true},
        ['bastok'] = {[4] = true, [11] = true},
        ['windurst'] = {[4] = true},
    },
}
