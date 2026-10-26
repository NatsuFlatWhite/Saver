require "TxBase"
require "TxRace.PveNpc"
module(..., package.seeall, TxBase.Object.inherit())

local NPC = TxRace.PveNpc
local bugNames = {"slower", "curse", "smell"}
local whirlCooldownMs = 60000
local spawnSpots = require "Darkcity.Spots"
local patrolRoutes = require "Darkcity.Patrols"

local startPositions = {"-628.9 -500.5 100.3", "-387.9 1086.9 64.1", "1511 -760.4 46.8"}

local boxNames = {"nos", "sp", "transparent", "hp"}
local boxEffects = {nos = "Item_Boo", sp = "Saver_SPRecover",
    transparent = "Saver_Antizombie", hp = "Saver_Recover"}
local soulPersons = {168, 169, 170, 171, 173}
local setNpc, clearBugs

local function enabled(value, fallback)
    if value == nil then return fallback end
    return value == true or value == 1 or value == "1" or value == "true"
end

local function number(value, fallback, low, high)
    value = tonumber(value) or fallback
    if value ~= value or value == math.huge or value == -math.huge then value = fallback end
    return math.max(low, math.min(high, value))
end

local function expired(tick, now)
    return tick and Tick__Compare(tick, now) <= 0
end

local function soulValue(game, npc)
    local point = npc.basePoint
    if game.healthPoints then point = math.max(1, math.floor(point * npc.hp / 300)) end
    return point
end

local function drawGold(game)
    if game.goldEvery <= 0 then return false end
    if game.goldEvery == 1 then return true end
    return math.random(game.goldEvery) == 1
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function fieldMovement(game, npc)
    local movement = NPC:Movement_Field(npc.pos, "1 0 0")
    if npc.patrol then
        movement.speed = game.zombieSpeed

        for i, pos in ipairs(npc.patrol.points) do
            movement["pos" .. i] = tostring(Vector3.new(pos[1], pos[2], pos[3]))
        end
        npc.patrolUntil = Tick__Add(Tick__Cur(), math.ceil(npc.patrol.length / game.zombieSpeed * 1000) + 1000)
    end
    return movement
end

local function protectUntil(game, player, untilTick, now)
    if not player.protectedUntil or Tick__Compare(player.protectedUntil, untilTick) < 0 then
        player.protectedUntil = untilTick
    end
    game.raw:addTransparent(player.id, math.max(1, Tick__Sub(player.protectedUntil, now)))
end

local function startShadow(game)
    local now = Tick__Cur()
    if game.shadowStarted or game.shadowMs <= 0 or Tick__Compare(now, game.shadowTick) < 0
        or Tick__Compare(now, game.beginTick) < 0 or expired(game.endTick, now) then return end
    game.shadowStarted = true
    local duration = math.max(1, Tick__Sub(game.endTick, now))
    for _, player in pairs(game.players) do
        protectUntil(game, player, game.endTick, now)
    end

end

local function createBox(game, box)
    game.nextBox = game.nextBox + 1
    if box.idx then game.boxById[box.idx] = nil end
    box.idx, box.active, box.respawn = game.nextBox, true, nil
    game.boxById[box.idx] = box
    game.raw:sendCreateItemBox(nil, {{itemBoxIdx = box.idx, name = box.name, pos = box.pos}})
end

local function makeBoxes(game)
    game.boxes, game.boxById = {}, {}
    local spots = {}
    for i, pos in ipairs(game.spawnSpots) do spots[i] = pos end
    local sx, sy = game.pos:match("^%s*([%d.+-]+)%s+([%d.+-]+)")
    sx, sy = tonumber(sx), tonumber(sy)
    table.sort(spots, function(a, b)
        local ad = (a[1] - sx)^2 + (a[2] - sy)^2
        local bd = (b[1] - sx)^2 + (b[2] - sy)^2
        return ad < bd
    end)
    local fieldSpots = {}
    for i = 5, #spots do fieldSpots[#fieldSpots + 1] = spots[i] end
    shuffle(fieldSpots)
    for i = 1, game.boxCount do

        local pos = i <= 4 and spots[i] or fieldSpots[((i - 5) % #fieldSpots) + 1]
        local box = {name = boxNames[((i - 1) % #boxNames) + 1], pos = Vector3.new(pos[1], pos[2], pos[3])}
        game.boxes[i] = box
        createBox(game, box)
    end

end

local function eatBox(game, player, idx)
    local box = game.boxById[idx]
    if not box or not box.active then return end
    box.active, box.respawn = false, Tick__Add(Tick__Cur(), game.boxRespawnMs)
    game.raw:sendDeleteItemBox(nil, {idx})
    if box.name == "nos" then

        game.raw:sendSkillUsing(player.id, 103, {spentSp = 0, waitTime = 0,
            affectTime = 10, param1 = 100, param2 = 1000, param3 = 0, param4 = 0})
    elseif box.name == "sp" then
        game.raw:increaseSP(player.id, 100)
    elseif box.name == "transparent" then
        local now = Tick__Cur()
        protectUntil(game, player, Tick__Add(now, 10000), now)
        clearBugs(game, player)
    else
        local damages = {}
        for i = 1, 5 do
            local npc = player.slots[i]
            if npc then
                damages[#damages+1] = {npcIdx = npc.idx, hpDiff = math.ceil(300 - npc.hp), maxHp = 300}
                npc.hp, npc.hpTick, npc.point = 300, Tick__Cur(), npc.basePoint
                setNpc(game, npc, {point = npc.point})
            end
        end
        game.raw:sendSetNpcHp(player.id, damages)
    end
    game.raw:setRelementEffect(player.id, boxEffects[box.name])

end

setNpc = function(game, npc, param)
    for k, v in pairs(param) do npc.param[k] = v end
    game.raw:sendSetNpc(npc.idx, param)
end

local function detach(game, npc, movement, respawn)
    if npc.owner then
        local player = game.players[npc.owner]
        if player then player.slots[npc.slot] = nil end
    end
    npc.owner, npc.slot, npc.hpTick = nil, nil, nil
    npc.respawn = respawn and not npc.consumed and Tick__Add(Tick__Cur(), game.respawnMs) or nil
    if npc.consumed then npc.destroyTick = Tick__Add(Tick__Cur(), 1000) end
    setNpc(game, npc, {movement = movement})
end

local function updateAttr(game, player)
    game.raw:sendSetPlayerAttr(nil, {[player.id] = {
        point = player.point, totalPoint = player.totalPoint,

        score1 = player.rescuedSoulCount, score2 = player.scores[2] or 0,
        whirl = {enabled = true, coolTime = whirlCooldownMs, sp = 20}, attack = false,
    }})
end

local function comboValue(game, team, now)
    local combo = game.combo[team]
    if not combo then return 0 end
    local chargeMs = math.floor(combo.count * 1000 + 0.5)
    return math.max(0, chargeMs - math.max(0, Tick__Sub(now, combo.tick))) / 1000
end

local function comboSnapshot(game, init)
    local now = Tick__Cur()
    return {init = init and 1 or 0, round = game.round, tick = now,
        count1 = comboValue(game, 1, now), count2 = comboValue(game, 2, now),
        count3 = comboValue(game, 3, now), count4 = comboValue(game, 4, now)}
end

local function publishRank(game, final)
    local sorted, teams, totals, order, teamOrder, resultTeams = {}, {}, {}, {}, {}, {}
    for id, player in pairs(game.players) do
        sorted[#sorted + 1] = player
        teams[player.team] = (teams[player.team] or 0) + player.point
        totals[player.team] = (totals[player.team] or 0) + player.totalPoint
    end
    table.sort(sorted, function(a, b)
        local ap, bp = a.point, b.point
        if final then ap, bp = a.totalPoint, b.totalPoint end
        if ap ~= bp then return ap > bp end
        return a.slotNo < b.slotNo
    end)
    for i, player in ipairs(sorted) do order[i] = player.id end
    if game.teamCount > 1 then
        for i = 1, game.teamCount do teamOrder[i], resultTeams[i] = i, i end
        table.sort(teamOrder, function(a, b)
            if (teams[a] or 0) ~= (teams[b] or 0) then return (teams[a] or 0) > (teams[b] or 0) end
            return a < b
        end)
        table.sort(resultTeams, function(a, b)
            if (totals[a] or 0) ~= (totals[b] or 0) then return (totals[a] or 0) > (totals[b] or 0) end
            return a < b
        end)
    end

    if game.teamCount > 1 then game.raw:sendRank(order, order, teamOrder, resultTeams, comboSnapshot(game))
    else game.raw:sendRank(order, order) end
    return sorted, final and resultTeams or teamOrder, final and totals or teams
end

local function damagePassengers(game, player, amount)
    local damages = {}
    for i = 1, 5 do
        local npc = player.slots[i]
        if npc then
            npc.hp = math.max(0, npc.hp - amount)
            if npc.hp > 0 then
                npc.point = soulValue(game, npc)
                setNpc(game, npc, {point = npc.point})
            end
            damages[#damages + 1] = {npcIdx = npc.idx, hpDiff = -amount, maxHp = 0}
        end
    end
    game.raw:sendSetNpcHp(player.id, damages)
    for i = 1, 5 do
        local npc = player.slots[i]
        if npc and npc.hp <= 0 then detach(game, npc, NPC:Movement_Die(), true) end
    end
end

clearBugs = function(game, player)
    local ids = {}
    for i, bug in ipairs(player.bugs) do ids[i] = bug.idx end
    player.bugs = {}
    if #ids > 0 then
        game.raw:sendBlowBug(player.id, ids)
    end
end

local function decayPassenger(player, npc, now)
    local elapsed = math.max(0, Tick__Sub(now, npc.hpTick))
    local cursedMs = 0
    if player.curseStarted and player.curseUntil then
        local first = math.max(0, Tick__Sub(player.curseStarted, npc.hpTick))
        local last = math.min(elapsed, Tick__Sub(player.curseUntil, npc.hpTick))
        cursedMs = math.max(0, last - first)
    end
    npc.hp = math.max(0, npc.hp - (elapsed + 2 * cursedMs) * 0.01)
    npc.hpTick = now
end

local function checkBugs(game, player, upto)
    local counts, eligible = {}, {}
    for _, bug in ipairs(player.bugs) do
        if not upto or bug.idx <= upto then
            counts[bug.name] = (counts[bug.name] or 0) + 1
            eligible[#eligible + 1] = bug
        end
    end
    local all = #eligible >= 5
    local removed, kept, effects = {}, {}, {}
    for _, bug in ipairs(player.bugs) do
        if (not upto or bug.idx <= upto) and (all or counts[bug.name] >= 3) then
            removed[#removed + 1] = bug.idx

            if counts[bug.name] >= 3 then effects[bug.name] = true end
        else kept[#kept + 1] = bug end
    end
    player.bugs = kept
    if #removed == 0 then return end

    game.raw:sendBlowBug(player.id, removed)
    local now = Tick__Cur()
    if effects.slower then
        game.raw:addRpmPenalty(player.id, 0.5, 10000)

    end
    if effects.curse then

        for _, npc in pairs(player.slots) do decayPassenger(player, npc, now) end
        player.curseStarted = now
        player.curseUntil = Tick__Add(now, 10000)
        game.raw:setNpcHpIncrementFactor(player.id, 3, 10000)
    end
    if effects.smell then
        player.cannotRescueUntil = Tick__Add(now, 10000)
        game.raw:setCannotRescue(player.id, 10000)
    end
    if all then
        game.raw:blowPlayer(player.id, 30, 10)
        damagePassengers(game, player, 80)
    end
end

local function leave(game, id)
    local player = game.players[id]
    if not player then return end
    for i = 1, 5 do
        local npc = player.slots[i]
        if npc then detach(game, npc, NPC:Movement_Die(), true) end
    end
    clearBugs(game, player)
    game.players[id] = nil
end

local function handlePlayEvent(game, event)
    local id = tonumber(event.characterId)
    local player = game.players[id]
    local now = Tick__Cur()
    if event._NAME == "leave" then
        leave(game, id)
        publishRank(game)
        return
    end
    if not player or Tick__Compare(now, game.beginTick) < 0 or expired(game.endTick, now) then return end
    if event._NAME == "hitByNpc" then
        local npc = game.npcs[tonumber(event.npcIdx)]
        if not npc or npc.param.movement.type ~= "field" then
            game.raw:sendNpcHitResult(id, event.npcIdx, false)
            return
        end
        if npc.kind == "friendly" then
            local slot
            local lowest, lowestPoint
            for i = 1, 5 do
                local passenger = player.slots[i]
                if passenger then
                    decayPassenger(player, passenger, now)
                    if passenger.hp <= 0 then
                        detach(game, passenger, NPC:Movement_Die(), true)
                        if not slot then slot = i end
                    else
                        local point = soulValue(game, passenger)
                        if not lowestPoint or point < lowestPoint then lowest, lowestPoint = i, point end
                    end
                elseif not slot then slot = i end
            end
            if not slot then
                if soulValue(game, npc) <= lowestPoint then
                    game.raw:sendNpcHitResult(id, npc.idx, false)
                    return
                end
                slot = lowest
                detach(game, player.slots[slot], NPC:Movement_Die(), true)
            end
            player.slots[slot] = npc
            npc.owner, npc.slot, npc.hp, npc.hpTick, npc.point = id, slot, 300, now, npc.basePoint
            if npc.site then
                npc.consumed = true
                npc.site.refill = Tick__Add(now, game.fieldRespawnMs)
            end

            setNpc(game, npc, {movement = NPC:Movement_Ride(id, slot), hp = NPC:HP(300, 300, -10), point = npc.point})
        elseif player.protectedUntil and not expired(player.protectedUntil, now) then
            game.raw:sendNpcHitResult(id, npc.idx, false)
        elseif npc.hostileType == "blow" then
            detach(game, npc, NPC:Movement_Die(), true)
            setNpc(game, npc, {blow = NPC:Blow_Player(id, 30, 10)})
            damagePassengers(game, player, 80)
        else
            game.raw:sendNpcHitResult(id, npc.idx, false)
            if not player.hitCooldown[npc.idx] or expired(player.hitCooldown[npc.idx], now) then
                player.hitCooldown[npc.idx] = Tick__Add(now, 2000)
                game.nextBug = game.nextBug + 1
                local bug = {idx = game.nextBug, name = bugNames[math.random(#bugNames)], readyTick = Tick__Add(now, 2000)}
                player.bugs[#player.bugs + 1] = bug
                game.raw:sendCreateBug(id, npc.idx, bug.idx, bug.name)

            end
        end
    elseif event._NAME == "setNpcHp" then
        local npc = game.npcs[tonumber(event.npcIdx)]

        if npc and npc.owner == id and tonumber(event.hp) and tonumber(event.hp) <= 0 then
            detach(game, npc, NPC:Movement_Die(), true)
        end
    elseif event._NAME == "destEvent" then
        local dest = tonumber(event.destIdx)
        if not game.destinations[dest] or (player.cannotRescueUntil and not expired(player.cannotRescueUntil, now)) then
            game.raw:sendDestEventResult(id, event.destIdx, false)
            return
        end
        local souls = {}
        for i = 1, 5 do
            local npc = player.slots[i]
            if npc then
                decayPassenger(player, npc, now)
                if npc.hp <= 0 then detach(game, npc, NPC:Movement_Die(), true)
                else
                    npc.point = soulValue(game, npc)
                    souls[#souls + 1] = npc
                end
            end
        end
        if #souls == 0 then
            game.raw:sendDestEventResult(id, dest, true)
            return
        end
        local combo = game.combo[player.team] or {count = 0, tick = now}
        combo.count = comboValue(game, player.team, now)
        local bonus = game.teamCount > 1 and (1 + math.min(4, math.floor(combo.count / 5)) * 0.25) or 1
        local points = 0
        for _, npc in ipairs(souls) do

            points = points + math.floor(npc.point * (npc.gold and 2 or 1) * bonus)
            detach(game, npc, NPC:Movement_Rescue(), true)
        end
        combo.count, combo.tick = math.min(25, combo.count + #souls), now
        game.combo[player.team] = combo
        player.point, player.totalPoint = player.point + points, player.totalPoint + points
        player.rescuedSoulCount = player.rescuedSoulCount + #souls
        player.scores[game.round] = player.point
        updateAttr(game, player)
        game.raw:increaseSP(id, #souls * 5)
        publishRank(game)
        game.raw:sendDestEventResult(id, dest, true)
    elseif event._NAME == "whirl" then
        if player.whirlUntil and not expired(player.whirlUntil, now) then

            return
        end
        player.whirlUntil = Tick__Add(now, whirlCooldownMs)

        local count = #player.bugs > 0 and math.random(1, 3) or 0
        local ids = {}
        for i = 1, math.min(count, #player.bugs) do
            ids[i] = table.remove(player.bugs, 1).idx
        end
        if #ids > 0 then game.raw:sendWindBug(id, ids) end

    elseif event._NAME == "checkBug" then
        checkBugs(game, player, tonumber(event.bugIdx))
    elseif event._NAME == "eatItemBox" then
        eatBox(game, player, tonumber(event.itemBoxIdx))
    elseif event._NAME == "outOfField" or event._NAME == "playerOutOfField" then
        damagePassengers(game, player, 300)
    end
end

local function refillSoul(game, site)
    game.nextNpc = game.nextNpc + 1
    local point = game.variablePoints and math.random(game.soulPointMin, game.soulPointMax) or game.soulPoint
    local npc = {idx = game.nextNpc, pos = site.pos, site = site, kind = "friendly",
        basePoint = point, gold = drawGold(game), hp = 300}
    npc.point = soulValue(game, npc)
    npc.param = {type = "friendly", hostileType = "friendly", interactType = "follow", movement = fieldMovement(game, npc),
        action = NPC:Action_Rescue(), point = npc.point, gold = npc.gold, hp = NPC:HP(300, 300, 0)}
    game.npcs[npc.idx] = npc
    site.refill = nil
    game.raw:sendCreateNpc(npc.idx, soulPersons[math.random(#soulPersons)], Vector3.new(0, 0, 0), 5, npc.param)

end

local function pulse(game)
    local now = Tick__Cur()
    startShadow(game)
    for _, player in pairs(game.players) do
        local upto
        for _, bug in ipairs(player.bugs) do
            if expired(bug.readyTick, now) then upto = bug.idx else break end
        end
        if upto then checkBugs(game, player, upto) end
    end
    local destroyed = {}
    for _, npc in pairs(game.npcs) do
        if expired(npc.destroyTick, now) then
            destroyed[#destroyed + 1] = npc.idx
        elseif npc.owner then
            local player = game.players[npc.owner]
            decayPassenger(player, npc, now)
            if npc.hp <= 0 then detach(game, npc, NPC:Movement_Die(), true)
            else
                local point = soulValue(game, npc)
                if point ~= npc.point then
                    npc.point = point
                    setNpc(game, npc, {point = point})
                end
            end
        elseif expired(npc.respawn, now) then
            npc.respawn = nil
            if game.variablePoints and npc.kind == "friendly" then
                npc.basePoint = math.random(game.soulPointMin, game.soulPointMax)
            end
            npc.hp = 300
            npc.gold = npc.kind == "friendly" and drawGold(game) or false
            npc.point = soulValue(game, npc)
            setNpc(game, npc, {movement = fieldMovement(game, npc), hp = NPC:HP(300, 300, 0), point = npc.point, gold = npc.gold})
        elseif npc.patrol and expired(npc.patrolUntil, now) and Tick__Compare(now, game.beginTick) >= 0 then
            setNpc(game, npc, {movement = fieldMovement(game, npc)})
        end
    end
    for _, idx in ipairs(destroyed) do
        game.raw:sendDestroyNpc(idx, {})
        game.npcs[idx] = nil
    end
    for _, site in ipairs(game.soulSites) do
        if expired(site.refill, now) then refillSoul(game, site) end
    end
    for _, box in ipairs(game.boxes or {}) do
        if not box.active and expired(box.respawn, now) then createBox(game, box) end
    end
end

local function makeNpcs(game)
    game.npcs, game.soulSites = {}, {}
    local count = game.friendlyCount + game.hostileCount
    local positions = game.raw:getSpotList(game.region, count) or {}
    if #positions < count then

        positions = {}
        local candidates = {}
        for i, pos in ipairs(game.spawnSpots) do candidates[i] = pos end
        shuffle(candidates)
        for i = 1, math.min(count, #game.spawnSpots) do
            local pos = candidates[i]
            positions[i] = Vector3.new(pos[1], pos[2], pos[3])
        end
    end

    shuffle(positions)
    local usedPatrols = {}
    local actualCount = math.min(count, #positions)
    game.nextNpc = actualCount
    local friendlyCount = math.min(game.friendlyCount, math.floor(actualCount * game.friendlyCount / count))
    local friendlyPositions, hostilePositions = {}, {}

    for i = 1, actualCount do
        local list = math.floor(i * friendlyCount / actualCount) > math.floor((i - 1) * friendlyCount / actualCount)
            and friendlyPositions or hostilePositions
        list[#list + 1] = positions[i]
    end

    for i = 1, actualCount do
        local friendly = i <= friendlyCount
        local explosive = (i % 3 == 0)
        local gold = friendly and drawGold(game) or false
        local point = game.soulPoint
        if friendly and game.variablePoints then point = math.random(game.soulPointMin, game.soulPointMax) end
        local pos = friendly and friendlyPositions[i] or hostilePositions[i - friendlyCount]
        local npc = {idx = i, pos = pos, kind = friendly and "friendly" or "hostile",
            hostileType = explosive and "blow" or "throw", basePoint = point, gold = gold, hp = 300}
        npc.point = soulValue(game, npc)
        if friendly and game.replacePickedSouls then
            npc.site = {pos = pos}
            game.soulSites[#game.soulSites + 1] = npc.site
        end
        if not friendly then
            local nearest, distance
            for routeId, route in ipairs(game.patrols) do
                local p = route.points[1]
                local d = (p[1] - pos.x)^2 + (p[2] - pos.y)^2 + (p[3] - pos.z)^2
                if usedPatrols[routeId] then d = d + 100000000 end
                if not distance or d < distance then nearest, distance = route, d; npc.routeId = routeId end
            end
            usedPatrols[npc.routeId] = true
            npc.patrol = nearest
            local p = nearest.points[1]
            npc.pos = Vector3.new(p[1], p[2], p[3])
        end
        npc.param = {type = npc.kind, interactType = friendly and "follow" or "touch", movement = fieldMovement(game, npc),
            action = friendly and NPC:Action_Rescue() or NPC:Action_Attack(),
            point = npc.point, gold = gold, hostileType = npc.kind, hp = NPC:HP(300, 300, 0)}
        game.npcs[i] = npc

        game.raw:sendCreateNpc(i, friendly and soulPersons[((i - 1) % #soulPersons) + 1] or (explosive and 167 or (i % 2 == 0 and 166 or 165)),
            Vector3.new(0, 0, 0), 5, npc.param)
    end
end

local function waitEvent(thread)
    while true do
        local disp, event = thread:Wait()
        if disp == "pve" then return event end
    end
end

local function waitTimer(thread, game, name)
    while true do
        local event = waitEvent(thread)
        if event._NAME == "close" then return false end
        if event._NAME == "leave" then leave(game, tonumber(event.characterId)) end
        if not next(game.players) then return false end
        if event._NAME == name then return true end
    end
end

local function rewardInfo(game)
    local items = {}
    if game.teamCount > 1 then
        for i = 1, 4 do items['item' .. i] = {itemId = 19753 + i, teamRank = i} end
    else
        items.item1 = {itemId = 19576, minRank = 1, maxRank = 2}
        items.item2 = {itemId = 19575, minRank = 3, maxRank = 5}
        items.item3 = {itemId = 19573, minRank = 6, maxRank = 10}
    end
    return {items = items}
end

local function sendRoundReward(game, player, rank, teamRank)
    if player.paidRounds[game.round] then return end
    local dropName
    if game.teamCount > 1 then
        if game.round == 2 then dropName = 'item' .. teamRank end
    else
        if game.round == 2 and rank <= 10 then
            dropName = rank <= 2 and 'item1' or (rank <= 5 and 'item2' or 'item3')
        end
    end
    player.paidRounds[game.round] = true
    game.raw:sendResult(player.id, {
        reward = {point = player.point, exp = player.point, carExp = player.point,
            rain = math.floor(player.point / 10), dropName = dropName},
        rewardInfo = rewardInfo(game), rank = rank, point = player.point, totalPoint = player.totalPoint,

        saverReward = {round = game.round, point = player.point, rank = rank,
            teamCount = game.teamCount, teamRank = teamRank or 0},
    })

end

local function playRound(thread, game)
    local raw = game.raw
    game.combo, game.destinations = {}, {[1] = true}
    game.npcs, game.boxes, game.boxById = {}, {}, {}
    if game.startIndex then game.pos = startPositions[((game.startIndex + game.round - 2) % #startPositions) + 1] end
    for _, player in pairs(game.players) do
        player.slots, player.bugs, player.hitCooldown = {}, {}, {}
        player.point, player.loadingDone = 0, false
        player.curseStarted, player.curseUntil, player.cannotRescueUntil, player.whirlUntil = nil, nil, nil, nil
        player.protectedUntil = nil
    end
    local param = {region = game.region, pos = game.pos, roundId = game.round,
        teamCount = game.teamCount, rideNpc = true, score = true, whirl = true,
        rewardInfo = rewardInfo(game), darkcity = {bugSlotCount = 5}}
    local x, y, z = game.pos:match("^%s*([%d.+-]+)%s+([%d.+-]+)%s+([%d.+-]+)%s*$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then

        return false
    end

    if game.teamCount > 1 then raw:sendRank({}, {}, {1, 2, 3, 4}, {1, 2, 3, 4}, comboSnapshot(game, true)) end
    for id in pairs(game.players) do
        raw:sendStart(id, param, {region = game.region, pos = game.pos})
    end

    local loadingTimer = "saver_loading_" .. game.round
    raw:setTimer(loadingTimer, nil, 60000)
    while true do
        local event = waitEvent(thread)
        if event._NAME == "close" then return false end
        if event._NAME == "leave" then leave(game, tonumber(event.characterId)) end
        if event._NAME == "loadingDone" then
            local player = game.players[tonumber(event.characterId)]
            if player then player.loadingDone = true end
        elseif event._NAME == loadingTimer then
            local kick = {}
            for id, player in pairs(game.players) do if not player.loadingDone then kick[#kick+1] = id end end
            for _, id in ipairs(kick) do
                leave(game, id)
                if raw:kickPlayer(id, 1) then return false end
            end
        end
        if not next(game.players) then return false end
        local ready = true
        for _, player in pairs(game.players) do if not player.loadingDone then ready = false end end
        if ready then break end
    end

    raw:sendCreateDest(nil, {{destIdx = 1, actionType = 0, color = "green", spline = {
        Vector3.new(x-20, y-20, z), Vector3.new(x-20, y+20, z),
        Vector3.new(x+20, y+20, z), Vector3.new(x+20, y-20, z)}}})
    raw:sendSetDest(nil, {1}, true)
    makeNpcs(game)
    makeBoxes(game)
    for id, player in pairs(game.players) do raw:sendSetNpcSlotCount(id, 5); updateAttr(game, player) end
    game.beginTick = Tick__Add(Tick__Cur(), game.waitMs)
    game.endTick = Tick__Add(game.beginTick, game.playMs)
    game.shadowStarted = false
    game.shadowTick = Tick__Add(game.beginTick, math.max(0, game.playMs - game.shadowMs))
    raw:sendPlay(nil, game.beginTick, game.endTick)
    publishRank(game)

    local finish = "saver_finish_" .. game.round
    local tick = "saver_tick_" .. game.round
    raw:setTimer(finish, nil, game.waitMs + game.playMs)
    raw:setTimer(tick, nil, 1000)
    local shadow = "saver_shadow_" .. game.round
    if game.shadowMs > 0 then raw:setTimer(shadow, nil, game.waitMs + math.max(0, game.playMs - game.shadowMs)) end
    while true do
        local event = waitEvent(thread)
        if event._NAME == "close" then return false end
        if event._NAME == finish then break end
        if event._NAME == tick then
            pulse(game)
            raw:setTimer(tick, nil, 1000)
        elseif event._NAME == shadow then
            startShadow(game)
        else handlePlayEvent(game, event) end
        if not next(game.players) then return false end
    end

    for _, player in pairs(game.players) do updateAttr(game, player) end
    local sorted, teamOrder = publishRank(game)
    raw:sendFinishRound(game.round)

    if game.round < 2 then
        local teamRanks = {}
        for i, team in ipairs(teamOrder) do teamRanks[team] = i end
        for rank, player in ipairs(sorted) do
            sendRoundReward(game, player, rank, teamRanks[player.team])
        end
    end
    local boxIds = {}
    for _, box in ipairs(game.boxes) do if box.active then boxIds[#boxIds+1] = box.idx end end
    if #boxIds > 0 then raw:sendDeleteItemBox(nil, boxIds) end
    for _, npc in pairs(game.npcs) do raw:sendDestroyNpc(npc.idx, {}) end
    for _, player in pairs(game.players) do
        clearBugs(game, player)
        player.slots = {}
    end
    game.npcs, game.boxes, game.boxById = {}, {}, {}
    game.soulSites = {}
    raw:sendSetDest(nil, {1}, false)
    return true
end

local function main(thread, self)
    thread:SetWait(self.eventDispatcher, "pve")
    local start
    while true do
        local event = waitEvent(thread)
        if event._NAME == "close" then thread:ClearWait(self.eventDispatcher); return end
        if event._NAME == "start" then start = event.param or {}; break end
    end
    local setting = start.setting or {}
    local game = {raw = self.obj_GamePve, players = {}, npcs = {}, nextBug = 0,
        teamCount = number(setting.teamCount, 1, 1, 4), region = "d1",
        pos = setting.pos or "-628.9 -500.5 100.3", playMs = number(setting.playTime, 300, 1, 1800) * 1000,
        waitMs = number(setting.waitTime, 10, 0, 60) * 1000,
        roundResultMs = number(setting.roundResultTime, 15, 5, 60) * 1000,
        shadowMs = number(setting.shadowTime, 30, 0, 60) * 1000,
        zombieSpeed = number(setting.zombieSpeed, 2, 0.5, 6),
        respawnMs = number(setting.respawnTime, 10, 1, 120) * 1000,
        fieldRespawnMs = number(setting.fieldRespawnTime, 5, 1, 30) * 1000,
        replacePickedSouls = enabled(setting.replacePickedSouls, true),
        friendlyCount = math.floor(number(setting.friendlyCount, 420, 1, 2000)),
        hostileCount = math.floor(number(setting.hostileCount, 180, 0, 1000)),
        soulPoint = math.floor(number(setting.soulPoint, 100, 1, 10000)),
        soulPointMin = math.floor(number(setting.soulPointMin, 100, 1, 10000)),
        soulPointMax = math.floor(number(setting.soulPointMax, 400, 1, 10000)),
        variablePoints = enabled(setting.variablePoints, true), healthPoints = enabled(setting.healthPoints, false),
        goldEvery = math.floor(number(setting.goldEvery, 20, 0, 200)),
        boxCount = math.floor(number(setting.boxCount, 120, 0, 250)),
        boxRespawnMs = number(setting.boxRespawnTime, 30, 1, 120) * 1000, nextBox = 10000}
    game.teamCount = game.teamCount > 1 and 4 or 1
    game.spawnSpots = spawnSpots
    game.patrols = patrolRoutes
    if enabled(setting.randomStart, true) then
        for _, pos in ipairs(startPositions) do
            if game.pos == pos then
                game.startIndex = math.random(#startPositions)
                game.pos = startPositions[game.startIndex]
                break
            end
        end
    end
    game.soulPointMax = math.max(game.soulPointMin, game.soulPointMax)
    for key, member in pairs(game.raw:getMemberList()) do
        local id = tonumber(member.characterId) or tonumber(key)
        local slotNo = tonumber(member.slotNo) or 0
        if id then game.players[id] = {id = id, name = member.characterName or tostring(id), slotNo = slotNo,
            team = game.teamCount > 1 and (slotNo % game.teamCount) + 1 or 1,
            point = 0, totalPoint = 0, rescuedSoulCount = 0, paidRounds = {}, scores = {}, slots = {}, bugs = {}} end
    end

    game.raw:sendInfo({region = game.region, pos = game.pos,
        teamCount = game.teamCount, rideNpc = true, score = true, whirl = true,
        rewardInfo = rewardInfo(game), darkcity = {bugSlotCount = 5}})
    local complete = next(game.players) ~= nil
    for round = 1, 2 do
        if not complete then break end
        game.round = round
        complete = playRound(thread, game)
        if complete and round < 2 then

            game.raw:setTimer("saver_intermission", nil, game.roundResultMs)
            complete = waitTimer(thread, game, "saver_intermission")
        end
    end
    if complete then
        local sorted, teamOrder, teamPoints = publishRank(game, true)
        local ranks, result = {}, {teamCount = game.teamCount, characterId2Rank = {}, rankers = {}, teams = {}}
        for i, player in ipairs(sorted) do
            ranks[player.id] = i
            result.characterId2Rank[player.id] = {rank = i, point = player.totalPoint}
            result.rankers[i] = {characterId = player.id, characterName = player.name, rank = i,
                point = player.point, totalPoint = player.totalPoint, team = player.team}
        end
        for i, team in ipairs(teamOrder) do result.teams[i] = {team = team, rank = i, point = teamPoints[team] or 0} end
        game.raw:setResult(result)
        local teamRanks = {}
        for i, team in ipairs(teamOrder) do teamRanks[team] = i end
        for id, player in pairs(game.players) do
            sendRoundReward(game, player, ranks[id], teamRanks[player.team])
        end
        game.raw:setTimer("saver_result", nil, 10000)
        waitTimer(thread, game, "saver_result")
    end

    if not self.closed then

        game.raw:makeTerminate()
    end
    thread:ClearWait(self.eventDispatcher)
end

function onEvent(self, event)
    if self.closed then return false end
    if event._NAME == "close" then self.closed = true end
    local result = self.eventDispatcher:HandleEvent(event)
    if self.closed and self.obj_GamePve then
        self.obj_GamePve:release()
        self.obj_GamePve = nil
    end
    return result
end

function Message(self, message)
    if not self.closed then self.obj_GamePve:broadcastMessage(message) end
end

function constructor(self, obj_GamePve)
    self.eventDispatcher = TxBase.EventDispatcher:new()
    self.obj_GamePve = obj_GamePve
    self.mainThread = TxBase.Thread:new()
    self.mainThread:Run(main, self)
    return self
end
