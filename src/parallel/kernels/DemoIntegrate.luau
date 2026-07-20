--!optimize 2
--!native
return function(input, count, params)
	local dt = params and buffer.readf32(params, 0) or 0
	local out = buffer.create(count * 8)
	for i = 0, count - 1 do
		local ib = i * 16
		local x = buffer.readf32(input, ib) + buffer.readf32(input, ib + 8) * dt
		local y = buffer.readf32(input, ib + 4) + buffer.readf32(input, ib + 12) * dt
		local ob = i * 8
		buffer.writef32(out, ob, x)
		buffer.writef32(out, ob + 4, y)
	end
	return out
end
