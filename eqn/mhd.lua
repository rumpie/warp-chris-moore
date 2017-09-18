local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local file = require 'ext.file'
local template = require 'template'
local makestruct = require 'eqn.makestruct'
local Equation = require 'eqn.eqn'

local MHD = class(Equation)

MHD.name = 'MHD'

MHD.numWaves = 7
MHD.numIntStates = 8
MHD.numStates = 9

MHD.primVars = table{
	{rho = 'real'},
	{v = 'real3'},
	{P = 'real'},
	{B = 'real3'},
	{BPot = 'real'},
}

MHD.consVars = table{
	{rho = 'real'},
	{m = 'real3'},
	{ETotal = 'real'},
	{B = 'real3'},
	{BPot = 'real'},
}

MHD.mirrorVars = {{'m.x', 'B.x'}, {'m.y', 'B.y'}, {'m.z', 'B.z'}}

MHD.hasEigenCode = true
MHD.hasFluxFromCons = true

-- hmm, we want init.euler and init.mhd here ...
MHD.initStates = require 'init.euler'

function MHD:init(solver)
	MHD.super.init(self, solver)
	local NoDiv = require 'solver.nodiv'
	solver.ops:insert(NoDiv{solver=solver})
end

function MHD:createInitState()
	MHD.super.createInitState(self)
	self:addGuiVar{name='heatCapacityRatio', value=2}	-- 5/3 for most problems, but 2 for Brio-Wu, so I will just set it here for now (in case something else is reading it before it is set there)
	self:addGuiVar{name='mu0', value=1}	-- this should be 4 pi for natural units, but I haven't verified that all mu0's are where they should be ...
end

function MHD:getCodePrefix()
	return table{
		MHD.super.getCodePrefix(self),
		template([[
inline real calc_eKin(<?=eqn.prim_t?> W) { return .5 * real3_lenSq(W.v); }
inline real calc_EKin(<?=eqn.prim_t?> W) { return W.rho * calc_eKin(W); }
inline real calc_EInt(<?=eqn.prim_t?> W) { return W.P / (heatCapacityRatio - 1.); }
inline real calc_eInt(<?=eqn.prim_t?> W) { return calc_EInt(W) / W.rho; }
inline real calc_EMag(<?=eqn.prim_t?> W) { return .5 * real3_lenSq(W.B); }
inline real calc_eMag(<?=eqn.prim_t?> W) { return calc_EMag(W) / W.rho; }
inline real calc_PMag(<?=eqn.prim_t?> W) { return .5 * real3_lenSq(W.B); }
inline real calc_EHydro(<?=eqn.prim_t?> W) { return calc_EKin(W) + calc_EInt(W); }
inline real calc_eHydro(<?=eqn.prim_t?> W) { return calc_EHydro(W) / W.rho; }
inline real calc_ETotal(<?=eqn.prim_t?> W) { return calc_EKin(W) + calc_EInt(W) + calc_EMag(W); }
inline real calc_eTotal(<?=eqn.prim_t?> W) { return calc_ETotal(W) / W.rho; }
inline real calc_H(real P) { return P * (heatCapacityRatio / (heatCapacityRatio - 1.)); }
inline real calc_h(real rho, real P) { return calc_H(P) / rho; }
inline real calc_HTotal(<?=eqn.prim_t?> W, real ETotal) { return W.P + calc_PMag(W) + ETotal; }
inline real calc_hTotal(<?=eqn.prim_t?> W, real ETotal) { return calc_HTotal(W, ETotal) / W.rho; }
inline real calc_Cs(<?=eqn.prim_t?> W) { return sqrt(heatCapacityRatio * W.P / W.rho); }

inline <?=eqn.prim_t?> primFromCons(
	<?=eqn.cons_t?> U,
	real3 x
) {
	<?=eqn.prim_t?> W;
	W.rho = U.rho;
	W.v = real3_scale(U.m, 1./U.rho);
	W.B = U.B;
	real vSq = real3_lenSq(W.v);
	real BSq = real3_lenSq(W.B);
	real EKin = .5 * U.rho * vSq;
	real EMag = .5 * BSq;
	real EInt = U.ETotal - EKin - EMag;
	W.P = EInt * (heatCapacityRatio - 1.);
	W.P = max(W.P, (real)1e-7);
	W.rho = max(W.rho, (real)1e-7);
	W.BPot = U.BPot;
	return W;
}

inline <?=eqn.cons_t?> consFromPrim(<?=eqn.prim_t?> W, real3 x) {
	<?=eqn.cons_t?> U;
	U.rho = W.rho;
	U.m = real3_scale(W.v, W.rho);
	U.B = W.B;
	real vSq = real3_lenSq(W.v);
	real BSq = real3_lenSq(W.B);
	real EKin = .5 * W.rho * vSq;
	real EMag = .5 * BSq;
	real EInt = W.P / (heatCapacityRatio - 1.);
	U.ETotal = EInt + EKin + EMag;
	U.BPot = W.BPot;
	return U;
}
]], {
	eqn = self,
}),
	}:concat'\n'
end

MHD.initStateCode = [[
kernel void initState(
	global <?=eqn.cons_t?>* UBuf
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
	real rho = 0;
	real3 v = _real3(0,0,0);
	real P = 0;
	real3 B = _real3(0,0,0);

	<?=code?>
	
	<?=eqn.prim_t?> W = {.rho=rho, .v=v, .P=P, .B=B, .BPot=0};
	UBuf[index] = consFromPrim(W, x);
}
]]

function MHD:getSolverCode()
	return template(file['eqn/mhd.cl'], {eqn=self, solver=self.solver})
end

function MHD:getDisplayVarCodePrefix()
	return template([[
	global const <?=eqn.cons_t?>* U = buf + index;
	<?=eqn.prim_t?> W = primFromCons(*U, x);
]], {
	eqn = self,
})
end

function MHD:getDisplayVars()
	return MHD.super.getDisplayVars(self):append{
		{v = '*valuevec = W.v;', type='real3'},
		{['div B'] = template([[
	*value = .5 * (0.
<? 
for j=0,solver.dim-1 do 
?>		+ (U[stepsize.s<?=j?>].<?=field?>.s<?=j?> 
			- U[-stepsize.s<?=j?>].<?=field?>.s<?=j?>
		) / grid_dx<?=j?>
<? 
end 
?>	)<? 
if field == 'epsE' then 
?> / eps0<?
end
?>;
]], {solver=self.solver, field='B'})},
		{['BPot'] = '*value = U->BPot;'},
		{P = '*value = W.P;'},
		--{PMag = '*value = calc_PMag(W);'},
		--{PTotal = '*value = W.P + calc_PMag(W);'},
		--{eInt = '*value = calc_eInt(W);'},
		{EInt = '*value = calc_EInt(W);'},
		--{eKin = '*value = calc_eKin(W);'},
		{EKin = '*value = calc_EKin(W);'},
		--{eHydro = '*value = calc_eHydro(W);'},
		{EHydro = '*value = calc_EHydro(W);'},
		--{eMag = '*value = calc_eMag(W);'},
		{EMag = '*value = calc_EMag(W);'},
		--{eTotal = '*value = U->ETotal / W.rho;'},
		{S = '*value = W.P / pow(W.rho, (real)heatCapacityRatio);'},
		{H = '*value = calc_H(W.P);'},
		--{h = '*value = calc_H(W.P) / W.rho;'},
		--{HTotal = '*value = calc_HTotal(W, U->ETotal);'},
		--{hTotal = '*value = calc_hTotal(W, U->ETotal);'},
		--{Cs = '*value = calc_Cs(W); },
		{['primitive reconstruction error'] = template([[
		//prim have just been reconstructed from cons
		//so reconstruct cons from prims again and calculate the difference
		<?=eqn.cons_t?> U2 = consFromPrim(W, x);
		*value = 0;
		for (int j = 0; j < numIntStates; ++j) {
			*value += fabs(U->ptr[j] - U2.ptr[j]);
		}
]], {
	eqn = self,
})},
	}
end


-- these are calculated based on cell-centered (or extrapolated) conserved vars
-- they are used to calculate the eigensystem at a cell center or edge 
MHD.roeVars = table{
	{rho = 'real'},
	{v = 'real3'},
	{hTotal = 'real'},
	{B = 'real3'},
	{X = 'real'},
	{Y = 'real'},
}


-- here's the variables that an eigensystem uses to compute a left, right, or flux transform 
MHD.eigenVars = table(MHD.roeVars):append{
	{Cs = 'real'},
	{CAx = 'real'},
	{Cf = 'real'},
}


function MHD:getEigenTypeCode()
	return table{
		makestruct.makeStruct('Roe_t', self.roeVars),
		MHD.super.getEigenTypeCode(self),
	}:concat'\n'
end

return MHD
