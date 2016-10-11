--[[
Based on Alcubierre 2008 "Introduction to 3+1 Numerical Relativity" on the chapter on hyperbolic formalisms. 
The first Bona-Masso formalism.
--]]

local class = require 'ext.class'
local table = require 'ext.table'
local Equation = require 'equation'

local ADM_BonaMasso_3D = class(Equation)
ADM_BonaMasso_3D.name = 'ADM_BonaMasso_3D'

ADM_BonaMasso_3D.consVars = {
	'alpha',
	'gamma_xx', 'gamma_xy', 'gamma_xz', 'gamma_yy', 'gamma_yz', 'gamma_zz',
	'a_x', 'a_y', 'a_z',
	'd_xxx', 'd_xxy', 'd_xxz', 'd_xyy', 'd_xyz', 'd_xzz',
	'd_yxx', 'd_yxy', 'd_yxz', 'd_yyy', 'd_yyz', 'd_yzz',
	'd_zxx', 'd_zxy', 'd_zxz', 'd_zyy', 'd_zyz', 'd_zzz',
	'K_xx', 'K_xy', 'K_xz', 'K_yy', 'K_yz', 'K_zz',
	'V_x', 'V_y', 'V_z',
}
ADM_BonaMasso_3D.numStates = 7 + 30	-- should equal # consVars
ADM_BonaMasso_3D.numWaves = 30	-- skip alpha and gamma_ij

ADM_BonaMasso_3D.numStates = #ADM_BonaMasso_3D.consVars
ADM_BonaMasso_3D.displayVars = table()
	:append(ADM_BonaMasso_3D.consVars)
	:append{'volume'}

ADM_BonaMasso_3D.useSourceTerm = true

ADM_BonaMasso_3D.initStates = require 'init_adm'
ADM_BonaMasso_3D.initStateNames = table.map(ADM_BonaMasso_3D.initStates, function(state) return state.name end)

function ADM_BonaMasso_3D:codePrefix()
	return table.map(self.codes, function(code,name,t)
		return 'real calc_'..name..code, #t+1
	end):concat'\n'
end

ADM_BonaMasso_3D.guiVars = {'f'}
ADM_BonaMasso_3D.f = {
	value = 0,	-- 0-based index into options
	name = 'f',
	options = {'1', '1.69', '.49', '1 + 1/alpha^2'},
}

function ADM_BonaMasso_3D:getInitStateCode(solver)
	local initState = self.initStates[solver.initStatePtr[0]+1]
	
	local alphaVar = require 'symmath'.var'alpha'
	self.codes = initState.init(solver, ({
		{f = 1},
		{f = 1.69},
		{f = 1.49},
		{f = 1 + 1/alphaVar^2, alphaVar=alphaVar},
	})[self.f.value+1])

	local lines = table{
		self:codePrefix(),
		[[
__kernel void initState(
	__global cons_t* UBuf
) {
	SETBOUNDS(0,0);
	real4 x = CELL_X(i);
	__global cons_t* U = UBuf + index;
]]
	}

	local function build(var)
		return '\tU->'..var..' = calc_'..var..'(x.x, x.y, x.z);'
	end

	local xNames = table{'x', 'y', 'z'}
	local symNames = table{'xx', 'xy', 'xz', 'yy', 'yz', 'zz'}
	build'alpha'
	symNames:map(function(xij) build('gamma_'..xij) end)
	xNames:map(function(xi) build('a_'..xi) end)	
	xNames:map(function(xk)
		symNames:map(function(xij) build('d_'..xk..xij) end)
	end)
	symNames:map(function(xij) build('K_'..xij) end)
	lines:insert'}'
	
	return lines:concat'\n'
end

function ADM_BonaMasso_3D:solverCode()

	local calcDisplayVarCode = table{[[
real symMatDet(
	real xx, real xy, real xz, 
	real yy, real yz, real zz
) {
	return xx * yy * zz
		+ xy * yz * xz
		+ xz * xy * yz
		- xz * yy * xz
		- yz * yz * xx
		- zz * xy * xy;
}

#define symMatDet_prefix(prefix) symMatDet(prefix##xx, prefix##xy, prefix##xz, prefix##yy, prefix##yz, prefix##zz)

void symMatInv(
	real* y,
	real d,
	real xx, real xy, real xz, 
	real yy, real yz, real zz
) {
	y[0] = (yy * zz - yz * yz) / d;	// xx
	y[1] = (xz * yz - xy * zz) / d;	// xy
	y[2] = (xy * yz - xz * yy) / d;	// xz
	y[3] = (xx * zz - xz * xz) / d;	// yy
	y[4] = (xz * xy - xx * yz) / d;	// yz
	y[5] = (xx * yy - xy * xy) / d;	// zz
}

#define symMatInv_prefix(y, d, prefix) symMatInv(y, d, prefix##xx, prefix##xy, prefix##xz, prefix##yy, prefix##yz, prefix##zz)

real calcDisplayVar_UBuf(
	int displayVar, 
	const __global real* U_
) {
	const __global cons_t* U = (const __global cons_t*)U_;
	switch (displayVar) {
	case display_U_volume: return U->alpha * sqrt(symMatDet_prefix(U->gamma_));
]]
	}:append(table.map(self.consVars, function(var)
		return '	case display_U_'..var..': return U->'..var..';'
	end)):append{
[[
	}
	return 0;
}
]]
	}:concat'\n'
	
	return table{
		self:codePrefix(),
		calcDisplayVarCode,
		'#include "adm3d.cl"',
	}:concat'\n'
end

ADM_BonaMasso_3D.eigenVars = {'alpha', 'gammaUxx', 'gammaUxy', 'gammaUxz', 'gammaUyy', 'gammaUyz', 'gammaUzz', 'f'}
function ADM_BonaMasso_3D:getEigenInfo()
	local makeStruct = require 'makestruct'
	return {
		typeCode = [[
typedef struct {
	union {
		struct {
			real gammaUxx, gammaUxy, gammaUxz, gammaUyy, gammaUyz, gammaUzz;
		};
		real gammaU[6];
	};
	real f;
} eigen_t;
typedef eigen_t fluxXform_t;	// I've thought of merging these two ... this is more proof
]],
		code = nil,
		displayVars = {} -- working on this one
	}
end

return ADM_BonaMasso_3D
