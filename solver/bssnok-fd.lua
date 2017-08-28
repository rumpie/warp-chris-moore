local class = require 'ext.class'
local table = require 'ext.table'
local template = require 'template'
local BSSNOKFiniteDifferenceEquation = require 'eqn.bssnok-fd'
local Solver = require 'solver.solver'

local xNames = table{'x', 'y', 'z'}

local BSSNOKFiniteDifferenceSolver = class(Solver)
BSSNOKFiniteDifferenceSolver.name = 'BSSNOKFiniteDifferenceSolver'

function BSSNOKFiniteDifferenceSolver:init(...)
	BSSNOKFiniteDifferenceSolver.super.init(self, ...)
	self.name = nil	-- don't append the eqn name to this
end

function BSSNOKFiniteDifferenceSolver:createEqn(eqn)
	self.eqn = BSSNOKFiniteDifferenceEquation(self)
end

function BSSNOKFiniteDifferenceSolver:refreshSolverProgram()
	BSSNOKFiniteDifferenceSolver.super.refreshSolverProgram(self)
	
	self.calcDerivKernelObj = self.solverProgramObj:kernel'calcDeriv'
	self.calcDerivKernelObj.obj:setArg(1, self.UBuf)
end

function BSSNOKFiniteDifferenceSolver:refreshInitStateProgram()
	BSSNOKFiniteDifferenceSolver.super.refreshInitStateProgram(self)
	self.init_connBarUKernelObj = self.initStateProgramObj:kernel('init_connBarU', self.UBuf)
end

function BSSNOKFiniteDifferenceSolver:resetState()
	BSSNOKFiniteDifferenceSolver.super.resetState(self)
	
	self.init_connBarUKernelObj()
	self:boundary()
end

function BSSNOKFiniteDifferenceSolver:getCalcDTCode() end
function BSSNOKFiniteDifferenceSolver:refreshCalcDTKernel() end
function BSSNOKFiniteDifferenceSolver:calcDT() return self.fixedDT end

function BSSNOKFiniteDifferenceSolver:calcDeriv(derivBuf, dt)
	self.calcDerivKernelObj(derivBuf)
end

return BSSNOKFiniteDifferenceSolver
