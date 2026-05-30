--[[
╔══════════════════════════════════════════════════════════════╗
║                    S P E L L B O O K                         ║
║              A Grimoire UI Library for Roblox                ║
╠══════════════════════════════════════════════════════════════╣
║  REWRITE NOTES (v2):                                         ║
║  · CastingEngine replaced with explicit state machine        ║
║    IDLE → BUILDING → CHARGING → CASTING                      ║
║  · Version-token cancellation: _ver bumped on every reset.   ║
║    All Heartbeat callbacks check ver before acting.          ║
║  · All timing decisions moved to RunService.Heartbeat.       ║
║    task.delay used ONLY for cosmetic animation cleanup.      ║
║  · OrbitIndicator decoupled from engine timing — engine      ║
║    pushes state; indicator only renders what it's told.      ║
║  · Key-release detection fixed: tracks pending key           ║
║    separately from _pressOrder.                              ║
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

local CAST_KEYS = "1234567890"
local CAST_KEY_CODES = {
    Enum.KeyCode.One,   Enum.KeyCode.Two,   Enum.KeyCode.Three,
    Enum.KeyCode.Four,  Enum.KeyCode.Five,  Enum.KeyCode.Six,
    Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
    Enum.KeyCode.Zero,
}
local CAST_KEY_MAP = {}
for i, kc in ipairs(CAST_KEY_CODES) do
    CAST_KEY_MAP[kc] = CAST_KEYS:sub(i, i)
end

local THEME = {
    bg          = Color3.fromHex("0d0d14"),
    page_bg     = Color3.fromHex("12121e"),
    page_border = Color3.fromHex("2a2a4a"),
    ink         = Color3.fromHex("c8c8e8"),
    ink_dim     = Color3.fromHex("6060a0"),
    gold        = Color3.fromHex("c8a84b"),
    gold_dim    = Color3.fromHex("7a6530"),
    red         = Color3.fromHex("c84b4b"),
    red_bright  = Color3.fromHex("ff6060"),
    green       = Color3.fromHex("4bc87a"),
    orange      = Color3.fromHex("e8944a"),
    spine       = Color3.fromHex("1a1a2e"),
    ind_bg      = Color3.fromHex("0a0a14"),
    ind_border  = Color3.fromHex("2a2a50"),
    ind_key_bg  = Color3.fromHex("14142a"),
    ind_charge  = Color3.fromHex("e8c86a"),
    ind_ready   = Color3.fromHex("ffffff"),
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

local HOLD_TIME     = 1.0    -- final hold to cast (seconds)
local KEY_HOLD_TIME = 0.5    -- default per-key hold before next key allowed
local IDLE_RESET    = 1.2    -- idle seconds before auto-reset in cast mode
local WIN_W         = 400
local WIN_H         = 480

-- ─────────────────────────────────────────────────────────────
--  ENGINE STATES
-- ─────────────────────────────────────────────────────────────
--
--  IDLE      → cast mode off, or no input started
--  BUILDING  → keys being pressed; sequence accumulating;
--               waiting for current key to charge before next
--  CHARGING  → full match found; holding final sequence for HOLD_TIME
--  CASTING   → (instant) spell fires, resets to IDLE
--
-- ─────────────────────────────────────────────────────────────

local STATE = {
    IDLE     = "IDLE",
    BUILDING = "BUILDING",
    CHARGING = "CHARGING",
}

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

local function generateSequence(name, seed, usedSequences, maxAttempts)
    usedSequences = usedSequences or {}
    maxAttempts   = maxAttempts or 200

    local baseHash = hashString(seed)
    local roll     = baseHash % 1000

    local length
    if     roll < 500 then length = 2
    elseif roll < 800 then length = 3
    elseif roll < 930 then length = 4
    elseif roll < 990 then length = 5
    else                   length = 6
    end
    length = math.min(length, #CAST_KEYS)

    for attempt = 1, maxAttempts do
        local h   = hashString(seed .. tostring(attempt))
        local seq = {}
        local used = {}
        local ok  = true

        for i = 1, length do
            local n    = (h + i * 2654435761 + attempt * 999983) % (2^31)
            local idx  = (n % #CAST_KEYS) + 1
            local char = CAST_KEYS:sub(idx, idx)

            local inner = 0
            while used[char] do
                n    = (n + 7) % (2^31)
                idx  = (n % #CAST_KEYS) + 1
                char = CAST_KEYS:sub(idx, idx)
                inner = inner + 1
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

    return "1"
end

-- ─────────────────────────────────────────────────────────────
--  SPELL CLASS
-- ─────────────────────────────────────────────────────────────

local Spell = {}
Spell.__index = Spell

function Spell.new(name, callback, opts)
    opts = opts or {}
    local self       = setmetatable({}, Spell)
    self.name        = name or "Unnamed Spell"
    self.callback    = callback or function() end
    self.cooldown    = opts.cooldown    or 0
    self.keyHoldTime = opts.keyHoldTime or KEY_HOLD_TIME
    self._lastCast   = 0
    self._sequence   = nil
    return self
end

function Spell:getSequence()  return self._sequence or "?" end
function Spell:setCooldown(s) self.cooldown = s or 0 end

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
    local self  = setmetatable({}, Book)
    self.name   = name or "Grimoire"
    self.spells = {}
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
    return s
end

-- ─────────────────────────────────────────────────────────────
--  ORBIT INDICATOR
-- ─────────────────────────────────────────────────────────────
--
--  The indicator is now purely a renderer.
--  CastingEngine tells it what to show via explicit method calls.
--  It never reads engine state or runs its own timers.
--
--  Timing data is pushed in each frame by CastingEngine:
--    indicator:updateKeyProgress(badgeIndex, 0..1, done)
--    indicator:updateChargeProgress(0..1)
--
--  This guarantees the visual is always exactly one frame
--  behind the engine — never desynced by a stale task.delay.
-- ─────────────────────────────────────────────────────────────

local OrbitIndicator = {}
OrbitIndicator.__index = OrbitIndicator

function OrbitIndicator.new(screenGui)
    local self        = setmetatable({}, OrbitIndicator)
    self._sg          = screenGui
    self._badges      = {}     -- ordered list of badge tables
    self._angle       = 0
    self._visible     = false
    self._dying       = false
    self._chargeT     = 0      -- 0..1 pushed by engine each frame
    self._conn        = nil

    self._root = makeFrame({
        Name                   = "OrbitRoot",
        BackgroundTransparency = 1,
        Size                   = UDim2.new(1, 0, 1, 0),
        ZIndex                 = 30,
        Visible                = false,
    }, screenGui)

    self._conn = RunService.Heartbeat:Connect(function(dt)
        if not self._visible then return end
        self:_tick(dt)
    end)

    return self
end

function OrbitIndicator:_makeBadge(char)
    local SIZE = 38

    local frame = makeFrame({
        BackgroundColor3 = THEME.ind_key_bg,
        Size             = UDim2.new(0, SIZE, 0, SIZE),
        ZIndex           = 31,
    }, self._root)
    addCorner(10, frame)

    local stroke = addStroke(THEME.ind_border, 1.5, frame)

    local glow = makeFrame({
        BackgroundColor3       = THEME.gold_dim,
        BackgroundTransparency = 0.85,
        Size                   = UDim2.new(1, 14, 1, 14),
        Position               = UDim2.new(0, -7, 0, -7),
        ZIndex                 = 30,
    }, frame)
    addCorner(14, glow)

    local fill = makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(1, 0, 0, 0),
        Position         = UDim2.new(0, 0, 1, 0),
        ZIndex           = 31,
    }, frame)
    addCorner(10, fill)

    local label = makeLabel({
        Size       = UDim2.new(1, 0, 1, 0),
        Text       = char,
        TextColor3 = THEME.ink_dim,
        Font       = Enum.Font.Code,
        TextSize   = 16,
        ZIndex     = 33,
    }, frame)

    return {
        frame  = frame,
        glow   = glow,
        fill   = fill,
        stroke = stroke,
        label  = label,
        prog   = 0,     -- 0..1, written each frame by engine
        done   = false,
    }
end

-- Called once per Heartbeat when visible.
-- Reads _chargeT and each badge's .prog/.done.
function OrbitIndicator:_tick(dt)
    self._angle = self._angle + dt * 1.6

    local mouse = UserInputService:GetMouseLocation()
    local n     = #self._badges
    if n == 0 then return end

    local radius = 46 + n * 5

    for i, b in ipairs(self._badges) do
        local angle = self._angle + (i - 1) * (2 * math.pi / n)
        local ox    = math.cos(angle) * radius
        local oy    = math.sin(angle) * radius

        if not self._dying then
            b.frame.Position = UDim2.new(0, mouse.X + ox - 19, 0, mouse.Y + oy - 19)
        end

        local held = b.prog  -- 0..1, pushed by engine

        if not b.done then
            b.fill.Size              = UDim2.new(1, 0, held, 0)
            b.fill.Position          = UDim2.new(0, 0, 1 - held, 0)
            b.stroke.Color           = lerpColor(THEME.ind_border, THEME.gold_dim, held)
            b.stroke.Thickness       = 1.5 + held
            b.glow.BackgroundColor3  = lerpColor(THEME.ind_key_bg, THEME.gold, held)
            b.glow.BackgroundTransparency = 0.85 - held * 0.25
            b.label.TextColor3       = lerpColor(THEME.ink_dim, THEME.gold, held)
        else
            -- Fully held; may pulse during final charge
            b.fill.Size              = UDim2.new(1, 0, 1, 0)
            b.fill.Position          = UDim2.new(0, 0, 0, 0)
            b.fill.BackgroundColor3  = THEME.gold_dim
            b.stroke.Color           = THEME.gold
            b.stroke.Thickness       = 2
            b.glow.BackgroundColor3  = THEME.gold
            b.glow.BackgroundTransparency = 0.6
            b.label.TextColor3       = THEME.bg

            -- Last badge pulses during final charge
            if i == n and self._chargeT > 0 then
                local ct  = self._chargeT
                local col = lerpColor(THEME.gold, THEME.ind_ready, ct)
                b.fill.BackgroundColor3           = col
                b.glow.BackgroundColor3           = col
                b.glow.BackgroundTransparency     = 0.4 - ct * 0.3
                b.stroke.Color                    = col
                b.stroke.Thickness                = 2 + ct * 2
                local s = 38 + ct * 8
                b.frame.Size = UDim2.new(0, s, 0, s)
            end
        end
    end
end

-- Engine calls this each frame to push hold progress.
-- badgeIndex is 1-based; prog is 0..1.
function OrbitIndicator:updateKeyProgress(badgeIndex, prog, done)
    local b = self._badges[badgeIndex]
    if not b then return end
    b.prog = prog
    b.done = done
end

-- Engine calls this each frame during CHARGING state.
function OrbitIndicator:updateChargeProgress(t)
    self._chargeT = t
end

function OrbitIndicator:pushKey(char)
    table.insert(self._badges, self:_makeBadge(char))
    self._visible      = true
    self._root.Visible = true
end

-- Fail: red flash + drift animation, then cleanup.
-- Safe to call during _dying — second call is ignored.
function OrbitIndicator:fail()
    if self._dying then return end
    self._dying   = true
    self._chargeT = 0

    local mouse = UserInputService:GetMouseLocation()
    local n     = #self._badges

    for i, b in ipairs(self._badges) do
        local angle  = self._angle + (i - 1) * (2 * math.pi / math.max(n, 1))
        local radius = 46 + n * 5
        local ox     = math.cos(angle) * radius
        local oy     = math.sin(angle) * radius
        local startX = mouse.X + ox - 19
        local startY = mouse.Y + oy - 19
        local driftX = startX + ox * 1.4 + (math.random() - 0.5) * 30
        local driftY = startY + oy * 1.4 + (math.random() - 0.5) * 30 + 20

        b.frame.BackgroundColor3 = THEME.red
        b.fill.BackgroundColor3  = THEME.red_bright
        b.stroke.Color           = THEME.red_bright
        b.glow.BackgroundColor3  = THEME.red
        b.label.TextColor3       = Color3.new(1, 1, 1)
        b.glow.BackgroundTransparency = 0.3

        TweenService:Create(b.frame, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Position               = UDim2.new(0, driftX, 0, driftY),
            BackgroundTransparency = 1,
        }):Play()
        TweenService:Create(b.label, TweenInfo.new(0.55), { TextTransparency = 1 }):Play()
        TweenService:Create(b.glow,  TweenInfo.new(0.40), { BackgroundTransparency = 1 }):Play()
        TweenService:Create(b.stroke, TweenInfo.new(0.40), { Transparency = 1 }):Play()
    end

    -- Pure cosmetic cleanup — orphaned if indicator is destroyed first.
    task.delay(0.65, function()
        self:_hardReset()
    end)
end

function OrbitIndicator:_hardReset()
    self._dying   = false
    self._chargeT = 0
    for _, b in ipairs(self._badges) do
        if b.frame and b.frame.Parent then b.frame:Destroy() end
    end
    self._badges       = {}
    self._root.Visible = false
    self._visible      = false
end

function OrbitIndicator:resetSuccess() self:_hardReset() end
function OrbitIndicator:resetSilent()  self:_hardReset() end

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
        Name                   = "CastLog",
        BackgroundColor3       = THEME.ind_bg,
        Size                   = UDim2.new(0, w, 0, totalH),
        Position               = UDim2.new(0.5, -w / 2, 0, 120),
        BackgroundTransparency = 1,
        ZIndex                 = 25,
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
            t.Completed:Connect(function()
                if root then root:Destroy() end
            end)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────
--  CASTING ENGINE  (v2 — state machine + version tokens)
-- ─────────────────────────────────────────────────────────────
--
--  STATE MODEL
--  ───────────
--  IDLE      No input. Orbit invisible.
--  BUILDING  Player is pressing keys.
--              · _pressOrder   = chars confirmed (held long enough)
--              · _pendingChar  = char currently being held but not yet confirmed
--              · _pendingStart = os.clock() when pendingChar was pressed
--              · _pendingHold  = seconds required for pendingChar
--            Each Heartbeat: advance _pendingChar progress, mark done,
--            then check for exact/partial match.
--  CHARGING  Full sequence matched. Holding for HOLD_TIME.
--              · _chargeStart  = os.clock()
--              · _chargeSpell  = Spell to cast
--            Each Heartbeat: push charge progress to indicator,
--            fire cast when elapsed >= HOLD_TIME.
--
--  CANCELLATION
--  ────────────
--  _ver is bumped on every transition away from an active state.
--  The Heartbeat callback captures ver at start; if they mismatch
--  it returns immediately — nothing stale can fire.
--
--  KEY RELEASE
--  ───────────
--  Releasing _pendingChar (not yet confirmed) → fail
--  Releasing any char in _pressOrder while BUILDING or CHARGING → fail
--  Releasing any char while IDLE → ignored
-- ─────────────────────────────────────────────────────────────

local CastingEngine = {}
CastingEngine.__index = CastingEngine

function CastingEngine.new(screenGui, indicator)
    local self             = setmetatable({}, CastingEngine)
    self._screenGui        = screenGui
    self._indicator        = indicator
    self._books            = {}
    self._castMode         = false
    self._castModeKey      = Enum.KeyCode.Tilde
    self._modeLabel        = nil

    -- ── Core state ───────────────────────────────────────────
    self._state        = STATE.IDLE
    self._ver          = 0           -- bumped on every interrupt/reset

    -- BUILDING state
    self._pressOrder   = {}          -- confirmed chars, in order
    self._pressedSet   = {}          -- all physically held chars (for release detection)
    self._pendingChar  = nil         -- char held but not yet confirmed
    self._pendingStart = 0           -- os.clock() when pending started
    self._pendingHold  = 0           -- seconds required for pending
    self._pendingBadge = 0           -- badge index for pending char

    -- CHARGING state
    self._chargeSpell  = nil
    self._chargeStart  = 0

    -- Idle-reset tracking
    self._lastKeyTime  = 0           -- os.clock() of last key event

    -- Heartbeat connection
    self._hbConn       = nil
    self._connections  = {}

    return self
end

function CastingEngine:setBooks(books)    self._books = books end
function CastingEngine:setCastModeKey(kc) self._castModeKey = kc end

-- ── Spell lookup ─────────────────────────────────────────────

function CastingEngine:_allSpells()
    local all = {}
    for _, book in ipairs(self._books) do
        for _, spell in ipairs(book.spells) do
            table.insert(all, spell)
        end
    end
    return all
end

function CastingEngine:_findExact(seq)
    for _, spell in ipairs(self:_allSpells()) do
        if spell:getSequence() == seq then return spell end
    end
    return nil
end

function CastingEngine:_findPartial(seq)
    for _, spell in ipairs(self:_allSpells()) do
        if spell:getSequence():sub(1, #seq) == seq then return spell end
    end
    return nil
end

-- ── Version bump ─────────────────────────────────────────────
--
--  Call before any state transition that should kill pending work.
--  The running Heartbeat closure captures ver locally at the top
--  of each tick; if self._ver has changed, it bails out.

function CastingEngine:_bumpVer()
    self._ver = self._ver + 1
    return self._ver
end

-- ── Transition helpers ────────────────────────────────────────

-- Full reset to IDLE — no animation.
function CastingEngine:_toIdle()
    self:_bumpVer()
    self._state        = STATE.IDLE
    self._pressOrder   = {}
    self._pressedSet   = {}
    self._pendingChar  = nil
    self._pendingStart = 0
    self._pendingHold  = 0
    self._pendingBadge = 0
    self._chargeSpell  = nil
    self._chargeStart  = 0
    self._indicator:resetSilent()
end

-- Fail with animation + optional log message.
function CastingEngine:_fail(reason)
    self:_bumpVer()
    self._state        = STATE.IDLE
    self._pressOrder   = {}
    self._pressedSet   = {}
    self._pendingChar  = nil
    self._chargeSpell  = nil

    -- Indicator handles its own animation cleanup timing.
    -- Engine is already IDLE, so new input can start immediately
    -- (OrbitIndicator.fail() sets _dying=true to block duplicate calls,
    --  and _hardReset() clears _dying after animation).
    self._indicator:fail()

    if reason then
        showCastLog(self._screenGui, {
            { text = reason,                   color = THEME.red     },
            { text = randomFrom(SPELL_ERRORS), color = THEME.ink_dim },
        })
    end
end

-- Transition to BUILDING after confirming a key.
-- (State was already BUILDING; this just refreshes pending tracking.)
function CastingEngine:_confirmPending()
    -- pendingChar has been held long enough — add to pressOrder
    local char = self._pendingChar
    table.insert(self._pressOrder, char)
    self._pendingChar  = nil
    self._pendingStart = 0

    -- Update indicator badge: mark it done
    -- (prog=1, done=true — already pushed each frame, now locked)
    self._indicator:updateKeyProgress(self._pendingBadge, 1, true)
    self._pendingBadge = 0

    local current = table.concat(self._pressOrder)

    -- Exact match → CHARGING
    local exactSpell = self:_findExact(current)
    if exactSpell then
        self._state       = STATE.CHARGING
        self._chargeSpell = exactSpell
        self._chargeStart = os.clock()
        return
    end

    -- Partial match → keep BUILDING, wait for next key
    local partial = self:_findPartial(current)
    if not partial then
        self:_fail("No spell matches this sequence.")
    end
    -- else: waiting for next key press — stay in BUILDING
end

-- ── Main Heartbeat loop ───────────────────────────────────────
--
--  This is the single update function that drives all timing.
--  It captures _ver at entry and checks it before any state write.

function CastingEngine:_startHeartbeat()
    self._hbConn = RunService.Heartbeat:Connect(function()
        if not self._castMode then return end

        local ver = self._ver   -- capture current version

        -- ── BUILDING: advance pending-key progress ──────────
        if self._state == STATE.BUILDING and self._pendingChar then
            local elapsed = os.clock() - self._pendingStart
            local prog    = math.clamp(elapsed / self._pendingHold, 0, 1)
            self._indicator:updateKeyProgress(self._pendingBadge, prog, prog >= 1)

            if prog >= 1 then
                -- Held long enough — confirm only if ver hasn't changed
                if self._ver ~= ver then return end
                self:_confirmPending()
            end
            return
        end

        -- ── CHARGING: advance final hold ────────────────────
        if self._state == STATE.CHARGING then
            local elapsed = os.clock() - self._chargeStart
            local prog    = math.clamp(elapsed / HOLD_TIME, 0, 1)
            self._indicator:updateChargeProgress(prog)

            if prog >= 1 then
                if self._ver ~= ver then return end

                -- Verify all sequence keys still held
                local seq = self._chargeSpell:getSequence()
                for i = 1, #seq do
                    if not self._pressedSet[seq:sub(i, i)] then
                        self:_fail("Grip broke at the last moment…")
                        return
                    end
                end

                self:_doCast(self._chargeSpell)
            end
            return
        end

        -- ── IDLE: check idle-reset timer ────────────────────
        -- (Keys may still be physically held from a non-cast key;
        --  only reset if we somehow drifted here with pressedSet non-empty)
        -- Nothing to do — IDLE is the resting state.
    end)
end

-- ── Key pressed ───────────────────────────────────────────────

function CastingEngine:onKeyDown(key)
    -- Cast mode toggle
    if key == self._castModeKey then
        if self._castMode then self:_exitCastMode() else self:_enterCastMode() end
        return
    end

    if not self._castMode then return end

    if key == Enum.KeyCode.Escape then
        self:_exitCastMode()
        return
    end

    local char = CAST_KEY_MAP[key]
    if not char then return end

    -- Track that this key is physically held (for release detection)
    self._pressedSet[char] = true
    self._lastKeyTime = os.clock()

    -- ── IDLE → BUILDING ─────────────────────────────────────
    if self._state == STATE.IDLE then
        -- Determine hold time from any spell that starts with this key
        local keyHold = KEY_HOLD_TIME
        local partial  = self:_findPartial(char)
        if partial then keyHold = partial.keyHoldTime or KEY_HOLD_TIME end

        self._state        = STATE.BUILDING
        self._pendingChar  = char
        self._pendingStart = os.clock()
        self._pendingHold  = keyHold
        self._pendingBadge = 1
        self._indicator:pushKey(char)
        return
    end

    -- ── BUILDING: new key while a key is pending ─────────────
    --  Block until pending key is confirmed (held long enough).
    if self._state == STATE.BUILDING then
        if self._pendingChar then
            -- Key pressed before current pending key finished.
            -- Treat as a fail — "too fast" is a legit skill ceiling.
            -- (Alternative: queue it. We choose fail for precision feel.)
            self:_fail("Hold each key longer before pressing the next.")
            return
        end

        -- Pending is nil → last key was confirmed, waiting for next.
        -- Pressing same key as one already in sequence = fail.
        for _, c in ipairs(self._pressOrder) do
            if c == char then
                self:_fail("Key already in sequence.")
                return
            end
        end

        -- Determine hold time from partial spell
        local seq      = table.concat(self._pressOrder) .. char
        local keyHold  = KEY_HOLD_TIME
        local partial  = self:_findPartial(seq)
        if partial then keyHold = partial.keyHoldTime or KEY_HOLD_TIME end

        local badgeIdx = #self._pressOrder + 1
        self._pendingChar  = char
        self._pendingStart = os.clock()
        self._pendingHold  = keyHold
        self._pendingBadge = badgeIdx
        self._indicator:pushKey(char)
        return
    end

    -- ── CHARGING: any new key = interrupt ───────────────────
    if self._state == STATE.CHARGING then
        self:_fail("Sequence interrupted.")
        -- Re-enter the key as a fresh start on the next frame.
        -- (pressedSet already has it; let onKeyDown fire again next frame
        --  naturally if they hold it. Don't auto-restart here to avoid
        --  ghost sequences.)
        return
    end
end

-- ── Key released ─────────────────────────────────────────────

function CastingEngine:onKeyUp(key)
    if not self._castMode then return end
    local char = CAST_KEY_MAP[key]
    if not char then return end

    -- Not tracking this key at all? Ignore.
    if not self._pressedSet[char] then return end
    self._pressedSet[char] = nil

    if self._state == STATE.IDLE then return end

    -- Released the pending key (not yet confirmed) → fail
    if self._pendingChar == char then
        self:_fail("Key released too soon.")
        return
    end

    -- Released a confirmed key while BUILDING or CHARGING → fail
    for _, c in ipairs(self._pressOrder) do
        if c == char then
            self:_fail("Sequence broken — " .. char .. " released.")
            return
        end
    end

    -- Released an unrelated key (e.g. a previously pressed non-cast key).
    -- If BUILDING and now no relevant keys held, start idle timer.
    -- (We don't use a separate idle thread — the Heartbeat is always running.)
    -- Nothing extra to do here.
end

-- ── Cast execution ────────────────────────────────────────────

function CastingEngine:_doCast(spell)
    -- Transition to IDLE before firing callback
    -- (Prevents re-entrance if callback triggers input)
    local capturedSpell = spell
    self:_bumpVer()
    self._state       = STATE.IDLE
    self._pressOrder  = {}
    self._pressedSet  = {}
    self._chargeSpell = nil
    self._pendingChar = nil

    if capturedSpell:isCoolingDown() then
        local rem = math.ceil(capturedSpell:cooldownRemaining())
        self._indicator:fail()
        showCastLog(self._screenGui, {
            { text = "On cooldown — " .. capturedSpell.name, color = THEME.orange  },
            { text = rem .. "s remaining",                   color = THEME.ink_dim },
        })
        return
    end

    local msg = randomFrom(CAST_MESSAGES)
    local success, err = pcall(capturedSpell.callback)
    capturedSpell:onCast()

    local lines = {
        { text = msg .. " — " .. capturedSpell.name, color = THEME.gold }
    }
    if success then
        table.insert(lines, { text = "The magic takes hold.", color = THEME.ink })
    else
        table.insert(lines, { text = randomFrom(SPELL_ERRORS),      color = THEME.red })
        if err then
            table.insert(lines, { text = tostring(err):sub(1, 60), color = THEME.red })
        end
    end
    if capturedSpell.cooldown > 0 then
        table.insert(lines, { text = "Cooldown: " .. capturedSpell.cooldown .. "s", color = THEME.ink_dim })
    end

    showCastLog(self._screenGui, lines)
    self._indicator:resetSuccess()
end

-- Public cast (called from the UI "Cast Now" button)
function CastingEngine:_cast(spell)
    self:_doCast(spell)
end

-- ── Cast mode enter / exit ────────────────────────────────────

function CastingEngine:_enterCastMode()
    self._castMode = true
    self:_toIdle()
    if self._modeLabel then
        self._modeLabel.Text       = "◆ CASTING"
        self._modeLabel.TextColor3 = THEME.gold
        self._modeLabel.Visible    = true
    end
end

function CastingEngine:_exitCastMode()
    self._castMode = false
    self:_toIdle()
    if self._modeLabel then
        self._modeLabel.Visible = false
    end
end

-- ── Input listeners ───────────────────────────────────────────

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
    self:_startHeartbeat()
end

function CastingEngine:stopListening()
    for _, c in ipairs(self._connections) do c:Disconnect() end
    self._connections = {}
    if self._hbConn then
        self._hbConn:Disconnect()
        self._hbConn = nil
    end
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

    self._indicator = OrbitIndicator.new(sg)
    self._engine    = CastingEngine.new(sg, self._indicator)
    self._engine:setBooks(self._lib._books)
    self._engine:startListening()

    -- Cast mode label (top-center)
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

    local closeBtn = makeButton({
        BackgroundColor3 = THEME.spine,
        TextColor3       = THEME.red,
        Font             = Enum.Font.Code,
        TextSize         = 11,
        Size             = UDim2.new(0, 32, 0, 22),
        Position         = UDim2.new(1, -38, 0.5, -11),
        Text             = "[x]",
        ZIndex           = 12,
    }, bar)
    addCorner(4, closeBtn)
    closeBtn.MouseButton1Click:Connect(function() self:close() end)

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

    makeFrame({
        BackgroundColor3 = THEME.gold_dim,
        Size             = UDim2.new(1, -pad*2, 0, 1),
        Position         = UDim2.new(0, pad, 0, 72),
        ZIndex           = 12,
    }, c)

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

    local infoHolder = makeFrame({
        BackgroundColor3 = THEME.spine,
        Size             = UDim2.new(1, -pad*2, 0, 130),
        Position         = UDim2.new(0, pad, 0, 148),
        ZIndex           = 12,
    }, c)
    addCorner(6, infoHolder)
    addStroke(THEME.page_border, 1, infoHolder)

    self._infoLabel = makeLabel({
        Size           = UDim2.new(1, -16, 1, -12),
        Position       = UDim2.new(0, 8, 0, 6),
        Text           = "",
        TextColor3     = THEME.ink,
        Font           = Enum.Font.Code,
        TextSize       = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped    = true,
        RichText       = true,
        ZIndex         = 13,
    }, infoHolder)

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

    local castBtn = makeButton({
        Size             = UDim2.new(0, 120, 0, 32),
        Position         = UDim2.new(0, pad, 0, 344),
        BackgroundColor3 = THEME.gold_dim,
        Text             = "> Cast Now",
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
        self._cdBar.Size   = UDim2.new(0, 0, 1, 0)
        self._cdLabel.Text = "None"
        return
    end

    local rem  = spell:cooldownRemaining()
    local frac = 1 - (rem / spell.cooldown)
    TweenService:Create(self._cdBar, TweenInfo.new(0.1), {
        Size = UDim2.new(frac, 0, 1, 0)
    }):Play()

    if rem > 0 then
        self._cdBar.BackgroundColor3 = lerpColor(THEME.red, THEME.green, frac)
        self._cdLabel.Text = string.format("%.1fs / %.0fs", rem, spell.cooldown)
    else
        self._cdBar.BackgroundColor3 = THEME.green
        self._cdLabel.Text = string.format("Ready  (%.0fs)", spell.cooldown)
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

    self._prevBtn = navBtn("<", 6,   function() self:_prevPage() end)
    self._nextBtn = navBtn(">", 36,  function() self:_nextPage() end)
    navBtn("^", 72,  function() self:_reorder(-1) end)
    navBtn("v", 102, function() self:_reorder(1)  end)

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
    local book = self:_currentBookF()
    if not book then return end
    local spells = book.spells
    local total  = math.max(#spells, 1)
    local idx    = math.clamp(self._currentPage, 1, math.max(#spells, 1))
    self._currentPage = idx

    self._pageNumLabel.Text  = idx .. " / " .. total
    self._prevBtn.TextColor3 = (idx > 1)       and THEME.gold or THEME.ink_dim
    self._nextBtn.TextColor3 = (idx < #spells) and THEME.gold or THEME.ink_dim
    self._titleLabel.Text    = book.name
    self._bookLabel.Text     = book.name

    if #spells == 0 then
        self._nameLabel.Text = "Empty Grimoire"
        self._infoLabel.Text = "No spells.\nUse :addSpell() to add one."
        self:_clearSeq()
        self._cdLabel.Text = "None"
        return
    end

    local spell = spells[idx]
    self._nameLabel.Text = spell.name

    local seqStr = spell:getSequence()
    self._infoLabel.Text =
        "<font color='#6060a0'>sequence</font>   " .. seqStr
        .. "\n<font color='#6060a0'>key hold</font>    " .. spell.keyHoldTime .. "s per key"
        .. "\n<font color='#6060a0'>final hold</font>  " .. HOLD_TIME .. "s to cast"
        .. "\n<font color='#6060a0'>cooldown</font>   "
        .. (spell.cooldown > 0 and spell.cooldown .. "s" or "none")

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

function SpellbookUI:_prevPage()
    local book = self:_currentBookF()
    if not book or self._currentPage <= 1 then return end
    self._currentPage = self._currentPage - 1
    self:_renderPage()
end

function SpellbookUI:_nextPage()
    local book = self:_currentBookF()
    if not book or self._currentPage >= #book.spells then return end
    self._currentPage = self._currentPage + 1
    self:_renderPage()
end

function SpellbookUI:_reorder(dir)
    local book = self:_currentBookF()
    if not book then return end
    self._currentPage = book:moveSpell(self._currentPage, dir)
    self:_renderPage()
end

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
    self._statusLabel.Text       = "> " .. books[self._currentBook].name
    self._statusLabel.TextColor3 = THEME.green
    task.delay(2, function() if self._statusLabel then self._statusLabel.Text = "" end end)
end

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
--  SPELLBOOK LIBRARY  — public API (unchanged)
-- ─────────────────────────────────────────────────────────────

local SpellbookLib = {}
SpellbookLib.__index = SpellbookLib

--[[
    SpellbookLib.new(config?)

    config:
        toggleKey     Enum.KeyCode   window toggle          (default: RightBracket)
        castModeKey   Enum.KeyCode   enter/exit cast mode   (default: Tilde `)
        autoOpen      bool           open immediately       (default: false)
]]
function SpellbookLib.new(config)
    local self = setmetatable({}, SpellbookLib)
    config = config or {}

    self._books         = {}
    self._ui            = nil
    self._usedSequences = {}

    local toggleKey   = config.toggleKey   or Enum.KeyCode.RightBracket
    local castModeKey = config.castModeKey or Enum.KeyCode.Tilde
    local autoOpen    = config.autoOpen    or false

    task.defer(function()
        self._ui = SpellbookUI.new(self)
        self._ui._engine:setCastModeKey(castModeKey)
        if autoOpen then self._ui:open() end

        UserInputService.InputBegan:Connect(function(input, gp)
            if gp then return end
            if input.KeyCode == toggleKey then self._ui:toggle() end
        end)
    end)

    return self
end

--[[
    lib:addBook(name) → Book
    Returns a book whose addSpell guarantees globally unique sequences.
]]
function SpellbookLib:addBook(name)
    local lib  = self
    local book = Book.new(name)

    book.addSpell = function(bk, spellName, callback, opts)
        local spell = Spell.new(spellName, callback, opts)
        spell._sequence = generateSequence(
            spellName,
            spellName,
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

function SpellbookLib:open()   if self._ui then self._ui:open()   end end
function SpellbookLib:close()  if self._ui then self._ui:close()  end end
function SpellbookLib:toggle() if self._ui then self._ui:toggle() end end

function SpellbookLib:destroy()
    if self._ui then self._ui:destroy() end
    self._books         = {}
    self._usedSequences = {}
end

return SpellbookLib
