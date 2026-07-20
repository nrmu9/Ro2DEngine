--!optimize 2
--!native

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local actor = script:GetActor()

local function A(name)
	local v = actor:GetAttribute(name)
	while v == nil do
		actor:GetAttributeChangedSignal(name):Wait()
		v = actor:GetAttribute(name)
	end
	return v
end
local INDEX = A("WorkerIndex")

local IN_KEY = "cin_" .. INDEX
local N_KEY = "ccount_" .. INDEX
local RES_KEY = "cres_" .. INDEX
local JOB_KEY = "cjob_" .. INDEX

local kernels = {}
actor:BindToMessage("kernel", function(id, module)
	kernels[id] = require(module)
end)

local ST = SharedTableRegistry:GetSharedTable("Ro2D_Compute")
local lastJob = -1

RunService.RenderStepped:ConnectParallel(function()
	local job = ST.job
	if job == nil or job == lastJob then
		return
	end
	lastJob = job
	local kernel = kernels[ST.kernel]
	local inBytes = ST[IN_KEY]
	local n = ST[N_KEY] or 0
	if kernel and inBytes and inBytes ~= "" and n > 0 then
		local params = ST.params
		params = (params ~= nil and params ~= "") and buffer.fromstring(params) or nil
		local out = kernel(buffer.fromstring(inBytes), n, params)
		ST[RES_KEY] = out and buffer.tostring(out) or ""
	else
		ST[RES_KEY] = ""
	end
	ST[JOB_KEY] = job
end)

SharedTable.update(ST, "ready", function(v)
	return (v or 0) + 1
end)
