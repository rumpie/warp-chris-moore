/*
WENO solver:
sources:
1998 Shu "Essentially Non-Oscillatory and Weighted Essentially Non-Oscillatory Schemes for Hyperbolic Conservation Laws"
"A hybrid approach for the regularized long wave-Burgers equation"
2016 Rathan, Raju "An improved Non-linear Weights for Seventh-Order WENO Scheme"
https://github.com/jzrake/Mara for weno5 examples
https://github.com/wme7/WENO7-Z/blob/master/WENO7ZresAdv1d.m for weno7 examples
*/

inline real sqr(real x) { return x * x; }

<? 
local clnumber = require 'cl.obj.number'

local stencilSize = solver.stencilSize

local cs = {
	[3] = {
		{ 1/3, -7/6, 11/6},
		{-1/6,  5/6,  1/3},
		{ 1/3,  5/6, -1/6},
		{11/6, -7/6,  1/3},
	},
	[4] = {
		-- from "A hybrid approach for the regularized long wave-Burgers equation"
		-- and 2016 Rathan, Raju between eqn 6 and 7
		-- and https://github.com/wme7/WENO7-Z/blob/master/WENO7ZresAdv1d.m
		{ -3/12,  13/12, -23/12, 25/12, },
		{  1/12,  -5/12,  13/12,  3/12, },
		{ -1/12,   7/12,   7/12, -1/12, },
		{  3/12,  13/12,  -5/12,  1/12, },
		{ 25/12, -23/12,  13/12, -3/12, },
	},
}
local ds = {
	[3] = { 3/10, 3/5, 1/10},
	
	-- from "A hybrid approach for the regularized long wave-Burgers equation"
	-- and 2016 Rathan, Raju eqn 8 
	--[4] = {4/35, 18/35, 12/35, 1/35},
	[4] = {1/35, 12/35, 18/35, 4/35},
}

local c = cs[stencilSize]
local d = ds[stencilSize]

for _,l_or_r in ipairs{'l', 'r'} do
	local cofs = l_or_r == 'l' and 2 or 1
	local d0 = l_or_r == 'l' and 1 or stencilSize 
	local dd = l_or_r == 'l' and 1 or -1
?>
<?=eqn.waves_t?> weno_<?=l_or_r?>(const <?=eqn.waves_t?>* v) {
	<?=eqn.waves_t?> result;
	for (int k = 0; k < numWaves; ++k) {
		
<? 	if stencilSize == 3 then -- weno5 
?>		real beta0 = (13./12.)*sqr( v[0].ptr[k] - 2*v[1].ptr[k] + v[2].ptr[k]) + (1./4.)*sqr(  v[0].ptr[k] - 4*v[1].ptr[k] + 3*v[2].ptr[k]);
		real beta1 = (13./12.)*sqr( v[1].ptr[k] - 2*v[2].ptr[k] + v[3].ptr[k]) + (1./4.)*sqr(  v[1].ptr[k]                 -   v[3].ptr[k]);
		real beta2 = (13./12.)*sqr( v[2].ptr[k] - 2*v[3].ptr[k] + v[4].ptr[k]) + (1./4.)*sqr(3*v[2].ptr[k] - 4*v[3].ptr[k] +   v[4].ptr[k]);
<? 	elseif stencilSize == 4 then 
?>// weno7, from "A hybrid approach for the regularized long wave-Burgers equation" 
// and 2016 Rathan, Raju "An improved Non-linear Weights for Seventh-Order WENO Scheme"  in the Appendix for WENO-BS
//		real beta0 = v[0].ptr[k] * ( 547 * v[0].ptr[k] - 3882 * v[1].ptr[k] + 4642 * v[2].ptr[k] - 1854 * v[3].ptr[k]) + v[1].ptr[k] * ( 7043 * v[1].ptr[k] - 17246 * v[2].ptr[k] + 7042 * v[3].ptr[k]) + v[2].ptr[k] * (11003 * v[2].ptr[k] - 9402 * v[3].ptr[k]) + v[3].ptr[k] * 2107 * v[3].ptr[k];
//		real beta1 = v[1].ptr[k] * ( 267 * v[1].ptr[k] - 1642 * v[2].ptr[k] + 1602 * v[3].ptr[k] -  494 * v[4].ptr[k]) + v[2].ptr[k] * ( 2843 * v[2].ptr[k] -  5966 * v[3].ptr[k] + 1922 * v[4].ptr[k]) + v[3].ptr[k] * ( 3443 * v[3].ptr[k] - 2522 * v[4].ptr[k]) + v[4].ptr[k] *  547 * v[4].ptr[k];
//		real beta2 = v[2].ptr[k] * ( 547 * v[2].ptr[k] - 2522 * v[3].ptr[k] + 1922 * v[4].ptr[k] -  494 * v[5].ptr[k]) + v[3].ptr[k] * ( 3443 * v[3].ptr[k] -  5966 * v[4].ptr[k] + 1602 * v[5].ptr[k]) + v[4].ptr[k] * ( 2843 * v[4].ptr[k] - 1642 * v[5].ptr[k]) + v[5].ptr[k] *  267 * v[5].ptr[k];
//		real beta3 = v[3].ptr[k] * (2107 * v[3].ptr[k] - 9402 * v[4].ptr[k] + 7042 * v[5].ptr[k] - 1854 * v[6].ptr[k]) + v[4].ptr[k] * (11003 * v[4].ptr[k] - 17246 * v[5].ptr[k] + 4642 * v[6].ptr[k]) + v[5].ptr[k] * ( 7043 * v[5].ptr[k] - 3882 * v[6].ptr[k]) + v[6].ptr[k] *  547 * v[6].ptr[k];
// 2016 Rathan, Raju after eqn 12 ... 
//	... TODO
// https://github.com/wme7/WENO7-Z/blob/master/WENO7ZresAdv1d.m
		real beta0 = v[2].ptr[k] * (134241. * v[2].ptr[k] - 114894. * v[3].ptr[k]) + v[0].ptr[k] * ( 56694. * v[2].ptr[k] -  47214. * v[1].ptr[k] +  6649. * v[0].ptr[k] - 22778. * v[3].ptr[k]) + 25729. * sqr(v[3].ptr[k]) + v[1].ptr[k] * (-210282. * v[2].ptr[k] +  85641. * v[1].ptr[k] + 86214. * v[3].ptr[k]);
		real beta1 = v[3].ptr[k] * ( 41001. * v[3].ptr[k] -  30414. * v[4].ptr[k]) + v[1].ptr[k] * (-19374. * v[2].ptr[k] +   3169. * v[1].ptr[k] + 19014. * v[3].ptr[k] -  5978. * v[4].ptr[k]) +  6649. * sqr(v[4].ptr[k]) + v[2].ptr[k] * (  33441. * v[2].ptr[k] -  70602. * v[3].ptr[k] + 23094. * v[4].ptr[k]);
		real beta2 = v[4].ptr[k] * ( 33441. * v[4].ptr[k] -  19374. * v[5].ptr[k]) + v[2].ptr[k] * (  6649. * v[2].ptr[k] -  30414. * v[3].ptr[k] + 23094. * v[4].ptr[k] -  5978. * v[5].ptr[k]) +  3169. * sqr(v[5].ptr[k]) + v[3].ptr[k] * (  41001. * v[3].ptr[k] -  70602. * v[4].ptr[k] + 19014. * v[5].ptr[k]);
		real beta3 = v[5].ptr[k] * ( 85641. * v[5].ptr[k] -  47214. * v[6].ptr[k]) + v[3].ptr[k] * ( 25729. * v[3].ptr[k] - 114894. * v[4].ptr[k] + 86214. * v[5].ptr[k] - 22778. * v[6].ptr[k]) +  6649. * sqr(v[6].ptr[k]) + v[4].ptr[k] * ( 134241. * v[4].ptr[k] - 210282. * v[5].ptr[k] + 56694. * v[6].ptr[k]);
<? 	end 

	if solver.wenoMethod == '1996 Jiang Shu' then 		-- WENO-JS
		--local epsilon = clnumber(1e-14)
		local epsilon = clnumber(1e-6)
?>
<? 		for i=0,stencilSize-1 do
?>		real w<?=i?> = <?=clnumber(d[d0 + i * dd])?> / sqr(<?=epsilon?> + beta<?=i?>);
<? 		end 

	elseif solver.wenoMethod == '2008 Borges' then 	-- WENO-Z
		local epsilon = clnumber(1e-14)	-- weno5
		--local epsilon = clnumber(1e-40)		-- weno7 ... but >64 grid sizes and this diverges?
?>		real tau = fabs(beta0 - beta<?=stencilSize-1?>);
<? 		for i=0,stencilSize-1 do 
?>		real w<?=i?> = <?=clnumber(d[d0 + i * dd])?> * (1 + (tau / (beta<?=i?> + <?=epsilon?>)));
<? 		end

	elseif solver.wenoMethod == '2010 Shen Zha' then -- WENO-BS?
		local epsilon = clnumber(1e-10)
		local shen_zha_A = clnumber(50)	-- 0-100
?>		real minB = min(min(beta0, beta1), beta2);
		real maxB = max(max(beta0, beta1), beta2);
		real R0 = minB / (maxB + <?=epsilon?>);
<? 		for i=0,stencilSize-1 do 
?>		beta<?=i?> += R0 * <?=shen_zha_A?> * minB;
<? 		end 
 		for i=0,stencilSize-1 do 
?>		real w<?=i?> = <?=clnumber(d[d0 + i * dd])?> / sqr(<?=epsilon?> + beta<?=i?>);
<?	 	end 
 
	else
		error("unknown wenoMethod "..tostring(solver.wenoMethod))
	end

	for i=0,stencilSize-1 do 
?>		real vs<?=i?> = 0.<?
		for j=0,stencilSize-1 do
		?> + <?=clnumber(c[cofs+i][j+1])?> * v[<?=i+j?>].ptr[k]<?
		end ?>;
<? 
	end 
?>		real wtot = 0.<? for i=0,stencilSize-1 do ?> + w<?=i?><? end ?>;
		result.ptr[k] = (0.<?
	for i=0,stencilSize-1 do
		?> + w<?=i?> * vs<?=i?><?
	end ?>) / wtot;
	}
	return result;
}
<? end ?>

kernel void calcFlux(
	constant <?=solver.solver_t?>* solver,
	global <?=eqn.cons_t?>* fluxBuf,
	const global <?=eqn.cons_t?>* UBuf
) {
	SETBOUNDS(numGhost,numGhost-1);
	
	real3 xR = cell_x(i);
	const global <?=eqn.cons_t?>* U = UBuf + index;
	<?
for side=0,solver.dim-1 do ?>{
		const int side = <?=side?>;	
		
		int indexL = index - solver->stepsize.s<?=side?>;
		const global <?=eqn.cons_t?>* UL = UBuf + indexL;
	
		int indexR = index;
		const global <?=eqn.cons_t?>* UR = UBuf + indexR;

		real3 xInt = xR;
		xInt.s<?=side?> -= .5 * solver->grid_dx.s<?=side?>;

		<?=eqn.eigen_t?> eig = eigen_forInterface(solver, *UL, *UR, xInt, normalForSide<?=side?>());

		real maxAbsLambda = 0.;
		for (int j = 0; j < <?=2*stencilSize?>; ++j) {
			const global <?=eqn.cons_t?>* Uj = U + (j - <?=stencilSize?>) * solver->stepsize.s<?=side?>;
			
			<?=eqn:consWaveCodePrefix(side, '*Uj', 'xInt'):gsub('\n', '\n\t\t')?>
			
			real lambdaMin = <?=eqn:consMinWaveCode(side, '*Uj', 'xInt')?>;
			maxAbsLambda = max(maxAbsLambda, fabs(lambdaMin));
			
			real lambdaMax = <?=eqn:consMaxWaveCode(side, '*Uj', 'xInt')?>;
			maxAbsLambda = max(maxAbsLambda, fabs(lambdaMax));
		}

	<? for j=0,2*stencilSize-1 do ?>
		const global <?=eqn.cons_t?>* U<?=j?> = U + <?=j - stencilSize?> * solver->stepsize.s<?=side?>;
		<?=eqn.cons_t?> F<?=j?> = fluxFromCons_<?=side?>(solver, *U<?=j?>, xInt);
<?
		if j < 2*stencilSize-1 then
?>		<?=eqn.cons_t?> Fp<?=j?>;
<?			for k=0,eqn.numStates-1 do 
?>		Fp<?=j?>.ptr[<?=k?>] = (F<?=j?>.ptr[<?=k?>] + maxAbsLambda * U<?=j?>->ptr[<?=k?>]) * .5;
<?			end
		end
		if j > 0 then
?>		<?=eqn.cons_t?> Fm<?=j?>;
<?			for k=0,eqn.numStates-1 do 
?>		Fm<?=j?>.ptr[<?=k?>] = (F<?=j?>.ptr[<?=k?>] - maxAbsLambda * U<?=j?>->ptr[<?=k?>]) * .5;
<? 			end
		end
	end ?>

		<?=eqn.waves_t?> fp[<?=2*stencilSize-1?>], fm[<?=2*stencilSize-1?>];
<? 	for j=0,2*stencilSize-2 do
?>		fp[<?=j?>] = eigen_leftTransform_<?=side?>(solver, eig, Fp<?=j?>, xInt);
		fm[<?=j?>] = eigen_leftTransform_<?=side?>(solver, eig, Fm<?=j+1?>, xInt);
<? 	end ?>
	
		<?=eqn.waves_t?> wf;
		<?=eqn.waves_t?> wfp = weno_r(fp);
		<?=eqn.waves_t?> wfm = weno_l(fm);
		for (int j = 0; j < numWaves; ++j) {
			wf.ptr[j] = wfp.ptr[j] + wfm.ptr[j];
		}
		
		int fluxIndexInt = side + dim * index;
		global <?=eqn.cons_t?>* flux = fluxBuf + fluxIndexInt;
		*flux = eigen_rightTransform_<?=side?>(solver, eig, wf, xInt);
	}<? 
end ?>
}
