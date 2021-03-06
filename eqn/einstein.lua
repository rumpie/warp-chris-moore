--[[
common functions for all Einstein field equation solvers
--]]

local class = require 'ext.class'
local table = require 'ext.table'
local template = require 'template'
local Equation = require 'eqn.eqn'

local common = require 'common'()
local xNames = common.xNames

local EinsteinEquation = class(Equation)

-- these hyperbolic formalisms usually take the metric into account themselves
EinsteinEquation.weightFluxByGridVolume = false

EinsteinEquation.initStates = require 'init.einstein'

function EinsteinEquation:createInitState()
	EinsteinEquation.super.createInitState(self)
	self:addGuiVars{
		{
			type = 'combo',
			name = 'f_eqn',
			options = {
				'2/alpha',	-- 1+log slicing
				'1 + 1/alpha^2', 	-- Alcubierre 10.2.24: "shock avoiding condition" for Toy 1+1 spacetimes 
				'1', 		-- Alcubierre 4.2.50 - harmonic slicing
				'0', '.49', '.5', '1.5', '1.69',
			}
		},
	}
end

-- add an option for fixed Minkowsky boundary spacetime
function EinsteinEquation:createBoundaryOptions()
	self.solver.boundaryOptions:insert{
		fixed = function(args)
			local lines = table()
			local gridSizeSide = 'solver->gridSize.'..xNames[args.side]
			for _,j in ipairs{'j', gridSizeSide..'-numGhost+j'} do
				local index = args.indexv(j)
				local U = 'buf[INDEX('..index..')]'
				lines:insert(template([[
	setFlatSpace(&<?=U?>, cell_x((int4)(<?=index?>, 0)));
]], 			{
					eqn = eqn,
					U = U,
					index = index,
				}))
			end
			return lines:concat'\n'
		end,
	}
end

-- and now for fillRandom ...
local ffi = require 'ffi'
local function crand() return 2 * math.random() - 1 end
function EinsteinEquation:fillRandom(epsilon)
	local solver = self.solver
	local ptr = ffi.new(self.cons_t..'[?]', solver.numCells)
	ffi.fill(ptr, 0, ffi.sizeof(ptr))
	for i=0,solver.numCells-1 do
		for j=0,self.numStates-1 do
			ptr[i].ptr[j] = epsilon * crand()
		end
	end
	solver.UBufObj:fromCPU(ptr)
	return ptr
end

return EinsteinEquation
