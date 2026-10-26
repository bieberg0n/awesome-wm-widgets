--------------------------------------------------------------------
-- sink-switch.lua - fast switching of the default audio output.
--
-- Only talks to `pactl`, so it works on PipeWire (Ubuntu 22.10+) as
-- well as on PulseAudio.
--
-- Usage:
--
--   local sink_switch = require("awesome-wm-widgets.sink-switch")
--
--   sink_switch.setup {
--       sinks = {                       -- cycle order, full names or unique prefixes
--           "bluez_output",             -- bluetooth headset
--           "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.5.HiFi__hw_sofhdadsp__sink",
--       },
--       labels = {                      -- prefix -> text shown in the notification
--           ["bluez_output"] = "蓝牙耳机",
--           ["alsa_output"]  = "音箱",
--       },
--       move_streams = true,            -- let playing apps follow the new sink
--       notify = true,
--   }
--
--   sink_switch.cycle()                 -- next sink, wraps around
--   sink_switch.set("alsa_output.usb")  -- explicit sink (prefix is enough)
--------------------------------------------------------------------

local naughty = require("naughty")

local sink_switch = {}

local config = {
	sinks = nil, -- ordered list of sink names; nil = every sink pactl reports
	labels = {}, -- prefix -> short human readable label
	move_streams = true,
	notify = true,
	notify_timeout = 2,
	notify_title = "音频输出",
}

local last_notification_id = nil

--------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------

local function shell(command)
	local pipe = io.popen(command)
	if not pipe then
		return ""
	end
	local output = pipe:read("*a")
	pipe:close()
	return output or ""
end

local function quote(value)
	-- ' -> '\'' so that the value survives single quoting
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(value)
	return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

local function notify(text)
	if not config.notify then
		return
	end
	local notification = naughty.notify({
		title = config.notify_title,
		text = text,
		timeout = config.notify_timeout,
		replaces_id = last_notification_id,
	})
	if notification then
		last_notification_id = notification.id
	end
end

--------------------------------------------------------------------
-- querying pactl
--------------------------------------------------------------------

-- Returns a list of { id = <number>, name = <string> }.
function sink_switch.available()
	local sinks = {}
	for line in shell("LC_ALL=C pactl list short sinks"):gmatch("[^\r\n]+") do
		local id, name = line:match("^(%d+)%s+(%S+)")
		if name then
			sinks[#sinks + 1] = { id = tonumber(id), name = name }
		end
	end
	return sinks
end

-- Returns { [sink_name] = "Description" }
local function descriptions()
	local result = {}
	local current = nil

	local function flush()
		if current and current.name and current.description then
			result[current.name] = current.description
		end
	end

	for line in shell("LC_ALL=C pactl list sinks"):gmatch("[^\r\n]+") do
		if line:match("^Sink #%d+") then
			flush()
			current = {}
		elseif current then
			local name = line:match("^%s*Name: (.+)$")
			if name then
				current.name = name
			else
				local description = line:match("^%s*Description: (.+)$")
				if description then
					current.description = description
				end
			end
		end
	end
	flush()

	return result
end

-- Name of the current default sink ("" when pactl does not answer).
function sink_switch.current()
	return trim(shell("LC_ALL=C pactl get-default-sink"))
end

-- Exact name first, then prefix match, then suffix match (so that
-- "alsa_output.usb" and "HiFi__hw_sofhdadsp__sink" both resolve).
local function resolve(pattern, sinks)
	if type(pattern) ~= "string" or pattern == "" then
		return nil
	end
	for _, sink in ipairs(sinks) do
		if sink.name == pattern then
			return sink.name
		end
	end
	for _, sink in ipairs(sinks) do
		if sink.name:sub(1, #pattern) == pattern then
			return sink.name
		end
	end
	for _, sink in ipairs(sinks) do
		if #pattern < #sink.name and sink.name:sub(-#pattern) == pattern then
			return sink.name
		end
	end
	return nil
end

local function label_for(name, sink_descriptions)
	-- labels are matched by exact name, then by prefix, then by suffix,
	-- so both "bluez_output" and "HiFi__hw_sofhdadsp__sink" work
	local best, best_length = nil, 0
	for key, label in pairs(config.labels) do
		if name == key then
			return label
		end
	end
	for key, label in pairs(config.labels) do
		if name:sub(1, #key) == key and #key > best_length then
			best, best_length = label, #key
		end
	end
	if best then
		return best
	end
	for key, label in pairs(config.labels) do
		if #key < #name and name:sub(-#key) == key and #key > best_length then
			best, best_length = label, #key
		end
	end
	if best then
		return best
	end

	local description = sink_descriptions[name]
	if description and description ~= "" and description ~= "(null)" then
		if #description > 44 then
			description = "…" .. description:sub(-43)
		end
		return description
	end

	return (name:gsub("^alsa_output%.", ""):gsub("^bluez_output%.", ""):gsub("_", " "))
end

--------------------------------------------------------------------
-- switching
--------------------------------------------------------------------

-- Ordered list of sinks that cycle() walks through.
function sink_switch.devices()
	local sinks = sink_switch.available()
	local devices, seen = {}, {}

	local function add(name)
		if name and not seen[name] then
			seen[name] = true
			devices[#devices + 1] = name
		end
	end

	if config.sinks then
		for _, pattern in ipairs(config.sinks) do
			add(resolve(pattern, sinks))
		end
	else
		for _, sink in ipairs(sinks) do
			add(sink.name)
		end
	end

	return devices
end

-- Switch the default sink, optionally dragging running streams along.
function sink_switch.set(name)
	local target = resolve(name, sink_switch.available())
	if not target then
		notify("找不到设备：" .. tostring(name))
		return false
	end

	shell("LC_ALL=C pactl set-default-sink " .. quote(target))

	if config.move_streams then
		for line in shell("LC_ALL=C pactl list short sink-inputs"):gmatch("[^\r\n]+") do
			local id = line:match("^(%d+)")
			if id then
				shell("LC_ALL=C pactl move-sink-input " .. id .. " " .. quote(target))
			end
		end
	end

	notify(label_for(target, descriptions()))
	return true
end

-- Jump `step` devices forward in the configured list (negative = backwards).
function sink_switch.cycle(step)
	step = step or 1

	local devices = sink_switch.devices()
	if #devices == 0 then
		notify("没有可用的音频输出设备")
		return false
	end

	local current = sink_switch.current()
	local index = nil
	for i, name in ipairs(devices) do
		if name == current then
			index = i
		end
	end

	local next_index
	if index then
		next_index = ((index - 1 + step) % #devices) + 1
	else
		next_index = 1
	end

	return sink_switch.set(devices[next_index])
end

function sink_switch.next()
	return sink_switch.cycle(1)
end

function sink_switch.prev()
	return sink_switch.cycle(-1)
end

function sink_switch.toggle()
	return sink_switch.cycle(1)
end

function sink_switch.setup(args)
	if type(args) ~= "table" then
		return sink_switch
	end
	for key, value in pairs(args) do
		if key == "sinks" and type(value) == "string" then
			value = { value }
		end
		config[key] = value
	end
	return sink_switch
end

return sink_switch
