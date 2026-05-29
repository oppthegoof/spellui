--[[
╔══════════════════════════════════════════════════════════════╗
║                    S P E L L B O O K                         ║
║              A Grimoire UI Library for Roblox                ║
╠══════════════════════════════════════════════════════════════╣
║  USAGE:                                                      ║
║    local SpellbookLib = loadstring(...)()                    ║
║    local lib = SpellbookLib.new()                            ║
║    local book = lib:addBook("Grimoire")                      ║
║    book:addSpell("Luminary", function()                      ║
║        print("Let there be light!")                          ║
║    end)                                                      ║
║    book:addSpell("Blaze", function() end, { cooldown = 5 })  ║
║    lib:open()                                                ║
╠══════════════════════════════════════════════════════════════╣
║  CASTING:                                                    ║
║    Press castModeKey (default: `) to enter casting mode      ║
║    Press number keys 1-9, 0 in sequence                      ║
║    Hold the FINAL key for 1 second to cast                   ║
║    Release any key before hold completes = cancel            ║
║    Escape / castModeKey again = exit casting mode            ║
╠══════════════════════════════════════════════════════════════╣
║  IN-BOOK CONTROLS:                                           ║
║    ← / → Arrow keys   : Turn pages                           ║
║    ↑ / ↓ buttons      : Reorder spell in book                ║
║    [books] button     : Cycle to next book                   ║
╚══════════════════════════════════════════════════════════════╝
]]

-- ─────────────────────────────────────────────────────────────
--  SERVICES
-- ─────────────────────────────────────────────────────────────

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local LocalPlayer       = Players.LocalPlayer
local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────────────────────
--  CONSTANTS & THEME
-- ─────────────────────────────────────────────────────────────

-- Number keys only — zero keybind conflicts with tools/actions
local CAST_KEYS    = "1234567890"
local CAST_KEY_CODES = {
    Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
    Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six,
    Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
    Enum.KeyCode.Zero,
}
local CAST_KEY_MAP = {}
for i, kc in ipairs(CAST_KEY_CODES) do
    CAST_KEY_MAP[kc] = CAST_KEYS:sub(i, i)
end

local THEME = {
    bg           = Color3.fromHex("0d0d14"),
    page_bg      = Color3.fromHex("12121e"),
    page_border  = Color3.fromHex("2a2a4a"),
    ink          = Color3.fromHex("c8c8e8"),
    ink_dim      = Color3.fromHex("6060a0"),
    gold         = Color3.fromHex("c8a84b"),
    gold_dim     = Color3.fromHex("7a6530"),
    red          = Color3.fromHex("c84b4b"),
    green        = Color3.fromHex("4bc87a"),
    orange       = Color3.fromHex("e8944a"),
    spine        = Color3.fromHex("1a1a2e"),
    ind_bg       = Color3.fromHex("0a0a14"),
    ind_border   = Color3.fromHex("2a2a50"),
    ind_key_bg   = Color3.fromHex("14142a"),
    ind_charge   = Color3.fromHex("e8c86a"),
}

local SPELL_ERRORS = {
    "The spell fizzles out…",
    "Arcane instability detected…",
    "The incantation collapses…",
    "Mana threads unravel mid-cast…",
    "The runes lose their binding…",
    "Something stirs, then goes silent…",
    "The ether rejects this weaving…",
    "Your words dissolve before the void…",
    "The sigil cracks — the spell fails…",
}

local CAST_MESSAGES = {
    "Weaving complete",
    "Incantation released",
    "The magic flows",
    "Spell cast",
}

local HOLD_TIME   = 1.0
local TIMEOUT     = 5.0
local WIN_W       = 400
local WIN_H       = 480

-- ─────────────────────────────────────────────────────────────
--  UTILITY
-- ─────────────────────────────────────────────────────────────

local function randomFrom(t)
    return t[math.random(1, #t)]
end

local function lerpColor(c1, c2, t)
    t = math.clamp(t, 0, 1)
    return Color3.new(
        c1.R + (c2.R - c1.R) * t,
        c1.G + (c2.G - c1.G) * t,
        c1.B + (c2.B - c1.B) * t
    )
end

local function hashString(s)
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + string.byte(s, i)) % (2^31)
    end
    return h
end

-- Generate a sequence using only CAST_KEYS digits, no duplicates within seq
-- Also accepts a `usedSequences` set to guarantee global uniqueness
local function generateSequence(name, seed, usedSequences, maxAttempts)
    usedSequences  = usedSequences or {}
    maxAttempts    = maxAttempts or 200

    local nameLen = #(name:match("^%s*(.-)%s*$") or "")
    local length
    if nameLen < 40 then
        length = 2
    elseif nameLen < 100 then
        length = 3
    elseif nameLen < 200 then
        length = 4
    else
        length = 5
    end
    -- cap to available digits
    length = math.min(length, #CAST_KEYS)

    local attempt = 0
    while attempt < maxAttempts do
        attempt += 1
        local combined = name .. seed .. tostring(attempt)
        local h = hashString(combined)

        local seq  = {}
        local used = {}
        local ok   = true

        for i = 1, length do
            local n    = (h + i * 2654435761 + attempt * 999983) % (2^31)
            local idx  = (n % #CAST_KEYS) + 1
            local char = CAST_KEYS:sub(idx, idx)

            local inner = 0
            while used[char] do
                n    = (n + 7) % (2^31)
                idx  = (n % #CAST_KEYS) + 1
                char = CAST_KEYS:sub(idx, idx)
                inner += 1
                if inner > #CAST_KEYS then ok = false; break end
            end
            if not ok then break end

            used[char] = true
            table.insert(seq, char)
        end

        if ok then
            local result = table.concat(seq)
            if not usedSequences[result] then
                usedSequences[result] = true
                return result
            end
        end
    end

    -- Fallback: just pick any unused sequence
    -- (extremely unlikely to reach here in practice)
    return "1"
end

-- ─────────────────────────────────────────────────────────────
--  SPELL CLASS
-- ─────────────────────────────────────────────────────────────

local Spell = {}
Spell.__index = Spell

function Spell.new(name, callback, opts)
    opts = opts or {}
    local self    = setmetatable({}, Spell)
    self.name      = name or "Unnamed Spell"
    self.callback  = callback or function() end
    self.cooldown  = opts.cooldown or 0   -- seconds; 0 = no cooldown
    self._lastCast = 0
    self._sequence = nil
    return self
end

function Spell:getSequence()
    return self._sequence or "?"
end

function Spell:setCooldown(seconds)
    self.cooldown = seconds or 0
end

function Spell:isCoolingDown()
    if self.cooldown <= 0 then return false end
    return (tick() - self._lastCast) < self.cooldown
end

function Spell:cooldownRemaining()
    if self.cooldown <= 0 then return 0 end
    return math.max(0, self.cooldown - (tick() - self._lastCast))
end

function Spell:onCast()
    self._lastCast = tick()
end

-- ─────────────────────────────────────────────────────────────
--  BOOK CLASS
-- ─────────────────────────────────────────────────────────────

local Book = {}
Book.__index = Book

function Book.new(name)
    local self   = setmetatable({}, Book)
    self.name    = name or "Grimoire"
    self.spells  = {}
    return self
end

function Book:addSpell(name, callback, opts)
    local spell = Spell.new(name, callback, opts)
    table.insert(self.spells, spell)
    return spell
end

function Book:removeSpell(index)
    if self.spells[index] then table.remove(self.spells, index) end
end

function Book:moveSpell(index, direction)
    local newIndex = index + direction
    if newIndex >= 1 and newIndex <= #self.spells then
        self.spells[index], self.spells[newIndex] =
            self.spells[newIndex], self.spells[index]
        return newIndex
    end
    return index
end

-- ─────────────────────────────────────────────────────────────
--  GUI HELPERS
-- ─────────────────────────────────────────────────────────────

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    if parent then inst.Parent = parent end
    return inst
end

local function makeFrame(props, parent)
    props.BackgroundColor3 = props.BackgroundColor3 or THEME.page_bg
    props.BorderSizePixel  = props.BorderSizePixel  or 0
    return make("Frame", props, parent)
end

local function makeLabel(props, parent)
    props.BackgroundTransparency = props.BackgroundTransparency or 1
    props.TextColor3             = props.TextColor3 or THEME.ink
    props.Font                   = props.Font or Enum.Font.Code
    props.TextSize               = props.TextSize or 13
    props.BorderSizePixel        = props.BorderSizePixel or 0
    return make("TextLabel", props, parent)
end

local function makeButton(props, parent)
    props.BackgroundColor3 = props.BackgroundColor3 or THEME.gold_dim
    props.TextColor3       = props.TextColor3 or THEME.bg
    props.Font             = props.Font or Enum.Font.GothamBold
    props.TextSize         = props.TextSize or 13
    props.BorderSizePixel  = props.BorderSizePixel or 0
    props.AutoButtonColor  = false
    return make("TextButton", props, parent)
end

local function addCorner(radius, parent)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = parent
end

local function addStroke(color, thickness, parent)
    local s = Instance.new("UIStroke")
    s.Color     = color or THEME.page_border
    s.Thickness = thickness or 1
    s.Parent    = parent
end

-- ─────────────────────────────────────────────────────────────
--  ORBIT INDICATOR  — pressed keys orbit the mouse cursor
-- ─────────────────────────────────────────────────────────────
--  Shows ALL pressed keys as floating badges around the cursor.
--  No sequence awareness — just raw input visualization.
--  A charge arc appears on the outermost badge when holding.
-- ─────────────────────────────────────────────────────────────

local OrbitIndicator = {}
OrbitIndicator.__index = OrbitIndicator

function OrbitIndicator.new(screenGui)
    local self = setmetatable({}, OrbitIndicator)

    self._sg        = screenGui
    self._keys      = {}     -- ordered list of pressed key strings
    self._badges    = {}     -- Frame instances
    self._charge    = 0
    self._charging  = false
    self._chargeStart = 0
    self._chargeDur   = HOLD_TIME
    self._angle     = 0
    self._visible   = false
    self._conn      = nil

    -- Root clipping frame (invisible, just holds children in place)
    self._root = makeFrame({
        Name             = "OrbitRoot",
        BackgroundTransparency = 1,
        Size             = UDim2.new(1, 0, 1, 0),
        ZIndex           = 30,
        Visible          = false,
    }, screenGui)

    self._conn = RunService.Heartbeat:Connect(function(dt)
        if not self._visible then return end
        self:_tick(dt)
    end)

    return self
end

function OrbitIndicator:_tick(dt)
    self._angle = self._angle + dt * 1.8  -- slow orbit

    local mouse = UserInputService:GetMouseLocation()
    local n     = #self._keys
    if n == 0 then return end

    -- Charge progress
    if self._charging then
        self._charge = math.clamp((tick() - self._chargeStart) / self._chargeDur, 0, 1)
    end

    local radius = 42 + n * 4  -- slightly expand radius with more keys
    for i, badge in ipairs(self._badges) do
        local angle = self._angle + (i - 1) * (2 * math.pi / n)
        local ox = math.cos(angle) * radius
        local oy = math.sin(angle) * radius
        local bx = mouse.X + ox - 18
        local by = mouse.Y + oy - 18
        badge.Position = UDim2.new(0, bx, 0, by)

        -- Charge glow on last badge
        if self._charging and i == n then
            local col = lerpColor(THEME.gold_dim, THEME.ind_charge, self._charge)
            badge.BackgroundColor3 = col
            -- pulse scale via size
            local s = 36 + self._charge * 6
            badge.Size = UDim2.new(0, s, 0, s)
        end
    end
end

function OrbitIndicator:pushKey(char)
    table.insert(self._keys, char)
    self._visible       = true
    self._root.Visible  = true

    local badge = makeFrame({
        Name             = "OBadge_".. #self._keys,
        BackgroundColor3 = THEME.ind_key_bg,
        Size             = UDim2.new(0, 36, 0, 36),
        ZIndex           = 31,
    }, self._root)
    addCorner(8, badge)
    addStroke(THEME.gold_dim, 1, badge)

    makeLabel({
        Size       = UDim2.new(1, 0, 1, 0),
        Text       = char,
        TextColor3 = THEME.gold,
        Font       = Enum.Font.Code,
        TextSize   = 16,
        ZIndex     = 32,
    }, badge)

    table.insert(self._badges, badge)
end

function OrbitIndicator:startCharge(duration)
    self._charging    = true
    self._chargeStart = tick()
    self._chargeDur   = duration or HOLD_TIME
    self._charge      = 0
    -- Brighten last badge stroke
    if #self._badges > 0 then
        addStroke(THEME.ind_charge, 2, self._badges[#self._badges])
    end
end

function OrbitIndicator:reset(instant)
    self._charging = false
    self._charge   = 0
    self._keys     = {}
    for _, b in ipairs(self._badges) do b:Destroy() end
    self._badges = {}

    if instant then
        self._root.Visible = false
        self._visible      = false
    else
        -- Fade out over 0.25s then hide
        task.delay(0.25, function()
            self._root.Visible = false
            self._visible      = false
        end)
    end
end

function OrbitIndicator:destroy()
    if self._conn then self._conn:Disconnect() end
    if self._root then self._root:Destroy() end
end

-- ─────────────────────────────────────────────────────────────
--  CAST LOG
-- ─────────────────────────────────────────────────────────────

local function showCastLog(screenGui, lines)
    local totalH = 12 + #lines * 22 + 10
    local w      = 320

    local root = makeFrame({
        Name             = "CastLog",
        BackgroundColor3 = THEME.ind_bg,
        Size             = UDim2.new(0, w, 0, totalH),
        Position         = UDim2.new(0.5, -w / 2, 0, 120),
        BackgroundTransparency = 1,
        ZIndex = 25,
    }, screenGui)
    addCorner(8, root)
    addStroke(THEME.ind_border, 1, root)

    local y = 10
    for _, line in ipairs(lines) do
        makeLabel({
            Size           = UDim2.new(1, -24, 0, 20),
            Position       = UDim2.new(0, 12, 0, y),
            Text           = line.text,
            TextColor3     = line.color,
            Font           = Enum.Font.Code,
            TextSize       = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex         = 26,
        }, root)
        y = y + 22
    end

    TweenService:Create(root, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
    task.delay(3.5, function()
        if root and root.Parent then
            local t = TweenService:Create(root, TweenInfo.new(0.6), { BackgroundTransparency = 1 })
            t:Play()
            t.Completed:Connect(function() if root then root:Destroy() end end)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────
--  CASTING ENGINE
-- ─────────────────────────────────────────────────────────────

local CastingEngine = {}
CastingEngine.__index = CastingEngine

function CastingEngine.new(screenGui, indicator)
    local self           = setmetatable({}, CastingEngine)
    self._screenGui      = screenGui
    self._indicator      = indicator  -- OrbitIndicator
    self._books          = {}
    self._castMode       = false
    self._pressOrder     = {}
    self._pressedSet     = {}
    self._lastPressTime  = 0
    self._holdThread     = nil
    self._connections    = {}
    self._castModeKey    = Enum.KeyCode.BackQuote
    self._modeLabel      = nil  -- set externally after UI build
    return self
end

function CastingEngine:setBooks(books)    self._books = books end
function CastingEngine:setCastModeKey(kc) self._castModeKey = kc end

function CastingEngine:_allSpells()
    local all = {}
    for _, book in ipairs(self._books) do
        for _, spell in ipairs(book.spells) do
            table.insert(all, spell)
        end
    end
    return all
end

function CastingEngine:_findSpell(seq)
    for _, spell in ipairs(self:_allSpells()) do
        if spell:getSequence() == seq then
            return spell
        end
    end
    return nil
end

function CastingEngine:_reset()
    self._pressOrder   = {}
    self._pressedSet   = {}
    self._lastPressTime = 0
    if self._holdThread then
        task.cancel(self._holdThread)
        self._holdThread = nil
    end
    self._indicator:reset(false)
end

function CastingEngine:_enterCastMode()
    self._castMode = true
    self:_reset()
    if self._modeLabel then
        self._modeLabel.Text      = "◆ CASTING"
        self._modeLabel.TextColor3 = THEME.gold
        self._modeLabel.Visible    = true
    end
end

function CastingEngine:_exitCastMode()
    self._castMode = false
    self:_reset()
    if self._modeLabel then
        self._modeLabel.Visible = false
    end
end

function CastingEngine:_onKeyAdded()
    local current = table.concat(self._pressOrder)
    local n       = #current

    -- Check for exact match → start hold countdown
    local exactSpell = self:_findSpell(current)
    if exactSpell then
        self:_startHold(exactSpell, current)
        return
    end

    -- Otherwise just continue collecting (indicator already updated by pushKey)
    -- Timeout check happens in onKeyDown
end

function CastingEngine:_startHold(spell, seq)
    if self._holdThread then task.cancel(self._holdThread) end
    self._indicator:startCharge(HOLD_TIME)
    self._holdThread = task.delay(HOLD_TIME, function()
        -- Verify sequence still intact
        local current = table.concat(self._pressOrder)
        if current ~= seq then
            self:_reset()
            return
        end
        self:_cast(spell)
        self:_reset()
    end)
end

function CastingEngine:_cast(spell)
    -- Cooldown check
    if spell:isCoolingDown() then
        local rem = math.ceil(spell:cooldownRemaining())
        showCastLog(self._screenGui, {
            { text = "On cooldown — ".. spell.name, color = THEME.orange },
            { text = rem .. "s remaining",          color = THEME.ink_dim },
        })
        return
    end

    local msg = randomFrom(CAST_MESSAGES)
    local success, err = pcall(spell.callback)
    spell:onCast()

    local lines = {
        { text = msg .. " — " .. spell.name, color = THEME.gold }
    }
    if success then
        table.insert(lines, { text = "The magic takes hold.", color = THEME.ink })
    else
        table.insert(lines, { text = randomFrom(SPELL_ERRORS), color = THEME.red })
        if err then
            table.insert(lines, { text = tostring(err):sub(1, 60), color = THEME.red })
        end
    end

    if spell.cooldown > 0 then
        table.insert(lines, { text = "Cooldown: " .. spell.cooldown .. "s", color = THEME.ink_dim })
    end

    showCastLog(self._screenGui, lines)
end

function CastingEngine:onKeyDown(key)
    -- Cast mode toggle key
    if key == self._castModeKey then
        if self._castMode then
            self:_exitCastMode()
        else
            self:_enterCastMode()
        end
        return
    end

    if not self._castMode then return end

    -- Escape exits cast mode
    if key == Enum.KeyCode.Escape then
        self:_exitCastMode()
        return
    end

    local char = CAST_KEY_MAP[key]
    if not char then return end

    local now = tick()
    if #self._pressOrder > 0 and (now - self._lastPressTime) > TIMEOUT then
        self:_reset()
    end
    self._lastPressTime = now

    if self._pressedSet[char] then return end
    self._pressedSet[char] = true
    table.insert(self._pressOrder, char)
    self._indicator:pushKey(char)
    self:_onKeyAdded()
end

function CastingEngine:onKeyUp(key)
    if not self._castMode then return end
    local char = CAST_KEY_MAP[key]
    if char and self._pressedSet[char] then
        -- Release cancels hold
        if self._holdThread then
            task.cancel(self._holdThread)
            self._holdThread = nil
            self:_reset()
        end
    end
end

function CastingEngine:startListening()
    local c1 = UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            self:onKeyDown(input.KeyCode)
        end
    end)
    local c2 = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Keyboard then
            self:onKeyUp(input.KeyCode)
        end
    end)
    table.insert(self._connections, c1)
    table.insert(self._connections, c2)
end

function CastingEngine:stopListening()
    for _, c in ipairs(self._connections) do c:Disconnect() end
    self._connections = {}
end

-- ─────────────────────────────────────────────────────────────
--  SEQUENCE BADGE ROW  (in-book display)
-- ─────────────────────────────────────────────────────────────

local function buildSeqRow(parent, sequence)
    local n = #sequence
    if n == 0 then return end

    local layout = Instance.new("UIListLayout")
    layout.FillDirection     = Enum.FillDirection.Horizontal
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding           = UDim.new(0, 5)
    layout.Parent            = parent

    for i = 1, n do
        local ch    = sequence:sub(i, i)
        local badge = makeFrame({
            BackgroundColor3 = THEME.spine,
            Size             = UDim2.new(0, 28, 0, 28),
            ZIndex           = 12,
        }, parent)
        addCorner(4, badge)
        addStroke(THEME.gold_dim, 1, badge)
        makeLabel({
            Size       = UDim2.new(1, 0, 1, 0),
            Text       = ch,
            TextColor3 = THEME.gold,
            Font       = Enum.Font.Code,
            TextSize   = 14,
            ZIndex     = 13,
        }, badge)
    end
end

-- ─────────────────────────────────────────────────────────────
--  SPELLBOOK UI
-- ─────────────────────────────────────────────────────────────

local SpellbookUI = {}
SpellbookUI.__index = SpellbookUI

function SpellbookUI.new(lib)
    local self = setmetatable({}, SpellbookUI)
    self._lib         = lib
    self._currentBook = 1
    self._currentPage = 1
    self._open        = false
    self._dragging    = false
    self._dragOffset  = Vector2.new()
    self:_buildGui()
    return self
end

function SpellbookUI:_buildGui()
    local sg = make("ScreenGui", {
        Name           = "SpellbookUI",
        ResetOnSpawn   = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
    }, PlayerGui)
    self._screenGui = sg

    -- Orbit indicator + engine
    self._indicator = OrbitIndicator.new(sg)
    self._engine    = CastingEngine.new(sg, self._indicator)
    self._engine:setBooks(self._lib._books)
    self._engine:startListening()

    -- Cast mode label (top-center, always visible when casting)
    self._modeLabel = makeLabel({
        Name           = "CastModeLabel",
        Size           = UDim2.new(0, 120, 0, 22),
        Position       = UDim2.new(0.5, -60, 0, 8),
        Text           = "◆ CASTING",
        TextColor3     = THEME.gold,
        Font           = Enum.Font.GothamBold,
        TextSize       = 12,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex         = 40,
        Visible        = false,
    }, sg)
    addCorner(5, self._modeLabel)
    local mlBg = makeFrame({
        BackgroundColor3 = THEME.ind_bg,
        Size             = UDim2.new(1, 0, 1, 0),
        ZIndex           = 39,
    }, self._modeLabel)
    addCorner(5, mlBg)
    addStroke(THEME.gold_dim, 1, mlBg)
    self._modeLabel.BackgroundTransparency = 1

    self._engine._modeLabel = self._modeLabel

    -- Main window
    local win = makeFrame({
        Name             = "SpellbookWindow",
        BackgroundColor3 = THEME.bg,
        Size             = UDim2.new(0, WIN_W, 0, WIN_H),
        Position         = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
        ClipsDescendants = true,
        Visible          = false,
        ZIndex           = 10,
    }, sg)
    addCorner(8, win)
    addStroke(THEME.page_border, 1, win)
    self._window = win

    self:_buildTitlebar(win)
    self:_buildSpine(win)
    self:_buildPageArea(win)
    self:_buildBottomBar(win)
end

function SpellbookUI:_buildTitlebar(win)
    local bar = makeFrame({
        Name             = "TitleBar",
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, 0, 0, 36),
        ZIndex           = 11,
    }, win)
    makeFrame({ BackgroundColor3 = THEME.gold_dim, Size = UDim2.new(1, 0, 0, 1), ZIndex = 12 }, bar)

    self._titleLabel = makeLabel({
        Size           = UDim2.new(1, -120, 1, 0),
        Position       = UDim2.new(0, 14, 0, 0),
        Text           = "Grimoire",
        TextColor3     = THEME.gold,
        Font           = Enum.Font.GothamBold,
        TextSize       = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, bar)

    -- Close button
    local closeBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.red,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 32, 0, 22),
        Position         = UDim2.new(1, -38, 0.5, -11),
        Text             = "[×]",
        ZIndex           = 12,
    }, bar)
    addCorner(4, closeBtn)
    closeBtn.MouseButton1Click:Connect(function() self:close() end)

    -- Books cycle button
    local booksBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.ink_dim,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 54, 0, 22),
        Position         = UDim2.new(1, -100, 0.5, -11),
        Text             = "[books]",
        ZIndex           = 12,
    }, bar)
    addCorner(4, booksBtn)
    booksBtn.MouseButton1Click:Connect(function() self:_cycleBook() end)
    self._booksBtn = booksBtn

    -- Drag
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self._dragging  = true
            self._dragOffset = Vector2.new(
                input.Position.X - self._window.AbsolutePosition.X,
                input.Position.Y - self._window.AbsolutePosition.Y
            )
        end
    end)
    bar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self._dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if self._dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            self._window.Position = UDim2.new(
                0, input.Position.X - self._dragOffset.X,
                0, input.Position.Y - self._dragOffset.Y
            )
        end
    end)
end

function SpellbookUI:_buildSpine(win)
    makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(0, 14, 1, -36),
        Position         = UDim2.new(0, 0, 0, 36),
        ZIndex           = 11,
    }, win)
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0, 1, 1, -36),
        Position         = UDim2.new(0, 13, 0, 36),
        ZIndex           = 11,
    }, win)
end

function SpellbookUI:_buildPageArea(win)
    local pageArea = makeFrame({
        BackgroundColor3 = THEME.page_bg,
        Size             = UDim2.new(1, -14, 1, -62),
        Position         = UDim2.new(0, 14, 0, 36),
        ClipsDescendants = true,
        ZIndex           = 11,
    }, win)
    self._pageArea = pageArea

    self._pageContainer = makeFrame({
        BackgroundTransparency = 1,
        Size                   = UDim2.new(1, 0, 1, 0),
        ZIndex                 = 11,
    }, pageArea)

    self:_buildPageContent(self._pageContainer)
end

function SpellbookUI:_buildPageContent(c)
    local pad = 22

    -- ── Header row: page counter + book name ──
    local hdr = makeFrame({
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -pad*2, 0, 20),
        Position = UDim2.new(0, pad, 0, 12),
        ZIndex   = 12,
    }, c)

    self._bookLabel = makeLabel({
        Size           = UDim2.new(0.5, 0, 1, 0),
        Text           = "",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, hdr)

    self._pageNumLabel = makeLabel({
        Size           = UDim2.new(0.5, 0, 1, 0),
        Position       = UDim2.new(0.5, 0, 0, 0),
        Text           = "1 / 1",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex         = 12,
    }, hdr)

    -- ── Spell name ──
    self._nameLabel = makeLabel({
        Size           = UDim2.new(1, -pad*2, 0, 32),
        Position       = UDim2.new(0, pad, 0, 36),
        Text           = "Unnamed Spell",
        TextColor3     = THEME.gold,
        Font           = Enum.Font.GothamBold,
        TextSize       = 20,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, c)

    -- ── Thin divider ──
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(1, -pad*2, 0, 1),
        Position         = UDim2.new(0, pad, 0, 72),
        ZIndex           = 12,
    }, c)

    -- ── Sequence section ──
    makeLabel({
        Size           = UDim2.new(1, -pad*2, 0, 16),
        Position       = UDim2.new(0, pad, 0, 82),
        Text           = "KEY SEQUENCE",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, c)

    self._seqHolder = makeFrame({
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -pad*2, 0, 34),
        Position = UDim2.new(0, pad, 0, 100),
        ZIndex   = 12,
    }, c)

    -- ── Spell info block ──
    local infoHolder = makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, -pad*2, 0, 130),
        Position         = UDim2.new(0, pad, 0, 148),
        ZIndex           = 12,
    }, c)
    addCorner(6, infoHolder)
    addStroke(THEME.page_border, 1, infoHolder)

    self._infoLabel = makeLabel({
        Size             = UDim2.new(1, -16, 1, -12),
        Position         = UDim2.new(0, 8, 0, 6),
        Text             = "",
        TextColor3       = THEME.ink,
        Font             = Enum.Font.Code,
        TextSize         = 12,
        TextXAlignment   = Enum.TextXAlignment.Left,
        TextYAlignment   = Enum.TextYAlignment.Top,
        TextWrapped      = true,
        RichText         = true,
        ZIndex           = 13,
    }, infoHolder)

    -- ── Cooldown bar ──
    makeLabel({
        Size           = UDim2.new(1, -pad*2, 0, 14),
        Position       = UDim2.new(0, pad, 0, 290),
        Text           = "COOLDOWN",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, c)

    self._cdHolder = makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, -pad*2, 0, 22),
        Position         = UDim2.new(0, pad, 0, 306),
        ZIndex           = 12,
    }, c)
    addCorner(4, self._cdHolder)
    addStroke(THEME.page_border, 1, self._cdHolder)

    self._cdBar = makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0, 0, 1, 0),
        ZIndex           = 13,
    }, self._cdHolder)
    addCorner(4, self._cdBar)

    self._cdLabel = makeLabel({
        Size           = UDim2.new(1, 0, 1, 0),
        Text           = "None",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Code,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex         = 14,
    }, self._cdHolder)

    -- ── Cast button + status ──
    local castBtn = makeButton({
        Size             = UDim2.new(0, 120, 0, 32),
        Position         = UDim2.new(0, pad, 0, 344),
        BackgroundColor3 = THEME.gold_dim,
        Text             = "▶  Cast Now",
        TextColor3       = THEME.bg,
        Font             = Enum.Font.GothamBold,
        TextSize         = 13,
        ZIndex           = 12,
    }, c)
    addCorner(6, castBtn)
    castBtn.MouseButton1Click:Connect(function() self:_castCurrent() end)
    castBtn.MouseEnter:Connect(function()
        TweenService:Create(castBtn, TweenInfo.new(0.1), { BackgroundColor3 = THEME.gold }):Play()
    end)
    castBtn.MouseLeave:Connect(function()
        TweenService:Create(castBtn, TweenInfo.new(0.1), { BackgroundColor3 = THEME.gold_dim }):Play()
    end)
    self._castBtn = castBtn

    self._statusLabel = makeLabel({
        Size           = UDim2.new(0, 180, 0, 32),
        Position       = UDim2.new(0, pad + 132, 0, 344),
        Text           = "",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, c)

    -- Cooldown update loop
    RunService.Heartbeat:Connect(function()
        self:_tickCooldownBar()
    end)
end

function SpellbookUI:_tickCooldownBar()
    if not self._open then return end
    local book = self:_currentBookF()
    if not book or #book.spells == 0 then return end
    local spell = book.spells[self._currentPage]
    if not spell then return end

    if spell.cooldown <= 0 then
        self._cdBar.Size  = UDim2.new(0, 0, 1, 0)
        self._cdLabel.Text = "None"
        return
    end

    local rem = spell:cooldownRemaining()
    local frac = 1 - (rem / spell.cooldown)
    TweenService:Create(self._cdBar, TweenInfo.new(0.1), {
        Size = UDim2.new(frac, 0, 1, 0)
    }):Play()

    if rem > 0 then
        self._cdBar.BackgroundColor3 = lerpColor(THEME.red, THEME.green, frac)
        self._cdLabel.Text = string.format("%.1fs / %.0fs", rem, spell.cooldown)
    else
        self._cdBar.BackgroundColor3 = THEME.green
        self._cdLabel.Text = "Ready  (%.0fs)":format(spell.cooldown)
    end
end

function SpellbookUI:_buildBottomBar(win)
    local bar = makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, 0, 0, 26),
        Position         = UDim2.new(0, 0, 1, -26),
        ZIndex           = 11,
    }, win)
    makeFrame({ BackgroundColor3 = THEME.gold_dim, Size = UDim2.new(1, 0, 0, 1), ZIndex = 12 }, bar)

    local function navBtn(text, x, cb)
        local b = makeButton({
            BackgroundColor3 = THEME.spine,
            TextColor3       = THEME.gold,
            Font             = Enum.Font.GothamBold,
            TextSize         = 13,
            Size             = UDim2.new(0, 26, 0, 22),
            Position         = UDim2.new(0, x, 0, 2),
            Text             = text,
            ZIndex           = 12,
        }, bar)
        addCorner(4, b)
        b.MouseButton1Click:Connect(cb)
        return b
    end

    self._prevBtn = navBtn("◀", 6,  function() self:_prevPage() end)
    self._nextBtn = navBtn("▶", 36, function() self:_nextPage() end)
    navBtn("↑", 72,  function() self:_reorder(-1) end)
    navBtn("↓", 102, function() self:_reorder(1)  end)

    -- Cast mode hint
    makeLabel({
        Size           = UDim2.new(0, 200, 1, 0),
        Position       = UDim2.new(1, -206, 0, 0),
        Text           = "` = toggle casting mode",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Code,
        TextSize       = 10,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex         = 12,
    }, bar)
end

-- ── Rendering ──────────────────────────────────────────────────

function SpellbookUI:_currentBookF()
    return self._lib._books[self._currentBook]
end

function SpellbookUI:_renderPage()
    local book   = self:_currentBookF()
    if not book then return end
    local spells = book.spells
    local total  = math.max(#spells, 1)
    local idx    = math.clamp(self._currentPage, 1, math.max(#spells, 1))
    self._currentPage = idx

    self._pageNumLabel.Text = idx .. " / " .. total
    self._prevBtn.TextColor3 = (idx > 1)        and THEME.gold or THEME.ink_dim
    self._nextBtn.TextColor3 = (idx < #spells)  and THEME.gold or THEME.ink_dim
    self._titleLabel.Text    = book.name
    self._bookLabel.Text     = book.name

    if #spells == 0 then
        self._nameLabel.Text  = "Empty Grimoire"
        self._infoLabel.Text  = "No spells.\nUse :addSpell() to add one."
        self:_clearSeq()
        self._cdLabel.Text    = "None"
        return
    end

    local spell = spells[idx]
    self._nameLabel.Text = spell.name

    -- Info block
    local seqStr = spell:getSequence()
    self._infoLabel.Text =
        "<font color='#6060a0'>sequence</font>   " .. seqStr
        .. "\n<font color='#6060a0'>hold final key</font>  " .. HOLD_TIME .. "s to cast"
        .. "\n<font color='#6060a0'>cooldown</font>   " .. (spell.cooldown > 0 and spell.cooldown .. "s" or "none")

    self._statusLabel.Text = ""
    self:_rebuildSeq(seqStr)
end

function SpellbookUI:_clearSeq()
    for _, ch in ipairs(self._seqHolder:GetChildren()) do ch:Destroy() end
end

function SpellbookUI:_rebuildSeq(seq)
    self:_clearSeq()
    buildSeqRow(self._seqHolder, seq)
end

-- ── Navigation ─────────────────────────────────────────────────

function SpellbookUI:_prevPage()
    local book = self:_currentBookF()
    if not book or self._currentPage <= 1 then return end
    self._currentPage -= 1
    self:_renderPage()
end

function SpellbookUI:_nextPage()
    local book = self:_currentBookF()
    if not book or self._currentPage >= #book.spells then return end
    self._currentPage += 1
    self:_renderPage()
end

function SpellbookUI:_reorder(dir)
    local book = self:_currentBookF()
    if not book then return end
    self._currentPage = book:moveSpell(self._currentPage, dir)
    self:_renderPage()
end

-- ── Cast current ───────────────────────────────────────────────

function SpellbookUI:_castCurrent()
    local book = self:_currentBookF()
    if not book or #book.spells == 0 then return end
    local spell = book.spells[self._currentPage]
    if not spell then return end

    TweenService:Create(self._castBtn, TweenInfo.new(0.1), { BackgroundColor3 = THEME.gold }):Play()
    task.delay(0.2, function()
        TweenService:Create(self._castBtn, TweenInfo.new(0.1), { BackgroundColor3 = THEME.gold_dim }):Play()
    end)
    self._engine:_cast(spell)
end

-- ── Book cycle ─────────────────────────────────────────────────

function SpellbookUI:_cycleBook()
    local books = self._lib._books
    if #books <= 1 then
        self._statusLabel.Text       = "No other books."
        self._statusLabel.TextColor3 = THEME.ink_dim
        task.delay(2, function() if self._statusLabel then self._statusLabel.Text = "" end end)
        return
    end
    self._currentBook = (self._currentBook % #books) + 1
    self._currentPage = 1
    self:_renderPage()
    self._statusLabel.Text       = "→ " .. books[self._currentBook].name
    self._statusLabel.TextColor3 = THEME.green
    task.delay(2, function() if self._statusLabel then self._statusLabel.Text = "" end end)
end

-- ── Toggle ─────────────────────────────────────────────────────

function SpellbookUI:open()
    self._open = true
    self._window.Visible = true
    self:_renderPage()
    self._window.BackgroundTransparency = 1
    TweenService:Create(self._window, TweenInfo.new(0.22, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 0
    }):Play()
end

function SpellbookUI:close()
    local t = TweenService:Create(self._window, TweenInfo.new(0.18), { BackgroundTransparency = 1 })
    t:Play()
    t.Completed:Connect(function()
        self._window.Visible = false
        self._open = false
    end)
end

function SpellbookUI:toggle()
    if self._open then self:close() else self:open() end
end

function SpellbookUI:destroy()
    self._engine:stopListening()
    self._indicator:destroy()
    if self._screenGui then self._screenGui:Destroy() end
end

-- ─────────────────────────────────────────────────────────────
--  SPELLBOOK LIBRARY  — public API
-- ─────────────────────────────────────────────────────────────

local SpellbookLib = {}
SpellbookLib.__index = SpellbookLib

--[[
    SpellbookLib.new(config?)
    
    config:
        toggleKey     Enum.KeyCode  window toggle key     (default: RightBracket)
        castModeKey   Enum.KeyCode  enter/exit cast mode  (default: BackQuote `)
        autoOpen      bool          open immediately       (default: false)
]]
function SpellbookLib.new(config)
    local self = setmetatable({}, SpellbookLib)
    config = config or {}

    self._books          = {}
    self._ui             = nil
    self._usedSequences  = {}   -- global dedup table

    local toggleKey   = config.toggleKey   or Enum.KeyCode.RightBracket
    local castModeKey = config.castModeKey or Enum.KeyCode.BackQuote
    local autoOpen    = config.autoOpen    or false

    task.defer(function()
        self._ui = SpellbookUI.new(self)
        self._ui._engine:setCastModeKey(castModeKey)
        if autoOpen then self._ui:open() end

        UserInputService.InputBegan:Connect(function(input, gp)
            if gp then return end
            if input.KeyCode == toggleKey then
                self._ui:toggle()
            end
        end)
    end)

    return self
end

--[[
    lib:addBook(name) → Book
]]
function SpellbookLib:addBook(name)
    local book = Book.new(name)
    table.insert(self._books, book)
    if self._ui then self._ui._engine:setBooks(self._books) end
    return book
end

--[[
    book:addSpell(name, callback, opts?)
    opts: { cooldown = number }
    
    Sequences are guaranteed unique across ALL books.
]]
local _origAddSpell = Book.addSpell
function Book:addSpell(name, callback, opts)
    local spell = Spell.new(name, callback, opts)
    -- sequence assigned by lib when registered; if called directly, generate without dedup
    if not spell._sequence then
        spell._sequence = generateSequence(name, tostring(name), {})
    end
    table.insert(self.spells, spell)
    return spell
end

-- Override when added via lib so we can guarantee global uniqueness
function SpellbookLib:addSpellToBook(book, name, callback, opts)
    local spell = Spell.new(name, callback, opts)
    spell._sequence = generateSequence(name, tostring(#self._usedSequences), self._usedSequences)
    table.insert(book.spells, spell)
    if self._ui then self._ui._engine:setBooks(self._books) end
    return spell
end

-- Convenience: addBook returns a book whose addSpell is dedup-aware
function SpellbookLib:addBook(name)
    local lib  = self
    local book = Book.new(name)

    -- Wrap addSpell to use lib's dedup table
    book.addSpell = function(bk, spellName, callback, opts)
        local spell = Spell.new(spellName, callback, opts)
        spell._sequence = generateSequence(
            spellName,
            tostring(#lib._usedSequences + math.random(1, 9999)),
            lib._usedSequences
        )
        table.insert(bk.spells, spell)
        if lib._ui then lib._ui._engine:setBooks(lib._books) end
        return spell
    end

    table.insert(self._books, book)
    if self._ui then self._ui._engine:setBooks(self._books) end
    return book
end

function SpellbookLib:open()    if self._ui then self._ui:open()   end end
function SpellbookLib:close()   if self._ui then self._ui:close()  end end
function SpellbookLib:toggle()  if self._ui then self._ui:toggle() end end

function SpellbookLib:destroy()
    if self._ui then self._ui:destroy() end
    self._books = {}
    self._usedSequences = {}
end

-- ─────────────────────────────────────────────────────────────

return SpellbookLib
