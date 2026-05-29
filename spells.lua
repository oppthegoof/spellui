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
║    lib:open()                                                ║
╠══════════════════════════════════════════════════════════════╣
║  CASTING:                                                    ║
║    Press keys in sequence shown on each spell page           ║
║    Hold the FINAL key for 1 second to cast                   ║
║    Release any key before hold completes = cancel            ║
║    Escape = cancel current sequence                          ║
╠══════════════════════════════════════════════════════════════╣
║  IN-BOOK CONTROLS:                                           ║
║    ← / → Arrow keys   : Turn pages                           ║
║    Ctrl+S             : Save spell name edits                ║
║    Ctrl+N             : New spell slot                       ║
║    Ctrl+B             : Switch books                         ║
╚══════════════════════════════════════════════════════════════╝
]]

-- ─────────────────────────────────────────────────────────────
--  SERVICES
-- ─────────────────────────────────────────────────────────────

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer       = Players.LocalPlayer
local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────────────────────
--  CONSTANTS & THEME
-- ─────────────────────────────────────────────────────────────

local CAST_KEYS = "QERTYUIOPFGHJKLZXCVBNM"

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
    spine        = Color3.fromHex("1a1a2e"),
    shadow       = Color3.fromHex("000000"),
    ind_bg       = Color3.fromHex("0a0a14"),
    ind_border   = Color3.fromHex("2a2a50"),
    ind_key_bg   = Color3.fromHex("14142a"),
    ind_key_done = Color3.fromHex("1e1e3a"),
    ind_charge   = Color3.fromHex("e8c86a"),
    console_text = Color3.fromHex("9090d0"),
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
    "Spell cast…",
    "Weaving complete…",
    "Incantation released…",
    "The magic flows…",
}

local HOLD_TIME   = 1.0   -- seconds to hold final key
local TIMEOUT     = 4.0   -- seconds before sequence resets
local WIN_W       = 480
local WIN_H       = 640

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

-- SHA256-like deterministic hash → sequence generator
-- Uses a simple but consistent approach for Roblox
local function hashString(s)
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + string.byte(s, i)) % (2^31)
    end
    return h
end

local function generateSequence(code, seed)
    local combined = code .. seed
    local h = hashString(combined)

    local charCount = #(code:match("^%s*(.-)%s*$") or "")
    local length
    if charCount < 60 then
        length = 2
    elseif charCount < 150 then
        length = 3
    elseif charCount < 400 then
        length = 4
    else
        length = 5
    end

    local seq = {}
    local used = {}

    for i = 1, length do
        -- derive a new number per index (no chaining)
        local n = (h + i * 2654435761) % (2^31)

        local idx = (n % #CAST_KEYS) + 1
        local char = CAST_KEYS:sub(idx, idx)

        -- prevent duplicates (retry deterministically)
        local attempts = 0
        while used[char] do
            n = (n + 1) % (2^31)
            idx = (n % #CAST_KEYS) + 1
            char = CAST_KEYS:sub(idx, idx)

            attempts += 1
            if attempts > #CAST_KEYS then break end
        end

        used[char] = true
        table.insert(seq, char)
    end

    return table.concat(seq)
end

-- ─────────────────────────────────────────────────────────────
--  SPELL CLASS
-- ─────────────────────────────────────────────────────────────

local Spell = {}
Spell.__index = Spell

function Spell.new(name, callback, seed)
    local self = setmetatable({}, Spell)
    self.name      = name or "Unnamed Spell"
    self.callback  = callback or function() end
    self.seed      = seed or tostring(math.random(100000, 999999))
    self.pageIndex = 0
    self._sequence = nil
    -- "description"used as pseudo-code for sequence length
    self._desc     = name .. self.seed
    return self
end

function Spell:getSequence()
    if not self._sequence then
        self._sequence = generateSequence(self._desc, self.seed)
    end
    return self._sequence
end

function Spell:invalidate()
    self._sequence = nil
    self._desc = self.name .. self.seed
end

-- ─────────────────────────────────────────────────────────────
--  BOOK CLASS
-- ─────────────────────────────────────────────────────────────

local Book = {}
Book.__index = Book

function Book.new(name)
    local self = setmetatable({}, Book)
    self.name   = name or "Grimoire"
    self.spells = {}
    return self
end

function Book:addSpell(name, callback)
    local spell = Spell.new(name, callback)
    spell.pageIndex = #self.spells
    table.insert(self.spells, spell)
    return spell
end

function Book:removeSpell(index)
    if self.spells[index] then
        table.remove(self.spells, index)
    end
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
--  GUI BUILDER HELPERS
-- ─────────────────────────────────────────────────────────────

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do
        inst[k] = v
    end
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
    return c
end

local function addStroke(color, thickness, parent)
    local s = Instance.new("UIStroke")
    s.Color     = color or THEME.page_border
    s.Thickness = thickness or 1
    s.Parent    = parent
    return s
end

local function addPadding(p, parent)
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft   = UDim.new(0, p)
    pad.PaddingRight  = UDim.new(0, p)
    pad.PaddingTop    = UDim.new(0, p)
    pad.PaddingBottom = UDim.new(0, p)
    pad.Parent        = parent
    return pad
end

-- ─────────────────────────────────────────────────────────────
--  CASTING INDICATOR  — floating overlay near screen center-top
-- ─────────────────────────────────────────────────────────────

local CastingIndicator = {}
CastingIndicator.__index = CastingIndicator

function CastingIndicator.new(screenGui)
    local self = setmetatable({}, CastingIndicator)

    self._sequence    = ""
    self._pressed     = {}   -- set of pressed keys
    self._pressedList = {}   -- ordered list
    self._charge      = 0
    self._charging    = false
    self._chargeStart = 0
    self._chargeDur   = HOLD_TIME
    self._spellName   = ""
    self._visible     = false
    self._pos         = nil
    self._angle       = 0

    -- Root frame
    self._root = makeFrame({
        Name              = "CastingIndicator",
        BackgroundColor3  = THEME.ind_bg,
        Size              = UDim2.new(0, 40, 0, 80),
        Position          = UDim2.new(0.5, -20, 0, 32),
        AnchorPoint       = Vector2.new(0.5, 0),
        Visible           = false,
        ZIndex            = 20,
        ClipsDescendants  = false,
    }, screenGui)
    addCorner(10, self._root)
    addStroke(THEME.ind_border, 1, self._root)

    -- Keys row
    self._keyRow = makeFrame({
        Name             = "KeyRow",
        BackgroundTransparency = 1,
        Size             = UDim2.new(1, -24, 0, 40),
        Position         = UDim2.new(0, 12, 0, 10),
        ZIndex           = 21,
    }, self._root)
    local listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection       = Enum.FillDirection.Horizontal
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    listLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
    listLayout.Padding             = UDim.new(0, 6)
    listLayout.Parent              = self._keyRow

    -- Charge bar background
    self._barBg = makeFrame({
        Name             = "BarBg",
        BackgroundColor3 = THEME.ind_key_bg,
        Size             = UDim2.new(1, -24, 0, 6),
        Position         = UDim2.new(0, 12, 0, 56),
        ZIndex           = 21,
    }, self._root)
    addCorner(3, self._barBg)
    addStroke(THEME.ind_border, 1, self._barBg)

    -- Charge bar fill
    self._barFill = makeFrame({
        Name             = "BarFill",
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0, 0, 1, 0),
        ZIndex           = 22,
    }, self._barBg)
    addCorner(3, self._barFill)

    -- Spell name label
    self._nameLabel = makeLabel({
        Name             = "SpellName",
        Size             = UDim2.new(1, -24, 0, 16),
        Position         = UDim2.new(0, 12, 0, 66),
        Text             = "",
        TextColor3       = THEME.ink_dim,
        Font             = Enum.Font.Gotham,
        TextSize         = 11,
        TextXAlignment   = Enum.TextXAlignment.Center,
        ZIndex           = 21,
    }, self._root)

    -- Render loop
    self._conn = RunService.Heartbeat:Connect(function(dt)
        self:_tick()
    end)

    self._keyBadges = {}
    return self
end

function CastingIndicator:_tick()
    if not self._visible then return end

    local dt = RunService.Heartbeat:Wait()

    -- ─── Charge Logic (unchanged) ───
    if self._charging then
        local elapsed = tick() - self._chargeStart
        self._charge = math.clamp(elapsed / self._chargeDur, 0, 1)

        local fillCol = lerpColor(THEME.gold_dim, THEME.ind_charge, self._charge)
        self._barFill.BackgroundColor3 = fillCol
        self._barFill.Size = UDim2.new(self._charge, 0, 1, 0)
    end

    -- ─── Mouse Follow ───
    local mouse = UserInputService:GetMouseLocation()
    local cam   = workspace.CurrentCamera
    local view  = cam.ViewportSize

    -- 🔧 SETTINGS (tweak these)
    local radius   = 40      -- distance from cursor
    local smooth   = 0.2     -- 0 = instant, 1 = slow
    local orbit    = true    -- true = circle around mouse

    -- Orbiting motion
    local offset
    if orbit then
        self._angle += dt * 4
        offset = Vector2.new(
            math.cos(self._angle) * radius,
            math.sin(self._angle) * radius
        )
    else
        offset = Vector2.new(20, 20)
    end

    local target = mouse + offset

    -- Smooth follow
    if not self._pos then
        self._pos = target
    end
    self._pos = self._pos:Lerp(target, smooth)

    -- Clamp to screen
    local size = self._root.AbsoluteSize
    local x = math.clamp(self._pos.X, 0, view.X - size.X)
    local y = math.clamp(self._pos.Y, 0, view.Y - size.Y)

    self._root.Position = UDim2.new(0, x, 0, y)
end

function CastingIndicator:_rebuildKeys()
    -- Clear existing badges
    for _, b in ipairs(self._keyBadges) do
        b:Destroy()
    end
    self._keyBadges = {}

    local seq = self._sequence
    local n   = #seq
    if n == 0 then return end

    local pressedCount = #self._pressedList

    for i = 1, n do
        local ch   = seq:sub(i, i)
        local done = (i <= pressedCount)

        local badge = makeFrame({
            Name             = "Key_".. i,
            BackgroundColor3 = done and THEME.ind_key_done or THEME.ind_key_bg,
            Size             = UDim2.new(0, 32, 0, 36),
            ZIndex           = 22,
        }, self._keyRow)
        addCorner(5, badge)
        addStroke(done and THEME.gold or THEME.ind_border, 1, badge)

        -- Glow dot
        if done then
            local dot = makeFrame({
                BackgroundColor3 = THEME.gold,
                Size             = UDim2.new(0, 6, 0, 6),
                Position         = UDim2.new(1, -8, 0, 2),
                ZIndex           = 23,
            }, badge)
            addCorner(3, dot)
        end

        makeLabel({
            Size           = UDim2.new(1, 0, 1, 0),
            Text           = ch,
            TextColor3     = done and THEME.gold or THEME.ink_dim,
            Font           = Enum.Font.Code,
            TextSize       = 15,
            ZIndex         = 23,
        }, badge)

        table.insert(self._keyBadges, badge)
    end

    -- Resize root width to fit
    local totalW = n * 32 + (n - 1) * 6 + 24
    local totalH = 90
    self._root.Size     = UDim2.new(0, math.max(totalW, 80), 0, totalH)

    -- Reposition bar and label relative to fixed offsets
    self._barBg.Position    = UDim2.new(0, 12, 0, 52)
    self._nameLabel.Position = UDim2.new(0, 12, 0, 66)
end

function CastingIndicator:show(sequence, pressedList, spellName)
    self._sequence    = sequence
    self._pressedList = pressedList or {}
    self._spellName   = spellName or ""
    self._charging    = false
    self._charge      = 0
    self._visible     = true

    self._root.Visible = true
    self._nameLabel.Text       = spellName
    self._nameLabel.TextColor3 = THEME.ink_dim
    self._barFill.Size         = UDim2.new(0, 0, 1, 0)
    self._barFill.BackgroundColor3 = THEME.gold_dim

    self:_rebuildKeys()

    -- Fade in
    self._root.BackgroundTransparency = 1
    TweenService:Create(self._root, TweenInfo.new(0.15), {
        BackgroundTransparency = 0
    }):Play()
end

function CastingIndicator:updatePressed(pressedList)
    self._pressedList = pressedList or {}
    self:_rebuildKeys()
end

function CastingIndicator:startCharge(duration)
    self._charging    = true
    self._chargeStart = tick()
    self._chargeDur   = duration or HOLD_TIME
    self._charge      = 0
    self._nameLabel.Text       = "".. self._spellName
    self._nameLabel.TextColor3 = THEME.ind_charge
end

function CastingIndicator:hide(fade)
    self._charging = false
    if not self._visible then return end

    if fade then
        local tween = TweenService:Create(self._root, TweenInfo.new(0.3), {
            BackgroundTransparency = 1
        })
        tween:Play()
        tween.Completed:Connect(function()
            self._root.Visible = false
            self._visible = false
        end)
    else
        self._root.Visible = false
        self._visible = false
    end
end

function CastingIndicator:destroy()
    if self._conn then self._conn:Disconnect() end
    if self._root then self._root:Destroy() end
end

-- ─────────────────────────────────────────────────────────────
--  CAST LOG — floating popup after casting
-- ─────────────────────────────────────────────────────────────

local function showCastLog(screenGui, lines)
    local totalH = 16 + #lines * 22 + 12
    local w      = 340

    local root = makeFrame({
        Name             = "CastLog",
        BackgroundColor3 = THEME.ind_bg,
        Size             = UDim2.new(0, w, 0, totalH),
        Position         = UDim2.new(0.5, -w / 2, 0, 130),
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

    -- Fade in
    TweenService:Create(root, TweenInfo.new(0.2), {
        BackgroundTransparency = 0
    }):Play()

    -- Hold then fade out
    task.delay(3.5, function()
        if root and root.Parent then
            local t = TweenService:Create(root, TweenInfo.new(0.6), {
                BackgroundTransparency = 1
            })
            t:Play()
            t.Completed:Connect(function()
                if root then root:Destroy() end
            end)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────
--  CASTING ENGINE
-- ─────────────────────────────────────────────────────────────

local CastingEngine = {}
CastingEngine.__index = CastingEngine

function CastingEngine.new(screenGui, indicator)
    local self = setmetatable({}, CastingEngine)

    self._screenGui     = screenGui
    self._indicator     = indicator
    self._books         = {}     -- reference to lib books
    self._pressOrder    = {}
    self._pressedSet    = {}
    self._lastPressTime = 0
    self._holdThread    = nil
    self._pendingSpell  = nil
    self._connections   = {}

    return self
end

function CastingEngine:setBooks(books)
    self._books = books
end

function CastingEngine:_allSpells()
    local all = {}
    for _, book in ipairs(self._books) do
        for _, spell in ipairs(book.spells) do
            table.insert(all, spell)
        end
    end
    return all
end

function CastingEngine:_reset(fade)
    self._pressOrder    = {}
    self._pressedSet    = {}
    self._lastPressTime = 0
    self._pendingSpell  = nil
    if self._holdThread then
        task.cancel(self._holdThread)
        self._holdThread = nil
    end
    self._indicator:hide(fade or false)
end

function CastingEngine:_onKeyAdded()
    local current = table.concat(self._pressOrder)
    local allSpells = self:_allSpells()

    -- Exact match
    for _, spell in ipairs(allSpells) do
        if spell:getSequence() == current then
            local pressed = {table.unpack(self._pressOrder)}
            if not self._indicator._visible then
                self._indicator:show(spell:getSequence(), pressed, spell.name)
            else
                self._indicator:updatePressed(pressed)
            end
            self:_startHold(spell)
            return
        end
    end

    -- Partial match
    local candidates = {}
    for _, spell in ipairs(allSpells) do
        if spell:getSequence():sub(1, #current) == current then
            table.insert(candidates, spell)
        end
    end

    if #candidates > 0 then
        table.sort(candidates, function(a, b)
            return #a:getSequence() < #b:getSequence()
        end)
        local target  = candidates[1]
        local pressed = {table.unpack(self._pressOrder)}
        if not self._indicator._visible then
            self._indicator:show(target:getSequence(), pressed, target.name)
        else
            self._indicator:updatePressed(pressed)
        end
    else
        self:_reset(false)
    end
end

function CastingEngine:_startHold(spell)
    self._pendingSpell = spell
    if self._holdThread then
        task.cancel(self._holdThread)
    end
    self._indicator:startCharge(HOLD_TIME)
    self._holdThread = task.delay(HOLD_TIME, function()
        if not self._pendingSpell then return end
        local current = table.concat(self._pressOrder)
        if current ~= self._pendingSpell:getSequence() then
            self:_reset(false)
            return end
        self:_cast(self._pendingSpell)
        self:_reset(true)
    end)
end

function CastingEngine:_cast(spell)
    self._indicator:hide(true)
    local msg = randomFrom(CAST_MESSAGES)
    local success, err = pcall(spell.callback)

    local lines = {
        { text = msg .. "[".. spell.name .. "]", color = THEME.gold }
    }
    if success then
        table.insert(lines, { text = "The magic takes hold.", color = THEME.ink })
    else
        table.insert(lines, { text = randomFrom(SPELL_ERRORS), color = THEME.red })
        if err then
            table.insert(lines, { text = tostring(err):sub(1, 55), color = THEME.red })
        end
    end

    showCastLog(self._screenGui, lines)
end

function CastingEngine:onKeyDown(key)
    local sym = key.Name:upper()
    if not CAST_KEYS:find(sym, 1, true) then return end

    local now = tick()
    if #self._pressOrder > 0 and (now - self._lastPressTime) > TIMEOUT then
        self:_reset(false)
    end
    self._lastPressTime = now

    if self._pressedSet[sym] then return end
    self._pressedSet[sym] = true
    table.insert(self._pressOrder, sym)
    self:_onKeyAdded()
end

function CastingEngine:onKeyUp(key)
    local sym = key.Name:upper()
    if self._pressedSet[sym] then
        self:_reset(false)
    end
end

function CastingEngine:startListening()
    local c1 = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            if input.KeyCode == Enum.KeyCode.Escape then
                self:_reset(false)
                return
            end
            self:onKeyDown(input.KeyCode)
        end
    end)
    local c2 = UserInputService.InputEnded:Connect(function(input, gameProcessed)
        if input.UserInputType == Enum.UserInputType.Keyboard then
            self:onKeyUp(input.KeyCode)
        end
    end)
    table.insert(self._connections, c1)
    table.insert(self._connections, c2)
end

function CastingEngine:stopListening()
    for _, c in ipairs(self._connections) do
        c:Disconnect()
    end
    self._connections = {}
end

-- ─────────────────────────────────────────────────────────────
--  SEQUENCE DISPLAY  (key badge row for a spell page)
-- ─────────────────────────────────────────────────────────────

local function buildSequenceDisplay(parent, sequence)
    local n = #sequence
    if n == 0 then return nil end

    local totalW = n * 30 + (n - 1) * 5
    local row = makeFrame({
        BackgroundTransparency = 1,
        Size                   = UDim2.new(0, totalW, 0, 30),
    }, parent)

    local layout = Instance.new("UIListLayout")
    layout.FillDirection       = Enum.FillDirection.Horizontal
    layout.VerticalAlignment   = Enum.VerticalAlignment.Center
    layout.Padding             = UDim.new(0, 5)
    layout.Parent              = row

    for i = 1, n do
        local ch    = sequence:sub(i, i)
        local badge = makeFrame({
            BackgroundColor3 = THEME.spine,
            Size             = UDim2.new(0, 28, 0, 28),
            ZIndex           = 12,
        }, row)
        addCorner(4, badge)
        addStroke(THEME.gold_dim, 1, badge)

        local dot = makeFrame({
            BackgroundColor3 = THEME.gold,
            Size             = UDim2.new(0, 5, 0, 5),
            Position         = UDim2.new(1, -7, 0, 2),
            ZIndex           = 13,
        }, badge)
        addCorner(3, dot)

        makeLabel({
            Size     = UDim2.new(1, 0, 1, 0),
            Text     = ch,
            TextColor3 = THEME.gold,
            Font     = Enum.Font.Code,
            TextSize = 14,
            ZIndex   = 13,
        }, badge)
    end

    return row
end

-- ─────────────────────────────────────────────────────────────
--  PAGE TURN EFFECT
-- ─────────────────────────────────────────────────────────────

local function pageTurnEffect(pageFrame, direction, onDone)
    -- Simple scale + fade page turn feel
    local startX = direction > 0 and 1 or -1
    pageFrame.Position = UDim2.new(startX, 0, 0, 0)

    TweenService:Create(pageFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
        Position = UDim2.new(0, 0, 0, 0)
    }):Play()

    task.delay(0.18, onDone)
end

-- ─────────────────────────────────────────────────────────────
--  MAIN SPELLBOOK UI
-- ─────────────────────────────────────────────────────────────

local SpellbookUI = {}
SpellbookUI.__index = SpellbookUI

function SpellbookUI.new(lib)
    local self = setmetatable({}, SpellbookUI)
    self._lib          = lib
    self._currentBook  = 1
    self._currentPage  = 1
    self._open         = false
    self._dragging     = false
    self._dragOffset   = Vector2.new()

    self:_buildGui()
    return self
end

function SpellbookUI:_buildGui()
    -- ScreenGui
    local sg = make("ScreenGui", {
        Name             = "SpellbookUI",
        ResetOnSpawn     = false,
        ZIndexBehavior   = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset   = true,
    }, PlayerGui)
    self._screenGui = sg

    -- Indicator + engine
    self._indicator = CastingIndicator.new(sg)
    self._engine    = CastingEngine.new(sg, self._indicator)
    self._engine:setBooks(self._lib._books)
    self._engine:startListening()

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

    -- Drop shadow
    local shadow = makeFrame({
        Name             = "Shadow",
        BackgroundColor3 = Color3.new(0, 0, 0),
        Size             = UDim2.new(1, 20, 1, 20),
        Position         = UDim2.new(0, -10, 0, -10),
        ZIndex           = 9,
        BackgroundTransparency = 0.5,
    }, win)
    addCorner(12, shadow)

    self:_buildTitlebar(win)
    self:_buildSpine(win)
    self:_buildPageArea(win)
    self:_buildBottomBar(win)
end

function SpellbookUI:_buildTitlebar(win)
    local bar = makeFrame({
        Name             = "TitleBar",
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, 0, 0, 40),
        ZIndex           = 11,
    }, win)

    -- Decorative top accent line
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(1, 0, 0, 1),
        ZIndex           = 12,
    }, bar)

    self._titleLabel = makeLabel({
        Size           = UDim2.new(1, -120, 1, 0),
        Position       = UDim2.new(0, 16, 0, 0),
        Text           = " Grimoire  ",
        TextColor3     = THEME.gold,
        Font           = Enum.Font.GothamBold,
        TextSize       = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, bar)

    -- Titlebar buttons
    local btnCfg = {
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.ink_dim,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 60, 0, 24),
        ZIndex           = 12,
    }

    local closeBtn = makeButton(table.clone and table.clone(btnCfg) or {
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.red,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 36, 0, 24),
        ZIndex           = 12,
        Text             = "[×]",
        Position         = UDim2.new(1, -44, 0.5, -12),
    }, bar)
    closeBtn.Text     = "[×]"
    closeBtn.TextColor3 = THEME.red
    closeBtn.Size     = UDim2.new(0, 36, 0, 24)
    closeBtn.Position = UDim2.new(1, -44, 0.5, -12)
    closeBtn.MouseButton1Click:Connect(function() self:close() end)
    addCorner(4, closeBtn)

    -- Books button
    local booksBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.ink_dim,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 56, 0, 24),
        Position         = UDim2.new(1, -108, 0.5, -12),
        Text             = "[books]",
        ZIndex           = 12,
    }, bar)
    addCorner(4, booksBtn)
    booksBtn.MouseButton1Click:Connect(function() self:_openBookSwitcher() end)
    self._booksBtn = booksBtn

    -- Drag
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self._dragging   = true
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
    -- Left spine strip
    makeFrame({
        Name             = "Spine",
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(0, 16, 1, -40),
        Position         = UDim2.new(0, 0, 0, 40),
        ZIndex           = 11,
    }, win)

    -- Decorative spine lines
    local spineDetail = makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0, 1, 1, -40),
        Position         = UDim2.new(0, 15, 0, 40),
        ZIndex           = 11,
    }, win)
end

function SpellbookUI:_buildPageArea(win)
    local pageArea = makeFrame({
        Name             = "PageArea",
        BackgroundColor3 = THEME.page_bg,
        Size             = UDim2.new(1, -16, 1, -70),
        Position         = UDim2.new(0, 16, 0, 40),
        ClipsDescendants = true,
        ZIndex           = 11,
    }, win)
    self._pageArea = pageArea

    -- Subtle vignette at top of page
    local vignette = makeFrame({
        BackgroundColor3 = THEME.bg,
        Size             = UDim2.new(1, 0, 0, 8),
        ZIndex           = 12,
    }, pageArea)
    local grad = Instance.new("UIGradient")
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    grad.Rotation = 90
    grad.Parent   = vignette

    self._pageContainer = makeFrame({
        Name             = "PageContainer",
        BackgroundTransparency = 1,
        Size             = UDim2.new(1, 0, 1, 0),
        ZIndex           = 11,
    }, pageArea)

    self:_buildPageContent(self._pageContainer)
end

function SpellbookUI:_buildPageContent(container)
    local pad = 28

    -- Page number / name header row
    local hdr = makeFrame({
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -pad*2, 0, 24),
        Position = UDim2.new(0, pad, 0, 14),
        ZIndex   = 12,
    }, container)

    makeLabel({
        Size           = UDim2.new(0, 100, 1, 0),
        Text           = "Spell Name",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, hdr)

    self._pageNumLabel = makeLabel({
        Size           = UDim2.new(0, 100, 1, 0),
        Position       = UDim2.new(1, -100, 0, 0),
        Text           = "Page 1 of 1",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex         = 12,
    }, hdr)

    -- Spell name
    self._nameBox = make("TextBox", {
        Name             = "SpellName",
        BackgroundTransparency = 1,
        Size             = UDim2.new(1, -pad*2, 0, 36),
        Position         = UDim2.new(0, pad, 0, 42),
        Text             = "Unnamed Spell",
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 20,
        TextXAlignment   = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        ZIndex           = 12,
    }, container)

    -- Ornamental divider
    local divFrame = makeFrame({
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -pad*2, 0, 14),
        Position = UDim2.new(0, pad, 0, 82),
        ZIndex   = 12,
    }, container)
    self._divFrame = divFrame

    -- Left line
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0.4, -14, 0, 1),
        Position         = UDim2.new(0, 0, 0.5, 0),
        ZIndex           = 12,
    }, divFrame)
    makeLabel({
        Size           = UDim2.new(0, 28, 1, 0),
        Position       = UDim2.new(0.5, -14, 0, 0),
        Text           = "",
        TextColor3     = THEME.gold,
        Font           = Enum.Font.SpecialElite,
        TextSize       = 11,
        ZIndex         = 12,
    }, divFrame)
    -- Right line
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(0.4, -14, 0, 1),
        Position         = UDim2.new(0.6, 14, 0.5, 0),
        ZIndex           = 12,
    }, divFrame)

    -- Incantation label
    makeLabel({
        Size           = UDim2.new(1, -pad*2, 0, 18),
        Position       = UDim2.new(0, pad, 0, 102),
        Text           = "Incantation",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, container)

    -- Code/description box (read-only display of what the spell does)
    local codeHolder = makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, -pad*2, 0, 200),
        Position         = UDim2.new(0, pad, 0, 124),
        ZIndex           = 12,
    }, container)
    addCorner(6, codeHolder)
    addStroke(THEME.page_border, 1, codeHolder)

    self._codeLabel = makeLabel({
        Size             = UDim2.new(1, -16, 1, -12),
        Position         = UDim2.new(0, 8, 0, 6),
        Text             = "-- No spell description provided.",
        TextColor3       = THEME.ink,
        Font             = Enum.Font.Code,
        TextSize         = 12,
        TextXAlignment   = Enum.TextXAlignment.Left,
        TextYAlignment   = Enum.TextYAlignment.Top,
        TextWrapped      = true,
        ZIndex           = 13,
    }, codeHolder)

    -- Key sequence label
    makeLabel({
        Size           = UDim2.new(0, 120, 0, 18),
        Position       = UDim2.new(0, pad, 0, 338),
        Text           = "Key Sequence:",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, container)

    self._seqHolder = makeFrame({
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -pad*2 - 130, 0, 36),
        Position = UDim2.new(0, pad + 128, 0, 332),
        ZIndex   = 12,
    }, container)

    -- Cast button
    local castBtn = makeButton({
        Size             = UDim2.new(0, 140, 0, 36),
        Position         = UDim2.new(0, pad, 0, 388),
        BackgroundColor3 = THEME.gold_dim,
        Text             = " Cast Now",
        TextColor3       = THEME.bg,
        Font             = Enum.Font.GothamBold,
        TextSize         = 13,
        ZIndex           = 12,
    }, container)
    addCorner(6, castBtn)
    castBtn.MouseButton1Click:Connect(function() self:_castCurrent() end)
    castBtn.MouseEnter:Connect(function()
        TweenService:Create(castBtn, TweenInfo.new(0.1), {
            BackgroundColor3 = THEME.gold
        }):Play()
    end)
    castBtn.MouseLeave:Connect(function()
        TweenService:Create(castBtn, TweenInfo.new(0.1), {
            BackgroundColor3 = THEME.gold_dim
        }):Play()
    end)
    self._castBtn = castBtn

    -- Status label
    self._statusLabel = makeLabel({
        Size           = UDim2.new(0, 160, 0, 36),
        Position       = UDim2.new(0, pad + 152, 0, 388),
        Text           = "",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 12,
    }, container)

    -- Book name footer label
    self._bookLabel = makeLabel({
        Size           = UDim2.new(1, -pad*2, 0, 18),
        Position       = UDim2.new(0, pad, 0, 434),
        Text           = "",
        TextColor3     = THEME.ink_dim,
        Font           = Enum.Font.Gotham,
        TextSize       = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex         = 12,
    }, container)
end

function SpellbookUI:_buildBottomBar(win)
    local bar = makeFrame({
        Name             = "BottomBar",
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, 0, 0, 30),
        Position         = UDim2.new(0, 0, 1, -30),
        ZIndex           = 11,
    }, win)

    -- Top accent
    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(1, 0, 0, 1),
        ZIndex           = 12,
    }, bar)

    local navCfg = {
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        Size             = UDim2.new(0, 30, 0, 26),
        ZIndex           = 12,
    }

    -- Prev
    local prevBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        Size             = UDim2.new(0, 30, 0, 26),
        Position         = UDim2.new(0, 6, 0, 2),
        Text             = "◀",
        ZIndex           = 12,
    }, bar)
    addCorner(4, prevBtn)
    prevBtn.MouseButton1Click:Connect(function() self:_prevPage() end)
    self._prevBtn = prevBtn

    -- Next
    local nextBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        Size             = UDim2.new(0, 30, 0, 26),
        Position         = UDim2.new(0, 40, 0, 2),
        Text             = "▶",
        ZIndex           = 12,
    }, bar)
    addCorner(4, nextBtn)
    nextBtn.MouseButton1Click:Connect(function() self:_nextPage() end)
    self._nextBtn = nextBtn

    -- Up/down reorder
    local upBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        Size             = UDim2.new(0, 26, 0, 26),
        Position         = UDim2.new(0, 80, 0, 2),
        Text             = "↑",
        ZIndex           = 12,
    }, bar)
    addCorner(4, upBtn)
    upBtn.MouseButton1Click:Connect(function() self:_reorder(-1) end)

    local downBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.gold,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        Size             = UDim2.new(0, 26, 0, 26),
        Position         = UDim2.new(0, 110, 0, 2),
        Text             = "↓",
        ZIndex           = 12,
    }, bar)
    addCorner(4, downBtn)
    downBtn.MouseButton1Click:Connect(function() self:_reorder(1) end)
end

-- ── Rendering ─────────────────────────────────────────────────

function SpellbookUI:_currentBookF()
    return self._lib._books[self._currentBook]
end

function SpellbookUI:_renderPage()
    local book = self:_currentBookF()
    if not book then return end

    local spells = book.spells
    local total  = math.max(#spells, 1)
    local idx    = self._currentPage

    -- Clamp
    if idx > #spells then
        idx = #spells
        self._currentPage = idx
    end
    if idx < 1 then
        idx = 1
        self._currentPage = idx
    end

    self._pageNumLabel.Text = "Page ".. idx .. "of ".. total
    self._prevBtn.TextColor3 = (idx > 1)        and THEME.gold or THEME.ink_dim
    self._nextBtn.TextColor3 = (idx < #spells)  and THEME.gold or THEME.ink_dim
    self._titleLabel.Text    = " ".. book.name .. " "
    self._bookLabel.Text     = book.name

    if #spells == 0 then
        self._nameBox.Text  = "Empty Grimoire"
        self._codeLabel.Text = "-- No spells in this book.\n-- Use :addSpell() to add one."
        self:_clearSeqDisplay()
        return
    end

    local spell = spells[idx]
    self._nameBox.Text   = spell.name
    self._codeLabel.Text = "-- Callback bound to: ".. spell.name
                        .. "\n-- Sequence: ".. spell:getSequence()
                        .. "\n-- Seed: ".. spell.seed
                        .. "\n\n-- Hold the final key in the\n-- sequence for 1s to cast."
    self._statusLabel.Text = ""
    self:_rebuildSeqDisplay(spell:getSequence())
end

function SpellbookUI:_clearSeqDisplay()
    for _, c in ipairs(self._seqHolder:GetChildren()) do
        c:Destroy()
    end
end

function SpellbookUI:_rebuildSeqDisplay(sequence)
    self:_clearSeqDisplay()
    buildSequenceDisplay(self._seqHolder, sequence)
end

-- ── Navigation ─────────────────────────────────────────────────

function SpellbookUI:_prevPage()
    local book = self:_currentBookF()
    if not book then return end
    if self._currentPage > 1 then
        self._currentPage = self._currentPage - 1
        self:_renderPage()
    end
end

function SpellbookUI:_nextPage()
    local book = self:_currentBookF()
    if not book then return end
    if self._currentPage < #book.spells then
        self._currentPage = self._currentPage + 1
        self:_renderPage()
    end
end

function SpellbookUI:_reorder(direction)
    local book = self:_currentBookF()
    if not book then return end
    local newIdx = book:moveSpell(self._currentPage, direction)
    self._currentPage = newIdx
    self:_renderPage()
end

-- ── Spell actions ──────────────────────────────────────────────

function SpellbookUI:_castCurrent()
    local book = self:_currentBookF()
    if not book or #book.spells == 0 then return end
    local spell = book.spells[self._currentPage]
    if not spell then return end

    -- Flash cast button
    TweenService:Create(self._castBtn, TweenInfo.new(0.1), {
        BackgroundColor3 = THEME.gold
    }):Play()
    task.delay(0.2, function()
        TweenService:Create(self._castBtn, TweenInfo.new(0.1), {
            BackgroundColor3 = THEME.gold_dim
        }):Play()
    end)

    self._engine:_cast(spell)
end

-- ── Book switcher ──────────────────────────────────────────────

function SpellbookUI:_openBookSwitcher()
    local books = self._lib._books
    if #books <= 1 then
        self._statusLabel.Text       = "No other books."
        self._statusLabel.TextColor3 = THEME.ink_dim
        task.delay(2, function()
            if self._statusLabel then self._statusLabel.Text = ""end
        end)
        return
    end

    -- Cycle to next book
    self._currentBook = (self._currentBook % #books) + 1
    self._currentPage = 1
    self:_renderPage()
    self._statusLabel.Text       = "Switched to: ".. books[self._currentBook].name
    self._statusLabel.TextColor3 = THEME.green
    task.delay(2, function()
        if self._statusLabel then self._statusLabel.Text = ""end
    end)
end

-- ── Toggle ─────────────────────────────────────────────────────

function SpellbookUI:open()
    self._open = true
    self._window.Visible = true
    self:_renderPage()
    -- Animate in
    self._window.BackgroundTransparency = 1
    TweenService:Create(self._window, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 0
    }):Play()
end

function SpellbookUI:close()
    local t = TweenService:Create(self._window, TweenInfo.new(0.2), {
        BackgroundTransparency = 1
    })
    t:Play()
    t.Completed:Connect(function()
        self._window.Visible = false
        self._open = false
    end)
end

function SpellbookUI:toggle()
    if self._open then
        self:close()
    else
        self:open()
    end
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
    Creates a new SpellbookLib instance.
    
    @param config  (optional) table:
        toggleKey   Enum.KeyCode  — key to show/hide the grimoire window (default: Enum.KeyCode.RightBracket)
        autoOpen    bool          — open the window immediately (default: false)
    
    @returns SpellbookLib
--]]
function SpellbookLib.new(config)
    local self = setmetatable({}, SpellbookLib)
    config = config or {}

    self._books = {}
    self._ui    = nil

    local toggleKey = config.toggleKey or Enum.KeyCode.RightBracket
    local autoOpen  = config.autoOpen   or false

    -- Build UI deferred so books can be added first
    task.defer(function()
        self._ui = SpellbookUI.new(self)
        if autoOpen then self._ui:open() end

        -- Toggle key
        UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if gameProcessed then return end
            if input.KeyCode == toggleKey then
                self._ui:toggle()
            end
        end)
    end)

    return self
end

--[[
    Add a new book (tab/chapter) to the grimoire.
    
    @param name  string  — display name of the book
    @returns Book
--]]
function SpellbookLib:addBook(name)
    local book = Book.new(name)
    table.insert(self._books, book)
    -- Keep engine in sync if UI already built
    if self._ui then
        self._ui._engine:setBooks(self._books)
    end
    return book
end

--[[
    Directly open the grimoire window.
--]]
function SpellbookLib:open()
    if self._ui then self._ui:open() end
end

--[[
    Directly close the grimoire window.
--]]
function SpellbookLib:close()
    if self._ui then self._ui:close() end
end

--[[
    Toggle the grimoire window visibility.
--]]
function SpellbookLib:toggle()
    if self._ui then self._ui:toggle() end
end

--[[
    Destroy the entire library and its GUI.
--]]
function SpellbookLib:destroy()
    if self._ui then self._ui:destroy() end
    self._books = {}
end

-- ─────────────────────────────────────────────────────────────
--  RETURN MODULE
-- ─────────────────────────────────────────────────────────────

return SpellbookLib
