--[[
behavior for allocating a primbuf
and updating it using newton descent every iteration
and passing it as an extra arg to all those functions that need it

this is different from Euler in that Euler doesn't hold a prim buf
but maybe it should -- because this is running faster than Euler
--]]
local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'

return function(parent)
	local template = class(parent)

	function template:createBuffers()
		template.super.createBuffers(self)
		self:clalloc('primBuf', self.volume * self.dim * ffi.sizeof(self.eqn.prim_t))
	end

	template.ConvertToTex_U = class(template.ConvertToTex_U)
	function template.ConvertToTex_U:setArgs(kernel, var)
		kernel:setArg(1, self.solver.UBuf)
		kernel:setArg(2, self.solver.primBuf)
	end

	-- replace the U convertToTex with some custom code 
	function template:getAddConvertToTexUBufArgs()
		return table(template.super.getAddConvertToTexUBufArgs(self),
			{extraArgs = {'const global '..self.eqn.prim_t..'* primBuf'}})
	end

	function template:addConvertToTexs()
		template.super.addConvertToTexs(self)

		self:addConvertToTex{
			name = 'prim', 
			type = self.eqn.prim_t,
			varCodePrefix = self.eqn:getPrimDisplayVarCodePrefix(),
			vars = self.eqn.primDisplayVars,
		}
	end

	function template:refreshInitStateProgram()
		template.super.refreshInitStateProgram(self)
		self.initStateKernel:setArg(1, self.primBuf)
	end

	--[[
	calcDT, calcEigenBasis use primBuf
	so for the Roe implicit linearized solver,
	(TODO?) primBuf must be push/pop'd as well as UBuf
	(or am I safe just using the last iteration's prim values, and doing the newton descent to update them?)
	--]]
	function template:refreshSolverProgram()
		-- createKernels in particular ...
		template.super.refreshSolverProgram(self)

		self.calcDTKernel:setArg(1, self.primBuf)
		self.calcEigenBasisKernel:setArg(2, self.primBuf)
		
		-- grhd has one of these, srhd doesn't
		if self.addSourceKernel then
			self.addSourceKernel:setArg(2, self.primBuf)
		end

		self.updatePrimsKernel = self.solverProgram:kernel('updatePrims', self.primBuf, self.UBuf)
	end

	function template:step(dt)
		template.super.step(self, dt)

		self.app.cmds:enqueueNDRangeKernel{kernel=self.updatePrimsKernel, dim=self.dim, globalSize=self.globalSize:ptr(), localSize=self.localSize:ptr()}
	end

	function template:boundary()
		-- U boundary
		template.super.boundary(self)
		-- prim boundary
		self.boundaryKernel:setArg(0, self.primBuf)
		self:applyBoundaryToBuffer(self.boundaryKernel)
		self.boundaryKernel:setArg(0, self.UBuf)
	end

	return template
end
