--!optimize 2

local SharedTableRegistry = game:GetService("SharedTableRegistry")

local ceil, min = math.ceil, math.min

local CP = {}
local ST = SharedTableRegistry:GetSharedTable("Ro2D_Compute")

local workers = {}
local nWorkers = 0
local kernelReg, kernelList = {}, {}
local nextKernelId = 1
local jobId = 0
local lastReady = 0

CP.IsReady = false
CP.WorkerCount = 0

local function broadcastKernel(id, module)
	for i = 1, nWorkers do
		workers[i].actor:SendMessage("kernel", id, module)
	end
end

function CP.registerKernel(module)
	local id = kernelReg[module]
	if not id then
		id = nextKernelId
		nextKernelId += 1
		kernelReg[module] = id
		kernelList[id] = module
		broadcastKernel(id, module)
	end
	return id
end

function CP.init(parent, count, template)
	for i = 1, nWorkers do
		workers[i].actor:Destroy()
	end
	table.clear(workers)
	table.clear(kernelReg)
	table.clear(kernelList)
	nextKernelId = 1
	jobId = 0
	lastReady = 0
	nWorkers = count or 0
	CP.WorkerCount = nWorkers
	ST.job = 0
	for w = 0, nWorkers - 1 do
		ST["cjob_" .. w] = 0
		ST["cres_" .. w] = ""
	end
	for w = 0, nWorkers - 1 do
		local a = template:Clone()
		a:SetAttribute("WorkerIndex", w)
		a:SetAttribute("WorkerCount", nWorkers)
		a.Parent = parent
		workers[w + 1] = { actor = a }
	end
	CP.IsReady = nWorkers > 0
end

function CP.dispatch(kernelId, inputBytes, count, stride, paramsBytes)
	if not CP.IsReady or nWorkers == 0 then
		return
	end
	local rdy = ST.ready or 0
	if rdy ~= lastReady then
		lastReady = rdy
		for id, m in pairs(kernelList) do
			broadcastKernel(id, m)
		end
	end
	local per = ceil(count / nWorkers)
	for w = 0, nWorkers - 1 do
		local lo = w * per
		local hi = min(count, lo + per)
		local n = hi - lo
		if n > 0 then
			ST["cin_" .. w] = string.sub(inputBytes, lo * stride + 1, hi * stride)
			ST["ccount_" .. w] = n
		else
			ST["cin_" .. w] = ""
			ST["ccount_" .. w] = 0
		end
	end
	ST.kernel = kernelId
	ST.params = paramsBytes or ""
	jobId += 1
	ST.job = jobId
end

function CP.gather()
	if nWorkers == 0 then
		return nil
	end
	local job = ST["cjob_0"]
	if job == nil or job <= 0 then
		return nil
	end
	for w = 1, nWorkers - 1 do
		if ST["cjob_" .. w] ~= job then
			return nil
		end
	end
	local parts = table.create(nWorkers)
	for w = 0, nWorkers - 1 do
		parts[w + 1] = ST["cres_" .. w] or ""
	end
	return table.concat(parts), job
end

return CP
