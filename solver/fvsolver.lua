--[[
This is a Solver that uses a fluxBuffer
and that uses calcDerivFromFlux to update it
--]]
local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local file = require 'ext.file'
local template = require 'template'
local GridSolver = require 'solver.gridsolver'

local common = require 'common'()
local xNames = common.xNames
local symNames = common.symNames
local from3x3to6 = common.from3x3to6 
local from6to3x3 = common.from6to3x3 
local sym = common.sym


local FiniteVolumeSolver = class(GridSolver)

function FiniteVolumeSolver:createBuffers()
	FiniteVolumeSolver.super.createBuffers(self)
	self:clalloc('fluxBuf', self.numCells * self.dim * ffi.sizeof(self.eqn.cons_t))
end

function FiniteVolumeSolver:getSolverCode()
	return table{
		FiniteVolumeSolver.super.getSolverCode(self),
		template(file['solver/calcDerivFV.cl'], {solver=self}),
	}:concat'\n'
end

function FiniteVolumeSolver:refreshSolverProgram()
	FiniteVolumeSolver.super.refreshSolverProgram(self)

	-- 'calcFlux' is usually provided, but the args vary, so I'll leave it to the subclass
	
	self.calcDerivFromFluxKernelObj = self.solverProgramObj:kernel{name='calcDerivFromFlux', domain=self.domainWithoutBorder}
	self.calcDerivFromFluxKernelObj.obj:setArg(0, self.solverBuf)
	self.calcDerivFromFluxKernelObj.obj:setArg(2, self.fluxBuf)
end

function FiniteVolumeSolver:addDisplayVars()
	FiniteVolumeSolver.super.addDisplayVars(self)

	for side=0,self.dim-1 do
		local xj = xNames[side+1]
		self:addDisplayVarGroup{
			name = 'flux '..xj, 
			bufferField = 'fluxBuf',
			type = self.eqn.cons_t,
			codePrefix = template([[
	int indexInt = <?=side?> + dim * index;
	const global <?=eqn.cons_t?>* flux = buf + indexInt;
]],			{
				eqn = self.eqn,
				side = side,
			}),
			vars = range(0,self.eqn.numIntStates-1):map(function(i)
				return {[''..i] = '*value = flux->ptr['..i..'];'}
			end),
		}
	end

	-- code for getting the interface eigensystem variables
	local function getEigenCode(args)
		return template([[
	int indexR = index;
	int indexL = index - solver->stepsize.s<?=side?>;
	real3 xInt = x;
	xInt.s<?=side?> -= .5 * solver->grid_dx.s<?=side?>;
	<?=solver:getULRCode{bufName='buf'}?>
	<?=eqn.eigen_t?> eig = eigen_forInterface(solver, *UL, *UR, xInt, normalForSide<?=side?>());
]], 	{
			solver = self,
			eqn = self.eqn,
			side = args.side,
		})
	end
	
	for side=0,self.dim-1 do
		local xj = xNames[side+1]
		self:addDisplayVarGroup{
			name = 'wave '..xj,
			bufferField = self.getULRBufName,
			type = self.getULRBufType,
			codePrefix = table{
				getEigenCode{side=side},
				template([[
	<?=eqn:eigenWaveCodePrefix(side, 'eig', 'xInt')?>
]], 			{
					eqn = self.eqn,
					side = side,
				}),
			}:concat'\n',
			vars = range(0, self.eqn.numWaves-1):map(function(i)
				return {[''..i] = template([[
	*value = <?=eqn:eigenWaveCode(side, 'eig', 'xInt', i)?>;
]], {
		eqn = self.eqn,
		i = i,
	})}
			end),
		}
	end

	-- TODO rename to 'getEigenDisplayVarDescs()'
	local eigenDisplayVars = self.eqn:getEigenDisplayVars()
	if eigenDisplayVars and #eigenDisplayVars > 0 then
		for side=0,self.dim-1 do
			local xj = xNames[side+1]
			self:addDisplayVarGroup{
				name = 'eigen '..xj,
				bufferField = self.getULRBufName,
				type = self.getULRBufType,
				codePrefix = getEigenCode{side=side},
				vars = table.map(eigenDisplayVars, function(kv)
					return table.map(kv, function(v,k)
						if k == 'type' then return v, k end
						return v, k
					end)
				end),
			}
		end
	end

	-- ortho
	-- TODO why is the x error getting 'nans' after a few iterations?
	for side=0,self.dim-1 do
		self:addDisplayVarGroup{
			name = 'ortho error '..xNames[side+1],
			bufferField = self.getULRBufName,
			type = self.getULRBufType,
			codePrefix = '',
			useLog = true,
			vars = {
				{['0'] = table{
					getEigenCode{side=side},
					template([[
	*value = 0;
	//the flux transform is F v = R Lambda L v, I = R L
	//but if numWaves < numIntStates then certain v will map to the nullspace 
	//so to test orthogonality for only numWaves dimensions, I will verify that Qinv Q v = v 
	//I = L R
	//Also note (courtesy of Trangenstein) consider summing across outer products of basis vectors to fulfill rank
	for (int k = 0; k < numWaves; ++k) {
		<?=eqn.cons_t?> basis;
		for (int j = 0; j < numStates; ++j) {
			basis.ptr[j] = k == j ? 1 : 0;
		}
		
		<?=eqn.waves_t?> chars = eigen_leftTransform_<?=side?>(solver, eig, basis, xInt);
		<?=eqn.cons_t?> newbasis = eigen_rightTransform_<?=side?>(solver, eig, chars, xInt);
	
		for (int j = 0; j < numStates; ++j) {
			*value += fabs(newbasis.ptr[j] - basis.ptr[j]);
		}
	}
]], 					{
							eqn = self.eqn,
							side = side,
						}),
					}:concat'\n',
				},
			}
		}
	end

	-- flux
	-- TODO same as above, why is the x error getting 'nans' after a few iterations?
	for side=0,self.dim-1 do
		self:addDisplayVarGroup{
			name = 'flux error '..xNames[side+1],
			bufferField = self.getULRBufName,
			type = self.getULRBufType,
			codePrefix = '',
			useLog = true,
			vars = {
				{['0'] = table{
					getEigenCode{side=side},
					template([[
	<?=eqn:eigenWaveCodePrefix(side, 'eig', 'xInt')?>
	
	*value = 0;
	for (int k = 0; k < numIntStates; ++k) {
		//This only needs to be numIntStates in size, but just in case the left/right transforms are reaching past that memory boundary ...
		//Then again, how do I know what the non-integrated states should be?  Defaulting to zero is a bad idea.
		<?=eqn.cons_t?> basis;
		for (int j = 0; j < numStates; ++j) {
			basis.ptr[j] = k == j ? 1 : 0;
		}

		<?=eqn.waves_t?> chars = eigen_leftTransform_<?=side?>(solver, eig, basis, xInt);

		<?=eqn.waves_t?> charScaled;
		<? for j=0,eqn.numWaves-1 do ?>{
			real lambda_j = <?=eqn:eigenWaveCode(side, 'eig', 'xInt', j)?>;
			charScaled.ptr[<?=j?>] = chars.ptr[<?=j?>] * lambda_j;
		}<? end ?>
	
		//once again, only needs to be numIntStates
		<?=eqn.cons_t?> newtransformed = eigen_rightTransform_<?=side?>(solver, eig, charScaled, xInt);

//this shouldn't need to be reset here
// but it will if leftTransform does anything destructive
for (int j = 0; j < numStates; ++j) {
	basis.ptr[j] = k == j ? 1 : 0;
}

		//once again, only needs to be numIntStates
		<?=eqn.cons_t?> transformed = eigen_fluxTransform_<?=side?>(solver, eig, basis, xInt);
		
		for (int j = 0; j < numIntStates; ++j) {
			*value += fabs(newtransformed.ptr[j] - transformed.ptr[j]);
		}
	}
]], 					{
							solver = self,
							eqn = self.eqn,
							side = side,
						}),
					}:concat'\n',
				},
			}
		}
	end
end

return FiniteVolumeSolver
