-- slowly making this the home of all initial conditions...
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local clnumber = require 'cl.obj.number'
local template = require 'template'
local materials = require 'materials'
local ffi = require 'ffi'
local InitCond = require 'init.init'

local common = require 'common'()
local xNames = common.xNames
local minmaxs = common.minmaxs

local function quadrantProblem(args)
	args.initState = function(self, solver)
		solver.cfl = .475
		solver:setBoundaryMethods'freeflow'
		local function build(i)
			local q = args[i]
			return table.map(q, function(v,k,t)
				return k..'='..v..';', #t+1
			end):concat' '
		end
		return [[
	bool xp = x.x > mids.x;
	bool yp = x.y > mids.y;
	if (yp) {
		if (xp) {
			]]..build(1)..[[
		} else {
			]]..build(2)..[[	
		}
	} else {
		if (!xp) {
			]]..build(3)..[[
		} else {
			]]..build(4)..[[
		}
	}
]]
	end
	return args
end

-- right now 'center' is provided in cartesian coordinates (i.e. post-applying coordMap)
local SelfGravProblem = class()

function SelfGravProblem:getRadiusCode(source)
	return clnumber(source.radius)
end

function SelfGravProblem:init(args)
	self.args = args
	self.getRadiusCode = args.getRadiusCode
end

function SelfGravProblem:__call(initState, solver)
	local args = self.args

	solver.useGravity = true
	--[[ the boundary might not be necessary/appropriate, esp for cylindrical geometry
	solver:setBoundaryMethods'freeflow'
	--]]

	return template([[
	rho = .1;
	P = 1;
	//v[i] = .1 * noise * crand();
	<? for i,source in ipairs(sources) do ?>{
		real3 xc = coordMap(x);
		real3 delta = real3_sub(xc, _real3(
			<?=clnumber(source.center[1])?>,
			<?=clnumber(source.center[2])?>,
			<?=clnumber(source.center[3])?>));
		real distSq = real3_lenSq(delta);
		real radius = <?=self:getRadiusCode(source)?>;
		if (distSq < radius * radius) {
			<?=source.inside or 'rho = P = 1;'?>
		}
	}<? end ?>
]], {
		self = self,
		sources = args.sources,
		clnumber = clnumber,
	})
end

local realptr = ffi.new'realparam[1]'
local function real(x)
	realptr[0] = x
	return realptr
end

--[[
args:
	solver = solver
	side = which side, default xmin
	dir = which direction the wave will point. default 'x'
	amplitude = wave amplitude.  default 1
	frequency = wave frequency.  default 1
--]]
local function addMaxwellOscillatingBoundary(args)
	local solver = assert(args.solver)
	local side = args.side or 'xmin'
	local amplitude = args.amplitude or 1
	local frequency = args.frequency or 1
	local dir = args.dir or 'y'
	-- this args is only for the UBuf boundary program -- not calle for the Poisson boundary program
	function solver:getBoundaryProgramArgs()
		-- i'm completely overriding this
		-- so I can completely override boundaryMethods for the solver boundary kernel
		-- yet not for the poisson boundary kernel
		local boundaryMethods = table(self.boundaryMethods)
		-- TODO get the oscillations on 2D 256x256 in the upper left corner to stop
		--local oldxmin = select(2, next(solver.boundaryOptions[boundaryMethods.xmin]))
		boundaryMethods[side] = function(args)
			local gridSizeSide = 'solver->gridSize.'..xNames[args.side]
			local U = args.array('buf', args.index(
				side:sub(-3) == 'min' and 'j+1' or (gridSizeSide..'-numGhost-1-j')
			))
			-- TODO put the old code here
			return 
				--oldxmin(args) .. 
				template([[
<?
	local epsSrc = 
		(require 'eqn.twofluid-emhd-lingr'.is(eqn) 
			or require 'eqn.glm-maxwell'.is(eqn))
		and U or 'solver'
?>
	
	<?=U?>.B = <?=vec3?>_zero;
	<?=U?>.D = <?=vec3?>_zero;
	<?=U?>.D.<?=dir?> = <?=real_mul?>(
		<?=mul?>(<?=epsSrc?>.sqrt_1_eps, <?=epsSrc?>.sqrt_1_eps),
		<?=amplitude?> * sin(2. * M_PI * <?=frequency?> * t)); 
]], table(solver.eqn:getTemplateEnv(), {
		U = U,
		eqn = self.eqn,
		frequency = clnumber(frequency),
		amplitude = clnumber(amplitude),
		dir = dir,
	}))
		end

		-- same as super 
		-- except with extraAgs
		-- and using boundaryMethods instead of self.boundaryMethods
		-- (which I leave alone so Poisson can deal with it)
		return {
			type = self.eqn.cons_t,
			
			-- TODO just give the solver a parameter 't' ?
			-- give it a parameter 'dt' while you're at it
			-- that would save on a few kernel parameters
			
			extraArgs = {'real t'},
			-- remap from enum/combobox int values to functions from the solver.boundaryOptions table
			methods = table.map(boundaryMethods, function(v)
				if type(v) == 'function' then return v end
				return (select(2, next(self.boundaryOptions[v])))
			end),
			mirrorVars = self.eqn.mirrorVars,
		}
	end
	
	-- this runs before refreshBoundaryProgram, so lets hijack refreshBoundaryProgram and add in our time-based boundary conditions
	local oldBoundary = solver.boundary
	function solver:boundary()
assert(self.t)		
		for _,obj in ipairs(self.boundaryKernelObjs) do
			obj.obj:setArg(2, real(self.t))
		end
		oldBoundary(self)
	end
end

local initStates = table{
	{
		name = 'constant',
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		initState = function(self, solver)
			return [[
	rho = 1;
	P = 1;
]]
		end,
	},
	{
		name = 'linear',
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		initState = function(self, solver)
			return [[
	real3 xc = coordMap(x);
	rho = 1. + xc.x;
	P = 1. + xc.x;
]]
		end,
	},
	{
		name = 'constant with velocity',
		initState = function(self, solver) 
			return [[
	rho=1;
	v.x=1;
	v.y=1;
	v.z=1;
	P=1;
]]
		end,
	},
	{
		name = 'linear',
		initState = function(self, solver)
			return '	rho=2+x.x; P=1;'
		end,
	},
	
	-- 2017 Zingale section 7.9.3
	{
		name = 'gaussian',
		guiVars = {
			{name = 'init_rho0', value = 1e-3},
			{name = 'init_rho1', value = 1},
			{name = 'init_sigma', value = .1},
			{name = 'init_u0', value = 1},
			{name = 'init_v0', value = 1},
			{name = 'init_P0', value = 1e-6},
		},
		initState = function(self, solver)
			return template([[
	real3 xc = coordMap(x);
	real xSq = real3_lenSq(xc);
	rho = (solver->init_rho1 - solver->init_rho0) * exp(-xSq / (solver->init_sigma*solver->init_sigma)) + solver->init_rho0;
	v.x = solver->init_u0;
	v.y = solver->init_v0;
	P = solver->init_P0;
]],		{
			clnumber = clnumber,
		})
		end,
	},
	
	{
		name = 'advect wave',
		mins = {0,0,0},
		maxs = {1,1,1},
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		guiVars = {
			{name = 'init_v0x', value = 1},
			{name = 'init_v0y', value = 0},
			{name = 'init_rho0', value = 1},
			{name = 'init_rho1', value = 3.2e-1},
			{name = 'init_P0', value = 1},
		},
		initState = function(self, solver)
			solver:setBoundaryMethods{
				xmin = 'periodic',
				xmax = 'periodic',
				ymin = 'periodic',
				ymax = 'periodic',
				zmin = 'periodic',
				zmax = 'periodic',
			}
			return [[
	real3 xc = coordMap(x);
	real xmin = solver->mins.x;
	real xmax = solver->maxs.x;
	real width = xmax - xmin;
	real k0 = 2. * M_PI / width;
	rho = solver->init_rho0 + solver->init_rho1 * sin(k0 * (xc.x - xmin));
	v.x = solver->init_v0x;
	v.y = solver->init_v0y;
	v.z = 0;
	P = solver->init_P0;
	ePot = 0;
]]
		end,
		-- TODO combine this with above, use a parser / transpiler to convert between Lua and OpenCL, and just write one equation?
		-- TODO TODO do this with all math everywhere, and analyze the dependency graph of variables and automatically slice out what GPU calculations should be buffered / automatically inline equations
		exactSolution = function(solver, x, t)
			local solverPtr = solver.solverPtr
			local k0 = 2 * math.pi / (solverPtr.maxs.x - solverPtr.mins.x)
			local rho = solverPtr.init_rho0 + solverPtr.init_rho1 * math.sin(k0 * (x - t))
			local mx = 1 * rho
			local my = 0
			local mz = 0
			local P = 1
			-- hmm, only good with cartesian geometry
			local mSq = mx * mx + my * my + mz * mz 
			local EKin = .5 * mSq  / rho
			local EInt = P / (solverPtr.heatCapacityRatio - 1)
			local ETotal = EKin + EInt
			return rho, mx, my, mz, ETotal
		end,
	},

	{
		name = 'Sod',
-- [[ test-case vars
		guiVars = {
			{name = 'init_rhoL', value = 1},
			{name = 'init_PL', value = 1},
			{name = 'init_rhoR', value = .125},
			{name = 'init_PR', value = .1},
		},
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
--]]		
--[[ real-world vars ... which are a few orders higher, and therefore screw up the backward-euler solver
-- 		which means, todo, redo the backward euler error metric so it is independent of magnitude ... ?   seems I removed that for another numerical error reason.
		guiVars = {
			{name = 'init_rhoL', value = 8 * materials.Air.seaLevelDensity},	-- kg / m^3
			{name = 'init_PL', value = 10 * materials.Air.seaLevelPressure},	-- Pa = N / m^2
			{name = 'init_rhoR', value = materials.Air.seaLevelDensity},
			{name = 'init_PR', value = materials.Air.seaLevelPressure},
		},
		overrideGuiVars = {
			heatCapacityRatio = materials.Air.C_p / materials.Air.C_v,	-- ~1.4
		},
--]]
--[[
some various initial conditions from 2012 Toro "The HLLC Riemann Solver" http://marian.fsik.cvut.cz/~bodnar/PragueSum_2012/Toro_2-HLLC-RiemannSolver.pdf 
Test	ρ L		u L		    p L		 ρ R		u R		    p R		   	
1		1.0		0.75		1.0		 0.125		0.0		    0.1		
2		1.0		-2.0		0.4		 1.0		2.0		    0.4		
3		1.0		0.0		    1000.0	 1.0		0.0		    0.01		     
4		5.99924	19.5975		460.894	 5.99242	-6.19633	46.0950				    	
5		1.0		-19.59745	1000.0	 1.0		-19.59745	0.01			    	
6		1.4		0.0		    1.0		 1.0		0.0		    1.0		
7		1.4		0.1		    1.0		 1.0		0.1		    1.0		
--]]
		initState = function(self, solver)
			return template([[
#if 0	//offsetting the region	so I can see if there's a problem at the boundary ...
	lhs = true 
<?
for i=1,solver.dim do
	local xi = xNames[i]
?> 		&& x.<?=xi?> > .75 * solver->mins.<?=xi?> + .25 * solver->maxs.<?=xi?>
		&& x.<?=xi?> < .25 * solver->mins.<?=xi?> + .75 * solver->maxs.<?=xi?>
<?
end
?>;
#endif

	rho = lhs ? solver->init_rhoL : solver->init_rhoR;
	P = lhs ? solver->init_PL : solver->init_PR;
]], {
		solver = solver,
		xNames = xNames,
	})
		end,
		
		-- http://www.itam.nsc.ru/flowlib/SRC/sod.f
		-- TODO it might be more efficient to hand this function the array, and have it return an array
		-- or at least have it calculate certain values up front before iterating across all x's
		exactSolution = function(solver, x, t)
			local solverPtr = solver.solverPtr
			-- TODO initial condition object to share these values with initialization
			local rhoL = solverPtr.init_rhoL
			local rhoR = solverPtr.init_rhoR
			local PL = solverPtr.init_PL
			local PR = solverPtr.init_PR
			local vL = 0
			local vR = 0
			local gamma = solverPtr.heatCapacityRatio
			
			local muSq = (gamma - 1)/(gamma + 1)
			local K = PL / rhoL^gamma

			local CsL = math.sqrt(gamma * PL / rhoL)
			local CsR = math.sqrt(gamma * PR / rhoR)

			local solveP3 = function()
				-- hmm, for some reason, using the symmath-compiled code is resulting in memory corruption
				-- it's not like symmath compile performs any ffi allocations ... maybe something is getting freed prematurely?
				-- or maybe I'm passing in a cdata that is a number, and luajit is not agreeing with some implicit conversion to a Lua number somewhere?  I don't know...
				-- so to fix this, I'll just print out the code and inline it myself
				--[=[ using symmath-compiled functions
				local symmath = require 'symmath'
				local P3, PL, PR, CsL, CsR, gamma = symmath.vars('P3', 'PL', 'PR', 'CsL', 'CsR', 'gamma')
				local f = -2*CsL*(1 - (P3/PL)^((-1 + gamma)/(2*gamma)))/(CsR*(-1 + gamma)) + (-1 + P3/PR)*((1 - muSq)/(gamma*(muSq + P3/PR)))^.5
				local df_dP3 = f:diff(P3)()	
				local vars = {P3, PL, PR, CsL, CsR, gamma}
				local f_func, f_code = f:compile(vars)
				local df_dP3_func, df_dP3_code = df_dP3:compile(vars)
				--print(f_code)
				--print(df_dP3_code)
				--os.exit()
				--]=]
				local P3 = .5 * (PL + PR)
				local epsilon = 1e-16	-- this is the limit for the sod.f before it oscillates
				while true do
					--[=[ using symmath-compiled functions
					local dP3 = -f_func(P3) / df_dP3_func(P3)
					--]=]
					-- [=[ using inlining
					local f = ((((-2 * CsL) * (1 - ((P3 / PL) ^ ((-1 + gamma) / (2 * gamma))))) / (CsR * (-1 + gamma))) + ((-1 + (P3 / PR)) * ((0.75 / (gamma * (0.25 + (P3 / PR)))) ^ 0.5))) 
					local df_dP3 = ((-((((((1.5 * math.sqrt(0.75) * CsR * PR * (gamma ^ 1.5)) - ((0.75 ^ 1.5) * CsR * PR * math.sqrt(gamma))) - ((0.75 ^ 1.5) * CsR * (gamma ^ 2.5) * PR)) - (0.5 * P3 * math.sqrt(0.75) * CsR * math.sqrt(gamma))) - (0.5 * P3 * math.sqrt(0.75) * CsR * (gamma ^ 2.5))) + (((P3 * math.sqrt(0.75) * CsR * (gamma ^ 1.5)) - (0.25 * (PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ (((-1) - gamma) / (2 * gamma))) * (PR ^ 1.5) * math.sqrt((P3 + (0.25 * PR))))) - ((PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ ((-(1 - gamma)) / (2 * gamma))) * math.sqrt(PR) * math.sqrt((P3 + (0.25 * PR))))) + (0.5 * (PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ (((-1) - gamma) / (2 * gamma))) * (PR ^ 1.5) * gamma * math.sqrt((P3 + (0.25 * PR)))) + (((2 * (PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ ((-(1 - gamma)) / (2 * gamma))) * math.sqrt(PR) * gamma * math.sqrt((P3 + (0.25 * PR)))) - (0.25 * (PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ (((-1) - gamma) / (2 * gamma))) * (gamma ^ 2) * (PR ^ 1.5) * math.sqrt((P3 + (0.25 * PR))))) - ((PL ^ ((1 - gamma) / (2 * gamma))) * CsL * (P3 ^ ((-(1 - gamma)) / (2 * gamma))) * (gamma ^ 2) * math.sqrt(PR) * math.sqrt((P3 + (0.25 * PR))))))) / (math.sqrt(PR) * CsR * ((P3 + (0.25 * PR)) ^ 1.5) * gamma * ((1 - (2 * gamma)) + (gamma ^ 2)))) 
					local dP3 = -f / df_dP3
					--]=]
					if math.abs(dP3) <= epsilon then break end
					if not math.isfinite(dP3) then error('delta is not finite! '..tostring(dP3)) end
					P3 = P3 + dP3 
				end
				return P3
			end

			local P3 = solveP3()
			local P4 = P3

			local rho3 = rhoL * (P3 / PL) ^ (1 / gamma)

			local v3 = vR + 2 * CsL / (gamma - 1) * (1 - (P3 / PL)^((gamma - 1)/(2*gamma)))
			local v4 = v3

			local rho4 = rhoR * (P4 + muSq * PR) / (PR + muSq * P4)

			local vshock = v4 * rho4 / (rho4 - rhoR)
			local vtail = CsL - v4 / (1 - muSq)

		
			-- between regions 1 and 2
			local s1 = -CsL	

			-- between regions 2 and 3
			-- http://www.itam.nsc.ru/flowlib/SRC/sod.f
			local s2 = -vtail

			local s3 = v3	-- between regions 3 and 4

			-- between regions 4 and 5 ...
			local s4 = vshock

			--print('wavespeeds:',s1,s2,s3,s4)

			local rho, vx, P
			local xi = x / t
			if xi < s1 then
				rho = rhoL
				vx = vL
				P = PL
			elseif xi < s2 then
				vx = (1 - muSq) * (x/t + CsL)
				
				-- Dullemon:
				--rho = (rhoL^gamma / (gamma * PL) * (v2(x) - x/t)^2)^(1/(gamma-1))
				-- http://www.itam.nsc.ru/flowlib/SRC/sod.f
				rho = rhoL * (-muSq * (x / (CsL * t)) + (1 - muSq))^(2/(gamma-1))

				-- Dullemon:
				--P = K * rho2^gamma
				-- http://www.itam.nsc.ru/flowlib/SRC/sod.f
				P = PL * (-muSq * (x / (CsL * t)) + (1 - muSq)) ^ (2*gamma/(gamma-1))
			elseif xi < s3 then
				rho = rho3
				vx = v3
				P = P3
			elseif xi < s4 then
				rho = rho4
				vx = v4
				P = P4
			else
				rho = rhoR
				vx = vR
				P = PR
			end

			local vy = 0
			local vz = 0
			local EInt = P * (gamma - 1)
			local EKin = .5 * rho * (vx*vx + vy*vy + vz*vz)
			local ETotal = EKin + EInt
			return rho, rho * vx, rho * vy, rho * vz, ETotal
		end,
	},
	
	{
		name = 'Sedov',
		guiVars = {
			{name = 'init_rho0', value = 1},
			{name = 'init_P0', value = 1},
			{name = 'init_P1', value = 1e+3},
		},
	
		initState = function(self, solver)
			return [[
	rho = solver->init_rho0;
	P = (i.x == solver->gridSize.x/2 && i.y == solver->gridSize.y/2 && i.z == solver->gridSize.z/2) ? solver->init_P1 : solver->init_P0;
]]
		end,
	},
	
	-- http://www-troja.fjfi.cvut.cz/~liska/CompareEuler/compare8/node36_ct.html
	{
		name = 'Noh',
--[[ I don't think this is setting correctly.  cell_x is still [-1,1]^n
		mins = {0,0,0},
		maxs = {1,1,1},
--]]		
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		initState = function(self, solver)
			-- TODO add boundary condition of exact solution
			return [[
	rho = 1.;
	P = 1e-6;
	real r = real3_len(x);
	v = real3_real_mul(x, -1./r);
]]
		end,
	},
	
	-- http://www-troja.fjfi.cvut.cz/~liska/CompareEuler/compare8/node36_ct.html
	{
		name = 'implosion',
		mins = {0,0,0},
		maxs = {.3, .3, .3},
		overrideGuiVars = {
			heatCapacityRatio = 1.4,
		},
		initState = function(self, solver)
			solver:setBoundaryMethods'mirror'
			return [[
	if (x.y < -1. - x.x) {
		rho = .125;
		P = .14;
	} else {
		rho = 1.;
		P = 1.;
	}
]]
		end,
	},
	
	-- http://www.astro.uni-bonn.de/~jmackey/jmac/node7.html
	-- http://www.astro.princeton.edu/~jstone/Athena/tests/brio-wu/Brio-Wu.html
	{
		name = 'Brio-Wu',
		guiVars = {
			{name = 'init_rhoL', value = 1},
			{name = 'init_rhoR', value = .125},
			{name = 'init_PL', value = 1},
			{name = 'init_PR', value = .1},
			{name = 'init_BxL', value = .75},
			{name = 'init_BxR', value = .75},
			{name = 'init_ByL', value = 1},
			{name = 'init_ByR', value = -1},
			{name = 'init_BzL', value = 0},
			{name = 'init_BzR', value = 0},
		},
		overrideGuiVars = {
			heatCapacityRatio = 2,
		},
		initState = function(self, solver)
			return [[
	rho = lhs ? solver->init_rhoL : solver->init_rhoR;
	P = lhs ? solver->init_PL : solver->init_PR;
	B.x = lhs ? solver->init_BxL : solver->init_BxR;
	B.y = lhs ? solver->init_ByL : solver->init_ByR;
	B.z = lhs ? solver->init_BzL : solver->init_BzR;
]]
		end,
	},

	-- 2014 Abgrall, Kumar "Robust Finite Volume Scheme for Two-Fluid Plasma Equations"
	-- TODO instead of providing this as an ideal MHD initial state
	--  instead provide it as a two-fluid initial state
	-- with distinct ion and electron values
	{
		name = 'two-fluid emhd modified Brio-Wu',
		guiVars = {
			{name = 'init_rhoL', value = 1},
			{name = 'init_rhoR', value = .125},
			{name = 'init_PL', value = 5e-5},
			{name = 'init_PR', value = 5e-6},
			{name = 'init_BxL', value = .75},
			{name = 'init_BxR', value = .75},
			{name = 'init_ByL', value = 1},
			{name = 'init_ByR', value = -1},
			{name = 'init_BzL', value = 0},
			{name = 'init_BzR', value = 0},
		},
		overrideGuiVars = {
			heatCapacityRatio = 2,
		},
		initState = function(self, solver)
			return [[
	rho = lhs ? solver->init_rhoL : solver->init_rhoR;
	P = lhs ? solver->init_PL : solver->init_PR;
	B.x = lhs ? solver->init_BxL : solver->init_BxR;
	B.y = lhs ? solver->init_ByL : solver->init_ByR;
	B.z = lhs ? solver->init_BzL : solver->init_BzR;
]]
		end,
	},

	-- http://www.astro.virginia.edu/VITA/ATHENA/ot.html
	-- http://www.astro.princeton.edu/~jstone/Athena/tests/orszag-tang/pagesource.html
	{
		name = 'Orszag-Tang',
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		initState = function(self, solver)
			
			-- TODO hmm looks like it's not setting on init correctly...
			local boundaryMethods = {}
			for i,x in ipairs(xNames) do
				for _,minmax in ipairs(minmaxs) do
					boundaryMethods[x..minmax] = 'periodic'
				end
			end
			solver:setBoundaryMethods(boundaryMethods)
			
			return [[
	const real B0 = 1./sqrt(4. * M_PI);
	rho = 25./(36.*M_PI);
	v.x = -sin(2.*M_PI*(x.y+.5));
	v.y = sin(2.*M_PI*(x.x+.5));
	v.z = 0;
	P = 5./(12.*M_PI);	// is this hydro pressure or total pressure?
	B.x = -B0 * sin(2. * M_PI * (x.y+.5));
	B.y = B0 * sin(4. * M_PI * (x.x+.5));
	B.z = 0;
]]
		end,
	},
	
	-- http://plutocode.ph.unito.it/Doxygen/Test_Problems/_m_h_d_2_rotor_2init_8c.html 
	-- http://flash.uchicago.edu/~jbgallag/2012/flash4_ug/node34.html#SECTION08123000000000000000 
	-- https://arxiv.org/pdf/0908.4362.pdf lists the following:
	--	omega = 2, P = 1, gamma = 7/5
	-- 	omega = 1, P = .5, gamma = 5/3
	{
		name = 'MHD rotor',
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		initState = function(self, solver)
			return [[
	real3 xc = coordMap(x);
	const real r0 = .1;
	const real r1 = .115;
	const real omega = 2.; 
	real r = sqrt(xc.x * xc.x + xc.y * xc.y);
	real vPhi = 0.;
	if (r <= r0) {
		rho = 10.;
		v = cartesianFromCoord(_real3(
			-omega * xc.y / r0,
			omega * xc.x / r0,
			0.
		), x);
	} else if (r <= r1) {
		real f = (r1 - r) / (r1 - r0);
		rho = 1 + 9 * f;
		v = cartesianFromCoord(_real3(
			-f * omega * xc.y / r,
			f * omega * xc.x / r,
			0.
		), x);
	} else {
		rho = 1.;
	}
	P = 1.;
	B.x = 5. / sqrt(4. * M_PI);
]]
		end,
	},

	{
		name = 'spinning magnetic fluid',
		initState = function(self, solver)
			return [[
	real3 xc = coordMap(x);
	rho = .1;
	P = 1;
	
	real3 delta = xc;
	real coord_r = real3_len(delta);
	real3 eHat_r = real3_real_mul(delta, 1. / coord_r);
	real3 eHat_theta = _real3(-eHat_r.y, eHat_r.x, 0.);
	real3 eHat_z = _real3(0., 0., 1.);
	real radius = 1.;
	real distPastRadius = coord_r - radius;
	
	real coord_R = coord_r - .5 * (solver->mins.x + solver->maxs.x);

	if (distPastRadius < 0.) {
		rho = P = 1.;
		v = real3_real_mul(eHat_theta, .1);
#if 0
		B = real3_add(v, 
			real3_add(
				real3_real_mul(eHat_r, -x.z),
				real3_real_mul(eHat_z, coord_R)
			)
		);
#else
		B = _real3(0,0,1);
#endif
	}
]]
		end,
	},

	{
		name = 'magnetic fluid',
		initState = function(self, solver)
			solver.useGravity = true
			return [[
	real3 xc = coordMap(x);
	rho = .1;
	P = 1;
	
	real3 delta = xc;
	real dist = real3_len(_real3(delta.x, delta.y, 0.));
	real radius = 1.;
	real distPastRadius = dist - radius;
	rho = .1;
	P = 1;
	if (distPastRadius < 0.) {
		rho = 1;
		v.z = 1;
	}
]]
		end,
	},

	{
		name = '2002 Dedner peak Bx',
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		mins = {-.5, -1.5, -1},
		maxs = {.5, 1.5, 1},
		initState = function(self, solver)
			return template([[
	rho = 1.;
	v.x = 1.;
	v.y = 1.;
	real s = 128.;	//TODO
	real r = 1. + s * s * (-128. + s * s * 4096.);
	B.x = r * (x.x * x.x + x.y * x.y) * <?=clnumber(1 / math.sqrt(4 * math.pi))?>;
	B.y = 0.;
	B.z = <?=clnumber(1 / math.sqrt(4 * math.pi))?>;
	P = 6.;
]],		{
			clnumber = clnumber,
		})
		end,
	},

	{
		name = '2002 Dedner 1D Riemann',
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		mins = {-.5, -.25, -1},
		maxs = {.5, .25, 1},
		initState = function(self, solver)
			return template([[
	rho = 1.;
	B.x = <?=clnumber(5 / math.sqrt(4 * math.pi))?>;
	B.y = <?=clnumber(5 / math.sqrt(4 * math.pi))?>;
	if (x.x < 0.) {
		v.x = 10.;
		P = 20.;
	} else {
		v.x = -10.;
		P = 1.;
	}
]], 	{
			clnumber = clnumber,
		})
		end,
	},

	{
		name = '2002 Dedner Shock Reflection',
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		mins = {-1, -.5, -1},
		maxs = {1, .5, 1},
		initState = function(self, solver)

			local boundaryMethods = {}
			for i,x in ipairs(xNames) do
				for _,minmax in ipairs(minmxas) do
					boundaryMethods[x..minmax] = 'freeflow'
				end
			end
			boundaryMethods.xmax = 'freeflow'
			boundaryMethods.ymax = 'mirror'
			solver:setBoundaryMethods(boundaryMethods)

			-- left boundary
			boundaryMethods.xmin = function(args)
				local U = 'buf['..args.index'j'..']'
				return template([[
	//TODO 'i'
	//args.index provides this ... post-converted to an integer
	//I need the vector now
	real3 x = cell_x((int4)(<?=args.indexv'j'?>,0));
	<?=eqn.prim_t?> W = {
		.rho = 1.,
		.v = _real3(2.9, 0., 0.),
		.B = _real3(.5, 0., 0.),
		.P = 5. / 7.,
<? if eqn.primVars:find(nil, function(var)
	return next(var) == 'psi'
end) then
?>		.psi = 0.,
<? end	
?>	};
	<?=U?> = consFromPrim(W, x);
]], {U=U, eqn=solver.eqn, args=args})
			end

			-- left boundary
			boundaryMethods.ymin = function(args)
				local U = 'buf['..args.index'j'..']'
				return template([[
	real3 x = cell_x(i);
	<?=eqn.prim_t?> W = {
		.rho = 1.4598,
		.v = _real3(2.717, -.4049, 0.),
		.B = _real3(.6838, -.1019, 0.),
		.P = 1.2229,
<? if eqn.primVars:find(nil, function(var)
	return next(var) == 'psi'
end) then
?>		.psi = 0.,
<? end	
?>	};
	<?=U?> = consFromPrim(W, x);
]], {U=U, eqn=solver.eqn})
			end
					
			return [[
	rho = 1.;
	v.x = 2.9;
	B.x = .5;
	P = 5./7.;
]]
		end,
	},

	{
		name = '2002 Dedner 2D Riemann problem',
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		initState = function(self, solver)
			-- TODO dirichlet 
			solver:setBoundaryMethods'freeflow'
			-- boundary: [-1, 1] x [-1, 1]
			return [[
	bool xp = x.x > mids.x;
	bool yp = x.y > mids.y;
	real3 m = real3_zero;
	real eInt = 0.;
	if (yp) {
		if (xp) {	//I
			rho = .9308;
			m = _real3(1.4557, -.4633, .0575);
			B = _real3(.3501, .9830, .3050);
			eInt = 5.0838;
		} else {	//II
			rho = 1.0304;
			m = _real3(1.5774, -1.0455, -0.1016);
			B = _real3(0.3501, 0.5078, 0.1576);
			eInt = 5.7813;
		}
	} else {
		if (!xp) {	//III
			rho = 1.0000;
			m = _real3(1.7500, -1.0000, 0.0000);
			B = _real3(0.5642, 0.5078, 0.2539);
			eInt = 6.0000;
		} else {	//IV
			rho = 1.8887;
			m = _real3(0.2334, -1.7422, 0.0733);
			B = _real3(0.5642, 0.9830, 0.4915);
			eInt = 12.999;
		}
	}
	v = real3_real_mul(m, 1. / rho);
	P = (heatCapacityRatio - 1.) * rho * eInt;
]]
		end,
	},

	{
		name = '2002 Dedner Kelvin-Helmholtz',
		mins = {0,-1,-1},
		maxs = {1,1,1},
		initState = function(self, solver)
			solver:setBoundaryMethods'periodic'
			return [[
	rho = 1.;
	v.x = 5. * (tanh(20. * (x.y + .5)) - (tanh(20. * (x.y - .5)) + 1.));
	v.y = .25 * sin(2. * M_PI * x.x) * (
		exp(-100. * (x.y + .5) * (x.y + .5))
		- exp(-100. * (x.y - .5) * (x.y - .5))
	);
	B.x = 1.;
	P = 50.;
]]
		end,
	},

	-- http://www.cfd-online.com/Wiki/Explosion_test_in_2-D
	{
		name = 'sphere',
		initState = function(self, solver)
			return [[
	real3 xc = coordMap(x);
	real rSq = real3_lenSq(xc);
	const real R = .2;
	bool inside = rSq < R*R;
	rho = inside ? 1 : .1;
	P = inside ? 1 : .1;
]]
		end,
	},
	{
		name = 'rarefaction wave',
		initState = function(self, solver)
			return [[
	real delta = .1;
	rho = 1;	// lhs ? .2 : .8;
	v.x = lhs ? .5 - delta : .5 + delta;
	P = 1;
]]
		end,
	},
	
	-- 2D tests described in Alexander Kurganov, Eitan Tadmor, Solution of Two-Dimensional Riemann Problems for Gas Dynamics without Riemann Problem Solvers
	--  which says it is compared with  C. W. Schulz-Rinne, J. P. Collins, and H. M. Glaz, Numerical solution of the Riemann problem for two-dimensional gas dynamics
	-- and I can't find that paper right now
	quadrantProblem{
		name = 'configuration 1',
		{rho=1, P=1, ['v.x']=0, ['v.y']=0},
		{rho=.5197, P=.4, ['v.x']=-.7259, ['v.y']=0},
		{rho=.1072, P=.0439, ['v.x']=-.7259, ['v.y']=-1.4045},
		{rho=.2579, P=.15, ['v.x']=0, ['v.y']=-1.4045},
	},
	quadrantProblem{
		name = 'configuration 2',
		{rho=1, P=1, ['v.x']=0, ['v.y']=0},
		{rho=.5197, P=.4, ['v.x']=-.7259, ['v.y']=0},
		{rho=1, P=1, ['v.x']=-.7259, ['v.y']=-.7259},
		{rho=.5197, P=.4, ['v.x']=0, ['v.y']=-.7259},
	},
	quadrantProblem{
		name = 'configuration 3',
		{rho=1.5, P=1.5, ['v.x']=0, ['v.y']=0},
		{rho=.5323, P=.3, ['v.x']=1.206, ['v.y']=0},
		{rho=.138, P=.029, ['v.x']=1.206, ['v.y']=1.206},
		{rho=.5323, P=.3, ['v.x']=0, ['v.y']=1.206},
	},
	quadrantProblem{
		name = 'configuration 4',
		{rho=1.1, P=1.1, ['v.x']=0, ['v.y']=0},
		{rho=.5065, P=.35, ['v.x']=.8939, ['v.y']=0},
		{rho=1.1, P=1.1, ['v.x']=.8939, ['v.y']=.8939},
		{rho=.5065, P=.35, ['v.x']=0, ['v.y']=.8939},
	},
	quadrantProblem{
		name = 'configuration 5',
		{rho=1, P=1, ['v.x']=-.75, ['v.y']=-.5},
		{rho=2, P=1, ['v.x']=-.75, ['v.y']=.5},
		{rho=1, P=1, ['v.x']=.75, ['v.y']=.5},
		{rho=3, P=1, ['v.x']=.75, ['v.y']=-.5},
	},
	quadrantProblem{
		name = 'configuration 6',
		{rho=1, P=1, ['v.x']=.75, ['v.y']=-.5},
		{rho=2, P=1, ['v.x']=.75, ['v.y']=.5},
		{rho=1, P=1, ['v.x']=-.75, ['v.y']=.5},
		{rho=3, P=1, ['v.x']=-.75, ['v.y']=-.5},
	},
	--from SRHD Marti & Muller 2000
	{
		name = 'relativistic shock reflection',
		overrideGuiVars = {
			heatCapacityRatio = 4/3,
		},
		initState = function(self, solver)
			solver.cfl = .5	-- needs a slower cfl
			return [[
	rho = 1;
	v.x = 1. - 1e-5;
	P = (heatCapacityRatio - 1.) * rho * (1e-7 / sqrt(1. - v.x * v.x));
]]
		end,
	},
	{
		name = 'relativistic blast wave test problem 1',
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		initState = function(self, solver)
			solver.cfl = .5	-- needs a slower cfl
			return [[
	rho = lhs ? 10 : 1;
	P = (heatCapacityRatio - 1.) * rho * (lhs ? 2 : 1e-6);
]]
		end,
	},
	{
		name = 'relativistic blast wave test problem 2',
		overrideGuiVars = {
			heatCapacityRatio = 5/3,
		},
		initState = function(self, solver)
			solver.cfl = .5	-- needs a slower cfl
			return [[
	rho = 1;
	P = lhs ? 1000 : .01;
]]
		end,
	},
	{
		name = 'relativistic blast wave interaction',
		initState = function(self, solver)
			solver.cfl = .5	-- needs a slower cfl
			return template([[
	
	bool wave1 = true
<? for i=0,solver.dim-1 do ?>
		&& x.s<?=i?> < .9 * solver->mins.s<?=i?> + .1 * solver->maxs.s<?=i?>
<? end ?>;
	bool wave2 = true
<? for i=0,solver.dim-1 do ?>
		&& x.s<?=i?> > .1 * solver->mins.s<?=i?> + .9 * solver->maxs.s<?=i?>
<? end ?>;
	rho = 1;
	P = wave1 ? 1000 : (wave2 ? 100 : .01);
]], 		{
				solver = solver,
			})
		end,
	},

	{
		name = 'Colella-Woodward',
		initState = function(self, solver)
			solver:setBoundaryMethods'freeflow'
			return [[
	rho = 1;
	if (x.x < -.4) {
		P = 1000;
	} else if (x.x < .4) {
		P = .01;
	} else {
		P = 100;
	}
]]
		end,
	},
	{
		name = 'Kelvin-Helmholtz',
		init = function(self, solver)
			local moveAxis = 1
			local sliceAxis = 2
			
			-- move around the cylinder
			if require 'coord.cylinder'.is(solver.coord) then
				moveAxis = 2
				sliceAxis = 1
			end
			
			solver.eqn:addGuiVars{
				{name='moveAxis', type='combo', value=moveAxis, options={'x','y','z'}, compileTime=true},
				{name='sliceAxis', type='combo', value=sliceAxis, options={'x','y','z'}, compileTime=true},
				{name='rhoInside', value=2.},
				{name='rhoOutside', value=1.},
				{name='amplitude', value=1e-2},
				-- not seeing much of a difference
				{name='noiseAmplitude', value=1e-4},
				{name='backgroundPressure', value=2.5},
				{name='frequency', value=2.},
				{name='thickness', value=1e-7},--.035},
				{name='velInside', value=-.5},
				{name='velOutside', value=.5},
			}
		end,
		initState = function(self, solver)	
			local boundaryMethods = {}
			for i,x in ipairs(xNames) do
				for _,minmax in ipairs(minmaxs) do
					boundaryMethods[x..minmax] = 'periodic'
					if require 'coord.cylinder'.is(solver.coord) 
					and i == 1
					then
						boundaryMethods[x..minmax] = 'mirror'
					end
				end
			end
			solver:setBoundaryMethods(boundaryMethods)
		
			return template([[
	real yq1 = solver->mins.<?=sliceAxis?> * .75 + solver->maxs.<?=sliceAxis?> * .25;
	real yq2 = solver->mins.<?=sliceAxis?> * .25 + solver->maxs.<?=sliceAxis?> * .75;

	real inside = (.5 + .5 * tanh((x.<?=sliceAxis?> - yq1) / solver->thickness))
				- (.5 + .5 * tanh((x.<?=sliceAxis?> - yq2) / solver->thickness));

	real theta = solver->frequency * 2. * M_PI;
<?
for i=0,solver.dim-1 do 
	if xNames[i+1] ~= sliceAxis then
?>	theta *= (x.s<?=i?> - solver->mins.s<?=i?>) / (solver->maxs.s<?=i?> - solver->mins.s<?=i?>);
<? 
	end	
end ?>

	real noise = (solver->maxs.x - solver->mins.x) * solver->amplitude;
	rho = inside * solver->rhoInside + (1. - inside) * solver->rhoOutside;
	//v.x = cos(theta) * noise;
#if dim == 2
	v.y = sin(theta) * noise;
#endif
#if dim == 3
	v.z = sin(theta) * noise;
#endif
	v.<?=moveAxis?> += inside * solver->velInside + (1. - inside) * solver->velOutside;
	v = cartesianFromCoord(v, x);
	P = solver->backgroundPressure;
	rho += solver->noiseAmplitude * crand();
	v.x += solver->noiseAmplitude * crand();
	v.y += solver->noiseAmplitude * crand();
	v.z += solver->noiseAmplitude * crand();
	
	P += solver->noiseAmplitude * crand();
]],				{
					solver = solver,
					moveAxis = solver.eqn.guiVars.moveAxis.options[solver.eqn.guiVars.moveAxis.value],
					sliceAxis = solver.eqn.guiVars.sliceAxis.options[solver.eqn.guiVars.sliceAxis.value],
					xNames = xNames,
				}
			)
		end,
	},
	
	-- http://www.astro.princeton.edu/~jstone/Athena/tests/rt/rt.html
	-- TODO fixme 
	{
		name = 'Rayleigh-Taylor',
		mins = {-3,-1,-1},
		maxs = {3,1,1},
		initState = function(self, solver)	
			local xmid = (solver.mins + solver.maxs) * .5
			
			-- triple the length along the interface dimension
			--local k = solver.dim
			--solver.mins[k] = xmid[k] + (solver.mins[k] - xmid[k]) * 3
			--solver.maxs[k] = xmid[k] + (solver.maxs[k] - xmid[k]) * 3

			-- triple resolution along interface dimension
			--size[k] = size[k] * 3
			-- (can it handle npo2 sizes?)

			local boundaryMethods = {}
			for i,x in ipairs(xNames) do
				for _,minmax in ipairs(minmaxs) do
					boundaryMethods[x..minmax] = i == solver.dim and 'mirror' or 'periodic'
				end
			end
			solver:setBoundaryMethods(boundaryMethods)
		
			return template([[
	const real3 externalForce = _real3(0,1,0);
	ePot = 0. <? 
for side=0,solver.dim-1 do
?> + (x.s<?=side?> - solver->mins.s<?=side?>) * externalForce.s<?=side?><?
end ?>;
	int topdim = <?=solver.dim-1?>;
	bool top = x.s[topdim] > mids.s[topdim];
	//TODO noise too?
	rho = top ? 2 : 1;
	P = 2.5 - rho * ePot;
	// or maybe it is ... pressure = (gamma - 1) * density * (2.5 - potentialEnergy)
]], {
			solver = solver,
		})
		end,
	},


	--http://www.astro.virginia.edu/VITA/ATHENA/dmr.html
	{
		name = 'double mach reflection',
		mins = {0,0,0},
		maxs = {4,1,1},
		overrideGuiVars = {
			heatCapacityRatio = 7/5,
		},
		initState = function(self, solver)
			-- I am not correctly modeling the top boundary
			solver:setBoundaryMethods{
				xmin = 'freeflow',
				xmax = 'freeflow',
				ymin = 'mirror',
				ymax = 'freeflow',
				zmin = 'mirror',
				zmax = 'mirror',
			}
			return table{
	'#define sqrt1_3 '..clnumber(math.sqrt(1/3)),
	[[
	bool inside = x.x < x.y * sqrt1_3;
	if (inside) {
		rho = 8;
		P = 116.5;
		v.x = 8.25 * cos(30. * M_PI / 180.);
		v.y = -8.25 * sin(30. * M_PI / 180.);
	} else {
		rho = 1.4;
		P = 1;
	}
]],
			}:concat'\n'
		end,
	},

	-- http://www.cfd-online.com/Wiki/2-D_laminar/turbulent_driven_square_cavity_flow
	{
		name = 'square cavity',
		initState = function(self, solver)
			solver:setBoundaryMethods{
				xmin = 'mirror',
				xmax = 'mirror',
				ymin = 'mirror',
				ymax = 'freeflow',	-- TODO none
				zmin = 'mirror',
				zmax = 'mirror',
			}
			return [[
	rho = 1;
	v.x = x.y > .45 ? 1 : 0;
	P = 1;
]]
		end,
	},

	{
		name='shock bubble interaction',
		initState = function(self, solver)
			solver:setBoundaryMethods'freeflow'
			return [[
	const real waveX = -.45;
	real3 bubbleCenter = real3_zero;
	real bubbleRadius = .2;
	real3 delta = real3_sub(x, bubbleCenter);
	real bubbleRSq = real3_lenSq(delta);
	rho = x.x < waveX ? 1. : (bubbleRSq < bubbleRadius*bubbleRadius ? .1 : 1);
	P = x.x < waveX ? 1 : .1;
	v.x = x.x < waveX ? 0 : -.5;
]]
		end,
	},

	{
		name = 'Richmyer-Meshkov',
		mins = {-2,0,0},
		maxs = {6,1,1},
		initState = function(self, solver)
			solver:setBoundaryMethods'freeflow'
			
			local theta = math.pi / 4
			local eta = 3
			local betaInv = .5	-- .5 for magnetic field
			local P0 = 1

			return template([[
	constant real P0 = <?=clnumber(P0)?>;
	if (x.x < -.2) {
		//TODO how do you calculate conditions for a particular mach speed shock wave? 
		//constant real gamma = heatCapacityRatio;		
		//constant real M = 2;
		//rho = (gamma + 1) / (gamma - 1) * M*M / (M*M + 2);
		//P = P0 * (2 * gamma * M*M * (gamma - 1)) / ((gamma + 1) * (gamma + 1));
		rho = 1;
		P = 10;
	} else {
		P = P0;
		if (x.x < x.y * <?=clnumber(math.tan(theta))?>) {
			rho = 1;
		} else {
			rho = <?=clnumber(eta)?>;
		}
	}
	B.x = sqrt(2 * P0 * <?=clnumber(betaInv)?>);
]], 			{
					clnumber = clnumber,
					theta = theta,
					eta = eta,
					betaInv = betaInv,
					P0 = P0,
				})
		end,
	},

	-- gravity potential test - equilibrium - Rayleigh-Taylor ... or is it Jeans? (still has an shock wave ... need to fix initial conditions?)

	{
		name = 'self-gravitation test 1',
		initState = function(self, solver)
			local radius = .5
			local f = SelfGravProblem{
				solver = solver,
				sources={
					{center={0, 0, 0}, radius = radius},
				},
			}
			if require 'coord.cylinder'.is(solver.coord) then
				solver:setBoundaryMethods{
					xmin = 'freeflow',
					xmax = 'freeflow',
					ymin = 'periodic',
					ymax = 'periodic',
					zmin = 'freeflow',
					zmax = 'freeflow',
				}
			end
			return f(self, solver)
		end
	},

	{
		name = 'self-gravitation test 1 spinning',
		initState = function(self, solver)
			local inside = [[
	v.x = -2 * delta.y;
	v.y = 2 * delta.x;
	rho = 1.;
	P = 1.;
]]

			return SelfGravProblem{
				getRadiusCode = function(source)
					-- TODO compute dr's component in each dx^i's, and scale our random number by that
					-- add some noise
					return '.2 - .003 * cos(1.+2.*M_PI*cos(1.+2.*M_PI*cos(1.+2.*M_PI*x.y/x.x)))'
				end,
				sources={
					{
						center={0, 0, 0}, 
						radius = .2,
						-- srhd solver requires the max velocity not to exceed 1 ...
						inside = inside,
					},
				},
			}(self, solver)
		end,
	},

	{
		name = 'self-gravitation test 2',
		initState = SelfGravProblem{ 
			sources={
				{
					center = {-.25, 0, 0},
					radius = .1,
				},
				{
					center = {.25, 0, 0},
					radius = .1,
				},
			},
		},
	},

	{
		-- TODO add tidal-locked rotations
		name = 'self-gravitation test 2 orbiting',
		initState = SelfGravProblem{ 
			sources = {
				{
					center = {-.25, 0, 0},
					radius = .1,
					inside = [[
	v.x = -2 * delta.y - .1 * x.y;
	v.y = 2 * delta.x + .1 * x.x;
	rho = 1;
	P = 1;
					]],
				},
				{
					center = {.25, 0, 0},
					radius = .1,
					inside = [[
	v.x = -2 * delta.y - .1 * x.y;
	v.y = 2 * delta.x + .1 * x.x;
	rho = 1;
	P = 1;
					]],
				},
			},
		},
	},
	
	{
		name = 'self-gravitation test 4',
		initState =  SelfGravProblem{
			sources={
				{center={.25, .25, 0}, radius = .1},
				{center={-.25, .25, 0}, radius = .1},
				{center={.25, -.25, 0}, radius = .1},
				{center={-.25, -.25, 0}, radius = .1},
			},
		},
	},

	{
		name = 'self-gravitation soup',
		initState = function(self, solver)
			return [[
	int q = index;
	for (int i = 0; i < 20; ++i) {
		q = (int)floor((float)0x7fffffff * fabs(sin(2. * M_PI * (float)q / (float)0x7fffffff)));
	}
	rho = .1 * (float)(q & 0xff) / (float)0xff + .1;
	
	q = (int)floor((float)0x7fffffff * fabs(sin(2. * M_PI * (float)q / (float)0x7fffffff)));
	P = .1 * (float)(q & 0xff) / (float)0xff + .1;

	q = (int)floor((float)0x7fffffff * fabs(sin(2. * M_PI * (float)q / (float)0x7fffffff)));
	v.x = .2 * (float)(q & 0xff) / (float)0xff - .1;
	
	q = (int)floor((float)0x7fffffff * fabs(sin(2. * M_PI * (float)q / (float)0x7fffffff)));
	v.y = .2 * (float)(q & 0xff) / (float)0xff - .1;
	
	q = (int)floor((float)0x7fffffff * fabs(sin(2. * M_PI * (float)q / (float)0x7fffffff)));
	v.z = .2 * (float)(q & 0xff) / (float)0xff - .1;
]]
		end,
	},

	{
		name = 'Maxwell default',
		initState = function(self, solver)
			return template([[
	D.x = <?=eqn.susc_t?>_from_real(lhs ? 1 : -1);
	D.y = <?=eqn.susc_t?>_from_real(1);
	B.y = <?=eqn.susc_t?>_from_real(-1);
	B.z = <?=eqn.susc_t?>_from_real(lhs ? 1 : -1);
]], solver.eqn:getTemplateEnv())
		end,
	},

	{
		name = 'Maxwell empty waves',
		initState = function(self, solver)
			addMaxwellOscillatingBoundary{
				solver = solver,
				side = xNames[solver.dim]..'max',
				dir = xNames[solver.dim],
				amplitude = 1,
				period = 10,
			}
			return ''
		end,
	},

	{
		name = 'Maxwell scattering around cylinder',
		initState = function(self, solver)
			addMaxwellOscillatingBoundary{
				solver = solver,
				side = 'xmin',
				dir = 'x',
				amplitude = 1,
				period = 10,
			}
			return template([[
	real3 xc = coordMap(x);
	if (real3_lenSq(xc) < .2*.2) {
		//2018 Balezin et al "Electromagnetic properties of the Great Pyramids..."
		permittivity = <?=eqn.susc_t?>_from_cplx(_cplx(5., .1));
	}
]], solver.eqn:getTemplateEnv())
		end,
	},

	{
		name = 'Maxwell scattering around pyramid',
		header = function(self, solver)
			return template([[
<? 
local table = require 'ext.table'

local objs = table()
local sqrt3 = math.sqrt(3)
if solver.dim == 2 then
	objs:insert{
		{p={0, -.5, 0}, n={0, -1, 0}},
		{p={.25*sqrt3, .25, 0}, n={.5*sqrt3, .5, 0}},
		{p={-.25*sqrt3, .25, 0}, n={-.5*sqrt3, .5, 0}},
	}
	-- if you want the floor... it is a separate CSG region
	objs:insert{
		{p={0, -.5, 0}, n={0, 1, 0}},
	}
elseif solver.dim == 3 then
	objs:insert{
		{p={0, 0, -.5}, n={0, 0, -1}},
		{p={.25*sqrt3, 0, .25}, n={.5*sqrt3, 0, .5}},
		{p={-.25*sqrt3, 0, .25}, n={-.5*sqrt3, 0, .5}},
		{p={0, .25*sqrt3, .25}, n={0, .5*sqrt3, .5}},
		{p={0, -.25*sqrt3, .25}, n={0, -.5*sqrt3, .5}},
	}
	-- if you want the floor... it is a separate CSG region
	objs:insert{
		{p={0, 0, -.5}, n={0, 0, 1}},
	}
end
?>

bool testTriangle(real3 xc) {
	return false
<? for _,obj in ipairs(objs) do ?>
		|| (true 
<? 
for _,pn in ipairs(obj) do
	local p = table(pn.p):map(clnumber):concat', '
	local n = table(pn.n):map(clnumber):concat', '
?>
			&& real3_dot(real3_sub(xc, _real3(<?=p?>)), _real3(<?=n?>)) < 0.
<? end ?>
		)
<? end ?>
	;
}
]], {
		solver = solver,
		clnumber = clnumber,
	})
		end,
		initState = function(self, solver)
			-- hmm, choosing min or max doesn't matter, it always shows up on min...
			addMaxwellOscillatingBoundary{
				solver = solver,
				side = xNames[solver.dim]..'max',
				dir = xNames[solver.dim],
				amplitude = -1,
				period = 10,
			}
			return template([[
	real3 xc = coordMap(x);
	xc = real3_real_mul(xc, 2.);
	if (testTriangle(xc)) {
		//2018 Balezin et al "Electromagnetic properties of the Great Pyramids..."
		permittivity = <?=eqn.susc_t?>_from_cplx(_cplx(5., .1));
	}
]], solver.eqn:getTemplateEnv())
		end,
	},

	{
		name = 'Maxwell scattering around square',
		initState = function(self, solver)
			-- hmm, choosing min or max doesn't matter, it always shows up on min...
			addMaxwellOscillatingBoundary{
				solver = solver,
				side = xNames[solver.dim]..'max',
				dir = xNames[solver.dim],
				amplitude = -1,
				period = 10,
			}
			return template([[
	real3 xc = coordMap(x);
	xc = real3_real_mul(xc, 2.);
	if (
		xc.x > -.5 && xc.x < .5
<? if solver.dim > 1 then ?>
		&& xc.y > -.5 && xc.y < .5
<? 	if solver.dim > 2 then ?>
		&& xc.z > -.5 && xc.z < .5
<? 	end 
end	?>
	) {
		//2018 Balezin et al "Electromagnetic properties of the Great Pyramids..."
		permittivity = <?=eqn.susc_t?>_from_cplx(_cplx(5., .1));
	}
]], solver.eqn:getTemplateEnv())
		end,
	},

	{
		name = 'Maxwell scattering around Koch snowflake',
		header = function(self, solver)
			return template([[

#define sqrt3 <?=clnumber(math.sqrt(3))?>

#define p1 _real3(0, .5, 0)
#define p2 _real3(.25*sqrt3, -.25, 0.)
#define p3 _real3(-.25*sqrt3, -.25, 0.)

#define n1 _real3(0, 1, 0)
#define n2 _real3(.5*sqrt3, -.5, 0)
#define n3 _real3(-.5*sqrt3, -.5, 0)

//initial branches
<? for i=1,3 do ?>
real3 branch<?=i?>(real3 x) {
	x = _real3(-x.x, -x.y, 0);	//180 rotation
	real3 n = _real3(-n<?=i?>.y, n<?=i?>.x, 0);	//angle of rotation of the normal
	x = _real3(n.x * x.x - n.y * x.y, n.x * x.y + n.y * x.x, 0.);	//rotate by 'n'
	x.y -= sqrt3*3./8.;	//translate to center
	x = real3_real_mul(x, 3.);	//scale up by 3
	x = _real3(-x.x, -x.y, 0);	//180 rotation
	return x;
}
<? end ?>

//secondary branches
real3 branch2_1(real3 x) {
	x.x += sqrt3;
	x = real3_real_mul(x, 3.);
	x.y -= .5*sqrt3;
	return x;
}

real3 branch2_2(real3 x) {
	x.x -= sqrt3;
	x = real3_real_mul(x, 3.);
	x.y -= .5*sqrt3;
	return x;
}

real3 branch2_3(real3 x) {
	real c = .5;
	real s = sqrt3*.5;
	x = _real3(x.x*c - x.y*s, x.x*s + x.y*c, 0.);	//rotate by c,s
	x = real3_real_mul(x, 3);	//scale by 3
	x.y += sqrt3;	//translate to center
	return x;
}

real3 branch2_4(real3 x) {
	real c = .5;
	real s = -sqrt3*.5;
	x = _real3(x.x*c - x.y*s, x.x*s + x.y*c, 0.);	//rotate by c,s
	x = real3_real_mul(x, 3);	//scale by 3
	x.y += sqrt3;	//translate to center
	return x;
}

bool testTriangle(real3 xc) {
	return (real3_dot(real3_sub(xc, p1), n1) < 0. &&
		real3_dot(real3_sub(xc, p2), n2) < 0. &&
		real3_dot(real3_sub(xc, p3), n3) < 0.);
}
]], {
	clnumber = clnumber,
})
		end,
		initState = function(self, solver)
			addMaxwellOscillatingBoundary{
				solver = solver,
				side = xNames[solver.dim]..'max',
				dir = xNames[solver.dim],
				amplitude = 1,
				period = 10,
			}
			
			local c = 299792458
			local s_in_m = 1 / c
			local G = 6.6740831e-11
			local kg_in_m = G / c^2
			local ke = 8.9875517873681764e+9
			local C_in_m = math.sqrt(ke * G) / c^2	-- m
			local Ohm_in_m = kg_in_m / (s_in_m * C_in_m^2)	-- m^0
			local resistivities = table{	-- at 20' Celsius, in Ohm m
				air = 2e+14,
				aluminum = 2.65e-8,
				copper = 1.724e-8,
				iron = 9.71e-8,
				nichrome = 1e-6,
				gold = 2.24e-8,
				silver = 1.59e-8,
				platinum = 1.06e-7,
				tungsten = 5.65e-8,
			}:map(function(v) return v * Ohm_in_m end)		
			
			return template([[
	real3 xc = coordMap(x);
	xc = real3_real_mul(xc, 2.);
	
	//conductivity = <?=clnumber(1/resistivities.air)?>;

	if (false
		|| testTriangle(xc)

<? for i=1,3 do ?>
		|| testTriangle( branch<?=i?>(xc) )	
<? end ?>

<? for i=1,3 do ?>
	<? for j=1,4 do ?>
		|| testTriangle( branch2_<?=j?>( branch<?=i?>( xc ) ) )
	<? end ?>
<? end ?>

<? for k=1,4 do ?>
	<? for j=1,4 do ?>
		<? for i=1,3 do ?>
		|| testTriangle( branch2_<?=k?>( branch2_<?=j?>( branch<?=i?>( xc ) ) ) )
		<? end ?>
	<? end ?>
<? end ?>
	
	) {
		//conductivity = 0;
		//conductivity = <?=clnumber(1/resistivities.copper)?>;
		permittivity = <?=eqn.susc_t?>_from_cplx(_cplx(5., .1));
	}

]], 		table({
				clnumber = clnumber,
				resistivities = resistivities,
			}, solver.eqn:getTemplateEnv()))
		end,
	},

	{
		name = 'Maxwell Lichtenberg',
		initState = function(self, solver)
			local src = {math.floor(tonumber(solver.gridSize.x)*.75)}
			local dst = {math.floor(tonumber(solver.gridSize.x)*.25)}
			for j=2,solver.dim do
				src[j] = math.floor(tonumber(solver.gridSize:ptr()[j-1])*.5)
				dst[j] = math.floor(tonumber(solver.gridSize:ptr()[j-1])*.5)
			end
			for j=solver.dim+1,3 do
				src[j] = 0
				dst[j] = 0
			end

			local addExtraSourceProgramObj = solver.Program{
				name='addExtraSource',
				code = table{
					solver.codePrefix,
					template([[
//single cell domain
kernel void addExtraSource(
	global <?=eqn.cons_t?>* UBuf
) {
	UBuf[INDEX(<?=src[1]?>,<?=src[2]?>,<?=src[3]?>)].D.x = -10;
	UBuf[INDEX(<?=dst[1]?>,<?=dst[2]?>,<?=dst[3]?>)].D.x = -10;
}
]], {
	eqn = solver.eqn,
	src = src,
	dst = dst,
}),
				}:concat'\n',
			}
			addExtraSourceProgramObj:compile()
			local addExtraSourceKernelObj = addExtraSourceProgramObj:kernel{
				name = 'addExtraSource', 
				argsOut = {solver.UBufObj},
				domain = solver.app.env:domain{dim=1, size=1},
			}
			
			local oldStep = solver.step
			function solver:step(dt)
				oldStep(self, dt)
				
				-- I just want to add to the D field at a specific point ...
				-- should this be a cpu/gpu mem cpy and write?
				-- or should this be a kernel with a single cell domain?
				addExtraSourceKernelObj()
			end
		end,
		resetState = function(self, solver)
			-- super calls initStateKernel ...
			InitCond.resetState(self, solver)
			-- and here I'm going to fill the permittivity 'eps' with random noise
			-- ... and put a source + and - current 'sigma' at two points on the image
			local ptr = ffi.cast(solver.eqn.cons_t..'*', solver.UBufObj:toCPU())
			for i=0,solver.numCells-1 do
				ptr[i].sigma = math.random() * 1e-4 + 1e-7
			end
			solver.UBufObj:fromCPU(ffi.cast('real*', ptr))
		end,
	},

	{
		name = 'Maxwell wire',
		initState = function(self, solver)
			addMaxwellOscillatingBoundary{solver=solver}
			
			local c = 299792458
			local s_in_m = 1 / c
			local G = 6.6740831e-11
			local kg_in_m = G / c^2
			local ke = 8.9875517873681764e+9
			local C_in_m = math.sqrt(ke * G) / c^2	-- m
			local Ohm_in_m = kg_in_m / (s_in_m * C_in_m^2)	-- m^0
			local resistivities = table{	-- at 20' Celsius, in Ohm m
				air = 2e+14,
				aluminum = 2.65e-8,
				copper = 1.724e-8,
				iron = 9.71e-8,
				nichrome = 1e-6,
				gold = 2.24e-8,
				silver = 1.59e-8,
				platinum = 1.06e-7,
				tungsten = 5.65e-8,
			}:map(function(v) return v * Ohm_in_m end)
			return template([[
	D.x = <?=eqn.susc_t?>_from_real(1.);
	
	conductivity = <?=eqn.susc_t?>_from_real(<?=clnumber(1/resistivities.air)?>);
	
	real r2 = x.y * x.y<? if solver.dim == 3 then ?> + x.z * x.z<? end ?>;	
	
	if (r2 < .1*.1) {
		conductivity = <?=eqn.susc_t?>_from_real(<?=clnumber(1/resistivities.copper)?>);
		permittivity = <?=eqn.susc_t?>_from_cplx(_cplx(5., .1));
	}
]], 		table({
				solver = solver,
				clnumber = clnumber,
				resistivities = resistivities,
			}, solver.eqn:getTemplateEnv()))
		end,
	},

	{
		name = '2017 Degris et al',
		initState = function(self, solver)
			return [[
	rho = 1.;
	P = 1.;
	if (x.x <= -.8) {
		B.x = 0.;
	} else if (x.x <= -.6) {
		B.x = -2. * (x.x + .8);
	} else if (x.x <= .6) {
		B.x = exp(-.5 * (x.x / .11) * (x.x / .11));
	} else { 
		B.x = .5;
	}
]]
		end,
	},

	{	-- from https://www.youtube.com/watch?v=Fe_f_mQCY6g
		-- doesn't have much description to it
		name = 'that one mhd simulation from youtube',
		initState = function(self, solver)
			-- I am not correctly modeling the top boundary
			solver:setBoundaryMethods{
				xmin = 'periodic',
				xmax = 'periodic',
				ymin = 'mirror',
				ymax = 'mirror',
				zmin = 'mirror',
				zmax = 'mirror',
			}
			return [[
	rho = 1.;
	P = 1. + .1 * x.y + .1 * cos(M_PI * x.x) * cos(M_PI * .5 * x.y);
	B.x = .1;
]]
		end,
	},

	{
		name = 'two-fluid EMHD soliton ion',
		initState = function(self, solver)
			return [[
	const real L = 12.;
	rho = 1. + (real)exp((real)-25. * (real)fabs(x.x - L / (real)3.));
]]
		end,
	},
	{
		name = 'two-fluid EMHD soliton electron',
		initState = function(self, solver)
			return [[
	const real L = 12.;
	rho = 5. * (1. + (real)exp((real)-25. * (real)fabs(x.x - L / (real)3.)));
]]
		end,
	},
	{
		name = 'two-fluid EMHD soliton maxwell',
		initState = function(self, solver)
-- TODO			
			return [[

]]
		end,
	},
}:map(function(cl)
	return class(InitCond, cl)
end)
return initStates
