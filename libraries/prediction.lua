--[[
	Prediction Library
	Source: https://devforum.roblox.com/t/predict-projectile-ballistics-including-gravity-and-motion/1842434
	Quartic solver after Jochen Schwarze, "Solving Quartic Equations" (Graphics Gems, 1990).
]]
local module = {}
local eps = 1e-9
local function isZero(d)
	return (d > -eps and d < eps)
end

local function cuberoot(x)
	return (x > 0) and math.pow(x, (1 / 3)) or -math.pow(math.abs(x), (1 / 3))
end

-- Appends every non-nil value, so a solver's variable number of results can be collected
-- without holes.
local function push(list, ...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if v ~= nil then
			list[#list + 1] = v
		end
	end
end

local function solveQuadric(c0, c1, c2)
	local s0, s1

	local p, q, D

	p = c1 / (2 * c0)
	q = c2 / c0
	D = p * p - q

	if isZero(D) then
		s0 = -p
		return s0
	elseif (D < 0) then
		return
	else --[[ if (D > 0) ]]
		local sqrt_D = math.sqrt(D)

		s0 = sqrt_D - p
		s1 = -sqrt_D - p
		return s0, s1
	end
end

local function solveCubic(c0, c1, c2, c3)
	local s0, s1, s2

	local num, sub
	local A, B, C
	local sq_A, p, q
	local cb_p, D

	A = c1 / c0
	B = c2 / c0
	C = c3 / c0

	sq_A = A * A
	p = (1 / 3) * (-(1 / 3) * sq_A + B)
	q = 0.5 * ((2 / 27) * A * sq_A - (1 / 3) * A * B + C)

	cb_p = p * p * p
	D = q * q + cb_p

	if isZero(D) then
		if isZero(q) then --[[ one triple solution ]]
			s0 = 0
			num = 1
		else --[[ one single and one double solution ]]
			local u = cuberoot(-q)
			s0 = 2 * u
			s1 = -u
			num = 2
		end
	elseif (D < 0) then --[[ Casus irreducibilis: three real solutions ]]
		-- Rounding can push the ratio a hair outside [-1, 1]; acos of that is nan, and a nan
		-- here turns every root of the quartic built on this cubic into nan as well.
		local phi = (1 / 3) * math.acos(math.clamp(-q / math.sqrt(-cb_p), -1, 1))
		local t = 2 * math.sqrt(-p)

		s0 = t * math.cos(phi)
		s1 = -t * math.cos(phi + math.pi / 3)
		s2 = -t * math.cos(phi - math.pi / 3)
		num = 3
	else --[[ one real solution ]]
		local sqrt_D = math.sqrt(D)
		local u = cuberoot(sqrt_D - q)
		local v = -cuberoot(sqrt_D + q)

		s0 = u + v
		num = 1
	end

	sub = (1 / 3) * A

	if (num > 0) then s0 = s0 - sub end
	if (num > 1) then s1 = s1 - sub end
	if (num > 2) then s2 = s2 - sub end

	return s0, s1, s2
end

-- A square root that tolerates the rounding Ferrari's substitutions leave behind: a value a
-- hair below zero is zero, not "this quartic has no real roots".
local function softSqrt(x, scale)
	if x >= 0 then return math.sqrt(x) end
	if x > -1e-9 * math.max(scale, 1) then return 0 end
	return nil
end

--[[ Real roots of c0 x^4 + c1 x^3 + c2 x^2 + c3 x + c4, as a list with no holes (nil when the
quartic has none). Two things differ from the port this replaced:

  * With no absolute term the depressed quartic is y (y^3 + p y + q) = 0, and y = 0 is a root
    too. The port only kept the cubic's.
  * The second quadratic is solved once. The port re-solved it for each root count it passed
    through, and handed back the same roots two or three times. ]]
function module.solveQuartic(c0, c1, c2, c3, c4)
	local roots = {}

	local A = c1 / c0
	local B = c2 / c0
	local C = c3 / c0
	local D = c4 / c0

	local sq_A = A * A
	local p = -0.375 * sq_A + B
	local q = 0.125 * sq_A * A - 0.5 * A * B + C
	local r = -(3 / 256) * sq_A * sq_A + 0.0625 * sq_A * B - 0.25 * A * C + D

	if isZero(r) then
		push(roots, solveCubic(1, 0, p, q))
		push(roots, 0)
	else
		local z = solveCubic(1, -0.5 * p, -r, 0.5 * r * p - 0.125 * q * q)
		local u = softSqrt(z * z - r, math.max(z * z, math.abs(r)))
		local v = softSqrt(2 * z - p, math.max(math.abs(2 * z), math.abs(p)))
		if not (u and v) then
			return
		end

		push(roots, solveQuadric(1, q < 0 and -v or v, z - u))
		push(roots, solveQuadric(1, q < 0 and v or -v, z + u))
	end

	local sub = 0.25 * A
	for i, s in roots do
		roots[i] = s - sub
	end
	return roots
end

-- c4 t^4 + c3 t^3 + c2 t^2 + c1 t + c0, and its slope.
local function evalQuartic(c4, c3, c2, c1, c0, t)
	return (((c4 * t + c3) * t + c2) * t + c1) * t + c0,
		((4 * c4 * t + 3 * c3) * t + 2 * c2) * t + c1
end

local SCAN_STEP, SCAN_LIMIT = 0.01, 10

--[[ The earliest t after `tMin` where the quartic reaches zero.

Ferrari's method supplies the candidates, but it works on coefficients that have been through
two rounds of substitution and loses digits doing it -- a root can come back a few thousandths
off. Each candidate is polished with Newton's method against the ORIGINAL polynomial and kept
only if it really is a root. If none is, the polynomial is walked directly and the first sign
change bisected, so a reachable target never comes back as unreachable because of rounding.
f(tMin) is positive for every caller here -- the projectile has not reached the target yet --
so the first crossing is the intercept.

With no gravity between the projectile and the target c4 and c3 vanish and it is a quadratic;
the port divided by c4 and returned nans for that, which is why a gravity-free projectile never
got an aim point. ]]
local function earliestRoot(c4, c3, c2, c1, c0, tMin)
	tMin = math.max(tMin or 0, 1e-6)
	local scale = math.max(math.abs(c4), math.abs(c3), math.abs(c2), math.abs(c1), math.abs(c0), 1e-12)

	local candidates = {}
	if math.abs(c4) > 1e-12 * scale then
		candidates = module.solveQuartic(c4, c3, c2, c1, c0) or candidates
	elseif math.abs(c2) > 1e-12 * scale then
		push(candidates, solveQuadric(c2, c1, c0))
	elseif math.abs(c1) > 1e-12 * scale then
		push(candidates, -c0 / c1)
	end

	local best
	for _, t in candidates do
		if t == t then
			local f = evalQuartic(c4, c3, c2, c1, c0, t)
			local polished = t
			for _ = 1, 4 do
				local pf, df = evalQuartic(c4, c3, c2, c1, c0, polished)
				if df == 0 then break end
				polished -= pf / df
			end
			local pf = evalQuartic(c4, c3, c2, c1, c0, polished)
			if pf == pf and math.abs(pf) <= math.abs(f) then
				t, f = polished, pf
			end
			local at = math.abs(t)
			local size = math.abs(c4) * at ^ 4 + math.abs(c3) * at ^ 3 + math.abs(c2) * at * at + math.abs(c1) * at + math.abs(c0)
			if t > tMin and math.abs(f) <= 1e-6 * size and (not best or t < best) then
				best = t
			end
		end
	end
	if best then return best end

	local prevT, prevF = tMin, evalQuartic(c4, c3, c2, c1, c0, tMin)
	local t = tMin
	while t < SCAN_LIMIT do
		t += SCAN_STEP
		local f = evalQuartic(c4, c3, c2, c1, c0, t)
		if (f <= 0) ~= (prevF <= 0) then
			local lo, hi = prevT, t
			for _ = 1, 50 do
				local mid = (lo + hi) * 0.5
				if (evalQuartic(c4, c3, c2, c1, c0, mid) <= 0) == (prevF <= 0) then
					lo = mid
				else
					hi = mid
				end
			end
			return (lo + hi) * 0.5
		end
		prevT, prevF = t, f
	end
	return nil
end

--[[ Launch onto a target moving at `vel` under `targetGravity`, starting at `startPos`, no
earlier than `tMin`. The projectile and the target both fall, so only the DIFFERENCE in their
gravity bends the relative path: with l = -(gravity - targetGravity) / 2,

    |disp + vel*t - (0, l*t^2, 0)| = speed * t

is the quartic below. Returns the aim point -- origin plus the launch velocity, the shape
every caller normalises -- and the flight time. ]]
local function intercept(origin, speed, gravity, startPos, vel, targetGravity, tMin)
	local disp = startPos - origin
	local h, j, k = disp.X, disp.Y, disp.Z
	local p, q, r = vel.X, vel.Y, vel.Z
	local l = -0.5 * (gravity - targetGravity)

	local t = earliestRoot(
		l * l,
		-2 * q * l,
		q * q - 2 * j * l - speed * speed + p * p + r * r,
		2 * j * q + 2 * h * p + 2 * k * r,
		j * j + h * h + k * k,
		tMin
	)
	if not t then return nil end
	return origin + Vector3.new((h + p * t) / t, (j + q * t - l * t * t) / t, (k + r * t) / t), t
end

-- A raycast that passes through characters. The landing probe starts at the target's own feet
-- and, on the way down from a jump, runs straight back through where its own body is standing
-- right now -- and a player is not a floor.
local function castPastCharacters(from, dir, params)
	local length = dir.Magnitude
	if length <= 1e-6 then return nil end
	local unit = dir / length
	local travelled = 0
	for _ = 1, 4 do
		local hit = workspace:Raycast(from, unit * (length - travelled), params)
		if not hit then return nil end
		local model = hit.Instance and hit.Instance:FindFirstAncestorOfClass('Model')
		if not (model and model:FindFirstChildOfClass('Humanoid')) then
			return hit
		end
		local step = (hit.Position - from).Magnitude + 0.01
		travelled += step
		if travelled >= length then return nil end
		from = from + unit * step
	end
	return nil
end

local LAND_LIFT = 0.1      -- probe from just above the feet, so a target standing on a floor finds it
local LAND_SEGMENTS = 40
local LAND_LIFT_OFFSET = Vector3.new(0, LAND_LIFT, 0)

-- Where a root starting at `pos` with `vel` is after falling `tt` seconds under `grav`. A plain
-- function rather than a closure made inside findLanding, which AimAssist calls every frame.
local function fallingAt(pos, vel, grav, tt)
	return pos + vel * tt - Vector3.new(0, 0.5 * grav * tt * tt, 0)
end

--[[ When the falling target's feet (`height` below the root) first meet a floor, within
`tEnd` seconds. The arc is walked in short chords rather than one straight ray from the root:
that ray cut the corner of the parabola and started inside the target's own legs. Only the way
down is probed -- nothing is landed on while rising. Returns the time and the root position
there. ]]
local function findLanding(pos, vel, grav, height, params, tEnd)
	if grav <= 0 or tEnd <= 0 then return nil end
	local t = math.max(vel.Y / grav, 0)
	if t >= tEnd then return nil end

	local step = math.max(0.05, (tEnd - t) / LAND_SEGMENTS)
	local feet = Vector3.new(0, height, 0)

	while t < tEnd do
		local t2 = math.min(t + step, tEnd)
		local a = fallingAt(pos, vel, grav, t) - feet + LAND_LIFT_OFFSET
		local hit = castPastCharacters(a, fallingAt(pos, vel, grav, t2) - feet - a, params)
		if hit and hit.Normal.Y > 0.5 then
			-- The exact moment the feet reach that surface on the way down.
			local disc = vel.Y * vel.Y - 2 * grav * (hit.Position.Y - (pos.Y - height))
			local tl = disc >= 0 and (vel.Y + math.sqrt(disc)) / grav or t
			tl = math.clamp(tl, t, t2)
			local landed = fallingAt(pos, vel, grav, tl)
			return tl, Vector3.new(landed.X, hit.Position.Y + height, landed.Z)
		end
		t = t2
	end
	return nil
end

--[[ Aim point for a projectile (origin plus launch velocity) onto a moving target, or nil when
no launch at this speed reaches it.

  playerGravity, playerHeight -- the target's fall and its root height above its feet
  playerJump                  -- accepted for older callers; unused
  params                      -- RaycastParams for the world. Passing it (with an airborne
                                 target and playerGravity) turns on the falling-target model
  offset                      -- aimed part's offset from targetPos, carried along
  ping                        -- extra seconds to age the target by (capped at 1)
  airborne                    -- nil infers it from the vertical velocity

Without params the target keeps a constant velocity, exactly as before. With them an airborne
target falls under its own gravity -- solved exactly, not approximated -- until its feet meet a
floor, and from then on keeps its run speed along it. The correction this replaced aimed at the
landing spot with every bit of velocity lead thrown away, and its ray started inside the
target's own legs, so any airborne target read as "landing half a stud below itself". ]]
function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params, offset, ping, airborne)
	local aimOffset = offset or Vector3.zero
	local lead = (ping and ping > 0) and math.min(ping, 1) or 0

	if airborne == nil then
		airborne = math.abs(targetVelocity.Y) > 0.01
	end

	if not (airborne and playerGravity and playerGravity > 0 and params) then
		local aim = intercept(origin, projectileSpeed, gravity,
			targetPos + targetVelocity * lead + aimOffset, targetVelocity, 0)
		return aim
	end

	local height = playerHeight or 0
	local g = playerGravity

	-- Aged by the ping under its own gravity: position and velocity both.
	local startPos = targetPos + targetVelocity * lead - Vector3.new(0, 0.5 * g * lead * lead, 0)
	local startVel = targetVelocity - Vector3.new(0, g * lead, 0)
	local aim, t = intercept(origin, projectileSpeed, gravity, startPos + aimOffset, startVel, g)

	local horizon = lead + (t or 2 * (startPos - origin).Magnitude / projectileSpeed)
	local landTime, landPos = findLanding(targetPos, targetVelocity, g, height, params, horizon)
	if not landTime then
		return aim
	end

	-- On the floor before the projectile arrives: from the landing on it runs at its
	-- horizontal speed, and the intercept has to come after the landing.
	local flat = Vector3.new(targetVelocity.X, 0, targetVelocity.Z)
	local groundStart = landPos + flat * (lead - landTime) + aimOffset
	local groundAim = intercept(origin, projectileSpeed, gravity, groundStart, flat, 0, landTime - lead)
	return groundAim
end

return module
