--!optimize 2

local UserInputService = game:GetService("UserInputService")

local Actions = {}

local PARTS = { "up", "down", "left", "right" }
local DEVICES = { "kbm", "pad" }
local MOUSE = { MouseLeftButton = 1, MouseRightButton = 2, MouseMiddleButton = 3 }
local STICKS = { Thumbstick1 = 1, Thumbstick2 = 3 }
local QUEUE_CAP = 3

local NEVER = {
	Unknown = true, None = true, Escape = true, ButtonStart = true, ButtonSelect = true,
	Thumbstick1 = true, Thumbstick2 = true, MousePosition = true, MouseWheel = true,
}
local CANCEL = { kbm = { Escape = true, Backspace = true }, pad = { ButtonA = true } }

local LABELS = {
	MouseLeftButton = "LMB", MouseRightButton = "RMB", MouseMiddleButton = "MMB",
	Space = "SPACE", Return = "ENTER", KeypadEnter = "ENTER", Tab = "TAB",
	LeftShift = "LSHIFT", RightShift = "RSHIFT", LeftControl = "LCTRL", RightControl = "RCTRL",
	LeftAlt = "LALT", RightAlt = "RALT", Backspace = "BKSP", CapsLock = "CAPS",
	Up = "UP", Down = "DOWN", Left = "LEFT", Right = "RIGHT",
	Insert = "INS", Delete = "DEL", Home = "HOME", End = "END", PageUp = "PGUP", PageDown = "PGDN",
	Backquote = "`", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]",
	Semicolon = ";", Quote = "'", Comma = ",", Period = ".", Slash = "/", BackSlash = "\\",
	KeypadZero = "KP0", KeypadOne = "KP1", KeypadTwo = "KP2", KeypadThree = "KP3",
	KeypadFour = "KP4", KeypadFive = "KP5", KeypadSix = "KP6", KeypadSeven = "KP7",
	KeypadEight = "KP8", KeypadNine = "KP9", KeypadPlus = "KP+", KeypadMinus = "KP-",
	KeypadMultiply = "KP*", KeypadDivide = "KP/", KeypadPeriod = "KP.",
}

local order, specs = {}, {}
local defaults, binds = {}, {}
local byKey = { kbm = {}, pad = {} }
local queues = {}
local version = 0
local capture = nil
local blocked = {}
local raw = nil
local lockedBy = function() return false end

local codes = {}
local function codeOf(name: string)
	local kc = codes[name]
	if kc == nil then
		local ok, v = pcall(function() return Enum.KeyCode[name] end)
		kc = ok and v or false
		codes[name] = kc
	end
	return kc or nil
end

local function copy(b)
	if type(b) ~= "table" then return b end
	local c = {}
	for k, v in pairs(b) do c[k] = v end
	return c
end

local function same(a, b): boolean
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for _, p in ipairs(PARTS) do
		if a[p] ~= b[p] then return false end
	end
	return true
end

local function index()
	table.clear(byKey.kbm)
	table.clear(byKey.pad)
	for _, name in ipairs(order) do
		local b = binds[name]
		for _, device in ipairs(DEVICES) do
			local k = b[device]
			if type(k) == "table" then
				for _, p in ipairs(PARTS) do
					if k[p] then byKey[device][k[p]] = name end
				end
			elseif k then
				byKey[device][k] = name
			end
		end
	end
	version += 1
end

function Actions.attach(t)
	raw = t
end

function Actions.lockedBy(fn)
	lockedBy = fn
end

function Actions.define(spec)
	table.clear(order)
	table.clear(specs)
	table.clear(defaults)
	table.clear(binds)
	table.clear(queues)
	table.clear(blocked)
	for k in pairs(NEVER) do blocked[k] = true end
	for _, k in ipairs(spec.blocked or {}) do blocked[k] = true end
	for _, name in ipairs(spec.order) do
		local a = spec.actions[name]
		order[#order + 1] = name
		specs[name] = { label = a.label or name, kind = a.kind or "button", lock = a.lock or {},
			alt = copy(a.alt) }
		defaults[name] = { kbm = copy(a.kbm), pad = copy(a.pad) }
		binds[name] = { kbm = copy(a.kbm), pad = copy(a.pad) }
	end
	capture = nil
	index()
end

function Actions.list()
	local out = {}
	for _, name in ipairs(order) do
		local s = specs[name]
		out[#out + 1] = { name = name, label = s.label, kind = s.kind, alt = copy(s.alt),
			lock = { kbm = s.lock.kbm == true, pad = s.lock.pad == true } }
	end
	return out
end

function Actions.version(): number
	return version
end

function Actions.blocked(key: string): boolean
	return blocked[key] == true or CANCEL.kbm[key] == true or CANCEL.pad[key] == true
end

function Actions.pressed(name: string): boolean
	local n = queues[name]
	if not n or n <= 0 then return false end
	queues[name] = n - 1
	return not lockedBy()
end

local function held(key, device): boolean
	if not key then return false end
	if device == "pad" then
		local kc = codeOf(key)
		return kc ~= nil and raw.padHeld[kc] == true
	end
	local m = MOUSE[key]
	if m then return raw.mouseHeld(m) end
	local kc = codeOf(key)
	return kc ~= nil and raw.keysDown[kc] == true
end

function Actions.down(name: string): boolean
	local b = binds[name]
	if not b or lockedBy() then return false end
	return held(b.kbm, "kbm") or held(b.pad, "pad")
end

function Actions.axis(name: string, device: string?): (number, number)
	local b = binds[name]
	if not b or lockedBy() then return 0, 0 end
	local x, y = 0, 0
	if device ~= "pad" and type(b.kbm) == "table" then
		local c = b.kbm
		if held(c.right, "kbm") then x += 1 end
		if held(c.left, "kbm") then x -= 1 end
		if held(c.down, "kbm") then y += 1 end
		if held(c.up, "kbm") then y -= 1 end
		local alt = specs[name].alt
		if x == 0 and y == 0 and alt then
			local own = byKey.kbm
			if held(alt.right, "kbm") and not own[alt.right] then x += 1 end
			if held(alt.left, "kbm") and not own[alt.left] then x -= 1 end
			if held(alt.down, "kbm") and not own[alt.down] then y += 1 end
			if held(alt.up, "kbm") and not own[alt.up] then y -= 1 end
		end
	end
	if device ~= "kbm" and x == 0 and y == 0 then
		local i = STICKS[b.pad]
		if i then x, y = raw.sticks[i], -raw.sticks[i + 1] end
	end
	return x, y
end

function Actions.pending(): boolean
	for _, n in pairs(queues) do
		if n > 0 then return true end
	end
	return false
end

function Actions.flush()
	table.clear(queues)
end

function Actions.fire(name: string)
	if specs[name] then queues[name] = math.min(QUEUE_CAP, (queues[name] or 0) + 1) end
end

function Actions.press(key: string, device: string, gameProcessed: boolean?): boolean
	if device == "kbm" and gameProcessed then return false end
	local c = capture
	if c and c.device == device then
		if CANCEL[device][key] then
			capture = nil
			c.cb(nil)
			return true
		end
		if not Actions.blocked(key) then
			capture = nil
			c.cb(key)
			return true
		end
	end
	local name = byKey[device][key]
	if name then queues[name] = math.min(QUEUE_CAP, (queues[name] or 0) + 1) end
	return false
end

function Actions.bindingOf(name: string, device: string, part: string?)
	local b = binds[name]
	if not b then return nil end
	local k = b[device]
	if type(k) == "table" then return part and k[part] or nil end
	return k
end

function Actions.keyCodeOf(name: string, device: string, part: string?)
	local k = Actions.bindingOf(name, device, part)
	return k and codeOf(k) or nil
end

function Actions.keyLabel(key: string?): string
	if not key then return "" end
	if LABELS[key] then return LABELS[key] end
	local kc = codeOf(key)
	if kc then
		local ok, s = pcall(function() return UserInputService:GetStringForKeyCode(kc) end)
		if ok and type(s) == "string" and #s > 0 and #s <= 4 then return string.upper(s) end
	end
	return string.upper(key)
end

function Actions.label(name: string, device: string, part: string?): string
	local b = binds[name]
	local k = b and b[device]
	if type(k) ~= "table" then return Actions.keyLabel(k) end
	if part then return Actions.keyLabel(k[part]) end
	local parts = { Actions.keyLabel(k.up), Actions.keyLabel(k.left),
		Actions.keyLabel(k.down), Actions.keyLabel(k.right) }
	for _, p in ipairs(parts) do
		if #p ~= 1 then return table.concat(parts, "/") end
	end
	return table.concat(parts)
end

function Actions.locked(name: string, device: string): boolean
	local s = specs[name]
	return s ~= nil and s.lock[device] == true
end

function Actions.rebind(name: string, device: string, key: string, part: string?)
	local b, s = binds[name], specs[name]
	if not b or not s then return false, "unknown" end
	if s.lock[device] then return false, "locked" end
	if type(key) ~= "string" or Actions.blocked(key) or not (MOUSE[key] or codeOf(key)) then
		return false, "blocked"
	end
	if device == "pad" and MOUSE[key] then return false, "blocked" end
	local holder = byKey[device][key]
	if holder and holder ~= name then return false, "taken", holder end
	if type(b[device]) == "table" then
		if not part or not b[device][part] then return false, "unknown" end
		if b[device][part] == key then return true end
		for _, p in ipairs(PARTS) do
			if b[device][p] == key then b[device][p] = b[device][part] end
		end
		b[device][part] = key
	else
		if b[device] == key then return true end
		b[device] = key
	end
	index()
	return true
end

function Actions.bindings()
	local out = {}
	for _, name in ipairs(order) do
		local d, b = defaults[name], binds[name]
		local entry = nil
		for _, device in ipairs(DEVICES) do
			if not same(d[device], b[device]) then
				entry = entry or {}
				entry[device] = copy(b[device])
			end
		end
		if entry then out[name] = entry end
	end
	return out
end

function Actions.apply(tbl): number
	for _, name in ipairs(order) do
		binds[name] = { kbm = copy(defaults[name].kbm), pad = copy(defaults[name].pad) }
	end
	index()
	local n = 0
	if type(tbl) ~= "table" then return 0 end
	for _, name in ipairs(order) do
		local e = tbl[name]
		if type(e) == "table" then
			for _, device in ipairs(DEVICES) do
				local k = e[device]
				if type(k) == "table" and type(binds[name][device]) == "table" then
					for _, p in ipairs(PARTS) do
						if type(k[p]) == "string" and Actions.rebind(name, device, k[p], p) then n += 1 end
					end
				elseif type(k) == "string" and Actions.rebind(name, device, k) then
					n += 1
				end
			end
		end
	end
	return n
end

function Actions.reset()
	Actions.apply(nil)
end

function Actions.isDefault(): boolean
	return next(Actions.bindings()) == nil
end

function Actions.capture(device: string, cb)
	capture = { device = device, cb = cb }
end

function Actions.cancelCapture()
	local c = capture
	capture = nil
	if c then c.cb(nil) end
end

function Actions.capturing(): string?
	return capture and capture.device or nil
end

return Actions
