/*
Font "Numerical Hydrodynamics and Magnetohydrodynamics in General Relativity" 2008 
*/

//everything matches the default except the params passed through to calcCellMinMaxEigenvalues
__kernel void calcDT(
	__global real* dtBuf,
	const __global cons_t* UBuf,
	const __global prim_t* primBuf
) {
	SETBOUNDS(0,0);
	if (OOB(2,2)) {
		dtBuf[index] = INFINITY;
		return;
	}
	
	cons_t U = UBuf[index];
	prim_t prim = primBuf[index];
	real rho = prim.rho;
	real eInt = prim.eInt;
	real3 vL = lower(prim.v);
	real vSq = real3_dot(prim.v, vL);
	real P = calc_P(rho, eInt);
	real h = calc_h(rho, P, eInt);
	real csSq = gamma * P / (rho * h);
	real cs = sqrt(csSq);
	
	real dt = INFINITY;
	//for (int side = 0; side < dim; ++side) {
	<? for side=0,solver.dim-1 do ?>{
		//for the particular direction
		real vi = prim.v.s<?=side?>;
		real viSq = vi * vi;
		
		// Marti 1998 eqn 19
		// also Marti & Muller 2008 eqn 68
		// also Font 2008 eqn 106
		const real betaUi = betaU.s<?=side?>;
		real discr = sqrt((1. - vSq) * (gammaUx.x * (1. - vSq * csSq) - viSq * (1. - csSq)));
		real lambdaMin = (vi * (1. - csSq) - cs * discr) / (1. - vSq * csSq) * alpha - betaUi;
		real lambdaMax = (vi * (1. - csSq) + cs * discr) / (1. - vSq * csSq) * alpha - betaUi;
		lambdaMin = min((real)0., lambdaMin);
		lambdaMax = max((real)0., lambdaMax);
		dt = min(dt, dx<?=side?>_at(i) / (fabs(lambdaMax - lambdaMin) + (real)1e-9));
	}<? end ?>
	
	dtBuf[index] = dt; 
}

__kernel void calcEigenBasis(
	__global real* waveBuf,
	__global eigen_t* eigenBuf,
	const __global prim_t* primBuf
) {
	SETBOUNDS(2,1);
	
	int indexR = index;
	prim_t primR = primBuf[indexR];
	
	//for (int side = 0; side < dim; ++side) {
	<? for side=0,solver.dim-1 do ?>{
		const int side = <?=side?>;
		
		int indexL = index - stepsize[side];
		prim_t primL = primBuf[indexL];

<? if true then -- arithmetic averaging ?>
		prim_t avg = (prim_t){
			.rho = .5 * (primL.rho + primR.rho),
			.v = real3_scale(real3_add(primL.v, primR.v), .5),
			.eInt = .5 * (primL.eInt + primR.eInt),
		};
<? -- else -- Roe-averaging, Font 2008 eqn 38 ?>
<? end ?>

		real rho = avg.rho;
		real3 v = avg.v;
		real eInt = avg.eInt;
	
		<? if side == 1 then ?>
		v = _real3(v.y, -v.x, v.z);	// -90' rotation to put the y axis contents into the x axis
		<? elseif side == 2 then ?>
		v = _real3(v.z, v.y, -v.x);	//-90' rotation to put the z axis in the x axis
		<? end ?>

//TODO NOTE if you're swapping vector components, you have to swap metric components too 

		real3 vL = lower(v);
		real vSq = real3_dot(v, vL);
		real oneOverW2 = 1. - vSq;
		real oneOverW = sqrt(oneOverW2);
		real W = 1. / oneOverW;
		real W2 = 1. / oneOverW2;
		real P = gamma_1 * rho * eInt;
		real h = 1. + eInt + P / rho;

		real hW = h * W;
		real hSq = h * h;

		//just after 2008 Font eqn 107:
		//h cs^2 = chi + P / rho^2 kappa = dp/drho + p / rho^2 dp/deInt
		// = (gamma-1) eInt + P/rho^2 (gamma-1) rho  for an ideal gas
		// = (gamma-1) (eInt + P/rho)
		// = 1/rho ( (gamma-1) rho eInt + (gamma-1) P )
		// = 1/rho ( P + (gamma-1) P)
		// = gamma P / rho
		real vxSq = v.x * v.x;
		real csSq = gamma * P / (rho * h);
		real cs = sqrt(csSq);

		const real betaUi = betaU.s<?=side?>;
		real discr = sqrt((1. - vSq) * ((1. - vSq * csSq) - vxSq * (1. - csSq)));
		real lambdaMin = (v.x * (1. - csSq) - cs * discr) / (1. - vSq * csSq) * alpha * alpha - betaUi;
		real lambdaMax = (v.x * (1. - csSq) + cs * discr) / (1. - vSq * csSq) * alpha * alpha - betaUi;

		int intindex = side + dim * index;	
		__global real* wave = waveBuf + numWaves * intindex;
		wave[0] = lambdaMin;
		wave[1] = v.x * alpha - betaUi;
		wave[2] = v.x * alpha - betaUi;
		wave[3] = v.x * alpha - betaUi;
		wave[4] = lambdaMax;

		__global eigen_t* eigen = eigenBuf + intindex;	

		real LambdaMin = (lambdaMin + betaUi) / alpha;	//2008 Font eqn 114
		real LambdaMax = (lambdaMax + betaUi) / alpha;	//2008 Font eqn 114
		real ATildeMinus = (gammaUx.x - vxSq) / (gammaUx.x - v.x * LambdaMin);	//2008 Font eqn 113
		real ATildePlus  = (gammaUx.x - vxSq) / (gammaUx.x - v.x * LambdaMax);	//2008 Font eqn 113
		real VMinus = (v.x - LambdaMin) / (gammaUx.x - v.x * LambdaMin);	//2008 Font eqn 113
		real VPlus = (v.x - LambdaMax) / (gammaUx.x - v.x * LambdaMax);	//2008 Font eqn 113
		real CMinus = vL.x - VMinus;	//2008 Font eqn 112
		real CPlus = vL.x - VPlus;	//2008 Font eqn 112

		real kappa = calc_dP_deInt(rho, eInt);	//2008 Font note just after eqn 107
		real kappaTilde = kappa / rho;	//2008 Font eqn 112.  
		real Kappa = kappaTilde / (kappaTilde - csSq);	//2008 Font eqn 112.  
		//Kappa = h;	//approx for ideal gas
		
		__global real* evR = eigen->evR;
		//min col	2008 Font eqn 111, r-
		evR[0 + numStates * 0] = 1.;
		evR[1 + numStates * 0] = hW * CMinus;
		evR[2 + numStates * 0] = hW * vL.y;
		evR[3 + numStates * 0] = hW * vL.z;
		evR[4 + numStates * 0] = hW * ATildeMinus - 1.;
		//mid col (normal)  2008 Font eqn 108: r0,1
		evR[0 + numStates * 1] = Kappa / hW;
		evR[1 + numStates * 1] = vL.x;
		evR[2 + numStates * 1] = vL.y;
		evR[3 + numStates * 1] = vL.z;
		evR[4 + numStates * 1] = 1. - Kappa / hW;
		//mid col (tangent A)	2008 Font eqn 109: r0,2
		evR[0 + numStates * 2] = W * vL.y;
		evR[1 + numStates * 2] = h * (gamma_y.x + 2. * W2 * vL.y * vL.x);
		evR[2 + numStates * 2] = h * (gamma_y.y + 2. * W2 * vL.y * vL.y);
		evR[3 + numStates * 2] = h * (gamma_y.z + 2. * W2 * vL.y * vL.z);
		evR[4 + numStates * 2] = W * vL.y * (2. * hW - 1.);
		//mid col (tangent B)	2008 Font eqn 110: r0,3
		evR[0 + numStates * 3] = W * vL.z;
		evR[1 + numStates * 3] = h * (gamma_z.x + 2. * W2 * vL.x * vL.z);
		evR[2 + numStates * 3] = h * (gamma_z.y + 2. * W2 * vL.y * vL.z);
		evR[3 + numStates * 3] = h * (gamma_z.z + 2. * W2 * vL.z * vL.z);
		evR[4 + numStates * 3] = W * vL.z * (2. * hW - 1.);
		//max col 
		evR[0 + numStates * 4] = 1.;
		evR[1 + numStates * 4] = hW * CPlus;
		evR[2 + numStates * 4] = hW * vL.y;
		evR[3 + numStates * 4] = hW * vL.z;
		evR[4 + numStates * 4] = hW * ATildePlus - 1.;

		real Gamma_xx = gamma_y.y * gamma_z.z - gamma_y.z * gamma_y.z;	//2008 Font eqn 123. looks like gamma gamma^xx.  srhd approx 1
		real Gamma_xy = gamma_y.z * gamma_x.z - gamma_x.y * gamma_z.z;	//2008 Font eqn 123. looks like gamma gamma^xy.  srhd approx 0
		real Gamma_xz = gamma_x.y * gamma_y.z - gamma_x.z * gamma_y.y;	//2008 Font eqn 123. looks like gamma gamma^xz.  srhd approx 0
		real xi = Gamma_xx - gammaDet * vxSq;//2008 Font eqn 121
		real Delta = hSq * hW * (Kappa - 1.) * (CPlus - CMinus) * xi;	//2008 Font eqn 121
		
		__global real* evL = eigen->evL; 
		//min row	2008 Font eqn 118
		real scale;
#if 0 	//2008 Marti & Muller
		scale = hSq / Delta;
		evL[0 + numStates * 0] = scale * (hW * ATildePlus * (v.x - lambdaMax) - v.x - W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (v.x - ATildePlus * lambdaMax) + Kappa * ATildePlus * lambdaMax);
		evL[0 + numStates * 1] = scale * (1. + W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (1. - ATildePlus) - Kappa * ATildePlus);
		evL[0 + numStates * 2] = scale * (W2 * v.y * (2. * Kappa - 1.) * ATildePlus * (v.x - lambdaMax));
		evL[0 + numStates * 3] = scale * (W2 * v.z * (2. * Kappa - 1.) * ATildePlus * (v.x - lambdaMax));
		evL[0 + numStates * 4] = scale * (-v.x - W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (v.x - ATildePlus * lambdaMax) + Kappa * ATildePlus * lambdaMax);
#endif
#if 1	//2008 Font eqn 118
		scale = hSq / Delta;
		real l5minus = (1 - Kappa) * (-gammaDet * v.x + VPlus * (W2 * xi - Gamma_xx)) - Kappa * W2 * VPlus * xi;
		evL[0 + numStates * 0] = scale * (hW * VPlus * xi + l5minus);
		evL[0 + numStates * 1] = scale * (Gamma_xx * (1 - Kappa * ATildePlus) + (2. * Kappa - 1.) * VPlus * (W2 * v.x * xi - Gamma_xx * v.x));
		evL[0 + numStates * 2] = scale * (Gamma_xy * (1 - Kappa * ATildePlus) + (2. * Kappa - 1.) * VPlus * (W2 * v.y * xi - Gamma_xy * v.x));
		evL[0 + numStates * 3] = scale * (Gamma_xz * (1 - Kappa * ATildePlus) + (2. * Kappa - 1.) * VPlus * (W2 * v.z * xi - Gamma_xz * v.x));
		evL[0 + numStates * 4] = scale * l5minus;
#endif
		//mid normal row	2008 Font eqn 115
		scale = W / (Kappa - 1.);
		evL[1 + numStates * 0] = scale * (h - W);
		evL[1 + numStates * 1] = scale * (W * v.x);
		evL[1 + numStates * 2] = scale * (W * v.y);
		evL[1 + numStates * 3] = scale * (W * v.z);
		evL[1 + numStates * 4] = scale * (-W);
		//mid tangent A row	2008 Font eqn 116
		scale = 1. / (h * xi);
		evL[2 + numStates * 0] = scale * (-gamma_z.z * vL.y + gamma_y.z * vL.z);
		evL[2 + numStates * 1] = scale * v.x * (gamma_z.z * vL.y - gamma_y.z * vL.z);
		evL[2 + numStates * 2] = scale * (gamma_z.z * (1. - v.x * vL.x) + gamma_x.z * vL.z * v.x);
		evL[2 + numStates * 3] = scale * (-gamma_y.z * (1. - vL.x * v.x) - gamma_x.z * vL.y * v.x);
		evL[2 + numStates * 4] = scale * (-gamma_z.z * vL.y + gamma_y.z * vL.z);
		//mid tangent B row	2008 Font eqn 117
		evL[3 + numStates * 0] = scale * (-gamma_y.y * vL.z + gamma_y.z * vL.y);
		evL[3 + numStates * 1] = scale * v.x * (gamma_y.y * vL.z - gamma_y.z * vL.y);
		evL[3 + numStates * 2] = scale * (-gamma_y.z * (1. - vL.x * v.x) - gamma_x.y * vL.z * v.x);
		evL[3 + numStates * 3] = scale * (gamma_y.y * (1. - vL.x * v.x) + gamma_x.y * vL.y * v.x);
		evL[3 + numStates * 4] = scale * (-gamma_y.y * vL.z + gamma_y.z * vL.y);
		//max row	2008 Font eqn 118
#if 0 	//from 2008 Marti & Muller
		scale = -hSq / Delta;
		evL[4 + numStates * 0] = scale * (hW * ATildeMinus * (v.x - lambdaMin) - v.x - W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (v.x - ATildeMinus * lambdaMin) + Kappa * ATildeMinus * lambdaMin);
		evL[4 + numStates * 1] = scale * (1. + W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (1. - ATildeMinus) - Kappa * ATildeMinus);
		evL[4 + numStates * 2] = scale * (W2 * v.y * (2. * Kappa - 1.) * ATildeMinus * (v.x - lambdaMin));
		evL[4 + numStates * 3] = scale * (W2 * v.z * (2. * Kappa - 1.) * ATildeMinus * (v.x - lambdaMin));
		evL[4 + numStates * 4] = scale * (-v.x - W2 * (vSq - vxSq) * (2. * Kappa - 1.) * (v.x - ATildeMinus * lambdaMin) + Kappa * ATildeMinus * lambdaMin);
#endif
#if 1	//2008 Font eqn 118
		scale = -hSq / Delta;
		real l5plus = (1 - Kappa) * (-gammaDet * v.x + VMinus * (W2 * xi - Gamma_xx)) - Kappa * W2 * VMinus * xi;
		evL[4 + numStates * 0] = scale * (h * W * VMinus * xi + l5plus);
		evL[4 + numStates * 1] = scale * (Gamma_xx * (1 - Kappa * ATildeMinus) + (2. * Kappa - 1.) * VMinus * (W2 * v.x * xi - Gamma_xx * v.x));
		evL[4 + numStates * 2] = scale * (Gamma_xy * (1 - Kappa * ATildeMinus) + (2. * Kappa - 1.) * VMinus * (W2 * v.y * xi - Gamma_xy * v.x));
		evL[4 + numStates * 3] = scale * (Gamma_xz * (1 - Kappa * ATildeMinus) + (2. * Kappa - 1.) * VMinus * (W2 * v.z * xi - Gamma_xz * v.x));
		evL[4 + numStates * 4] = scale * l5plus;
#endif

		<? if side == 1 then ?>
		for (int i = 0; i < numStates; ++i) {
			real tmp;
			//-90' rotation applied to the LHS of incoming velocity vectors, to move their y axis into the x axis
			// is equivalent of a -90' rotation applied to the RHS of the flux jacobian A
			// and A = Q V Q-1 for Q = the right eigenvectors and Q-1 the left eigenvectors
			// so a -90' rotation applied to the RHS of A is a +90' rotation applied to the RHS of Q-1 the left eigenvectors
			//and while a rotation applied to the LHS of a vector rotates the elements of its column vectors, a rotation applied to the RHS rotates the elements of its row vectors 
			//each row's y <- x, x <- -y
			tmp = evL[i + numStates * cons_Sx];
			evL[i + numStates * cons_Sx] = -evL[i + numStates * cons_Sy];
			evL[i + numStates * cons_Sy] = tmp;
			//a -90' rotation applied to the RHS of A must be corrected with a 90' rotation on the LHS of A
			//this rotates the elements of the column vectors by 90'
			//each column's x <- y, y <- -x
			tmp = evR[cons_Sx + numStates * i];
			evR[cons_Sx + numStates * i] = -evR[cons_Sy + numStates * i];
			evR[cons_Sy + numStates * i] = tmp;
		}
		<? elseif side == 2 then ?>
		for (int i = 0; i < numStates; ++i) {
			real tmp;
			tmp = evL[i + numStates * cons_Sx];
			evL[i + numStates * cons_Sx] = -evL[i + numStates * cons_Sz];
			evL[i + numStates * cons_Sz] = tmp;
			tmp = evR[cons_Sx + numStates * i];
			evR[cons_Sx + numStates * i] = -evR[cons_Sz + numStates * i];
			evR[cons_Sz + numStates * i] = tmp;
		}
		<? end ?>
	}<? end ?>
}

__kernel void constrainU(
	__global cons_t* UBuf
) {
	SETBOUNDS(0,0);

	__global cons_t* U = UBuf + index;
	
	U->D = max(U->D, (real)DMin);
	U->tau = max(U->tau, (real)tauMin);

	U->D = min(U->D, (real)DMax);
	U->tau = min(U->tau, (real)tauMax);
}

//TODO update to include alphas, betas, and gammas
__kernel void updatePrims(
	__global prim_t* primBuf,
	const __global cons_t* UBuf
) {
	SETBOUNDS(2,1);
	
	const __global cons_t* U = UBuf + index;
	real D = U->D;
	real3 S = U->S;
	real tau = U->tau;

	__global prim_t* prim = primBuf + index;
	real3 v = prim->v;

	real3 SL = lower(S);
	real SLen = sqrt(real3_dot(S,SL));
	real PMin = max(SLen - tau - D + SLen * solvePrimVelEpsilon, solvePrimPMinEpsilon);
	real PMax = gamma_1 * tau;
	PMax = max(PMax, PMin);
	real P = .5 * (PMin + PMax);

	for (int iter = 0; iter < solvePrimMaxIter; ++iter) {
		real vLen = SLen / (tau + D + P);
		real vSq = vLen * vLen;
		real W = 1. / sqrt(1. - vSq);
		real eInt = (tau + D * (1. - W) + P * (1. - W*W)) / (D * W);
		real rho = D / W;
		real f = gamma_1 * rho * eInt - P;
		real csSq = gamma_1 * (tau + D * (1. - W) + P) / (tau + D + P);
		real df_dP = vSq * csSq - 1.;
		real newP = P - f / df_dP;
		newP = max(newP, PMin);
		real PError = fabs(1. - newP / P);
		P = newP;
		if (PError < solvePrimStopEpsilon) {
			v = real3_scale(S, 1. / (tau + D + P));
			real3 vL = lower(v);
			vSq = real3_dot(v, vL);
			W = 1. / sqrt(1. - vSq);
			rho = D / W;
			rho = max(rho, (real)rhoMin);
			rho = min(rho, (real)rhoMax);
			eInt = P / (rho * gamma_1);
			eInt = min(eInt, (real)eIntMax);
			prim->rho = rho;
			prim->v = v;
			prim->eInt = eInt;
//printf("cell %d finished with prims = %f %f %f\n", index, rho, v.x, eInt);
			return;
		}
	}
}
