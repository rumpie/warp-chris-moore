--[[
Baumgarte & Shapiro "Numerical Relativity: Solving Einstein's Equations on the Computer" 2010
Alcubierre "Introduction to Numerical Relativity" 2008

then I'm applying 2017 Ruchlin changes..
separate gammaBar_ll = gammaHat_ll + epsilon_ll
--]]

local file = require 'ext.file'
local class = require 'ext.class'
local table = require 'ext.table'
local template = require 'template'
local symmath = require 'symmath'
local EinsteinEqn = require 'eqn.einstein'
local makestruct = require 'eqn.makestruct'
local applyCommon = require 'common'

local makePartials = require 'eqn.makepartial'
local makePartial = makePartials.makePartial
local makePartial2 = makePartials.makePartial2

local BSSNOKFiniteDifferenceEquation = class(EinsteinEqn)
BSSNOKFiniteDifferenceEquation.name = 'BSSNOK finite difference' 
BSSNOKFiniteDifferenceEquation.hasEigenCode = true
BSSNOKFiniteDifferenceEquation.hasCalcDTCode = true
BSSNOKFiniteDifferenceEquation.hasFluxFromConsCode = true
BSSNOKFiniteDifferenceEquation.useConstrainU = true
BSSNOKFiniteDifferenceEquation.useSourceTerm = true

--[[
args:
	useShift = 'none'
				'GammaDriver'
				'HyperbolicGammaDriver' (default)
	useChi (default true)
--]]
function BSSNOKFiniteDifferenceEquation:init(args)
	-- options:
	-- needs to be defined up front
	-- otherwise rebuild intVars based on it ...
	self.useShift = args.useShift or 'HyperbolicGammaDriver'

	-- use chi = 1/psi instead of phi, as described in 2006 Campanelli 
	-- it should be used with the hyperbolic gamma driver
	if args.useChi ~= nil then
		self.useChi = args.useChi
	else
		self.useChi = true
	end

	local intVars = table{
		{alpha = 'real'},			-- 1
		{beta_u = 'real3'},         -- 3: beta^i
		{epsilon_ll = 'sym3'},    -- 6: gammaBar_ij, only 5 dof since det gammaBar_ij = 1
																									 
		self.useChi 
			and {chi = 'real'}		-- 1
			or {phi = 'real'},		-- 1
		
		{K = 'real'},               -- 1
		{ABar_ll = 'sym3'},       -- 6: ABar_ij, only 5 dof since ABar^k_k = 0
		{connBar_u = 'real3'},      -- 3: connBar^i = gammaBar^jk connBar^i_jk = -partial_j gammaBar^ij
	}
	if self.useShift == 'HyperbolicGammaDriver' then
		intVars:insert{B_u = 'real3'}
	end

	self.consVars = table()
	:append(intVars)
	:append{
		--hyperbolic variables:
		--real3 a;			//3: a_i
		--_3sym3 dBar;		//18: dBar_ijk, only 15 dof since dBar_ij^j = 0
		--real3 Phi;			//3: Phi_i

		--stress-energy variables:
		{rho = 'real'},		--1: n_a n_b T^ab
		{S_u = 'real3'},			--3: -gamma^ij n_a T_aj
		{S_ll = 'sym3'},			--6: gamma_i^c gamma_j^d T_cd

		--constraints:
		{H = 'real'},				--1
		{M_u = 'real3'},			--3

		-- aux variable
		{gammaBar_uu = 'sym3'},		--6
	}
	self.numIntStates = makestruct.countScalars(intVars)
	
	-- call construction / build structures	
	BSSNOKFiniteDifferenceEquation.super.init(self, args)
end


function BSSNOKFiniteDifferenceEquation:createInitState()
	BSSNOKFiniteDifferenceEquation.super.createInitState(self)
	self:addGuiVars{
		{name='constrain_det_gammaBar_ll', value=true, compileTime=true},
		{name='constrain_tr_ABar_ll', value=true, compileTime=true},
		{name='calc_H_and_M', value=true, compileTime=true},
		{name='diffuseSigma', value=.01},
		{name='alphaMin', value=1e-7},
	}
end

function BSSNOKFiniteDifferenceEquation:getTemplateEnv()
	local derivOrder = 2 * self.solver.numGhost
	return applyCommon{
		eqn = self,
		solver = self.solver,
		makePartial = function(...) return makePartial(derivOrder, self.solver, ...) end,
		makePartial2 = function(...) return makePartial2(derivOrder, self.solver, ...) end,
	}
end

function BSSNOKFiniteDifferenceEquation:getCommonFuncCode()
	return template([[

//gammaBar_ij = gammaHat_ij + epsilon_ij
sym3 calc_gammaBar_ll(global const <?=eqn.cons_t?>* U, real3 x) {
	sym3 gammaHat_ll = coord_g(x);
	return sym3_add(gammaHat_ll, U->epsilon_ll);
}

//det(gammaBar_ij) = det(gammaHat_ij + epsilon_ij)
//however det(gammaHat_ij) == det(gammaBar_ij) by the eqn just before (6) in 2017 Ruchlin
real calc_det_gammaBar_ll(real3 x) {
	return sqrt_det_g_grid(x);
}

void setFlatSpace(global <?=eqn.cons_t?>* U, real3 x) {
	U->alpha = 1.;
	U->beta_u = real3_zero;
	U->epsilon_ll = sym3_zero;
<? if eqn.useChi then 
?>	U->chi = 1;
<? else
?>	U->phi = 0;
<? end
?>	U->K = 0;
	U->ABar_ll = sym3_ident;
	U->connBar_u = real3_zero;
<? if eqn.useShift == 'HyperbolicGammaDriver' then
?>	U->B_u = real3_zero;
<? end
?>	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	real det_gammaBar_ll = calc_det_gammaBar_ll(x);
	U->gammaBar_uu = sym3_inv(gammaBar_ll, det_gammaBar_ll);

	//what to do with the constraint vars and the source vars?
	U->rho = 0;
	U->S_u = real3_zero;
	U->S_ll = sym3_zero;
	U->H = 0;
	U->M_u = real3_zero;
}

<? if eqn.useChi then
?>#define calc_exp_neg4phi(U) ((U)->chi)
<? else
?>#define calc_exp_neg4phi(U) (exp(-4. * (U)->phi))
<? end
?>

//|g| = exp(12 phi) |g_grid|
real calc_det_gamma(global const <?=eqn.cons_t?>* U, real3 x) {
	real exp_neg4phi = calc_exp_neg4phi(U);
	real det_gamma = sqrt_det_g_grid(x) / (exp_neg4phi * exp_neg4phi * exp_neg4phi);
	return det_gamma;
}

sym3 calc_gamma_uu(global const <?=eqn.cons_t?>* U) {
	real exp_neg4phi = calc_exp_neg4phi(U);
	sym3 gamma_uu = sym3_real_mul(U->gammaBar_uu, exp_neg4phi);
	return gamma_uu;
}

sym3 calc_gamma_ll(global const <?=eqn.cons_t?>* U, real3 x) {
	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	real exp_4phi = 1. / calc_exp_neg4phi(U);
	sym3 gamma_ll = sym3_real_mul(gammaBar_ll, exp_4phi);
	return gamma_ll;
}

]], {eqn=self})
end

function BSSNOKFiniteDifferenceEquation:getInitStateCode()
	return template([[
kernel void initState(
	constant <?=solver.solver_t?>* solver,
	global <?=eqn.cons_t?>* UBuf
) {
	SETBOUNDS(numGhost,numGhost);
	real3 x = cell_x(i);
	real3 xc = coordMap(x);
	real3 mids = real3_real_mul(real3_add(solver->mins, solver->maxs), .5);
	
	global <?=eqn.cons_t?>* U = UBuf + index;

	real alpha = 1.;
	real3 beta_u = real3_zero;
	sym3 gamma_ll = sym3_ident;
	sym3 K_ll = sym3_zero;
	real rho = 0.;

	<?=code?>

	U->alpha = alpha;
	U->beta_u = beta_u;

	real det_gamma_ll = sym3_det(gamma_ll);
	sym3 gamma_uu = sym3_inv(gamma_ll, det_gamma_ll);
	
	//det(gammaBar_ij) == det(gammaHat_ij)
	real det_gammaBar_ll = calc_det_gammaBar_ll(x); 

	//gammaBar_ij = e^(-4phi) gamma_ij
	//real exp_neg4phi = exp(-4 * U->phi);
	real exp_neg4phi = cbrt(det_gammaBar_ll / det_gamma_ll);

<? if eqn.useChi then 
?>	U->chi = exp_neg4phi;
<? else
?>	U->phi = log(det_gamma / det_gammaGrid) / 12.;
<? end 
?>

	sym3 gammaBar_ll = sym3_real_mul(gamma_ll, exp_neg4phi);
	sym3 gammaHat_ll = coord_g(x);
	U->epsilon_ll = sym3_sub(gammaBar_ll, gammaHat_ll);
	U->gammaBar_uu = sym3_inv(gammaBar_ll, det_gammaBar_ll);

<? if false then ?>
<? for _,x in ipairs(xNames) do
?>	U->a.<?=x?> = calc_a_<?=x?>(x.x, x.y, x.z);
<? end ?>
<? end ?>

	U->K = sym3_dot(K_ll, gamma_uu);
	sym3 A_ll = sym3_sub(K_ll, sym3_real_mul(gamma_ll, 1./3. * U->K));
	U->ABar_ll = sym3_real_mul(A_ll, exp_neg4phi);
	
	U->rho = rho;
	U->S_u = real3_zero;
	U->S_ll = sym3_zero;
	
	U->H = 0.;
	U->M_u = real3_zero;
}

//after popularing gammaBar_ll, use its finite-difference derivative to initialize connBar_u
kernel void initDerivs(
	constant <?=solver.solver_t?>* solver,
	global <?=eqn.cons_t?>* UBuf
) {
	SETBOUNDS(numGhost,numGhost);
	real3 x = cell_x(i);
	global <?=eqn.cons_t?>* U = UBuf + index;
	
<?=makePartial('gammaBar_uu', 'sym3')?>

	//connBar^i = -gammaBar^ij_,j
<? for i,xi in ipairs(xNames) do
?>	U->connBar_u.<?=xi?> =<?
	for j,xj in ipairs(xNames) do
?> - partial_gammaBar_uul[<?=j-1?>].<?=sym(i,j)?><?
	end
?>;
<? end
?>
}
]], table(self:getTemplateEnv(), {
		code = self.initState:initState(self.solver),
	}))
end

BSSNOKFiniteDifferenceEquation.solverCodeFile = 'eqn/bssnok-fd.cl'

function BSSNOKFiniteDifferenceEquation:getEigenTypeCode()
	return template([[
typedef struct { char unused; } <?=eqn.eigen_t?>;
]], {eqn=self})
end

BSSNOKFiniteDifferenceEquation.predefinedDisplayVars = {
	'U alpha',
	'U beta_u mag',
	'U epsilon_ll norm',
	'U chi',
	'U ABar_ll tr weighted',
	'U connBar_u mag',
	'U K',
	'U Delta_u mag',
	'U H',
	'U M_u mag',
	'U det gammaBar - det gammaHat',
	'U det gamma_ij based on phi',
	'U volume',
	'U f',
	'U gamma_ll tr weighted',
}

function BSSNOKFiniteDifferenceEquation:getDisplayVars()	
	local vars = BSSNOKFiniteDifferenceEquation.super.getDisplayVars(self)

	vars:insert{['det gammaBar - det gammaHat'] = [[
	*value = sym3_det(calc_gammaBar_ll(U, x)) - calc_det_gammaBar_ll(x);
]]}	-- for logarithmic displays
	vars:insert{['det gamma based on phi'] = [[
	real exp_neg4phi = calc_exp_neg4phi(U);
	*value = 1. / (exp_neg4phi * exp_neg4phi * exp_neg4phi);   
]]}
	
	local derivOrder = 2 * self.solver.numGhost
	vars:append{
		{S = '*value = sym3_dot(U->S_ll, calc_gamma_uu(U));'},
		{volume = '*value = U->alpha * calc_det_gamma(U, x);'},
	
--[[ expansion:
2003 Thornburg:  ... from Wald ...
Theta = n^i_;i + K_ij n^i n^j - K
= n^i_,i + Gamma^i_ji n^j + K_ij (n^i n^j - gamma^ij)
... in ADM: n^i = -beta^i / alpha ...
= (-beta^i / alpha)_,i + Gamma^i_ji (-beta^j / alpha) + K_ij (beta^i beta^j / alpha^2 - gamma^ij)
= -beta^i_,i / alpha
	+ beta^i alpha_,i / alpha^2
	- beta^i (1/2 |g|_,i / |g|) / alpha
	+ K_ij beta^i beta^j / alpha^2
	- K

Gamma^j_ij = (ln sqrt(g))_,i = .5 (ln g)_,i = .5 g_,i / g

(det g)_,i / (det g)
... using phi ...
=  exp(12 phi)_,i / exp(12 phi)
= 12 exp(12 phi) phi_,i / exp(12 phi)
= 12 phi_,i
... using chi ...
= (chi^-3)_,i / (chi^-3)
= -3 chi_,i / chi^4 / (chi^-3)
= -3 chi_,i / chi
--]]
		{expansion = template([[
<? if eqn.useChi then
?>	<?=makePartial('chi', 'real')?>
<? else 
?>	<?=makePartial('phi', 'real')?>
<? end
?>
	<?=makePartial('alpha', 'real')?>
	<?=makePartial('beta_u', 'real3')?>
	real tr_partial_beta = 0. <?
for i,xi in ipairs(xNames) do
?> + partial_beta_ul[<?=i-1?>].<?=xi?><?
end ?>;

	real exp_4phi = 1. / calc_exp_neg4phi(U);

	//gamma_ij = exp(4 phi) gammaBar_ij
	sym3 gamma_ll = sym3_real_mul(calc_gammaBar_ll(U, x), exp_4phi);

	//K_ij = exp(4 phi) ABar_ij + 1/3 gamma_ij K 
	sym3 K_ll = sym3_add(
		sym3_real_mul(U->ABar_ll, exp_4phi),
		sym3_real_mul(gamma_ll, U->K/3.));

	*value = -tr_partial_beta / U->alpha
<? 
for i,xi in ipairs(xNames) do
?>		 + U->beta_u.<?=xi?> * partial_alpha_l[<?=i-1?>] / (U->alpha * U->alpha) 
		 - U->beta_u.<?=xi?> * partial_alpha_l[<?=i-1?>] / (U->alpha * U->alpha) 
<? 	if eqn.useChi then
?>		- 3. * partial_chi_l[<?=i-1?>] / U->chi
<? 	else
?>		+ 12. * partial_phi_l[<?=i-1?>]
<? 	end
		?> * -.5 * U->beta_u.<?=xi?> / U->alpha
<?	for j,xj in ipairs(xNames) do
?>		+ K_ll.<?=sym(i,j)?> * U->beta_u.<?=xi?> * U->beta_u.<?=xj?> / (U->alpha * U->alpha)
<?	end
end
?>		- U->K;
]], 			applyCommon{
					eqn = self,
					solver = self.solver,
					makePartial = function(...) return makePartial(derivOrder, self.solver, ...) end,
				}

			)
		},
		
		{f = '*value = calc_f(U->alpha);'},
		{['df/dalpha'] = '*value = calc_dalpha_f(U->alpha);'},
		{gamma_ll = [[
	real exp_4phi = 1. / calc_exp_neg4phi(U);
	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	*valuesym3 = sym3_real_mul(gammaBar_ll, exp_4phi);
]], type='sym3'},
		{K_ll = [[
	real exp_4phi = 1. / calc_exp_neg4phi(U);
	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	*valuesym3 = sym3_real_mul(
		sym3_add(
			U->ABar_ll,
			sym3_real_mul(gammaBar_ll, U->K / 3.)
		), exp_4phi);
]], type='sym3'},

		--[[ ADM geodesic equation spatial terms:
		-Gamma^i_tt = 
			- gamma^ij alpha_,j

			+ alpha^-1 (
				gamma^ij beta^l gamma_kl beta^k_,j
				+ 1/2 gamma^ij gamma_kl,j beta^k beta^l
				- beta^i_,t
				- gamma^ij beta^k gamma_jk,t

				+ alpha^-1 beta^i (
					alpha_,t
					+ beta^j alpha_,j

					+ alpha^-1 (
						beta^i 1/2 beta^j beta^k gamma_jk,t
						- beta^i 1/2 beta^j beta^k beta^l gamma_kl,j
						- beta^i beta^j beta^l gamma_kl beta^k_,j
					)
				)
			)

		substitute 
		alpha_,t = -alpha^2 f K + beta^j alpha_,j
		beta^k_,t = B^k
		gamma_jk,t = -2 alpha K_jk + gamma_jk,l beta^l + gamma_lj beta^l_,k + gamma_lk beta^l_,j
		--]]
		{
			gravity = template([[
	<?=makePartial('alpha', 'real')?>

	real _1_alpha = 1. / U->alpha;

	sym3 gamma_uu = calc_gamma_uu(U);
	real3 partial_alpha_u = sym3_real3_mul(gamma_uu, *(real3*)partial_alpha_l);		//alpha_,j gamma^ij = alpha^,i
	
<? for i,xi in ipairs(xNames) do
?>	value_real3-><?=xi?> = -partial_alpha_u.<?=xi?>;
<? end
?>

<? if eqn.useShift ~= 'none' then ?>

	<?=makePartial('beta_u', 'real3')?>

	<?=makePartial('epsilon_ll', 'sym3')?>
<? if not eqn.useChi then ?>
	
	real exp_4phi = 1. / calc_exp_neg4phi(U);

	//gamma_ij = exp(4 phi) gammaBar_ij
	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	sym3 gamma_ll = sym3_real_mul(gammaBar_ll, exp_4phi);

	//gamma_ij,k = exp(4 phi) gammaBar_ij,k + 4 phi,k exp(4 phi) gammaBar_ij
	<?=makePartial('phi', 'real')?>
	_3sym3 partial_gamma_lll = {
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = sym3_add(
			sym3_real_mul(partial_epsilon_lll[<?=i-1?>], exp_4phi),
			sym3_real_mul(gammaBar_ll, 4. * exp_4phi * partial_phi_l[<?=i-1?>])),
<? end
?>	};

<? else -- useChi ?>

	//chi = exp(-4 phi)
	real _1_chi = 1. / U->chi;
	
	//gamma_ij = 1/chi gammaBar_ij
	sym3 gammaBar_ll = calc_gammaBar_ll(U, x);
	sym3 gamma_ll = sym3_real_mul(gammaBar_ll, _1_chi);
	
	//gamma_ij,k = 1/chi gammaBar_ij,k - chi,k / chi^2 gammaBar_ij
	<?=makePartial('chi', 'real')?>
	_3sym3 partial_gamma_lll = {
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = sym3_sub(
			sym3_real_mul(partial_epsilon_lll[<?=i-1?>], _1_chi),
			sym3_real_mul(gammaBar_ll, partial_chi_l[<?=i-1?>] * _1_chi * _1_chi)),
<? end
?>	};

<? end -- useChi ?>

	//TODO
	real dt_alpha = 0.;
	sym3 dt_gamma_ll = sym3_zero;
	
	real partial_alpha_dot_beta = real3_dot(U->beta_u, *(real3*)partial_alpha_l);	//beta^j alpha_,j

	real3 beta_l = sym3_real3_mul(gamma_ll, U->beta_u);								//beta^j gamma_ij
	real3 beta_dt_gamma_l = sym3_real3_mul(dt_gamma_ll, U->beta_u);					//beta^j gamma_ij,t
	real beta_beta_dt_gamma = real3_dot(U->beta_u, beta_dt_gamma_l);				//beta^i beta^j gamma_ij,t
	
	real3 beta_dt_gamma_u = sym3_real3_mul(gamma_uu, beta_dt_gamma_l);				//gamma^ij gamma_jk,t beta^k

	//beta^i beta^j beta^k gamma_ij,k
	real beta_beta_beta_partial_gamma = 0.<?
for i,xi in ipairs(xNames) do
?> + U->beta_u.<?=xi?> * real3_weightedLenSq(U->beta_u, partial_gamma_lll.<?=xi?>)<?
end ?>;

	//beta_j beta^j_,i
	real3 beta_dbeta_l = (real3){
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = real3_dot(beta_l, partial_beta_ul[<?=i-1?>]),
<? end
?>	};

	//beta_j beta^j_,i beta^i
	real beta_beta_dbeta = real3_dot(U->beta_u, beta_dbeta_l);

	//beta_j beta^j_,k gamma^ik
	real3 beta_dbeta_u = sym3_real3_mul(gamma_uu, beta_dbeta_l);

	//gamma_kl,j beta^k beta^l
	real3 beta_beta_dgamma_l = (real3){
<? for i,xi in ipairs(xNames) do
?>		.<?=xi?> = real3_weightedLenSq(U->beta_u, partial_gamma_lll.<?=xi?>),
<? end
?>	};

	real3 beta_beta_dgamma_u = sym3_real3_mul(gamma_uu, beta_beta_dgamma_l);

<? for i,xi in ipairs(xNames) do
?>	value_real3-><?=xi?> +=
		_1_alpha * (
			beta_dbeta_u.<?=xi?>
			+ .5 * beta_beta_dgamma_u.<?=xi?>	
			- U->B_u.<?=xi?>
			- beta_dt_gamma_u.<?=xi?>

			+ _1_alpha * U->beta_u.<?=xi?> * (
				.5 * dt_alpha
				+ partial_alpha_dot_beta

				+ _1_alpha * (
					.5 * beta_beta_dt_gamma
					- .5 * beta_beta_beta_partial_gamma 
					- beta_beta_dbeta
				)
			)
		)
	; 
<? end
?>
<? end	-- eqn.useShift ?>
]],				applyCommon{
					eqn = self,
					solver = self.solver,
					makePartial = function(...) return makePartial(derivOrder, self.solver, ...) end,
				}
			), 
			type = 'real3',
		},
	}
	
	return vars
end

function BSSNOKFiniteDifferenceEquation:fillRandom(epsilon)
	local ptr = BSSNOKFiniteDifferenceEquation.super.fillRandom(self, epsilon)
	local solver = self.solver
	for i=0,solver.numCells-1 do
		ptr[i].alpha = ptr[i].alpha + 1
	end
	solver.UBufObj:fromCPU(ptr)
	return ptr
end

return BSSNOKFiniteDifferenceEquation
