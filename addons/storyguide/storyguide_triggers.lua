-- Evidence triggers: what the game does when a step is done, so the step ticks itself ([a]; //sg undo overrides it). Keyed by mission id, then step key.
-- Only events seen in a capture (data/<char>/evidence.tsv) belong here; the comment on each says which one. A trigger matches on every field it lists.
--   {kind = 'zone',  zone = <zone name>}                         zoning into that zone
--   {kind = 'event', zone = <zone name>, menu = <id>, npc = <name>}   a cutscene/menu event packet (0x032/0x034) from that NPC
return {
    ['Promathia Mission 3-3'] = {   -- The Road Forks
        p3s1 = {{kind = 'zone', zone = "Northern San d'Oria"}},                                    -- capture 2026-10-15 19:54 zone event
        p3s2 = {{kind = 'event', zone = "Northern San d'Oria", menu = 51, npc = 'Arnau'}},        -- capture 2026-10-15 20:02 event32; the cutscene was seen
    },
}
