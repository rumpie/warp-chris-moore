local class = require 'ext.class'
local table = require 'ext.table'
local file = require 'ext.file'
local Equation = require 'eqn.eqn'
local GuiFloat = require 'guivar.float'
local clnumber = require 'clnumber'

local Maxwell = class(Equation)
Maxwell.name = 'Maxwell'

Maxwell.numStates = 6
Maxwell.consVars = {'epsEx', 'epsEx', 'epsEz', 'Bx', 'By', 'Bz'}
Maxwell.mirrorVars = {{'epsE.x', 'B.x'}, {'epsE.y', 'B.y'}, {'epsE.z', 'B.z'}}

Maxwell.hasEigenCode = true
Maxwell.useSourceTerm = true

Maxwell.initStateNames = {'default'}

Maxwell.guiVars = table{
	GuiFloat{name='eps0', value=1},	-- permittivity
	GuiFloat{name='mu0', value=1},	-- permeability
	GuiFloat{name='sigma', value=1},-- conductivity
}
Maxwell.guiVarsForName = Maxwell.guiVars:map(function(var) return var, var.name end)

function Maxwell:getTypeCode()
	return [[
typedef struct {
	real3 epsE;
	real3 B;
} cons_t;
]]
end

function Maxwell:getCodePrefix()
	return table{
		Maxwell.super.getCodePrefix(self),
		'#define sqrt_eps0 '..clnumber(math.sqrt(self.guiVarsForName.eps0.value[0])),
		'#define sqrt_mu0 '..clnumber(math.sqrt(self.guiVarsForName.mu0.value[0])),
		[[
real ESq(cons_t U) { 
	return coordLenSq(U.epsE) / (eps0 * eps0);
}

real BSq(cons_t U) {
	return coordLenSq(U.B);
}
]]
	}:concat'\n'
end

function Maxwell:getInitStateCode(solver)
	return table{
		[[
__kernel void initState(
	__global cons_t* UBuf
) {
	SETBOUNDS(0,0);
	real3 x = cell_x(i);
	real3 mids = real3_scale(real3_add(mins, maxs), .5);
	bool lhs = x.x < mids.x
#if dim > 1
		&& x.y < mids.y
#endif
#if dim > 2
		&& x.z < mids.z
#endif
	;
	__global cons_t* U = UBuf + index;
	U->epsE = real3_scale(_real3(0,0,1), eps0);
	U->B = _real3(1, lhs ? 1 : -1, 0);
}
]],
	}:concat'\n'
end

function Maxwell:getSolverCode(solver)
	return require 'processcl'(file['eqn/maxwell.cl'], {solver=solver})
end

Maxwell.displayVars = {
	{Ex = 'value = U->epsE.x / eps0;'},
	{Ey = 'value = U->epsE.y / eps0;'},
	{Ez = 'value = U->epsE.z / eps0;'},
	{E = 'value = sqrt(ESq(*U));'},
	{Bx = 'value = U->B.x;'},
	{By = 'value = U->B.y;'},
	{Bz = 'value = U->B.z;'},
	{B = 'value = sqrt(BSq(*U));'},
	{energy = 'value = .5 * (coordLen(U->epsE) + coordLen(U->B) / mu0);'},
}

-- can it be zero sized?
function Maxwell:getEigenTypeCode(solver)
	return 'typedef struct { char mustbesomething; } eigen_t;'
end

function Maxwell:getEigenDisplayVars(solver)
	return {}
end

return Maxwell
