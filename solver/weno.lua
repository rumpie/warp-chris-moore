local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local file = require 'ext.file'
local template = require 'template'
local FiniteVolumeSolver = require 'solver.fvsolver'

local common = require 'common'()
local xNames = common.xNames
local symNames = common.symNames
local from3x3to6 = common.from3x3to6 
local from6to3x3 = common.from6to3x3 
local sym = common.sym


local WENO = class(FiniteVolumeSolver)
WENO.name = 'WENO'

WENO.stencilSize = 3

WENO.wenoMethod = '1996 Jiang Shu'	-- (WENO-JS)
--WENO.wenoMethod = '2008 Borges'		-- (WENO-Z)
--WENO.wenoMethod = '2010 Shen Zha'	-- (WENO-BS)	

--[[
args:
	wenoMethod
	order (5 or 7 only)
--]]
function WENO:init(args)
	self.wenoMethod = args.wenoMethod
	
	local order = args.order
	if order then
		self.stencilSize = (order+1)/2
	end
	
	self.numGhost = self.stencilSize
	WENO.super.init(self, args)
end

-- TODO find what intermediate values to buffer for perf increase
function WENO:createBuffers()
	WENO.super.createBuffers(self)
end

function WENO:getSolverCode()
	return table{
		WENO.super.getSolverCode(self),
	
		-- before this went above solver/plm.cl, now it's going after it ...
		template(file['solver/weno.cl'], {
			solver = self,
			eqn = self.eqn,
			clnumber = require 'cl.obj.number',
		}),
	}:concat'\n'
end

-- all these are found eqn's cl code
function WENO:refreshSolverProgram()
	WENO.super.refreshSolverProgram(self)

	self.calcFluxKernelObj = self.solverProgramObj:kernel'calcFlux'
	self.calcFluxKernelObj.obj:setArg(1, self.fluxBuf)

	if self.eqn.useSourceTerm then
		self.addSourceKernelObj = self.solverProgramObj:kernel{name='addSource', domain=self.domainWithoutBorder}
	end
end

function WENO:addDisplayVars()
	WENO.super.addDisplayVars(self)
end

local realptr = ffi.new'realparam[1]'
local function real(x)
	realptr[0] = x
	return realptr
end

-- NOTICE this adds the contents of derivBuf and does not clear it
function WENO:calcDeriv(derivBuf, dt)
	local dtArg = real(dt)
	
	self:boundary()
	
	if self.usePLM then
		self.calcLRKernelObj(self.solverBuf, self.UBuf, self.UBuf, dtArg)
	end

	self.calcFluxKernelObj.obj:setArg(0, self.solverBuf)
self.calcFluxKernelObj.obj:setArg(1, self.fluxBuf)
	self.calcFluxKernelObj.obj:setArg(2, self.UBuf)
	self.calcFluxKernelObj()

-- [=[ this is from the 2017 Zingale book
	if self.useCTU then
		self:boundary()
		-- if we're using CTU then ...
		-- 1) calc fluxes based on a slope-limiter method (PLM, etc)
		-- 2) at each interface, integrate each dimension's LR states by all other dimensions' fluxes with a timestep of -dt/2
		--	( don't use the deriv buf because it already has the sum of all dimensions' flux differences)
		self.updateCTUKernelObj(self.solverBuf, self.UBuf, self.fluxBuf, dtArg)

		-- now we need to calcBounds on the ULR
		-- TODO this will break for mirror conditions
		-- because I haven't got the boundary code flexible enough to operate on specific fields within the L & R fields of the ULRBuf
		for _,obj in ipairs(self.lrBoundaryKernelObjs) do
			obj()
		end

		-- 3) use the final LR states to calculate the flux ...

		-- the rest of this matches above
		-- maybe use 'repeat'?
		
		self.calcFluxKernelObj()
	end
--]=]
	
	self:boundary()
	self.calcDerivFromFluxKernelObj.obj:setArg(1, derivBuf)
self.calcDerivFromFluxKernelObj.obj:setArg(0, self.solverBuf)
self.calcDerivFromFluxKernelObj.obj:setArg(2, self.fluxBuf)
	self.calcDerivFromFluxKernelObj()

	if self.eqn.useSourceTerm then
		self:boundary()
		self.addSourceKernelObj.obj:setArgs(self.solverBuf, derivBuf, self.UBuf)
		self.addSourceKernelObj()
	end
end

return WENO