--buffbox rolls: Corsair roll values by roll number. Pure (no windower.*).
--
-- The value table is copied from RollTracker 1.8.1.1 (forks/rolltracker/rolltracker.lua, rollInfoTemp),
-- keeping only the base values 1-11, the bust value, the effect text and lucky/unlucky numbers.
-- RollTracker's own comments mark which rows are "Confirmed" and which "Needs Eval"; its gear and
-- job bonuses are not applied here, so every value shown is the BASE value for that number.
--
-- Copyright (c) 2013-2014, Thomas Rogers
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
--     * Redistributions of source code must retain the above copyright
--       notice, this list of conditions and the following disclaimer.
--     * Redistributions in binary form must reproduce the above copyright
--       notice, this list of conditions and the following disclaimer in the
--       documentation and/or other materials provided with the distribution.
--     * Neither the name of RollTracker nor the
--       names of its contributors may be used to endorse or promote products
--       derived from this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THOMAS ROGERS BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

local rolls = {}

-- Values: RollTracker's table only (the wiki-derived table that used to take priority was removed 2026-10-31).
-- RollTracker marks which rows it has confirmed; the rest are its estimates, so treat a value as the base number, not gospel.

-- name = {v1..v11, bust, effect, lucky, unlucky}
local T = {
    ['Allies\''] =      {6,7,17,9,11,13,15,17,17,5,17,'?','% Skillchain Damage',3,10},
    ['Avenger\'s'] =    {'?','?','?','?','?','?','?','?','?','?','?','?',' Counter Rate',4,8},
    ['Beast'] =         {64,80,96,256,112,128,160,32,176,192,320,'0','% Pet: Attack Bonus',4,8},
    ['Blitzer\'s'] =    {2,3.4,4.5,11.3,5.3,6.4,7.2,8.3,1.5,10.2,12.1,'-3','% Attack delay reduction',4,9},
    ['Bolter\'s'] =     {0.3,0.3,0.8,0.4,0.4,0.5,0.5,0.6,0.2,0.7,1.0,'0','% Movement Speed',3,9},
    ['Caster\'s'] =     {6,15,7,8,9,10,5,11,12,13,20,'-10','% Fast Cast',2,7},
    ['Chaos'] =         {64,80,96,256,112,128,160,32,176,192,320,'-9.76','% Attack',4,8},
    ['Choral'] =        {8,42,11,15,19,4,23,27,31,35,50,'+25',' Spell Interruption Rate down',2,6},
    ['Companion\'s'] =  {{4,20},{20,50},{6,20},{8,20},{10,30},{12,30},{14,30},{16,40},{18,40},{3,10},{25,60},'0',' Pet: Regen/Regain',2,10},
    ['Corsair\'s'] =    {10,11,11,12,20,13,15,16,8,17,24,'-6','% Experience Bonus',5,9},
    ['Courser\'s'] =    {'?','?','?','?','?','?','?','?','?','?','?','?',' Snapshot',3,9},
    ['Dancer\'s'] =     {3,4,12,5,6,7,1,8,9,10,16,'-4',' Regen',3,7},
    ['Drachen'] =       {10,13,15,40,18,20,25,5,28,30,50,'0',' Pet: Accuracy Bonus',4,8},
    ['Evoker\'s'] =     {1,1,1,1,3,2,2,2,1,3,4,'-1',' Refresh',5,9},
    ['Fighter\'s'] =    {2,2,3,4,12,5,6,7,1,9,18,'-4','% Double Attack',5,9},
    ['Gallant\'s'] =    {48,60,200,72,88,104,32,120,140,160,240,'-11.72','% Defense Bonus',3,7},
    ['Healer\'s'] =     {3,4,12,5,6,7,1,8,9,10,16,'-4','% Cure Potency Received',3,7},
    ['Hunter\'s'] =     {10,13,15,40,18,20,25,5,28,30,50,'-15',' Accuracy Bonus',4,8},
    ['Magus\'s'] =      {5,20,6,8,9,3,10,13,14,15,25,'-8',' Magic Defense Bonus',2,6},
    ['Miser\'s'] =      {30,50,70,90,200,110,20,130,150,170,250,'0',' Save TP',5,7},
    ['Monk\'s'] =       {8,10,32,12,14,15,4,20,22,24,40,'-?',' Subtle Blow',3,7},
    ['Naturalist\'s'] = {6,7,15,8,9,10,5,11,12,13,20,'-5','% Enhancing Magic Duration',3,7},
    ['Ninja'] =         {10,13,15,40,18,20,25,5,28,30,50,'-15',' Evasion Bonus',4,8},
    ['Puppet'] =        {5,8,35,11,14,18,2,22,26,30,40,'-8',' Pet: MAB/MAcc',3,7},
    ['Rogue\'s'] =      {2,2,3,4,12,5,6,6,1,8,14,'-6','% Critical Hit Rate',5,9},
    ['Runeist\'s'] =    {10,13,15,40,18,20,25,5,28,30,50,'-15',' Magic Evasion Bonus',4,8},
    ['Samurai'] =       {8,32,10,12,14,4,16,20,22,24,40,'-10',' Store TP Bonus',2,6},
    ['Scholar\'s'] =    {2,10,3,4,4,1,5,6,7,7,12,'-3','% Conserve MP',2,6},
    ['Tactician\'s'] =  {10,10,10,10,30,10,10,0,20,20,40,'-10',' Regain',5,8},
    ['Warlock\'s'] =    {10,13,15,40,18,20,25,5,28,30,50,'-15',' Magic Accuracy Bonus',4,8},
    ['Wizard\'s'] =     {4,6,8,10,25,12,14,17,2,20,30,'-10',' MAB',5,9},
}
-- RollTracker converts these from /1024 to percent; Bolter's from speed units (5.0 = 100%).
local PER_1024 = {['Beast'] = true, ['Chaos'] = true, ['Gallant\'s'] = true}

-- "Chaos Roll" (job ability and buff share the name in res/) -> "Chaos".
function rolls.key(name)
    local k = type(name) == 'string' and name:match('^(.-) Roll$')
    return k and T[k] and k or nil
end

-- One line for roll `num` (1-12) of roll `key`, base value only, e.g.
-- "11 (lucky): +31.25% Attack" or "12 (bust): -9.76% Attack".
function rolls.describe(key, num)
    local r = T[key]
    if not r or type(num) ~= 'number' or num < 1 or num > 12 then return nil end
    local v, effect = r[num], r[13]
    local tag = (num == 12 and ' (bust)') or ((num == r[14] or num == 11) and ' (lucky)')
        or (num == r[15] and ' (unlucky)') or ''
    local text
    if type(v) == 'table' then
        text = ('Pet: Regen +%d, Regain +%d'):format(v[1], v[2])
    elseif v == '?' or v == '-?' then
        text = '?' .. effect
    else
        v = tonumber(v)
        -- The bust column is already in percent; only 1-11 need converting.
        if num <= 11 and PER_1024[key] then v = v / 1024 * 100
        elseif num <= 11 and key == 'Bolter\'s' then v = v * 20 end
        -- Round half up ourselves: %.2f of 3.125 gives 3.12 on glibc, 3.13 on the Windows CRT.
        local s = (v == math.floor(v)) and ('%d'):format(v) or ('%.2f'):format(math.floor(v * 100 + 0.5) / 100)
        text = ((v > 0) and '+' or '') .. s .. effect
    end
    return ('%d%s: %s'):format(num, tag, text)
end

return rolls
