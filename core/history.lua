module 'aux.core.history'
--  Fork created 20250917: This fork reworks the calculations for item cost and record storage. The overall goal here was to have more timely/accurate AH prices in tooltips and for other add-ons (e.g. Artisan's reagent costs).

--  Added 20250914: Big thanks to Sedin from Even Better for all the coding help!

local T = require 'T'
local aux = require 'aux'

local persistence = require 'aux.util.persistence'
--  Added 20250914: Added daily_sum and daily_count to schema for averages
--  Added 20250914: Patched error from util.lua #148 strfind by moving daily_sum and daily_count to end of schema. See below note.
--  Note 20250914: DO NOT change order of history_schema lines or else it will error out the addon and likely crash your game. If adding new values/records, add at the end of the history_schema lines.
local history_schema = {'tuple', '#', 
	{next_push='number'}, 
	{daily_min_buyout='number'}, 
	{data_points={'list', ';', {'tuple', '@', {value='number'}, {time='number'}}}}, 
	{daily_sum='number'}, 
	{daily_count='number'}
}

local value_cache = {}

function aux.handle.LOAD2()
	data = aux.faction_data.history
end

-- Added 20250914: Reset item records on logout. This is what makes the "Today min" and "Today +10%" values in tooltip.lua much more accurate.
local resetFrame = CreateFrame("Frame")
resetFrame:RegisterEvent("PLAYER_LOGOUT")
resetFrame:SetScript("OnEvent", function()
	for item_key, raw in pairs(data) do
		local record = persistence.read(history_schema, raw)
		record.daily_sum = nil
		record.daily_count = nil
		record.daily_min_buyout = nil
		write_record(item_key, record)
	end
end)

do
	local next_push = 0
	function get_next_push()
		if time() > next_push then
			local date = date('*t')
			date.hour, date.min, date.sec = 24, 0, 0
			next_push = time(date)
		end
		return next_push
	end
end

function new_record()
	return T.temp-T.map('next_push', get_next_push(), 'data_points', T.acquire())
end

function read_record(item_key)
	local record = data[item_key] and persistence.read(history_schema, data[item_key]) or new_record()
	if record.next_push <= time() then
		push_record(record)
		write_record(item_key, record)
	end
	return record
end

function write_record(item_key, record)
	data[item_key] = persistence.write(history_schema, record)
	if value_cache[item_key] then
		T.release(value_cache[item_key])
		value_cache[item_key] = nil
	end
end

-- Old note: pfUI.api.strsplit
local function AuxAddon_strsplit(delimiter, subject)
	if not subject then return nil end
	local delimiter, fields = delimiter or ":", {}
	local pattern = string.format("([^%s]+)", delimiter)
	string.gsub(subject, pattern, function(c) fields[table.getn(fields)+1] = c end)
	return unpack(fields)
  end

-- Old note: taken from Atlasloot Update announcing code

AUX_data_sharer = CreateFrame("Frame")
AUX_data_sharer:RegisterEvent("CHAT_MSG_CHANNEL")
AUXplayerName = UnitName("player")


AUX_data_sharer:SetScript("OnEvent", function()
	if event == "CHAT_MSG_CHANNEL" and aux.account_data.sharing == true then
		local _,_,source = string.find(arg4,"(%d+)%.")
		if source then
			_,name = GetChannelName(source)
		end
		if name == "LFT" then
			local msg, item_key, munit_buyout_price = AuxAddon_strsplit(",", arg1) -- Old note: using , as a seperator because item_key contains a :
			if msg == "AuxData" then
				if arg2 ~= AUXplayerName then
					local unit_buyout_price = tonumber (munit_buyout_price)
					if unit_buyout_price and item_key then
					-- Old note: print("received data:" .. msg .. "," .. item_key .. "," .. unit_buyout_price); --for testing (print comes from PFUI)
						local item_record = read_record(item_key)
						if unit_buyout_price > 0 and unit_buyout_price < (item_record.daily_min_buyout or aux.huge) then
							-- Added 20250914: track daily sum, count, and min. The "or 0" portions prevent errors on null values, such as sell price for "blood of heroes", which is unsellable and untradeable.
							item_record.daily_sum = (item_record.daily_sum or 0) + unit_buyout_price
							item_record.daily_count = (item_record.daily_count or 0) + 1
							item_record.daily_min_buyout = unit_buyout_price
							write_record(item_key, item_record)
							-- Old note: print("wrote data"); --for testing (print comes from PFUI)
						end
					end
				end
			end
		end
	end
  end)

-- Added 20250914: patched to accumulate daily sum/count
function M.process_auction(auction_record, pages)
	local item_record = read_record(auction_record.item_key)
	local unit_buyout_price = ceil(auction_record.buyout_price / auction_record.aux_quantity)
	local item_key = auction_record.item_key
-- Added 20250914: patched to use the daily sum/count for price calculations
	if unit_buyout_price > 0 then
    item_record.daily_sum = (item_record.daily_sum or 0) + unit_buyout_price * auction_record.aux_quantity
    item_record.daily_count = (item_record.daily_count or 0) + auction_record.aux_quantity
-- Added 20250914: "print" command below used for testing to troubleshoot how item buyout and quantity were being used to calculate daily sum and count. VERY SPAMMY, but only to your own chat window in-game.
--	print("daily count: " .. item_record.daily_count .. ", daily sum: " .. item_record.daily_sum .. ", unit buyout price: " .. unit_buyout_price .. ", aux quantity: " .. auction_record.aux_quantity .. ", daily min buyout: " .. (item_record.daily_min_buyout or 0))
		-- Note 20250914: keep code below, it prevents min_buyout values from being overridden with higher values after records are reset on login.
		if unit_buyout_price < (item_record.daily_min_buyout or aux.huge) then
			item_record.daily_min_buyout = unit_buyout_price
		end

		write_record(item_key, item_record)

		-- Old note: share data if enabled
		if aux.account_data.sharing == true then
		-- Note 20250914: dashed out below argument so enable all AH queries being shared, regardless of page count. If for some reason your game becomes stuttery/"laggy" when doing a massive AH query, removed the "--" at the start of the below line and its respective "end" line further below.
--			if pages < 15 then -- only full scans
				if GetChannelName("LFT") ~= 0 then
					ChatThrottleLib:SendChatMessage(
						"BULK", nil,
						"AuxData," .. item_key .. "," .. unit_buyout_price,
						"CHANNEL", nil, GetChannelName("LFT")
					)
				end
--			end
		end
	end
end

function M.data_points(item_key)
	return read_record(item_key).data_points
end

-- Note 20250914: the below function and the lower-down "function weighted_median" is what is used to calculate the tooltip.lua "Value" line, which I rephrased to "11day avg." for clarity.

function M.value(item_key)
	if not value_cache[item_key] or value_cache[item_key].next_push <= time() then
		local item_record, value
		item_record = read_record(item_key)
		if getn(item_record.data_points) > 0 then
			local total_weight, weighted_values = 0, T.temp-T.acquire()
			for _, data_point in item_record.data_points do
				local weight = .99 ^ aux.round((item_record.data_points[1].time - data_point.time) / (60 * 60 * 24))
				total_weight = total_weight + weight
				tinsert(weighted_values, T.map('value', data_point.value, 'weight', weight))
			end
			for _, weighted_value in weighted_values do
				weighted_value.weight = weighted_value.weight / total_weight
			end
			value = weighted_median(weighted_values)
		else
			value = item_record.daily_min_buyout
		end
		value_cache[item_key] = T.map('value', value, 'next_push', item_record.next_push)
	end
	return value_cache[item_key].value
end

function M.market_value(item_key)
	local item_record = read_record(item_key)
	return item_record.daily_min_buyout
end

-- Removed 20250914: Removed the entire weighting section because: 1. I couldn't figure it out, 2. removing it didn't seem to negatively impact the changes made above.

--  Added 20250914: patched to add callable function 'avg', used in tooltip.lua to display current average AH price of item. This can also be used to call from other addons, such as Artisan, to have more current and somewhat accurate prices on reagent cost estimates.
function M.avg(item_key)
	local item_record = read_record(item_key)
	-- Note 20250914: below group of dashed out local records are from testing various formulae. Keeping for posterity in case anyone in the future wants to experiment.
	-- local unit_buyout_price = ceil(item_record.daily_min_buyout / item_record.daily_count)
	-- local avg = (read_record(item_key).daily_sum / read_record(item_key).daily_count)
	-- local avgten = table.sort{item_record.data_points.value, ", "}
	-- local value = item_record.daily_min_buyout
-- 	Attempting to get value of AH listing that is 10% above the min buyout price. Intent here is to give the user a more accurate cost range if buying AH items in bulk, since both "Value/11day avg" and "Today Min." would be inaccurate in this scenario.
	return ((item_record.daily_min_buyout or 0)*1.1)
	-- Note 20250914: same as note above, keeping the below dashed command for posterity and experimentation.
-- 	return (item_record.daily_sum or 0) / (item_record.daily_count or 1) -- adding "or 0" and "or 1" patches error of nil value for non-AH items (such as Blood of Heroes).
end

function weighted_median(list)
	sort(list, function(a,b) return a.value < b.value end)
	local weight = 0
	for _, v in ipairs(list) do
		weight = weight + v.weight
		if weight >= .5 then
			return v.value
		end
	end
end

--  Added 20250914: patched push_record to store average instead of only min
function push_record(item_record)
	if item_record.daily_count and item_record.daily_count > 0 then
		local avg = item_record.daily_sum / item_record.daily_count
		tinsert(item_record.data_points, 1, T.map('value', avg, 'time', item_record.next_push))
	elseif item_record.daily_min_buyout then
		tinsert(item_record.data_points, 1, T.map('value', item_record.daily_min_buyout, 'time', item_record.next_push))
	end

	while getn(item_record.data_points) > 11 do
		T.release(item_record.data_points[getn(item_record.data_points)])
		tremove(item_record.data_points)
	end
	
	item_record.next_push, item_record.daily_min_buyout = get_next_push(), item_record.daily_sum, item_record.daily_count, nil
end
