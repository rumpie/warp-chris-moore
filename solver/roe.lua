local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local file = require 'ext.file'
local template = require 'template'
local FiniteVolumeSolver = require 'solver.fvsolver'

local common = require 'common'()
local xNames = common.xNames
local symNames = common.symNames
local from3x3to6 = common.from3x3to6 
local from6to3x3 = common.from6to3x3 
local sym = common.sym


local Roe = class(FiniteVolumeSolver)
Roe.name = 'Roe'

function Roe:createBuffers()
	Roe.super.createBuffers(self)

	-- to get sizeof
	ffi.cdef(self.eqn:getEigenTypeCode())

	--self:clalloc('eigenBuf', self.numCells * self.dim * ffi.sizeof(self.eqn.eigen_t))
end

function Roe:getSolverCode()
	return table{
		Roe.super.getSolverCode(self),
	
		-- before this went above solver/plm.cl, now it's going after it ...
		template(file['solver/roe.cl'], {
			solver = self,
			eqn = self.eqn,
			clnumber = require 'cl.obj.number',
		}),
	}:concat'\n'
end

-- all these are found eqn's cl code
function Roe:refreshSolverProgram()
	Roe.super.refreshSolverProgram(self)

	--self.calcEigenBasisKernelObj = self.solverProgramObj:kernel'calcEigenBasis'
	--self.calcEigenBasisKernelObj.obj:setArg(1, self.eigenBuf)

	self.calcFluxKernelObj = self.solverProgramObj:kernel'calcFlux'
	self.calcFluxKernelObj.obj:setArg(1, self.fluxBuf)
	--self.calcFluxKernelObj.obj:setArg(3, self.eigenBuf)
end

function Roe:addDisplayVars()
	Roe.super.addDisplayVars(self)
	for side=0,self.dim-1 do
		local xj = xNames[side+1]
		self:addDisplayVarGroup{
			name = 'wave '..xj,
			bufferField = self.getULRBufName,
			type = self.getULRBufType,
			codePrefix = template([[
	int indexR = index;
	int indexL = index - solver->stepsize.s<?=side?>;
	real3 xInt = x;
	xInt.s<?=side?> -= .5 * solver->grid_dx.s<?=side?>;
	<?=solver:getULRCode{bufName='buf'}?>
	<?=eqn.eigen_t?> eig = eigen_forInterface(solver, *UL, *UR, xInt, normalForSide<?=side?>());
	<?=eqn:eigenWaveCodePrefix(side, 'eig', 'xInt')?>
]], 		{
				solver = self,
				eqn = self.eqn,
				side = side,
			}),
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
-- TODO calculate automatically instead of read from buffer
--[=[	
	local eigenDisplayVars = self.eqn:getEigenDisplayVars()
	if eigenDisplayVars and #eigenDisplayVars > 0 then
		for j=1,self.dim do
			local xj = xNames[j]
			self:addDisplayVarGroup{
				name = 'eigen '..xj,
				bufferField = 'eigenBuf',
				type = self.eqn.eigen_t,
				codePrefix = [[
	int indexInt = ]]..(j-1)..[[ + dim * index;
	const global ]]..self.eqn.eigen_t..[[* eigen = buf + indexInt;
]],
				vars = table.map(eigenDisplayVars, function(kv)
					return table.map(kv, function(v,k)
						if k == 'type' then return v, k end
						return v, k
					end)
				end),
			}
		end
	end
--]=]

--[=[
	-- ortho
	for side=0,self.dim-1 do
		self:addDisplayVarGroup{
			name = 'ortho error '..xNames[side+1],
			bufferField = 'eigenBuf',
			codePrefix = '',
			useLog = true,
			type = self.eqn.eigen_t,
			vars = {
				{['0'] = template([[
	int indexInt = <?=side?> + dim * index;
	const global <?=eqn.eigen_t?>* eig = buf + indexInt;

	real3 xInt = x;
	xInt.s<?=side?> -= .5 * solver->grid_dx.s<?=side?>;
	
	*value = 0;
	//the flux transform is F v = R Lambda L v, I = R L
	//but if numWaves < numIntStates then certain v will map to the nullspace 
	//so to test orthogonality for only numWaves dimensions, I will verify that Qinv Q v = v 
	//I = L R
	for (int k = 0; k < numWaves; ++k) {
		<?=eqn.cons_t?> basis;
		for (int j = 0; j < numStates; ++j) {
			basis.ptr[j] = k == j ? 1 : 0;
		}
		
		<?=eqn.waves_t?> eigenCoords = eigen_leftTransform_<?=side?>(solver, *eig, basis, xInt);
		<?=eqn.cons_t?> newbasis = eigen_rightTransform_<?=side?>(solver, *eig, eigenCoords, xInt);
	
		for (int j = 0; j < numWaves; ++j) {
			*value += fabs(newbasis.ptr[j] - basis.ptr[j]);
		}
	}
]], {
	solver = self,
	eqn = self.eqn,
	side = side,
})},
			}
		}
	end
--]=]

--[=[
	-- flux
	for side=0,self.dim-1 do
		self:addDisplayVarGroup{
			name = 'flux error '..xNames[side+1],
			bufferField = 'eigenBuf',
			codePrefix = '',
			useLog = true,
			type = self.eqn.eigen_t,
			vars = {
				{['0'] = template([[
		int indexInt = <?=side?> + dim * index;
		const global <?=eqn.eigen_t?>* eig = buf + indexInt;
	
		real3 xInt = x;
		xInt.s<?=side?> -= .5 * solver->grid_dx.s<?=side?>;

		*value = 0;
		<?=eqn:eigenWaveCodePrefix(side, '*eig', 'xInt')?>

		for (int k = 0; k < numIntStates; ++k) {
			//this only needs to be numIntStates in size
			//but just in case the left/right transforms are reaching past that memory boundary ...
			<?=eqn.cons_t?> basis;
			for (int j = 0; j < numStates; ++j) {
				basis.ptr[j] = k == j ? 1 : 0;
			}

			<?=eqn.waves_t?> eigenCoords = eigen_leftTransform_<?=side?>(solver, *eig, basis, xInt);

			<?=eqn.waves_t?> eigenScaled;
			<? for j=0,eqn.numWaves-1 do ?>{
				const int j = <?=j?>;
				real wave_j = <?=eqn:eigenWaveCode(side, '*eig', 'xInt', j)?>;
				eigenScaled.ptr[j] = eigenCoords.ptr[j] * wave_j;
			}<? end ?>
		
			//once again, only needs to be numIntStates
			<?=eqn.cons_t?> newtransformed = eigen_rightTransform_<?=side?>(solver, *eig, eigenScaled, xInt);

//this shouldn't need to be reset here
// but it will if leftTransform does anything destructive
for (int j = 0; j < numStates; ++j) {
	basis.ptr[j] = k == j ? 1 : 0;
}

			//once again, only needs to be numIntStates
			<?=eqn.cons_t?> transformed = eigen_fluxTransform_<?=side?>(solver, *eig, basis, xInt);
			
			for (int j = 0; j < numIntStates; ++j) {
				*value += fabs(newtransformed.ptr[j] - transformed.ptr[j]);
			}
		}
]], {
	solver = self,
	eqn = self.eqn,
	side = side,
})},
			}
		}
	end
--]=]
end

local realptr = ffi.new'realparam[1]'
local function real(x)
	realptr[0] = x
	return realptr
end

-- NOTICE this adds the contents of derivBufObj and does not clear it
function Roe:calcDeriv(derivBufObj, dt)
if self.checkNaNs then assert(math.isfinite(dt)) end
	local dtArg = real(dt)

if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
	
	if self.usePLM then
		self.calcLRKernelObj(self.solverBuf, self:getULRBuf(), self.UBuf, dtArg)
	end

if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end

	--self.calcEigenBasisKernelObj.obj:setArg(0, self.solverBuf)
	--self.calcEigenBasisKernelObj.obj:setArg(2, self:getULRBuf())
	--self.calcEigenBasisKernelObj()

if self.checkNaNs then assert(self:checkFinite(self.eigenBufObj)) end
if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end

	self.calcFluxKernelObj.obj:setArg(0, self.solverBuf)
	self.calcFluxKernelObj.obj:setArg(2, self:getULRBuf())
	self.calcFluxKernelObj.obj:setArg(3, dtArg)
	self.calcFluxKernelObj()

if self.checkNaNs then assert(self:checkFinite(self.fluxBufObj)) end
if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end

-- [=[ this is from the 2017 Zingale book
	if self.useCTU then
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
		-- if we're using CTU then ...
		-- 1) calc fluxes based on a slope-limiter method (PLM, etc)
		-- 2) at each interface, integrate each dimension's LR states by all other dimensions' fluxes with a timestep of -dt/2
		--	( don't use the deriv buf because it already has the sum of all dimensions' flux differences)
		self.updateCTUKernelObj(self.solverBuf, self:getULRBuf(), self.fluxBuf, dtArg)
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end

		-- now we need to calcBounds on the ULR
		-- TODO this will break for mirror conditions
		-- because I haven't got the boundary code flexible enough to operate on specific fields within the L & R fields of the ULRBuf
		self:boundaryLR()

		-- 3) use the final LR states to calculate the flux ...

		-- the rest of this matches above
		-- maybe use 'repeat'?
		
--if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
--		self.calcEigenBasisKernelObj()
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
		self.calcFluxKernelObj()
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
if self.checkNaNs then assert(self:checkFinite(self.fluxBufObj)) end
	end
--]=]

if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end
if self.checkNaNs then assert(self:checkFinite(self.fluxBufObj)) end
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end
	
	self.calcDerivFromFluxKernelObj.obj:setArg(1, derivBufObj.obj)
	self.calcDerivFromFluxKernelObj()

if self.checkNaNs then assert(self:checkFinite(self.UBufObj)) end
if self.checkNaNs then assert(self:checkFinite(derivBufObj)) end

end

return Roe
