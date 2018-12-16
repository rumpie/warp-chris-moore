--[[
from 2010 Colliander et al "Numerical Simulations ..."
--]]
local class = require 'ext.class'
local table = require 'ext.table'
local template = require 'template'
local GridSolver = require 'solver.gridsolver'

local NLSSolver = class(GridSolver)
NLSSolver.name = 'NonLinearSchrodinger'
NLSSolver.fixedDT = 1e-6
NLSSolver.eqnName = 'nls'

function NLSSolver:refreshSolverProgram()
	NLSSolver.super.refreshSolverProgram(self)
	
	self.calcDerivKernelObj = self.solverProgramObj:kernel'calcDeriv'
	self.calcDerivKernelObj.obj:setArg(0, self.solverBuf)
	self.calcDerivKernelObj.obj:setArg(2, self.UBuf)
end

function NLSSolver:createBoundaryOptions()
	NLSSolver.super.createBoundaryOptions(self)
	self.boundaryOptions:insert{
		oscillating = function(args)
			local index = args.index
			local assign = args.assign
			local lines = table()
			local gridSizeSide = 'gridSize_'..xNames[args.side]
			if args.minmax == 'min' then
				-- buf[0] = buf[4]
				-- buf[1] = buf[3]
				-- buf[2] is ... ?
				lines:insert(
					assign('buf['..index'j'..']',
						'buf['..index('2*numGhost-j')..']'))
			elseif args.minmax == 'max' then
				lines:insert(
					assign('buf['..index(gridSizeSide..'-1-j')..']',
						'buf['..index(gridSizeSide..'-2*numGhost-2+j')..']'))
			end
			return lines:concat'\n'
		end,
		fixed = function(args)
			if args.minmax == 'min' then
				assign('buf['..index'j'..']', '0')
			elseif args.minmax == 'max' then
				assign('buf['..index(gridSizeSide'-1-j')..']', '0')
			end
		end,
	}
end

function NLSSolver:refreshCalcDTKernel() end
function NLSSolver:calcDT() return self.fixedDT end

function NLSSolver:calcDeriv(derivBufObj, dt)
	self.calcDerivKernelObj.obj:setArg(1, derivBufObj.obj)
	self.calcDerivKernelObj()
end

return NLSSolver
