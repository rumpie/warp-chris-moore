<?
local common = require 'common'()
local xNames = common.xNames
local symNames = common.symNames
local from3x3to6 = common.from3x3to6 
local from6to3x3 = common.from6to3x3 
local sym = common.sym
?>

typedef <?=eqn.prim_t?> prim_t;
typedef <?=eqn.cons_t?> cons_t;
typedef <?=eqn.eigen_t?> eigen_t;
typedef <?=eqn.waves_t?> waves_t;
typedef <?=solver.solver_t?> solver_t;

kernel void calcDT(
	constant solver_t* solver,
	global real* dtBuf,
	const global cons_t* UBuf
) {
	SETBOUNDS(0,0);
	if (OOB(numGhost,numGhost)) {
		dtBuf[index] = INFINITY;
		return;
	}
		
	const global cons_t* U = UBuf + index;
	real det_gamma = sym3_det(U->gamma_ll);
	real f = calc_f(U->alpha);
	
	//the only advantage of this calcDT over the default is that here this sqrt(f) is only called once
	real sqrt_f = sqrt(f);

	real dt = INFINITY;
	<? for side=0,solver.dim-1 do ?>{
		
		<? if side==0 then ?>
		real gammaUjj = (U->gamma_ll.yy * U->gamma_ll.zz - U->gamma_ll.yz * U->gamma_ll.yz) / det_gamma;
		<? elseif side==1 then ?>
		real gammaUjj = (U->gamma_ll.xx * U->gamma_ll.zz - U->gamma_ll.xz * U->gamma_ll.xz) / det_gamma;
		<? elseif side==2 then ?>
		real gammaUjj = (U->gamma_ll.xx * U->gamma_ll.yy - U->gamma_ll.xy * U->gamma_ll.xy) / det_gamma;
		<? end ?>	
		real lambdaLight = U->alpha * sqrt(gammaUjj);
		
		real lambdaGauge = lambdaLight * sqrt_f;
		real lambda = (real)max(lambdaGauge, lambdaLight);
		
		real lambdaMin = (real)min((real)0., -lambda);
		real lambdaMax = (real)max((real)0., lambda);
		dt = (real)min((real)dt, (real)(solver->grid_dx.s<?=side?> / (fabs(lambdaMax - lambdaMin) + (real)1e-9)));
	}<? end ?>
	dtBuf[index] = dt; 
}

//used by PLM
<? for side=0,solver.dim-1 do ?>
eigen_t eigen_forCell_<?=side?>(
	constant solver_t* solver,
	cons_t U,
	real3 x 
) {
	eigen_t eig;
	eig.alpha = U.alpha;
	eig.sqrt_f = sqrt(calc_f(U.alpha));
	eig.gamma_ll = U.gamma_ll;
	real det_gamma = sym3_det(U.gamma_ll);
	eig.gamma_uu = sym3_inv(U.gamma_ll, det_gamma);
	eig.sqrt_gammaUjj = _real3(sqrt(eig.gamma_uu.xx), sqrt(eig.gamma_uu.yy), sqrt(eig.gamma_uu.zz));
	return eig;
}
<? end ?>

<? for side=0,solver.dim-1 do ?>
range_t calcCellMinMaxEigenvalues_<?=side?>(
	const global cons_t* U,
	real3 x
) {
	real det_gamma = sym3_det(U->gamma_ll);
	
	<? if side==0 then ?>
	real gammaUjj = (U->gamma_ll.yy * U->gamma_ll.zz - U->gamma_ll.yz * U->gamma_ll.yz) / det_gamma;
	<? elseif side==1 then ?>
	real gammaUjj = (U->gamma_ll.xx * U->gamma_ll.zz - U->gamma_ll.xz * U->gamma_ll.xz) / det_gamma;
	<? elseif side==2 then ?>
	real gammaUjj = (U->gamma_ll.xx * U->gamma_ll.yy - U->gamma_ll.xy * U->gamma_ll.xy) / det_gamma;
	<? end ?>
	
	real lambdaLight = U->alpha * sqrt(gammaUjj);
	
	real f = calc_f(U->alpha);
	real lambdaGauge = lambdaLight * sqrt(f);

	real lambdaMax = max(lambdaGauge, lambdaLight);
	//= lambdaLight * max(sqrt(f), 1)

	return (range_t){
		.min = -lambdaMax, 
		.max = lambdaMax,
	};
}
<? end ?>

eigen_t eigen_forInterface(
	constant solver_t* solver,
	cons_t UL,
	cons_t UR,
	real3 x,
	real3 n
) {
	real alpha = .5 * (UL.alpha + UR.alpha);
	sym3 avg_gamma = (sym3){
		.xx = .5 * (UL.gamma_ll.xx + UR.gamma_ll.xx),
		.xy = .5 * (UL.gamma_ll.xy + UR.gamma_ll.xy),
		.xz = .5 * (UL.gamma_ll.xz + UR.gamma_ll.xz),
		.yy = .5 * (UL.gamma_ll.yy + UR.gamma_ll.yy),
		.yz = .5 * (UL.gamma_ll.yz + UR.gamma_ll.yz),
		.zz = .5 * (UL.gamma_ll.zz + UR.gamma_ll.zz),
	};
	real det_avg_gamma = sym3_det(avg_gamma);

	eigen_t eig;
	eig.alpha = alpha;
	eig.sqrt_f = sqrt(calc_f(alpha));
	eig.gamma_uu = sym3_inv(avg_gamma, det_avg_gamma);
	eig.sqrt_gammaUjj = _real3(sqrt(eig.gamma_uu.xx), sqrt(eig.gamma_uu.yy), sqrt(eig.gamma_uu.zz));
	return eig;
}

<? for side=0,solver.dim-1 do ?>
waves_t eigen_leftTransform_<?=side?>(
	constant solver_t* solver,
	eigen_t eig,
	cons_t inputU,
	real3 pt
) {
	waves_t results;

	//input
	real3 a_l = real3_swap<?=side?>(inputU.a_l);							//0-2
	_3sym3 d_lll = (_3sym3){
		.x = sym3_swap<?=side?>(inputU.d_lll.v<?=side?>),					//3-8
		.y = sym3_swap<?=side?>(inputU.d_lll.v<?=side==1 and 0 or 1?>),		//9-14
		.z = sym3_swap<?=side?>(inputU.d_lll.v<?=side==2 and 0 or 2?>),		//15-20
	};
	sym3 K_ll = sym3_swap<?=side?>(inputU.K_ll);							//21-26
	real Theta = inputU.Theta;												//27
	real3 Z_l = real3_swap<?=side?>(inputU.Z_l);							//28-30

	//eig
	real sqrt_f = eig.sqrt_f;
	real f = sqrt_f * sqrt_f;	
	real _1_sqrt_f = 1. / sqrt_f;
	real _1_f = _1_sqrt_f * _1_sqrt_f;
	real fSq = f * f;
	real f_toThe_3_2 = f * sqrt_f;
	real f_toThe_5_2 = f * f * sqrt_f;

	real f_minus_1 = f - 1.;
	real f_minus_1_sq = f_minus_1 * f_minus_1;

	sym3 gamma_ll = sym3_swap<?=side?>(eig.gamma_ll);
	sym3 gamma_uu = sym3_swap<?=side?>(eig.gamma_uu);
	
	_3sym3 d_ull = sym3_3sym3_mul(gamma_uu, d_lll);
	
	//d_llu = d_ij^k = d_ijl * gamma^lk
	real3x3 d_llu[3] = {
<? for i,xi in ipairs(xNames) do
?>		sym3_sym3_mul(d_lll.<?=xi?>, gamma_uu),
<? end
?>	};

	real3x3 K_ul = sym3_sym3_mul(gamma_uu, K_ll);

	real tr_K = real3x3_trace(K_ul);

	real sqrt_gUxx = eig.sqrt_gammaUjj.s<?=side?>;
	real _1_sqrt_gUxx = 1. / sqrt_gUxx;
	real _1_gammaUxx = _1_sqrt_gUxx * _1_sqrt_gUxx;

	real a_u_x = a_l.x * gamma_uu.xx + a_l.y * gamma_uu.xy + a_l.z * gamma_uu.xz;
	real Z_u_x = Z_l.x * gamma_uu.xx + Z_l.y * gamma_uu.xy + Z_l.z * gamma_uu.xz;

	//d_i = d_ijk gamma^jk
	real3 d_l = _real3(
		sym3_dot(d_lll.x, gamma_uu),
		sym3_dot(d_lll.y, gamma_uu),
		sym3_dot(d_lll.z, gamma_uu));
	
	real d_u_x = d_l.x * gamma_uu.xx + d_l.y * gamma_uu.xy + d_l.z * gamma_uu.xz;

	//e_i = d_jki gamma^jk
	real3 e_l = (real3){
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = 0. <? 
	for j,xj in ipairs(xNames) do
		for k,xk in ipairs(xNames) do
?> + d_lll.<?=xj?>.<?=sym(k,i)?> * gamma_uu.<?=sym(j,k)?><?
		end
	end
?>,
<? end
?>	};
	
	real e_u_x = e_l.x * gamma_uu.xx + e_l.y * gamma_uu.xy + e_l.z * gamma_uu.xz;

	real m = solver->m;

	results.ptr[0] = (
		-(2. * gamma_uu.xy * a_l.y * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xy * a_l.y * fSq * _1_sqrt_gUxx 
		- 4. * gamma_uu.xy * a_l.y * f * _1_sqrt_gUxx 
		+ 8. * gamma_uu.xy * K_ll.xy * f_toThe_3_2 
		- 4. * gamma_uu.xy * K_ll.xy * sqrt_f 
		- 4. * gamma_uu.xy * K_ll.xy * f_toThe_5_2 
		+ 8. * gamma_uu.xz * K_ll.xz * f_toThe_3_2 
		- 4. * gamma_uu.xz * K_ll.xz * f_toThe_5_2 
		- 4. * gamma_uu.xz * K_ll.xz * sqrt_f 
		+ 2. * gamma_uu.xz * a_l.z * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xz * a_l.z * fSq * _1_sqrt_gUxx 
		- 4. * gamma_uu.xz * a_l.z * f * _1_sqrt_gUxx 
		+ 4. * gamma_uu.yy * K_ll.yy * f_toThe_3_2 
		- 2. * gamma_uu.yy * K_ll.yy * sqrt_f 
		- 2. * gamma_uu.yy * K_ll.yy * f_toThe_5_2 
		- 4. * gamma_uu.yz * K_ll.yz * f_toThe_5_2 
		- 4. * gamma_uu.yz * K_ll.yz * sqrt_f 
		+ 8. * gamma_uu.yz * K_ll.yz * f_toThe_3_2 
		+ 4. * gamma_uu.zz * K_ll.zz * f_toThe_3_2 
		- 2. * gamma_uu.zz * K_ll.zz * sqrt_f 
		- 2. * gamma_uu.zz * K_ll.zz * f_toThe_5_2 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yy * d_lll.y.xy 
		+ 4. * f * sqrt_gUxx * gamma_uu.yy * d_lll.y.xy 
		- 4. * f * sqrt_gUxx * gamma_uu.yy * d_lll.x.yy 
		+ 4. * fSq * sqrt_gUxx * gamma_uu.yy * d_lll.x.yy 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yy * m * d_lll.y.xy 
		- 2. * f * sqrt_gUxx * gamma_uu.yy * m * d_lll.y.xy 
		- 2. * fSq * sqrt_gUxx * gamma_uu.yy * m * d_lll.x.yy 
		+ 2. * f * sqrt_gUxx * gamma_uu.yy * m * d_lll.x.yy 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * d_lll.y.xz 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.y.xz 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * d_lll.z.xy 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.z.xy 
		- 8. * f * sqrt_gUxx * gamma_uu.yz * d_lll.x.yz 
		+ 8. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.x.yz 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.y.xz 
		- 2. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.y.xz 
		- 2. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.z.xy 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.z.xy 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.x.yz 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.x.yz 
		- 4. * fSq * sqrt_gUxx * gamma_uu.zz * d_lll.z.xz 
		+ 4. * f * sqrt_gUxx * gamma_uu.zz * d_lll.z.xz 
		+ 4. * fSq * sqrt_gUxx * gamma_uu.zz * d_lll.x.zz 
		- 4. * f * sqrt_gUxx * gamma_uu.zz * d_lll.x.zz 
		- 2. * f * sqrt_gUxx * gamma_uu.zz * m * d_lll.z.xz 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.zz * m * d_lll.z.xz 
		+ 2. * f * sqrt_gUxx * gamma_uu.zz * m * d_lll.x.zz 
		- 2. * fSq * sqrt_gUxx * gamma_uu.zz * m * d_lll.x.zz 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * d_lll.y.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.y.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.z.xy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * d_lll.z.xy * _1_sqrt_gUxx 
		+ 8. * f * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz * _1_sqrt_gUxx 
		- 8. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.y.xz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.y.xz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.z.xy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.z.xy * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.x.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.x.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.yz * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.yz * d_lll.y.yz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.yz * d_lll.z.yy * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.yz * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.yz * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.yz * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.yz * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.yz * m * d_lll.z.yy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.zz * d_lll.y.zz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.zz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.zz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.zz * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.zz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.zz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.zz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.zz * m * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xy * d_lll.y.xy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xy * d_lll.y.xy * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * Z_l.y * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * Z_l.y * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.xy * d_lll.x.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.xy * d_lll.x.yy * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xy * m * d_lll.y.xy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xy * m * d_lll.y.xy * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * m * Z_l.y * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * m * Z_l.y * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.xy * m * d_lll.x.yy * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.xy * m * d_lll.x.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.yy * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.yy * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.yy * d_lll.z.yy * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.yy * d_lll.z.yy * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.yy * m * d_lll.y.yz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.yy * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.yy * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.yy * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.yz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.yz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.yz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.yz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.yz * m * d_lll.y.zz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.yz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.yz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.yz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.xz * d_lll.z.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.xz * d_lll.z.xz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * Z_l.z * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * Z_l.z * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.xz * d_lll.x.zz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.xz * d_lll.x.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.xz * m * d_lll.z.xz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.xz * m * d_lll.z.xz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * m * Z_l.z * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * m * Z_l.z * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.xz * m * d_lll.x.zz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.xz * m * d_lll.x.zz * _1_sqrt_gUxx 
		+ 4. * f * Z_l.x * sqrt_gUxx 
		- 4. * fSq * Z_l.x * sqrt_gUxx 
		+ 2. * f_toThe_5_2 * m * Theta 
		- 2. * f_toThe_3_2 * m * Theta 
		- 2. * f * m * Z_l.x * sqrt_gUxx 
		+ 2. * fSq * m * Z_l.x * sqrt_gUxx 
		+ 2. * a_l.x * sqrt_gUxx 
		+ 2. * a_l.x * sqrt_gUxx * fSq 
		- 4. * a_l.x * sqrt_gUxx * f 
		+ 4. * K_ll.xx * gamma_uu.xx * f_toThe_3_2 
		- 2. * K_ll.xx * gamma_uu.xx * sqrt_f 
		- 2. * K_ll.xx * f_toThe_5_2 * gamma_uu.xx 
		+ 4. * Theta * sqrt_f 
		- 4. * Theta * f_toThe_3_2)) / (gamma_uu.xx * sqrt_f * (4. 
		- 8. * f 
		+ 4. * fSq));
	results.ptr[1] = (2. * gamma_uu.xx * sqrt_gUxx * K_ll.xz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.y.zz 
		+ gamma_uu.xy * gamma_uu.xz * d_lll.z.yz 
		- gamma_uu.xy * gamma_uu.xy * d_lll.y.yz 
		+ gamma_uu.xy * gamma_uu.xy * d_lll.z.yy 
		+ 2. * gamma_uu.xy * K_ll.yz * sqrt_gUxx 
		+ 2. * gamma_uu.xz * K_ll.zz * sqrt_gUxx 
		+ gamma_uu.yy * gamma_uu.xx * d_lll.y.yz 
		- gamma_uu.yy * gamma_uu.xx * d_lll.z.yy 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.y.zz 
		- gamma_uu.yz * gamma_uu.xx * d_lll.z.yz 
		- a_l.z * gamma_uu.xx 
		+ 2. * Z_l.z * gamma_uu.xx) / (4. * gamma_uu.xx);
	results.ptr[2] = (2. * gamma_uu.xx * sqrt_gUxx * K_ll.xy 
		+ gamma_uu.xy * gamma_uu.xz * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.yy 
		+ 2. * gamma_uu.xy * K_ll.yy * sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xz * gamma_uu.xz * d_lll.z.yz 
		+ 2. * gamma_uu.xz * K_ll.yz * sqrt_gUxx 
		- gamma_uu.yz * gamma_uu.xx * d_lll.y.yz 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.z.yy 
		- gamma_uu.zz * gamma_uu.xx * d_lll.y.zz 
		+ gamma_uu.zz * gamma_uu.xx * d_lll.z.yz 
		- a_l.y * gamma_uu.xx 
		+ 2. * Z_l.y * gamma_uu.xx) / (4. * gamma_uu.xx);
	results.ptr[3] = (gamma_uu.xy * gamma_uu.yz * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.yz * d_lll.z.yy 
		+ gamma_uu.xy * gamma_uu.zz * d_lll.y.zz 
		- gamma_uu.xy * gamma_uu.zz * d_lll.z.yz 
		+ gamma_uu.xy * a_l.y 
		- 2. * gamma_uu.xy * K_ll.xy * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * d_lll.y.yz 
		+ gamma_uu.xz * gamma_uu.yy * d_lll.z.yy 
		- gamma_uu.xz * gamma_uu.yz * d_lll.y.zz 
		+ gamma_uu.xz * gamma_uu.yz * d_lll.z.yz 
		- 2. * gamma_uu.xz * K_ll.xz * sqrt_gUxx 
		+ gamma_uu.xz * a_l.z 
		- 2. * gamma_uu.yy * K_ll.yy * sqrt_gUxx 
		- 4. * gamma_uu.yz * K_ll.yz * sqrt_gUxx 
		- 2. * gamma_uu.zz * K_ll.zz * sqrt_gUxx 
		+ 2. * Theta * sqrt_gUxx 
		+ 2. * Z_l.x * gamma_uu.xx) / (4. * gamma_uu.xx);
	results.ptr[4] = (gamma_uu.xx * gamma_uu.yy * d_lll.y.xy 
		- gamma_uu.xx * gamma_uu.yy * d_lll.x.yy 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.y.xz 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.z.xy 
		- 2. * gamma_uu.xx * gamma_uu.yz * d_lll.x.yz 
		+ gamma_uu.xx * gamma_uu.zz * d_lll.z.xz 
		- gamma_uu.xx * gamma_uu.zz * d_lll.x.zz 
		+ gamma_uu.xx * Z_l.x 
		- gamma_uu.xy * gamma_uu.xz * d_lll.y.xz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.xy 
		+ 2. * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz 
		- gamma_uu.xy * gamma_uu.yz * d_lll.y.yz 
		+ gamma_uu.xy * gamma_uu.yz * d_lll.z.yy 
		- gamma_uu.xy * gamma_uu.zz * d_lll.y.zz 
		+ gamma_uu.xy * gamma_uu.zz * d_lll.z.yz 
		- gamma_uu.xy * gamma_uu.xy * d_lll.y.xy 
		+ gamma_uu.xy * Z_l.y 
		+ gamma_uu.xy * gamma_uu.xy * d_lll.x.yy 
		+ gamma_uu.xz * gamma_uu.yy * d_lll.y.yz 
		- gamma_uu.xz * gamma_uu.yy * d_lll.z.yy 
		+ gamma_uu.xz * gamma_uu.yz * d_lll.y.zz 
		- gamma_uu.xz * gamma_uu.yz * d_lll.z.yz 
		- gamma_uu.xz * gamma_uu.xz * d_lll.z.xz 
		+ gamma_uu.xz * Z_l.z 
		+ gamma_uu.xz * gamma_uu.xz * d_lll.x.zz 
		+ Theta * sqrt_gUxx) / (2. * sqrt_gUxx);
	results.ptr[5] = (gamma_uu.xx * d_lll.z.xz 
		- gamma_uu.xx * d_lll.x.zz 
		- gamma_uu.xy * d_lll.y.zz 
		+ gamma_uu.xy * d_lll.z.yz 
		+ K_ll.zz * sqrt_gUxx) / (2. * sqrt_gUxx);
	results.ptr[6] = (gamma_uu.xx * d_lll.y.xz 
		+ gamma_uu.xx * d_lll.z.xy 
		- 2. * gamma_uu.xx * d_lll.x.yz 
		- gamma_uu.xy * d_lll.y.yz 
		+ gamma_uu.xy * d_lll.z.yy 
		+ gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xz * d_lll.z.yz 
		+ 2. * K_ll.yz * sqrt_gUxx) / (4. * sqrt_gUxx);
	results.ptr[7] = (
		-(gamma_uu.xx * gamma_uu.yy * d_lll.y.xy * f 
		- gamma_uu.xx * gamma_uu.yy * d_lll.x.yy * f 
		- gamma_uu.xx * gamma_uu.yy * m * d_lll.y.xy * f 
		+ gamma_uu.xx * gamma_uu.yy * m * d_lll.x.yy * f 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.y.xz * f 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.z.xy * f 
		- 2. * gamma_uu.xx * gamma_uu.yz * d_lll.x.yz * f 
		- gamma_uu.xx * gamma_uu.yz * m * d_lll.y.xz * f 
		- gamma_uu.xx * gamma_uu.yz * m * d_lll.z.xy * f 
		+ 2. * gamma_uu.xx * gamma_uu.yz * m * d_lll.x.yz * f 
		+ gamma_uu.xx * gamma_uu.zz * d_lll.z.xz * f 
		- gamma_uu.xx * gamma_uu.zz * d_lll.x.zz * f 
		- gamma_uu.xx * gamma_uu.zz * m * d_lll.z.xz * f 
		+ gamma_uu.xx * gamma_uu.zz * m * d_lll.x.zz * f 
		- 2. * gamma_uu.xy * gamma_uu.xz * d_lll.y.xz * f 
		- 2. * gamma_uu.xy * gamma_uu.xz * d_lll.z.xy * f 
		+ 4. * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz * f 
		+ gamma_uu.xy * gamma_uu.xz * m * d_lll.y.xz * f 
		+ gamma_uu.xy * gamma_uu.xz * m * d_lll.z.xy * f 
		- 2. * gamma_uu.xy * gamma_uu.xz * m * d_lll.x.yz * f 
		- 2. * gamma_uu.xy * gamma_uu.yz * d_lll.y.yz * f 
		+ 2. * gamma_uu.xy * gamma_uu.yz * d_lll.z.yy * f 
		+ gamma_uu.xy * gamma_uu.yz * m * d_lll.y.yz * f 
		- gamma_uu.xy * gamma_uu.yz * m * d_lll.z.yy * f 
		- 2. * gamma_uu.xy * gamma_uu.zz * d_lll.y.zz * f 
		+ 2. * gamma_uu.xy * gamma_uu.zz * d_lll.z.yz * f 
		+ gamma_uu.xy * gamma_uu.zz * m * d_lll.y.zz * f 
		- gamma_uu.xy * gamma_uu.zz * m * d_lll.z.yz * f 
		- 2. * gamma_uu.xy * gamma_uu.xy * d_lll.y.xy * f 
		+ gamma_uu.xy * a_l.y 
		+ 2. * gamma_uu.xy * Z_l.y * f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * d_lll.x.yy * f 
		+ gamma_uu.xy * gamma_uu.xy * m * d_lll.y.xy * f 
		- gamma_uu.xy * m * Z_l.y * f 
		- gamma_uu.xy * gamma_uu.xy * m * d_lll.x.yy * f 
		+ 2. * gamma_uu.xz * gamma_uu.yy * d_lll.y.yz * f 
		- 2. * gamma_uu.xz * gamma_uu.yy * d_lll.z.yy * f 
		- gamma_uu.xz * gamma_uu.yy * m * d_lll.y.yz * f 
		+ gamma_uu.xz * gamma_uu.yy * m * d_lll.z.yy * f 
		+ 2. * gamma_uu.xz * gamma_uu.yz * d_lll.y.zz * f 
		- 2. * gamma_uu.xz * gamma_uu.yz * d_lll.z.yz * f 
		- gamma_uu.xz * gamma_uu.yz * m * d_lll.y.zz * f 
		+ gamma_uu.xz * gamma_uu.yz * m * d_lll.z.yz * f 
		- 2. * gamma_uu.xz * gamma_uu.xz * d_lll.z.xz * f 
		+ gamma_uu.xz * a_l.z 
		+ 2. * gamma_uu.xz * Z_l.z * f 
		+ 2. * gamma_uu.xz * gamma_uu.xz * d_lll.x.zz * f 
		+ gamma_uu.xz * gamma_uu.xz * m * d_lll.z.xz * f 
		- gamma_uu.xz * m * Z_l.z * f 
		- gamma_uu.xz * gamma_uu.xz * m * d_lll.x.zz * f 
		- f * gamma_uu.xy * a_l.y 
		- f * gamma_uu.xz * a_l.z 
		+ a_l.x * gamma_uu.xx 
		- d_lll.x.xx * gamma_uu.xx * gamma_uu.xx * f 
		- m * Z_l.x * gamma_uu.xx * f)) / (gamma_uu.xx * gamma_uu.xx * f);
	results.ptr[8] = (
		-(2. * gamma_uu.xy * d_lll.y.xy 
		- 2. * gamma_uu.xy * d_lll.x.yy 
		+ gamma_uu.xz * d_lll.y.xz 
		+ gamma_uu.xz * d_lll.z.xy 
		- 2. * gamma_uu.xz * d_lll.x.yz 
		+ gamma_uu.yz * d_lll.y.yz 
		- gamma_uu.yz * d_lll.z.yy 
		+ gamma_uu.zz * d_lll.y.zz 
		- gamma_uu.zz * d_lll.z.yz 
		+ a_l.y 
		- 2. * Z_l.y 
		- 2. * d_lll.x.xy * gamma_uu.xx)) / (2. * gamma_uu.xx);
	results.ptr[9] = (
		-(gamma_uu.xy * d_lll.y.xz 
		+ gamma_uu.xy * d_lll.z.xy 
		- 2. * gamma_uu.xy * d_lll.x.yz 
		+ 2. * gamma_uu.xz * d_lll.z.xz 
		- 2. * gamma_uu.xz * d_lll.x.zz 
		- gamma_uu.yy * d_lll.y.yz 
		+ gamma_uu.yy * d_lll.z.yy 
		- gamma_uu.yz * d_lll.y.zz 
		+ gamma_uu.yz * d_lll.z.yz 
		+ a_l.z 
		- 2. * Z_l.z 
		- 2. * d_lll.x.xz * gamma_uu.xx)) / (2. * gamma_uu.xx);
	results.ptr[10] = d_lll.y.xx;
	results.ptr[11] = d_lll.y.xy;
	results.ptr[12] = d_lll.y.xz;
	results.ptr[13] = d_lll.y.yy;
	results.ptr[14] = d_lll.y.yz;
	results.ptr[15] = d_lll.y.zz;
	results.ptr[16] = d_lll.z.xx;
	results.ptr[17] = d_lll.z.xy;
	results.ptr[18] = d_lll.z.xz;
	results.ptr[19] = d_lll.z.yy;
	results.ptr[20] = d_lll.z.yz;
	results.ptr[21] = d_lll.z.zz;
	results.ptr[22] = (
		-(gamma_uu.xy * gamma_uu.xz * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.yy 
		+ gamma_uu.xz * gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xz * gamma_uu.xz * d_lll.z.yz 
		- gamma_uu.yz * gamma_uu.xx * d_lll.y.yz 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.z.yy 
		- gamma_uu.zz * gamma_uu.xx * d_lll.y.zz 
		+ gamma_uu.zz * gamma_uu.xx * d_lll.z.yz 
		- a_l.y * gamma_uu.xx)) / (2. * gamma_uu.xx);
	results.ptr[23] = (gamma_uu.xy * gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.yz 
		+ gamma_uu.xy * gamma_uu.xy * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.xy * d_lll.z.yy 
		- gamma_uu.yy * gamma_uu.xx * d_lll.y.yz 
		+ gamma_uu.yy * gamma_uu.xx * d_lll.z.yy 
		- gamma_uu.yz * gamma_uu.xx * d_lll.y.zz 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.z.yz 
		+ a_l.z * gamma_uu.xx) / (2. * gamma_uu.xx);
	results.ptr[24] = (
		-(2. * gamma_uu.xx * sqrt_gUxx * K_ll.xz 
		+ gamma_uu.xy * gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.yz 
		+ gamma_uu.xy * gamma_uu.xy * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.xy * d_lll.z.yy 
		+ 2. * gamma_uu.xy * K_ll.yz * sqrt_gUxx 
		+ 2. * gamma_uu.xz * K_ll.zz * sqrt_gUxx 
		- gamma_uu.yy * gamma_uu.xx * d_lll.y.yz 
		+ gamma_uu.yy * gamma_uu.xx * d_lll.z.yy 
		- gamma_uu.yz * gamma_uu.xx * d_lll.y.zz 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.z.yz 
		+ a_l.z * gamma_uu.xx 
		- 2. * Z_l.z * gamma_uu.xx)) / (4. * gamma_uu.xx);
	results.ptr[25] = (
		-(2. * gamma_uu.xx * sqrt_gUxx * K_ll.xy 
		- gamma_uu.xy * gamma_uu.xz * d_lll.y.yz 
		+ gamma_uu.xy * gamma_uu.xz * d_lll.z.yy 
		+ 2. * gamma_uu.xy * K_ll.yy * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.xz * d_lll.y.zz 
		+ gamma_uu.xz * gamma_uu.xz * d_lll.z.yz 
		+ 2. * gamma_uu.xz * K_ll.yz * sqrt_gUxx 
		+ gamma_uu.yz * gamma_uu.xx * d_lll.y.yz 
		- gamma_uu.yz * gamma_uu.xx * d_lll.z.yy 
		+ gamma_uu.zz * gamma_uu.xx * d_lll.y.zz 
		- gamma_uu.zz * gamma_uu.xx * d_lll.z.yz 
		+ a_l.y * gamma_uu.xx 
		- 2. * Z_l.y * gamma_uu.xx)) / (4. * gamma_uu.xx);
	results.ptr[26] = (gamma_uu.xy * gamma_uu.yz * d_lll.y.yz 
		- gamma_uu.xy * gamma_uu.yz * d_lll.z.yy 
		+ gamma_uu.xy * gamma_uu.zz * d_lll.y.zz 
		- gamma_uu.xy * gamma_uu.zz * d_lll.z.yz 
		+ gamma_uu.xy * a_l.y 
		+ 2. * gamma_uu.xy * K_ll.xy * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * d_lll.y.yz 
		+ gamma_uu.xz * gamma_uu.yy * d_lll.z.yy 
		- gamma_uu.xz * gamma_uu.yz * d_lll.y.zz 
		+ gamma_uu.xz * gamma_uu.yz * d_lll.z.yz 
		+ 2. * gamma_uu.xz * K_ll.xz * sqrt_gUxx 
		+ gamma_uu.xz * a_l.z 
		+ 2. * gamma_uu.yy * K_ll.yy * sqrt_gUxx 
		+ 4. * gamma_uu.yz * K_ll.yz * sqrt_gUxx 
		+ 2. * gamma_uu.zz * K_ll.zz * sqrt_gUxx 
		- 2. * Theta * sqrt_gUxx 
		+ 2. * Z_l.x * gamma_uu.xx) / (4. * gamma_uu.xx);
	results.ptr[27] = (
		-(gamma_uu.xx * gamma_uu.yy * d_lll.y.xy 
		- gamma_uu.xx * gamma_uu.yy * d_lll.x.yy 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.y.xz 
		+ gamma_uu.xx * gamma_uu.yz * d_lll.z.xy 
		- 2. * gamma_uu.xx * gamma_uu.yz * d_lll.x.yz 
		+ gamma_uu.xx * gamma_uu.zz * d_lll.z.xz 
		- gamma_uu.xx * gamma_uu.zz * d_lll.x.zz 
		+ gamma_uu.xx * Z_l.x 
		- gamma_uu.xy * gamma_uu.xz * d_lll.y.xz 
		- gamma_uu.xy * gamma_uu.xz * d_lll.z.xy 
		+ 2. * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz 
		- gamma_uu.xy * gamma_uu.yz * d_lll.y.yz 
		+ gamma_uu.xy * gamma_uu.yz * d_lll.z.yy 
		- gamma_uu.xy * gamma_uu.zz * d_lll.y.zz 
		+ gamma_uu.xy * gamma_uu.zz * d_lll.z.yz 
		- gamma_uu.xy * gamma_uu.xy * d_lll.y.xy 
		+ gamma_uu.xy * Z_l.y 
		+ gamma_uu.xy * gamma_uu.xy * d_lll.x.yy 
		+ gamma_uu.xz * gamma_uu.yy * d_lll.y.yz 
		- gamma_uu.xz * gamma_uu.yy * d_lll.z.yy 
		+ gamma_uu.xz * gamma_uu.yz * d_lll.y.zz 
		- gamma_uu.xz * gamma_uu.yz * d_lll.z.yz 
		- gamma_uu.xz * gamma_uu.xz * d_lll.z.xz 
		+ gamma_uu.xz * Z_l.z 
		+ gamma_uu.xz * gamma_uu.xz * d_lll.x.zz 
		- Theta * sqrt_gUxx)) / (2. * sqrt_gUxx);
	results.ptr[28] = (
		-(gamma_uu.xx * d_lll.z.xz 
		- gamma_uu.xx * d_lll.x.zz 
		- gamma_uu.xy * d_lll.y.zz 
		+ gamma_uu.xy * d_lll.z.yz 
		- K_ll.zz * sqrt_gUxx)) / (2. * sqrt_gUxx);
	results.ptr[29] = (
		-(gamma_uu.xx * d_lll.y.xz 
		+ gamma_uu.xx * d_lll.z.xy 
		- 2. * gamma_uu.xx * d_lll.x.yz 
		- gamma_uu.xy * d_lll.y.yz 
		+ gamma_uu.xy * d_lll.z.yy 
		+ gamma_uu.xz * d_lll.y.zz 
		- gamma_uu.xz * d_lll.z.yz 
		- 2. * K_ll.yz * sqrt_gUxx)) / (4. * sqrt_gUxx);
	results.ptr[30] = (2. * gamma_uu.xy * a_l.y * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xy * a_l.y * fSq * _1_sqrt_gUxx 
		- 4. * gamma_uu.xy * a_l.y * f * _1_sqrt_gUxx 
		- 8. * gamma_uu.xy * K_ll.xy * f_toThe_3_2 
		+ 4. * gamma_uu.xy * K_ll.xy * sqrt_f 
		+ 4. * gamma_uu.xy * K_ll.xy * f_toThe_5_2 
		- 8. * gamma_uu.xz * K_ll.xz * f_toThe_3_2 
		+ 4. * gamma_uu.xz * K_ll.xz * f_toThe_5_2 
		+ 4. * gamma_uu.xz * K_ll.xz * sqrt_f 
		+ 2. * gamma_uu.xz * a_l.z * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xz * a_l.z * fSq * _1_sqrt_gUxx 
		- 4. * gamma_uu.xz * a_l.z * f * _1_sqrt_gUxx 
		- 4. * gamma_uu.yy * K_ll.yy * f_toThe_3_2 
		+ 2. * gamma_uu.yy * K_ll.yy * sqrt_f 
		+ 2. * gamma_uu.yy * K_ll.yy * f_toThe_5_2 
		+ 4. * gamma_uu.yz * K_ll.yz * f_toThe_5_2 
		+ 4. * gamma_uu.yz * K_ll.yz * sqrt_f 
		- 8. * gamma_uu.yz * K_ll.yz * f_toThe_3_2 
		- 4. * gamma_uu.zz * K_ll.zz * f_toThe_3_2 
		+ 2. * gamma_uu.zz * K_ll.zz * sqrt_f 
		+ 2. * gamma_uu.zz * K_ll.zz * f_toThe_5_2 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yy * d_lll.y.xy 
		+ 4. * f * sqrt_gUxx * gamma_uu.yy * d_lll.y.xy 
		- 4. * f * sqrt_gUxx * gamma_uu.yy * d_lll.x.yy 
		+ 4. * fSq * sqrt_gUxx * gamma_uu.yy * d_lll.x.yy 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yy * m * d_lll.y.xy 
		- 2. * f * sqrt_gUxx * gamma_uu.yy * m * d_lll.y.xy 
		- 2. * fSq * sqrt_gUxx * gamma_uu.yy * m * d_lll.x.yy 
		+ 2. * f * sqrt_gUxx * gamma_uu.yy * m * d_lll.x.yy 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * d_lll.y.xz 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.y.xz 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * d_lll.z.xy 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.z.xy 
		- 8. * f * sqrt_gUxx * gamma_uu.yz * d_lll.x.yz 
		+ 8. * fSq * sqrt_gUxx * gamma_uu.yz * d_lll.x.yz 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.y.xz 
		- 2. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.y.xz 
		- 2. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.z.xy 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.z.xy 
		- 4. * fSq * sqrt_gUxx * gamma_uu.yz * m * d_lll.x.yz 
		+ 4. * f * sqrt_gUxx * gamma_uu.yz * m * d_lll.x.yz 
		- 4. * fSq * sqrt_gUxx * gamma_uu.zz * d_lll.z.xz 
		+ 4. * f * sqrt_gUxx * gamma_uu.zz * d_lll.z.xz 
		+ 4. * fSq * sqrt_gUxx * gamma_uu.zz * d_lll.x.zz 
		- 4. * f * sqrt_gUxx * gamma_uu.zz * d_lll.x.zz 
		- 2. * f * sqrt_gUxx * gamma_uu.zz * m * d_lll.z.xz 
		+ 2. * fSq * sqrt_gUxx * gamma_uu.zz * m * d_lll.z.xz 
		+ 2. * f * sqrt_gUxx * gamma_uu.zz * m * d_lll.x.zz 
		- 2. * fSq * sqrt_gUxx * gamma_uu.zz * m * d_lll.x.zz 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * d_lll.y.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.y.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.z.xy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * d_lll.z.xy * _1_sqrt_gUxx 
		+ 8. * f * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz * _1_sqrt_gUxx 
		- 8. * fSq * gamma_uu.xy * gamma_uu.xz * d_lll.x.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.y.xz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.y.xz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.z.xy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.z.xy * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xz * m * d_lll.x.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xz * m * d_lll.x.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.yz * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.yz * d_lll.y.yz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.yz * d_lll.z.yy * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.yz * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.yz * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.yz * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.yz * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.yz * m * d_lll.z.yy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.zz * d_lll.y.zz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.zz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.zz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.zz * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.zz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.zz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.zz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.zz * m * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xy * gamma_uu.xy * d_lll.y.xy * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xy * gamma_uu.xy * d_lll.y.xy * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * Z_l.y * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * Z_l.y * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xy * gamma_uu.xy * d_lll.x.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xy * gamma_uu.xy * d_lll.x.yy * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xy * gamma_uu.xy * m * d_lll.y.xy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xy * gamma_uu.xy * m * d_lll.y.xy * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * m * Z_l.y * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * m * Z_l.y * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xy * gamma_uu.xy * m * d_lll.x.yy * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xy * gamma_uu.xy * m * d_lll.x.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.yy * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.yy * d_lll.y.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.yy * d_lll.z.yy * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.yy * d_lll.z.yy * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.yy * m * d_lll.y.yz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.yy * m * d_lll.y.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.yy * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.yy * m * d_lll.z.yy * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.yz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.yz * d_lll.y.zz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.yz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.yz * d_lll.z.yz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.yz * m * d_lll.y.zz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.yz * m * d_lll.y.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.yz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.yz * m * d_lll.z.yz * _1_sqrt_gUxx 
		- 4. * f * gamma_uu.xz * gamma_uu.xz * d_lll.z.xz * _1_sqrt_gUxx 
		+ 4. * fSq * gamma_uu.xz * gamma_uu.xz * d_lll.z.xz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * Z_l.z * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * Z_l.z * _1_sqrt_gUxx 
		- 4. * fSq * gamma_uu.xz * gamma_uu.xz * d_lll.x.zz * _1_sqrt_gUxx 
		+ 4. * f * gamma_uu.xz * gamma_uu.xz * d_lll.x.zz * _1_sqrt_gUxx 
		+ 2. * f * gamma_uu.xz * gamma_uu.xz * m * d_lll.z.xz * _1_sqrt_gUxx 
		- 2. * fSq * gamma_uu.xz * gamma_uu.xz * m * d_lll.z.xz * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * m * Z_l.z * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * m * Z_l.z * _1_sqrt_gUxx 
		- 2. * f * gamma_uu.xz * gamma_uu.xz * m * d_lll.x.zz * _1_sqrt_gUxx 
		+ 2. * fSq * gamma_uu.xz * gamma_uu.xz * m * d_lll.x.zz * _1_sqrt_gUxx 
		+ 4. * f * Z_l.x * sqrt_gUxx 
		- 4. * fSq * Z_l.x * sqrt_gUxx 
		- 2. * f_toThe_5_2 * m * Theta 
		+ 2. * f_toThe_3_2 * m * Theta 
		- 2. * f * m * Z_l.x * sqrt_gUxx 
		+ 2. * fSq * m * Z_l.x * sqrt_gUxx 
		+ 2. * a_l.x * sqrt_gUxx 
		+ 2. * a_l.x * sqrt_gUxx * fSq 
		- 4. * a_l.x * sqrt_gUxx * f 
		- 4. * K_ll.xx * gamma_uu.xx * f_toThe_3_2 
		+ 2. * K_ll.xx * gamma_uu.xx * sqrt_f 
		+ 2. * K_ll.xx * f_toThe_5_2 * gamma_uu.xx 
		- 4. * Theta * sqrt_f 
		+ 4. * Theta * f_toThe_3_2) / (gamma_uu.xx * sqrt_f * (4. 
		- 8. * f 
		+ 4. * fSq));
	
	return results;
}

cons_t eigen_rightTransform_<?=side?>(
	constant solver_t* solver,
	eigen_t eig,
	waves_t input,
	real3 unused
) {
	cons_t resultU;
	for (int j = 0; j < numStates; ++j) {
		resultU.ptr[j] = 0;
	}
	
	sym3 gamma_ll = sym3_swap<?=side?>(eig.gamma_ll);
	sym3 gamma_uu = sym3_swap<?=side?>(eig.gamma_uu);

	real sqrt_f = eig.sqrt_f;
	real f = sqrt_f * sqrt_f;
	real fSq = f * f;
	real f_toThe_3_2 = f * sqrt_f;

	real f_minus_1 = f - 1.;
	real sqrt_gUxx = sqrt(gamma_uu.xx);
	real _1_sqrt_gUxx = 1. / sqrt_gUxx;
	real _1_gammaUxx = _1_sqrt_gUxx * _1_sqrt_gUxx;
	
	real m = solver->m;

	resultU.a_l.x = (gamma_uu.xy * gamma_uu.yz * input.ptr[14] * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.yz * input.ptr[14] * f * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.yz * input.ptr[19] * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.yz * input.ptr[19] * f * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.zz * input.ptr[15] * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.zz * input.ptr[15] * f * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.zz * input.ptr[20] * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.zz * input.ptr[20] * f * _1_sqrt_gUxx 
		- 2. * gamma_uu.xy * input.ptr[22] * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xy * input.ptr[22] * f * _1_sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[14] * _1_sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[14] * f * _1_sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[19] * _1_sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[19] * f * _1_sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yz * input.ptr[15] * _1_sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.yz * input.ptr[15] * f * _1_sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.yz * input.ptr[20] * _1_sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yz * input.ptr[20] * f * _1_sqrt_gUxx 
		- 2. * gamma_uu.xz * input.ptr[23] * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xz * input.ptr[23] * f * _1_sqrt_gUxx 
		+ f_toThe_3_2 * gamma_uu.xx * input.ptr[0] 
		- sqrt_f * gamma_uu.xx * input.ptr[0] 
		+ sqrt_f * gamma_uu.xx * input.ptr[30] 
		- f_toThe_3_2 * gamma_uu.xx * input.ptr[30] 
		+ 2. * f * input.ptr[27] 
		- 2. * f * input.ptr[4] 
		- f * m * input.ptr[27] 
		+ f * m * input.ptr[4]) / (sqrt_gUxx * (1. 
		- f));
	resultU.a_l.y = (gamma_uu.xy * gamma_uu.xz * input.ptr[14] 
		- gamma_uu.xy * gamma_uu.xz * input.ptr[19] 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[15] 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[20] 
		- gamma_uu.yz * gamma_uu.xx * input.ptr[14] 
		+ gamma_uu.yz * gamma_uu.xx * input.ptr[19] 
		- gamma_uu.zz * gamma_uu.xx * input.ptr[15] 
		+ gamma_uu.zz * gamma_uu.xx * input.ptr[20] 
		+ 2. * input.ptr[22] * gamma_uu.xx) / gamma_uu.xx;
	resultU.a_l.z = (
		-(gamma_uu.xy * gamma_uu.xz * input.ptr[15] 
		- gamma_uu.xy * gamma_uu.xz * input.ptr[20] 
		+ gamma_uu.xy * gamma_uu.xy * input.ptr[14] 
		- gamma_uu.xy * gamma_uu.xy * input.ptr[19] 
		- gamma_uu.yy * gamma_uu.xx * input.ptr[14] 
		+ gamma_uu.yy * gamma_uu.xx * input.ptr[19] 
		- gamma_uu.yz * gamma_uu.xx * input.ptr[15] 
		+ gamma_uu.yz * gamma_uu.xx * input.ptr[20] 
		- 2. * input.ptr[23] * gamma_uu.xx)) / gamma_uu.xx;
	resultU.d_lll.x.xx = (gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * f_toThe_3_2 * input.ptr[4] 
		- gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * f_toThe_3_2 * m * input.ptr[4] 
		- gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[27] * sqrt_f 
		- sqrt_gUxx * gamma_uu.yy * input.ptr[4] * gamma_uu.xy * gamma_uu.xy * sqrt_f 
		+ gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[4] * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * sqrt_gUxx * sqrt_f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[29] * _1_sqrt_gUxx * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[29] * f_toThe_3_2 * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * f_toThe_3_2 * sqrt_gUxx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[6] * _1_sqrt_gUxx * sqrt_f 
		+ 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * sqrt_gUxx * sqrt_f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[6] * f_toThe_3_2 * _1_sqrt_gUxx 
		- 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * f_toThe_3_2 * sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[25] * sqrt_f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[25] * f_toThe_3_2 
		+ gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * f_toThe_3_2 * gamma_uu.xx 
		- gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * sqrt_f * gamma_uu.xx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[2] * sqrt_f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[2] * f_toThe_3_2 
		+ gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * f_toThe_3_2 * gamma_uu.xx 
		- gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * sqrt_f * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * sqrt_gUxx * gamma_uu.yy * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * _1_sqrt_gUxx * sqrt_f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * f_toThe_3_2 * _1_sqrt_gUxx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * f_toThe_3_2 * sqrt_gUxx * gamma_uu.yy 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * sqrt_gUxx * gamma_uu.yy * sqrt_f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * _1_sqrt_gUxx * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * f_toThe_3_2 * _1_sqrt_gUxx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * f_toThe_3_2 * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * sqrt_gUxx * gamma_uu.yy * sqrt_f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * _1_sqrt_gUxx * sqrt_f 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * f_toThe_3_2 * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * f_toThe_3_2 * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * sqrt_gUxx * gamma_uu.yy * sqrt_f 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * _1_sqrt_gUxx * sqrt_f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * f_toThe_3_2 * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * f_toThe_3_2 * sqrt_gUxx * gamma_uu.yy 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f_toThe_3_2 * input.ptr[27] * _1_sqrt_gUxx 
		+ 3. * gamma_uu.xy * gamma_uu.xy * f_toThe_3_2 * input.ptr[27] * sqrt_gUxx * gamma_uu.yy 
		- 3. * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.yy * sqrt_f * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * f_toThe_3_2 
		+ 3. * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * f_toThe_3_2 * gamma_uu.yy * gamma_uu.xx 
		+ gamma_uu.xy * gamma_uu.xy * input.ptr[27] * sqrt_gUxx * gamma_uu.yy * sqrt_f 
		+ 3. * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * gamma_uu.yy * f_toThe_3_2 * gamma_uu.xx 
		- 3. * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * gamma_uu.yy * sqrt_f * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * sqrt_f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * f_toThe_3_2 
		- gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * sqrt_f * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * f_toThe_3_2 * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[1] * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[1] * sqrt_f * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[24] * gamma_uu.xy * gamma_uu.xy * sqrt_f 
		+ gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * f_toThe_3_2 * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * sqrt_f * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[24] * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[28] * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * sqrt_f 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * sqrt_gUxx * sqrt_f 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * f_toThe_3_2 * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[28] * f_toThe_3_2 * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[5] * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * sqrt_f 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * sqrt_gUxx * sqrt_f 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * f_toThe_3_2 * sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[5] * f_toThe_3_2 * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.yy * gamma_uu.yy * input.ptr[26] * sqrt_f * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.yy * gamma_uu.yy * input.ptr[26] * f_toThe_3_2 * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.yy * gamma_uu.yy * input.ptr[3] * f_toThe_3_2 * gamma_uu.xx * gamma_uu.xx 
		+ gamma_uu.yy * gamma_uu.yy * input.ptr[3] * sqrt_f * gamma_uu.xx * gamma_uu.xx 
		- f_toThe_3_2 * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[27] 
		+ 2. * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * _1_sqrt_gUxx 
		- 3. * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * sqrt_gUxx * gamma_uu.yy 
		- f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * m * input.ptr[4] * _1_sqrt_gUxx 
		+ 2. * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * m * input.ptr[4] * sqrt_gUxx * gamma_uu.yy 
		+ f_toThe_3_2 * m * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[27] 
		+ f_toThe_3_2 * m * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * _1_sqrt_gUxx 
		- 2. * f_toThe_3_2 * m * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * sqrt_gUxx * gamma_uu.yy 
		+ input.ptr[0] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * input.ptr[0] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ 2. * input.ptr[0] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * f 
		- input.ptr[0] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f 
		+ input.ptr[0] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		- input.ptr[0] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * f 
		- input.ptr[30] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		+ 2. * input.ptr[30] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		- input.ptr[30] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		+ input.ptr[30] * sqrt_gUxx * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * input.ptr[30] * gamma_uu.xx * sqrt_gUxx * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ input.ptr[30] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * f * gamma_uu.yy * gamma_uu.yy 
		- input.ptr[7] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * sqrt_f 
		+ input.ptr[7] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * f_toThe_3_2 * gamma_uu.yy * gamma_uu.yy 
		+ 2. * input.ptr[7] * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * sqrt_f * gamma_uu.xx * gamma_uu.xx 
		- input.ptr[7] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_f * gamma_uu.xx 
		+ input.ptr[7] * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		- 2. * input.ptr[7] * f_toThe_3_2 * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx) / (
		-gamma_uu.xx * sqrt_f * (gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ 2. * gamma_uu.xx * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.xx * f * gamma_uu.yy * gamma_uu.yy));
	resultU.d_lll.x.xy = (2. * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] 
		- 2. * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * gamma_uu.yy 
		- 2. * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] 
		+ 2. * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx * gamma_uu.zz * input.ptr[28] 
		- gamma_uu.xy * gamma_uu.xx * sqrt_gUxx * gamma_uu.zz * input.ptr[28] * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx * gamma_uu.zz * input.ptr[5] 
		+ gamma_uu.xy * gamma_uu.xx * sqrt_gUxx * gamma_uu.zz * input.ptr[5] * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[1] 
		+ gamma_uu.xy * gamma_uu.xz * input.ptr[1] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[24] 
		+ gamma_uu.xy * gamma_uu.xz * input.ptr[24] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[28] * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[28] * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[5] * _1_sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[5] * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.xx 
		+ gamma_uu.xy * input.ptr[26] * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[27] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * gamma_uu.xx 
		+ gamma_uu.xy * input.ptr[3] * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * sqrt_gUxx 
		- gamma_uu.xy * input.ptr[4] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[29] 
		- gamma_uu.xz * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[6] 
		- gamma_uu.xz * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[29] * _1_sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[6] * _1_sqrt_gUxx 
		+ gamma_uu.yy * gamma_uu.yy * input.ptr[25] * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.yy * input.ptr[25] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ gamma_uu.yy * gamma_uu.yy * input.ptr[2] * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.yy * input.ptr[2] * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy 
		- input.ptr[8] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy 
		- input.ptr[8] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ 2. * input.ptr[8] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy) / (
		-gamma_uu.xx * (gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy));
	resultU.d_lll.x.xz = (
		-(gamma_uu.xy * input.ptr[29] * _1_sqrt_gUxx 
		- gamma_uu.xy * input.ptr[6] * _1_sqrt_gUxx 
		+ gamma_uu.xz * input.ptr[28] * _1_sqrt_gUxx 
		- gamma_uu.xz * input.ptr[5] * _1_sqrt_gUxx 
		+ input.ptr[1] 
		+ input.ptr[24] 
		- input.ptr[9] * gamma_uu.xx)) / gamma_uu.xx;
	resultU.d_lll.x.yy = (2. * gamma_uu.xx * gamma_uu.yz * input.ptr[29] * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xx * gamma_uu.xx * gamma_uu.yz * input.ptr[29] * gamma_uu.yy 
		- 2. * gamma_uu.xx * gamma_uu.yz * input.ptr[6] * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xx * gamma_uu.xx * gamma_uu.yz * input.ptr[6] * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.zz * input.ptr[28] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.zz * input.ptr[28] * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.zz * input.ptr[5] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.zz * input.ptr[5] * gamma_uu.yy 
		- gamma_uu.xx * sqrt_gUxx * input.ptr[26] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * input.ptr[26] * gamma_uu.yy 
		- gamma_uu.xx * input.ptr[27] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * input.ptr[27] * gamma_uu.yy 
		- gamma_uu.xx * sqrt_gUxx * input.ptr[3] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * input.ptr[3] * gamma_uu.yy 
		+ gamma_uu.xx * input.ptr[4] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * input.ptr[4] * gamma_uu.yy 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[29] 
		+ 2. * gamma_uu.xy * gamma_uu.xz * input.ptr[29] * gamma_uu.xx * gamma_uu.yy 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[6] 
		- 2. * gamma_uu.xy * gamma_uu.xz * input.ptr[6] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[25] * sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[25] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[2] * sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[2] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xz * input.ptr[14] * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xz * input.ptr[14] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ gamma_uu.xz * input.ptr[14] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		- gamma_uu.xz * input.ptr[19] * _1_sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xz * input.ptr[19] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		- gamma_uu.xz * input.ptr[19] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		+ gamma_uu.xz * input.ptr[1] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xz * input.ptr[1] * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx 
		- gamma_uu.xz * input.ptr[24] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xz * input.ptr[24] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[28] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[28] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[5] * gamma_uu.xx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[5] * gamma_uu.xy * gamma_uu.xy 
		+ input.ptr[11] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * input.ptr[11] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ input.ptr[11] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy) / (sqrt_gUxx * (gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy));
	resultU.d_lll.x.yz = (
		-(gamma_uu.xy * input.ptr[14] * _1_sqrt_gUxx 
		- gamma_uu.xy * input.ptr[19] * _1_sqrt_gUxx 
		- gamma_uu.xz * input.ptr[15] * _1_sqrt_gUxx 
		+ gamma_uu.xz * input.ptr[20] * _1_sqrt_gUxx 
		- input.ptr[12] * sqrt_gUxx 
		- input.ptr[17] * sqrt_gUxx 
		- 2. * input.ptr[29] 
		+ 2. * input.ptr[6])) / (2. * sqrt_gUxx);
	resultU.d_lll.x.zz = (
		-(gamma_uu.xy * input.ptr[15] * _1_sqrt_gUxx 
		- gamma_uu.xy * input.ptr[20] * _1_sqrt_gUxx 
		- input.ptr[18] * sqrt_gUxx 
		- input.ptr[28] 
		+ input.ptr[5])) / sqrt_gUxx;
	resultU.d_lll.y.xx = input.ptr[10];
	resultU.d_lll.y.xy = input.ptr[11];
	resultU.d_lll.y.xz = input.ptr[12];
	resultU.d_lll.y.yy = input.ptr[13];
	resultU.d_lll.y.yz = input.ptr[14];
	resultU.d_lll.y.zz = input.ptr[15];
	resultU.d_lll.z.xx = input.ptr[16];
	resultU.d_lll.z.xy = input.ptr[17];
	resultU.d_lll.z.xz = input.ptr[18];
	resultU.d_lll.z.yy = input.ptr[19];
	resultU.d_lll.z.yz = input.ptr[20];
	resultU.d_lll.z.zz = input.ptr[21];
	resultU.K_ll.xx = (gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[26] 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[26] * f 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[3] 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[3] * f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[29] 
		+ 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[29] * f 
		+ 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * f * gamma_uu.xx * gamma_uu.xx 
		- 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[29] * f * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[6] 
		+ 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * input.ptr[6] * f 
		+ 2. * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * f * gamma_uu.xx * gamma_uu.xx 
		- 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[6] * f * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * gamma_uu.xx * sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[25] * sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[25] * sqrt_gUxx * f 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * gamma_uu.xx * sqrt_gUxx * f 
		+ gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[25] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * f 
		+ gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * gamma_uu.xx * sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[2] * sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * f * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * input.ptr[2] * f * sqrt_gUxx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * input.ptr[2] * f * gamma_uu.xx * sqrt_gUxx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * gamma_uu.yy * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * gamma_uu.yy * gamma_uu.yy * f * gamma_uu.xx * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * f 
		+ 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * f * gamma_uu.yy * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * gamma_uu.yy * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * gamma_uu.yy * gamma_uu.yy * f * gamma_uu.xx * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * f 
		+ 4. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * f * gamma_uu.yy * gamma_uu.xx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * gamma_uu.yy * gamma_uu.xx 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * f * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[28] * f * gamma_uu.yy * gamma_uu.xx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * gamma_uu.yy * gamma_uu.xx 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * f 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * f * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.zz * input.ptr[5] * f * gamma_uu.yy * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * input.ptr[27] 
		- 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * input.ptr[27] * gamma_uu.yy * gamma_uu.xx 
		+ 4. * gamma_uu.xy * gamma_uu.xy * f * input.ptr[27] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * input.ptr[4] 
		+ 4. * gamma_uu.xy * gamma_uu.xy * f * input.ptr[4] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * input.ptr[4] * gamma_uu.yy * gamma_uu.xx 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * sqrt_gUxx 
		- 4. * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		+ 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ 4. * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * f 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * sqrt_gUxx * f 
		- 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] * gamma_uu.xx * sqrt_gUxx * f * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * gamma_uu.yy * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * sqrt_gUxx 
		- 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ 4. * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * f * sqrt_gUxx 
		- 4. * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * f * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy 
		+ 5. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] * f * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * gamma_uu.yy * gamma_uu.xx 
		+ 2. * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		- 2. * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx * sqrt_gUxx 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[1] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * f * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		+ 2. * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[1] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[1] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx 
		+ 2. * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[24] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * f 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[24] * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f 
		+ gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[24] * gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * f 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[28] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * f * gamma_uu.xx * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[28] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[28] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[5] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * f * gamma_uu.xx * gamma_uu.xx 
		+ gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * input.ptr[5] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xz * gamma_uu.xz * gamma_uu.yy * gamma_uu.yy * input.ptr[5] * f * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		- gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[27] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[4] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- f * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[27] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- f * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[4] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- f * m * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] 
		- 3. * f * m * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 3. * f * m * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * gamma_uu.yy * gamma_uu.xx 
		- f * m * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] 
		- 3. * f * m * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		+ 3. * f * m * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * gamma_uu.yy * gamma_uu.xx 
		+ f * m * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[27] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		+ f * m * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * input.ptr[4] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- input.ptr[0] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy 
		+ input.ptr[0] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * f 
		+ input.ptr[0] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ 3. * input.ptr[0] * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- 3. * input.ptr[0] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- input.ptr[0] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.xx 
		+ 3. * input.ptr[0] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- 3. * input.ptr[0] * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- input.ptr[30] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy 
		+ input.ptr[30] * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * f 
		+ input.ptr[30] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx 
		+ 3. * input.ptr[30] * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		- 3. * input.ptr[30] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx 
		- input.ptr[30] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.xx 
		- 3. * input.ptr[30] * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx * gamma_uu.xx 
		+ 3. * input.ptr[30] * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy * gamma_uu.xx * gamma_uu.xx) 
		/ (gamma_uu.xx * (gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 3. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ 3. * gamma_uu.xx * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f 
		+ 3. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy 
		- 3. * gamma_uu.xx * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * f * gamma_uu.yy * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * gamma_uu.yy * f));
	resultU.K_ll.xy = (2. * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[29] 
		- 2. * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.yz * input.ptr[29] * gamma_uu.yy 
		+ 2. * sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.yz * input.ptr[6] 
		- 2. * gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * gamma_uu.yz * input.ptr[6] * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[26] 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.xy * input.ptr[26] * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[3] 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.xy * input.ptr[3] * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * input.ptr[25] 
		- gamma_uu.xx * gamma_uu.yy * input.ptr[25] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy * input.ptr[2] 
		+ gamma_uu.xx * gamma_uu.yy * input.ptr[2] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx * gamma_uu.zz * input.ptr[28] 
		- gamma_uu.xy * gamma_uu.xx * sqrt_gUxx * gamma_uu.zz * input.ptr[28] * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * sqrt_gUxx * gamma_uu.zz * input.ptr[5] 
		- gamma_uu.xy * gamma_uu.xx * sqrt_gUxx * gamma_uu.zz * input.ptr[5] * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[1] 
		- gamma_uu.xy * gamma_uu.xz * input.ptr[1] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[24] 
		+ gamma_uu.xy * gamma_uu.xz * input.ptr[24] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[28] * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[28] * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[5] * _1_sqrt_gUxx 
		+ gamma_uu.xy * gamma_uu.xz * gamma_uu.xz * input.ptr[5] * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[27] * sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[27] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		- gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[4] * sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[4] * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[29] 
		+ gamma_uu.xz * gamma_uu.xx * sqrt_gUxx * gamma_uu.yy * gamma_uu.yy * input.ptr[6] 
		- gamma_uu.xz * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[29] * _1_sqrt_gUxx 
		- gamma_uu.xz * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[6] * _1_sqrt_gUxx) / (
		-sqrt_gUxx * (gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xx * gamma_uu.xy * gamma_uu.xy * gamma_uu.yy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy));
	resultU.K_ll.xz = (
		-(gamma_uu.xy * input.ptr[29] * _1_sqrt_gUxx 
		+ gamma_uu.xy * input.ptr[6] * _1_sqrt_gUxx 
		+ gamma_uu.xz * input.ptr[28] * _1_sqrt_gUxx 
		+ gamma_uu.xz * input.ptr[5] * _1_sqrt_gUxx 
		- input.ptr[1] 
		+ input.ptr[24])) / sqrt_gUxx;
	resultU.K_ll.yy = (sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[25] 
		- gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * input.ptr[25] * gamma_uu.yy 
		- sqrt_gUxx * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * input.ptr[2] 
		+ gamma_uu.xx * sqrt_gUxx * gamma_uu.xy * input.ptr[2] * gamma_uu.yy 
		- sqrt_gUxx * gamma_uu.xz * input.ptr[1] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * sqrt_gUxx * gamma_uu.xz * input.ptr[1] * gamma_uu.yy 
		+ sqrt_gUxx * gamma_uu.xz * input.ptr[24] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * sqrt_gUxx * gamma_uu.xz * input.ptr[24] * gamma_uu.yy 
		- 2. * gamma_uu.xx * gamma_uu.yz * input.ptr[29] * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xx * gamma_uu.xx * gamma_uu.yz * input.ptr[29] * gamma_uu.yy 
		- 2. * gamma_uu.xx * gamma_uu.yz * input.ptr[6] * gamma_uu.xy * gamma_uu.xy 
		+ 2. * gamma_uu.xx * gamma_uu.xx * gamma_uu.yz * input.ptr[6] * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.zz * input.ptr[28] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.zz * input.ptr[28] * gamma_uu.yy 
		- gamma_uu.xx * gamma_uu.zz * input.ptr[5] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * gamma_uu.zz * input.ptr[5] * gamma_uu.yy 
		+ gamma_uu.xx * sqrt_gUxx * input.ptr[26] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * input.ptr[26] * gamma_uu.yy 
		+ gamma_uu.xx * input.ptr[27] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * input.ptr[27] * gamma_uu.yy 
		- gamma_uu.xx * sqrt_gUxx * input.ptr[3] * gamma_uu.xy * gamma_uu.xy 
		+ gamma_uu.xx * gamma_uu.xx * sqrt_gUxx * input.ptr[3] * gamma_uu.yy 
		+ gamma_uu.xx * input.ptr[4] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xx * gamma_uu.xx * input.ptr[4] * gamma_uu.yy 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[29] 
		- 2. * gamma_uu.xy * gamma_uu.xz * input.ptr[29] * gamma_uu.xx * gamma_uu.yy 
		+ 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xz * input.ptr[6] 
		- 2. * gamma_uu.xy * gamma_uu.xz * input.ptr[6] * gamma_uu.xx * gamma_uu.yy 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[28] * gamma_uu.xx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[28] * gamma_uu.xy * gamma_uu.xy 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[5] * gamma_uu.xx * gamma_uu.yy 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[5] * gamma_uu.xy * gamma_uu.xy) / (
		-(gamma_uu.xx * gamma_uu.xx * gamma_uu.yy * gamma_uu.yy 
		+ gamma_uu.xy * gamma_uu.xy * gamma_uu.xy * gamma_uu.xy 
		- 2. * gamma_uu.xy * gamma_uu.xy * gamma_uu.xx * gamma_uu.yy));
	resultU.K_ll.yz = input.ptr[29] 
		+ input.ptr[6];
	resultU.K_ll.zz = input.ptr[28] 
		+ input.ptr[5];
	resultU.Theta = input.ptr[27] 
		+ input.ptr[4];
	resultU.Z_l.x = (
		-(gamma_uu.xy * input.ptr[22] 
		+ gamma_uu.xz * input.ptr[23] 
		- input.ptr[26] * gamma_uu.xx 
		- input.ptr[3] * gamma_uu.xx)) / gamma_uu.xx;
	resultU.Z_l.y = input.ptr[22] 
		+ input.ptr[25] 
		+ input.ptr[2];
	resultU.Z_l.z = input.ptr[1] 
		+ input.ptr[23] 
		+ input.ptr[24];

	return resultU;
}

//notice this paper uses the decomposition alpha A = R Lambda L
// so this computation is for alpha A
cons_t eigen_fluxTransform_<?=side?>(
	constant solver_t* solver,
	eigen_t eig,
	cons_t input,
	real3 pt 
) {
	cons_t results;
	for (int i = 0; i < numStates; ++i) {
		results.ptr[i] = 0;
	}
	
	sym3 gamma_ll = sym3_swap<?=side?>(eig.gamma_ll);
	sym3 gamma_uu = sym3_swap<?=side?>(eig.gamma_uu);
	
	real sqrt_f = eig.sqrt_f;
	real f = sqrt_f * sqrt_f;
	
	real m = solver->m;
	
	results.ptr[0] = f * (gamma_uu.xx * input.ptr[21] 
		+ 2. * gamma_uu.xy * input.ptr[22] 
		+ 2. * gamma_uu.xz * input.ptr[23] 
		+ gamma_uu.yy * input.ptr[24] 
		+ 2. * gamma_uu.yz * input.ptr[25] 
		+ gamma_uu.zz * input.ptr[26] 
		- m * input.ptr[27]);
	results.ptr[1] = 0.;
	results.ptr[2] = 0.;
	results.ptr[3] = input.ptr[21];
	results.ptr[4] = input.ptr[22];
	results.ptr[5] = input.ptr[23];
	results.ptr[6] = input.ptr[24];
	results.ptr[7] = input.ptr[25];
	results.ptr[8] = input.ptr[26];
	results.ptr[9] = 0.;
	results.ptr[10] = 0.;
	results.ptr[11] = 0.;
	results.ptr[12] = 0.;
	results.ptr[13] = 0.;
	results.ptr[14] = 0.;
	results.ptr[15] = 0.;
	results.ptr[16] = 0.;
	results.ptr[17] = 0.;
	results.ptr[18] = 0.;
	results.ptr[19] = 0.;
	results.ptr[20] = 0.;
	results.ptr[21] = 
		-(gamma_uu.yy * input.ptr[10] 
		- gamma_uu.yy * input.ptr[6] 
		+ gamma_uu.yz * input.ptr[11] 
		+ gamma_uu.yz * input.ptr[16] 
		- 2. * gamma_uu.yz * input.ptr[7] 
		+ gamma_uu.zz * input.ptr[17] 
		- gamma_uu.zz * input.ptr[8] 
		- input.ptr[0] 
		+ 2. * input.ptr[28]);
	results.ptr[22] = (2. * gamma_uu.xy * input.ptr[10] 
		- 2. * gamma_uu.xy * input.ptr[6] 
		+ gamma_uu.xz * input.ptr[11] 
		+ gamma_uu.xz * input.ptr[16] 
		- 2. * gamma_uu.xz * input.ptr[7] 
		+ gamma_uu.yz * input.ptr[13] 
		- gamma_uu.yz * input.ptr[18] 
		+ gamma_uu.zz * input.ptr[14] 
		- gamma_uu.zz * input.ptr[19] 
		+ input.ptr[1] 
		- 2. * input.ptr[29]) / 2.;
	results.ptr[23] = (gamma_uu.xy * input.ptr[11] 
		+ gamma_uu.xy * input.ptr[16] 
		- 2. * gamma_uu.xy * input.ptr[7] 
		+ 2. * gamma_uu.xz * input.ptr[17] 
		- 2. * gamma_uu.xz * input.ptr[8] 
		- gamma_uu.yy * input.ptr[13] 
		+ gamma_uu.yy * input.ptr[18] 
		- gamma_uu.yz * input.ptr[14] 
		+ gamma_uu.yz * input.ptr[19] 
		+ input.ptr[2] 
		- 2. * input.ptr[30]) / 2.;
	results.ptr[24] = 
		-(gamma_uu.xx * input.ptr[10] 
		- gamma_uu.xx * input.ptr[6] 
		+ gamma_uu.xz * input.ptr[13] 
		- gamma_uu.xz * input.ptr[18]);
	results.ptr[25] = (
		-(gamma_uu.xx * input.ptr[11] 
		+ gamma_uu.xx * input.ptr[16] 
		- 2. * gamma_uu.xx * input.ptr[7] 
		- gamma_uu.xy * input.ptr[13] 
		+ gamma_uu.xy * input.ptr[18] 
		+ gamma_uu.xz * input.ptr[14] 
		- gamma_uu.xz * input.ptr[19])) / 2.;
	results.ptr[26] = 
		-(gamma_uu.xx * input.ptr[17] 
		- gamma_uu.xx * input.ptr[8] 
		- gamma_uu.xy * input.ptr[14] 
		+ gamma_uu.xy * input.ptr[19]);
	results.ptr[27] = 
		-(gamma_uu.xx * gamma_uu.yy * input.ptr[10] 
		- gamma_uu.xx * gamma_uu.yy * input.ptr[6] 
		+ gamma_uu.xx * gamma_uu.yz * input.ptr[11] 
		+ gamma_uu.xx * gamma_uu.yz * input.ptr[16] 
		- 2. * gamma_uu.xx * gamma_uu.yz * input.ptr[7] 
		+ gamma_uu.xx * gamma_uu.zz * input.ptr[17] 
		- gamma_uu.xx * gamma_uu.zz * input.ptr[8] 
		+ gamma_uu.xx * input.ptr[28] 
		- gamma_uu.xy * gamma_uu.xz * input.ptr[11] 
		- gamma_uu.xy * gamma_uu.xz * input.ptr[16] 
		+ 2. * gamma_uu.xy * gamma_uu.xz * input.ptr[7] 
		- gamma_uu.xy * gamma_uu.yz * input.ptr[13] 
		+ gamma_uu.xy * gamma_uu.yz * input.ptr[18] 
		- gamma_uu.xy * gamma_uu.zz * input.ptr[14] 
		+ gamma_uu.xy * gamma_uu.zz * input.ptr[19] 
		- gamma_uu.xy * gamma_uu.xy * input.ptr[10] 
		+ gamma_uu.xy * input.ptr[29] 
		+ gamma_uu.xy * gamma_uu.xy * input.ptr[6] 
		+ gamma_uu.xz * gamma_uu.yy * input.ptr[13] 
		- gamma_uu.xz * gamma_uu.yy * input.ptr[18] 
		+ gamma_uu.xz * gamma_uu.yz * input.ptr[14] 
		- gamma_uu.xz * gamma_uu.yz * input.ptr[19] 
		- gamma_uu.xz * gamma_uu.xz * input.ptr[17] 
		+ gamma_uu.xz * input.ptr[30] 
		+ gamma_uu.xz * gamma_uu.xz * input.ptr[8]);
	results.ptr[28] = gamma_uu.xy * input.ptr[22] 
		+ gamma_uu.xz * input.ptr[23] 
		+ gamma_uu.yy * input.ptr[24] 
		+ 2. * gamma_uu.yz * input.ptr[25] 
		+ gamma_uu.zz * input.ptr[26] 
		- input.ptr[27];
	results.ptr[29] = 
		-(gamma_uu.xx * input.ptr[22] 
		+ gamma_uu.xy * input.ptr[24] 
		+ gamma_uu.xz * input.ptr[25]);
	results.ptr[30] = 
		-(gamma_uu.xx * input.ptr[23] 
		+ gamma_uu.xy * input.ptr[25] 
		+ gamma_uu.xz * input.ptr[26]);

	return results;
}
<? end ?>

kernel void addSource(
	constant solver_t* solver,
	global cons_t* derivBuf,
	global cons_t* UBuf)
{
	SETBOUNDS_NOGHOST();
	global cons_t* U = UBuf + index;
	global cons_t* deriv = derivBuf + index;

	real det_gamma = sym3_det(U->gamma_ll);
	sym3 gamma_uu = sym3_inv(U->gamma_ll, det_gamma);
	real f = calc_f(U->alpha);	//could be based on alpha...

	//K^i_j = gamma^ik K_kj
	real3x3 K_ul = (real3x3){
<? 
for i,xi in ipairs(xNames) do
?>		.<?=xi?> = (real3){
<? 	for j,xj in ipairs(xNames) do
?>			.<?=xj?> = 0.<?
		for k,xk in ipairs(xNames) do
		?> + gamma_uu.<?=sym(i,k)?> * U->K_ll.<?=sym(k,j)?><? 
		end ?>,
<? 	end
?>		},
<? 
end
?>	};

	real tr_K = real3x3_trace(K_ul);

	//I'm taking this from the 2008 Yano et al "Flux-Vector Splitting..."
	//which itself references (for the source terms) the 2005 Bona et al "Geometrically Motivated ..." 
	//but notice, 2005 Bona paper shows the flux as densitized, so the eigenvalues without any gamma_ll influence
	
	//also note: 2005 Bona et al uses xi.  2008 Yano is based on xi and m... and for the eigenvector decomposition they use xi=0, so they're only based on uses m.
	const real xi = 0.;

	//alpha,t + ... = alpha beta^k a_k - alpha^2 f (K_ll - 2 Theta)
	deriv->alpha += -U->alpha * U->alpha * f * (tr_K - 2. * U->Theta);

	//a_i,t + ... = b_i^k a_k - b_k^k a_i

	//beta^i_,t + ... = beta^k b_k^i - alpha Q^i
	//Q^i = alpha (a^i - d^i + 2 V^i)
	//V^i = d^i - e^i - Z^i
	
	//gamma_ij,t + ... = 2 beta^k d_kij + b_ji + b_ij - 2 alpha K_ij
	deriv->gamma_ll = sym3_add(deriv->gamma_ll, sym3_real_mul(U->K_ll, -2. * U->alpha));

	//d_kij,t + ... = b_k^l d_lij - b^l d_kij

	//conn_ijk = .5 * (g_ij,k + g_ik,j - g_jk,i) 
	//= d_kij + d_jik - d_ijk
	_3sym3 conn_lll = {
<? 
for i,xi in ipairs(xNames) do
?>		.<?=xi?> = (sym3){
<? 	for jk,xjk in ipairs(symNames) do 
		local j,k = from6to3x3(jk)
		local xj,xk = xNames[j],xNames[k]
?>			.<?=xjk?> = U->d_lll.<?=xk?>.<?=sym(i,j)?> + U->d_lll.<?=xj?>.<?=sym(i,k)?> - U->d_lll.<?=xi?>.<?=sym(j,k)?>,
<? 	end 
?>		},
<? 
end
?>	};

	_3sym3 conn_ull = sym3_3sym3_mul(gamma_uu, conn_lll);
	_3sym3 d_ull = sym3_3sym3_mul(gamma_uu, U->d_lll);
	
	//d_llu = d_ij^k = d_ijl * gamma^lk
	real3x3 d_llu[3] = {
<? for i,xi in ipairs(xNames) do
?>		sym3_sym3_mul(U->d_lll.<?=xi?>, gamma_uu),
<? end
?>	};

	//conn^ij_k = gamma^jl conn^i_lk
	_3sym3 conn_uul = {
<? 
	for i,xi in ipairs(xNames) do
?>
		.<?=xi?> = {
<? 
		for jk,xjk in ipairs(symNames) do
			local j,k = from6to3x3(jk)
?>			.<?=xjk?> = 0. <?
			for l,xl in ipairs(xNames) do
				?> + gamma_uu.<?=sym(l,j)?> * conn_ull.<?=xi?>.<?=sym(l,k)?><?
			end	?>,
<? end		
?>		},
<? 
	end
?>	};

	//d_ijk conn^ij_l gamma^kl
	real d_dot_conn = 0.<?
for i,xi in ipairs(xNames) do
	for j,xj in ipairs(xNames) do
		for k,xk in ipairs(xNames) do
			for l,xl in ipairs(xNames) do
?> + U->d_lll.<?=xi?>.<?=sym(j,k)?> * conn_uul.<?=xi?>.<?=sym(j,k)?> * gamma_uu.<?=sym(k,l)?><?
			end
		end
	end
end
?>;

	//d_i = d_ik^k
	real3 d_lll = (real3){
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = sym3_dot(U->d_lll.<?=xi?>, gamma_uu),
<? end
?>	};
	
	//e_i = d^k_ki
	real3 e_l = (real3){
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = 0. <?
	for j,xj in ipairs(xNames) do
?> + d_ull.<?=xj?>.<?=sym(j,i)?><?
	end
?>,
<? end
?>	};

	//d_i = d_ijk gamma^jk
	real3 d_l = _real3(
		sym3_dot(U->d_lll.x, gamma_uu),
		sym3_dot(U->d_lll.y, gamma_uu),
		sym3_dot(U->d_lll.z, gamma_uu));

	real3 d_u = sym3_real3_mul(gamma_uu, d_l);
	real3 e_u = sym3_real3_mul(gamma_uu, e_l);
	real3 a_u = sym3_real3_mul(gamma_uu, U->a_l);
	real3 Z_u = sym3_real3_mul(gamma_uu, U->Z_l);

	//connSq_ij = conn^k_li conn^l_kj
	real connSq_ll[3][3] = {
<? for i,xi in ipairs(xNames) do 
?>		{
<?	for j,xj in ipairs(xNames) do
?>
			0. <?
		for k,xk in ipairs(xNames) do
			for l,xl in ipairs(xNames) do
				?> + conn_ull.<?=xk?>.<?=sym(l,i)?> * conn_ull.<?=xl?>.<?=sym(k,j)?><?
			end
		end
	?>,
<? end 
?>		},
<? end
?>	};

	//K_ik K^k_j
	sym3 KSq_ll = sym3_real3x3_to_sym3_mul(U->K_ll, K_ul);

	real tr_KSq = sym3_dot(KSq_ll, gamma_uu);

	//dsq_ij = d_ikl gamma^lm d^k_mj
	real3x3 dsq = {
<? 
for i,xi in ipairs(xNames) do
?>
		.<?=xi?> = {
<?	for j,xj in ipairs(xNames) do
?>			.<?=xj?> = 
				0.<?
		for k,xk in ipairs(xNames) do
			for l,xl in ipairs(xNames) do
				for m,xm in ipairs(xNames) do
					?> + U->d_lll.<?=xi?>.<?=sym(j,l)?> * gamma_uu.<?=sym(l,m)?> * d_ull.<?=xk?>.<?=sym(m,j)?>
<?
				end
			end
		end	
?>			,
<? 	end
?>		},
<? 
end
?>	};

	/*
	K_ij,t + ... = -K_ij b_k^k + K_ik b_j^k + K_jk b_i^k 
		+ alpha ( 1/2 (1 + xi) ( - a_k Gamma^k_ij + 1/2 (a_i d_j + a_j d_i))
			+ 1/2 (1 - xi) (a_k d^k_ij - 1/2 (a_j (2 e_i - d_i) + a_i (2 e_j - d_j))
				+ 2 (d_ir^m d^r_mj + d_jr^m d^r_mi) - 2 e_k (d_ij^k + d_ji^k)
			)
			+ (d_k + a_k - 2 Z_k) Gamma^k_ij - Gamma^k_mj Gamma^m_ki - (a_i Z_j + a_j Z_i)
			- 2 K^k_i K_kj + (K_ll - 2 Theta) K_ij
		) - 8 pi alpha (S_ij - 1/2 (S - tau) gamma_ij)
	*/
<? for ij,xij in ipairs(symNames) do 
	local i,j = from6to3x3(ij)
	local xi,xj = xNames[i], xNames[j]
?>
	deriv->K_ll.<?=xij?> += 
		//TODO shift terms
	U->alpha * (
		.5 * (1. + xi) * (
		<? for k,xk in ipairs(xNames) do ?> 
			- U->a_l.<?=xk?> * conn_ull.<?=xk?>.<?=xij?>
		<? end ?>
			+ .5 * (U->a_l.<?=xi?> * d_l.<?=xj?> + U->a_l.<?=xj?> * d_l.<?=xi?>)
		)
		+ .5 * (1. - xi) * (0.
		<? for k,xk in ipairs(xNames) do ?> 
			+ a_u.<?=xk?> * U->d_lll.<?=xk?>.<?=xij?>
		<? end ?>
			- .5 * ( 
				U->a_l.<?=xj?> * (2. * e_l.<?=xi?> - d_l.<?=xi?>) 
				+ U->a_l.<?=xi?> * (2. * e_l.<?=xj?> - d_l.<?=xj?>)
			)
			+ 2. * (dsq.v[<?=i-1?>].s[<?=j-1?>] + dsq.v[<?=j-1?>].s[<?=i-1?>])
		<? for k,xk in ipairs(xNames) do ?> 
			- 2. * e_u.<?=xk?> * (U->d_lll.<?=xi?>.<?=sym(j,k)?> + U->d_lll.<?=xj?>.<?=sym(i,k)?>)
		<? end ?>
		)
		<? for k,xk in ipairs(xNames) do ?> 
		+ (d_lll.<?=xk?> + U->a_l.<?=xk?> - 2. * U->Z_l.<?=xk?>) * conn_ull.<?=xk?>.<?=xij?>
		<? end ?>
		- connSq_ll[<?=j-1?>][<?=i-1?>]
		- U->a_l.<?=xi?> * U->Z_l.<?=xj?>
		- U->a_l.<?=xj?> * U->Z_l.<?=xi?>
		- 2. * KSq_ll.<?=xij?>
		+ U->K_ll.<?=xij?> * (tr_K - 2. * U->Theta)
	)
		// TODO source terms
	;
<? end
?>
		
	/*
	Theta,t + ... = 
		-Theta b_k^k 
		+ 1/2 alpha (
			2 a_k (d^k - e^k - 2 Z^k) 
			+ d_krs Gamma^krs 
			- d^k (d_k - 2 Z_k)
			- K^k_r K^r_k 
			+ K (K - 2 Theta)
		)
		- 8 pi alpha tau
	
	d_ijk conn^ijk
	= d_ijk (d^kij + d^jik - d^ijk)
	*/
	deriv->Theta += .5 * U->alpha * (0. 
		<? for k,xk in ipairs(xNames) do ?> 
		- d_u.<?=xk?> * (d_lll.<?=xk?> - 2. * U->Z_l.<?=xk?>)
		<? end ?>	
		+ d_dot_conn
		- tr_KSq
		+ tr_K * (tr_K - 2. * U->Theta)
	);

	// K^k_j Gamma^j_ki
	real3 K_times_conn = (real3){
<? 
for i,xi in ipairs(xNames) do
?>		.<?=xi?> = 0.<?
	for j,xj in ipairs(xNames) do
		for k,xk in ipairs(xNames) do
?> + K_ul.v[<?=k-1?>].s[<?=j-1?>] * conn_ull.<?=xj?>.<?=sym(k,i)?><?
		end
	end	?>,
<? 
end
?>	};

	/*
	Z_i,t + ... = 
		-Z_i b_k^k 
		+ Z_k b_i^k 
		- 8 pi alpha S_i
		+ alpha (
			a_i (K_ll - 2 Theta) 
			- a_k K^k_i 
			- K^k_r Gamma^r_ki 
			+ K^k_i (d_k - 2 Z_k)
		)
	*/
	<? for i,xi in ipairs(xNames) do ?> 
	deriv->Z_l.<?=xi?> += U->alpha * (
		U->a_l.<?=xi?> * (tr_K - 2. * U->Theta)
		<? for k,xk in ipairs(xNames) do ?> 
		- a_u.<?=xk?> * U->K_ll.<?=sym(i,k)?>
		+ U->K_ll.<?=sym(i,k)?> * (d_u.<?=xk?> - 2. * Z_u.<?=xk?>)
		<? end ?>
		- K_times_conn.<?=xi?>
	);
	<? end ?>

	sym3 R_ll = (sym3){
<? for ij,xij in ipairs(symNames) do
	local i,j = from6to3x3(ij)
	local xi, xj = xNames[i], xNames[j]
?>		.<?=xij?> = 0.
<? 	for k,xk in ipairs(xNames) do 
?>
			+ conn_ull.<?=xk?>.<?=xij?> * (d_l.<?=xk?> - 2. * e_l.<?=xk?>)

<?		for l,xl in ipairs(xNames) do
?>			+ 2. * d_llu[<?=k-1?>].<?=xi?>.<?=xl?> * d_ull.<?=xk?>.<?=sym(j,l)?>
			- 2. * d_llu[<?=k-1?>].<?=xi?>.<?=xl?> * d_llu[<?=l-1?>].<?=xj?>.<?=xk?>
			+ 2. * d_llu[<?=k-1?>].<?=xi?>.<?=xl?> * d_llu[<?=j-1?>].<?=xl?>.<?=xk?>
			+ 2. * d_llu[<?=i-1?>].<?=xl?>.<?=xk?> * d_llu[<?=k-1?>].<?=xj?>.<?=xl?>
			- 3. * d_llu[<?=i-1?>].<?=xl?>.<?=xk?> * d_llu[<?=j-1?>].<?=xk?>.<?=xl?>
<? 		end
	end
?>		,
<? end
?>	};

	
	
	//H = 1/2 (R + K^2 - K_ij K^ij) - 8 pi rho
	real R = sym3_dot(R_ll, gamma_uu);
	U->H = .5 * (R + tr_K * tr_K - tr_KSq) <? 
if calcConstraints then ?>
	- 8. * M_PI * U->rho <? 
end ?>;

}
