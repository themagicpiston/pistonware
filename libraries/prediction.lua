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

local function finite(d)
	return type(d) == 'number' and d == d and math.abs(d) < math.huge
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

-- Real roots of c0*x^2 + c1*x + c2 = 0: none, one (a discriminant within eps of zero) or two.
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
	else
		local sqrt_D = math.sqrt(D)

		s0 = sqrt_D - p
		s1 = -sqrt_D - p
		return s0, s1
	end
end

--[[ Real roots of c0*x^3 + c1*x^2 + c2*x + c3 = 0, up to three values. In the three-root case rounding
can push the acos argument a hair outside [-1, 1]; it is clamped, since a nan there would turn every
root of the quartic built on this cubic into nan as well. ]]
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
		if isZero(q) then
			s0 = 0
			num = 1
		else
			local u = cuberoot(-q)
			s0 = 2 * u
			s1 = -u
			num = 2
		end
	elseif (D < 0) then
		local phi = (1 / 3) * math.acos(math.clamp(-q / math.sqrt(-cb_p), -1, 1))
		local t = 2 * math.sqrt(-p)

		s0 = t * math.cos(phi)
		s1 = -t * math.cos(phi + math.pi / 3)
		s2 = -t * math.cos(phi - math.pi / 3)
		num = 3
	else
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

-- How far above the feet the landing probe starts, so a target standing on a floor finds it.
local LAND_LIFT = 0.1
local LAND_SEGMENTS = 40
local LAND_LIFT_OFFSET = Vector3.new(0, LAND_LIFT, 0)

-- Where a root starting at `pos` with `vel` is after falling `tt` seconds under `grav`. A plain
-- function rather than a closure made inside findLanding, which AimAssist calls every frame.
local function fallingAt(pos, vel, grav, tt)
	return pos + vel * tt - Vector3.new(0, 0.5 * grav * tt * tt, 0)
end

--[[ When the falling target's feet (height below the root) first meet a floor within tEnd seconds;
returns that time and the root position there, or nil. The arc is walked in short chords from its
top, because a single straight ray from the root cuts the corner of the parabola and starts inside
the target's own legs; nothing is landed on while rising. A hit is a floor when its normal points
up, and the landing time is solved exactly for that surface's height. ]]
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

--[[ Raw replicated velocity is the weakest input a solve gets: it spikes on a teleport or a
rubber-band, carries a knockback at full strength for the whole flight, and can drift from
the displacement the target is actually covering. SolveTrajectory takes the target's root as
its last argument to run this filter over it, on per-root state weakly keyed by that part:

  * velocity fused from the replicated reading and the displacement actually seen over the
    last six position changes, with glitches thrown out and real changes followed within a
    frame rather than trailing a fixed smoother
  * knockback carried as a decaying impulse on top of the pre-hit velocity, with the decay
    learned from how the target's own friction eats it, rather than a speed they keep for
    the whole flight ]]
local H = Vector3.new(1, 0, 1)
local motionState = setmetatable({}, {__mode = 'k'})

-- The position samples are a ring of eight parallel slots rather than a table per sample:
-- this runs on every solve while an aim module is on, and a moving target would otherwise
-- allocate a table a frame. Reads back as sampleHead..sampleHead+sampleCount-1 (mod 8,
-- 1-based), sampleHead being the oldest.
local resetMotion = function(st, pos, vel, now)
	local samplePos, sampleTime = st.samplePos or {}, st.sampleTime or {}
	table.clear(st)
	st.time = now
	st.position = pos
	st.assembly = vel
	st.velocity = vel
	st.stable = vel
	samplePos[1], sampleTime[1] = pos, now
	st.samplePos, st.sampleTime = samplePos, sampleTime
	st.sampleHead, st.sampleCount = 1, 1
	return st
end

--[[ Filtered velocity for a root at pos moving at replicated vel, and the motion state behind it. A nil
velocity passes the raw one through: on first sighting or after 0.75 s unseen, and after a
displacement no running speed explains (a teleport or a rubber-band), which restarts the track. A
second call at the same moment returns the last filtered velocity. The caller reads the state for
its knockback fields whenever it exists. Speeds above 260 studs/s are not trusted.

Positions are sampled only when they change: replication arrives slower than frames, and counting
the frames between as samples of a target standing still would read every runner as slower than they
are. Horizontally the replicated velocity is nudged toward the measured one when the two agree, and
replaced by it when replication reads still but the target moves. Smoothing scales with how far the
reading moved, so steady movement stays damped and a real change of direction or speed is followed
within the frame.

Knockback starts on a damage tick (LastDamageTakenTime) together with a jump in velocity, or a
PlatformStand shove. The pre-hit velocity is kept as kbBase, the target's friction is learned from
the impulse dying away, and a push the other way ends it as the target moving again. ]]
local filterMotion = function(root, pos, vel, now, airborne)
	local character = root.Parent
	local humanoid = typeof(character) == 'Instance' and character:FindFirstChildWhichIsA('Humanoid') or nil
	local damageTime = typeof(character) == 'Instance' and character:GetAttribute('LastDamageTakenTime') or nil
	local st = motionState[root]
	if not st or now - st.time > 0.75 then
		st = resetMotion(st or {}, pos, vel, now)
		st.damageTime = damageTime
		motionState[root] = st
		return nil, st
	end

	local dt = now - st.time
	if dt <= 1e-4 then
		return st.velocity, st
	end

	local displacement = pos - st.position
	local limit = math.max(12, (math.max(st.velocity.Magnitude, vel.Magnitude) + 30) * dt * 1.5)
	if not finite(vel.Magnitude) or vel.Magnitude > 260 or displacement.Magnitude > limit then
		resetMotion(st, pos, finite(vel.Magnitude) and vel.Magnitude <= 260 and vel or Vector3.zero, now)
		st.damageTime = damageTime
		return nil, st
	end

	local samplePos, sampleTime = st.samplePos, st.sampleTime
	local head, count = st.sampleHead, st.sampleCount
	if count == 0 or (pos - samplePos[(head + count - 2) % 8 + 1]).Magnitude > 1e-4 then
		local slot = (head + count - 1) % 8 + 1
		samplePos[slot], sampleTime[slot] = pos, now
		count += 1
	end
	while count > 6 or (count > 2 and now - sampleTime[head] > 0.2) do
		head = head % 8 + 1
		count -= 1
	end
	st.sampleHead, st.sampleCount = head, count
	local measured
	local latest = (head + count - 2) % 8 + 1
	if count >= 2 and sampleTime[latest] - sampleTime[head] > 0.02 then
		measured = (samplePos[latest] - samplePos[head]) / (sampleTime[latest] - sampleTime[head])
		if measured.Magnitude > 260 then measured = nil end
	end

	local assemblyH = vel * H
	local horiz = assemblyH
	if measured then
		local measuredH = measured * H
		local gap = (measuredH - assemblyH).Magnitude
		if gap < math.max(6, assemblyH.Magnitude * 0.35) then
			horiz = assemblyH:Lerp(measuredH, 0.15)
		elseif assemblyH.Magnitude < 2 and measuredH.Magnitude > 2 and measuredH.Magnitude < 45 then
			horiz = measuredH
		end
	end
	local combined = Vector3.new(horiz.X, vel.Y, horiz.Z)

	local previous = st.velocity
	local previousH = previous * H
	local turned = horiz.Magnitude > 2 and previousH.Magnitude > 2 and horiz.Unit:Dot(previousH.Unit) < 0.65
	local shift = (combined - previous).Magnitude / math.max(previous.Magnitude * 0.35, 7)
	local current
	if shift >= 1 or turned then
		current = combined
	else
		local alpha = math.clamp(dt * 20, 0.2, 1)
		current = previous:Lerp(combined, alpha + (1 - alpha) * shift * shift)
	end
	local currentH = current * H

	local damaged = finite(damageTime) and damageTime > 0 and damageTime ~= st.damageTime
	st.damageTime = damageTime
	local jolt = (current - previous) * H
	local started = damaged and (jolt.Magnitude > 1.5 or math.abs(current.Y - previous.Y) > 1.5)
	if not started and humanoid and humanoid.PlatformStand then
		started = jolt.Magnitude > 5 or math.abs(current.Y - previous.Y) > 5
	end
	if started then
		st.kbBase = st.stable * H
		st.kbDecay = airborne and 1.8 or 3.5
		st.kbStart = now
		st.kbUntil = now + 0.6
		st.kbImpulse = nil
	end
	local knocked = st.kbUntil ~= nil and now < st.kbUntil
	if knocked then
		local impulse = currentH - st.kbBase
		local last = st.kbImpulse
		if last and last.Magnitude > 4 and impulse.Magnitude > 4 and last.Unit:Dot(impulse.Unit) < 0.35 then
			st.kbUntil, knocked = nil, false
		elseif last and last.Magnitude > 3 and impulse.Magnitude > 3
			and last.Unit:Dot(impulse.Unit) > 0.8 and impulse.Magnitude < last.Magnitude then
			local decay = -math.log(impulse.Magnitude / last.Magnitude) / dt
			if finite(decay) and decay > 0 then
				st.kbDecay += (math.clamp(decay, 0.75, 8) - st.kbDecay) * 0.35
			end
		end
		if knocked then
			if impulse.Magnitude < 3 and now - st.kbStart > 0.1 then
				st.kbUntil, knocked = nil, false
			else
				st.kbImpulse = impulse
			end
		end
	end
	if not knocked then
		st.kbImpulse = nil
		st.stable = current
	end
	st.knocked = knocked

	st.assembly = vel
	st.position = pos
	st.time = now
	st.velocity = current
	return current, st
end

--[[ Earliest flight time at which a projectile of `speed`, launched from `origin` under the
constant `acceleration`, meets a target whose position `t` seconds out is positionAt(t) --
the numeric counterpart of intercept's quartic, for paths the quartic cannot express (the
decaying knockback below). |positionAt(t) - origin - acceleration t^2/2|^2 - speed^2 t^2 is
sampled along a grid that spreads from tMin out to at most twelve seconds and the first sign
change bisected to convergence. nil when nothing that far reaches. ]]
local function solveMotionTime(origin, speed, acceleration, positionAt, tMin)
	local function evaluate(t)
		local offset = positionAt(t) - origin - acceleration * (0.5 * t * t)
		return offset:Dot(offset) - speed * speed * t * t
	end

	local start = math.max(tMin or 0, 0)
	local startValue = evaluate(start)
	if not finite(startValue) then
		return
	end
	local distance = (positionAt(start) - origin).Magnitude
	local maximum = math.min(math.max(distance / speed * 4 + 1, start + 2), 12)
	local low, lowValue = start, startValue
	for step = 1, 72 do
		local high = start + (maximum - start) * (step / 72) ^ 1.35
		local highValue = evaluate(high)
		if not finite(highValue) then
			return
		end
		if math.abs(highValue) < math.max(1e-7, speed * speed * high * high * 1e-7) then
			return high
		end
		if (highValue > 0) ~= (lowValue > 0) then
			for _ = 1, 60 do
				local middle = (low + high) * 0.5
				if (evaluate(middle) > 0) == (lowValue > 0) then
					low = middle
				else
					high = middle
				end
			end
			return high
		end
		low, lowValue = high, highValue
	end
end

-- Launch onto a target whose horizontal offset from `targetPos`, `total` seconds from now,
-- is offsetAt(total) and whose height then is yAt(total): the decaying-knockback path solved
-- numerically. Returns the aim point and flight time in intercept's shapes.
local function solveDecaying(origin, speed, gravity, targetPos, aimOffset, lead, offsetAt, yAt)
	local positionAt = function(t)
		local total = lead + t
		local offset = offsetAt(total)
		return Vector3.new(
			targetPos.X + offset.X + aimOffset.X,
			yAt(total) + aimOffset.Y,
			targetPos.Z + offset.Z + aimOffset.Z)
	end
	local t = solveMotionTime(origin, speed, Vector3.new(0, -gravity, 0), positionAt)
	if not t then
		return nil
	end
	local future = positionAt(t)
	return origin + (future - origin - Vector3.new(0, -0.5 * gravity * t * t, 0)) / t, t
end

--[[ Whether the launch arc a solve returned actually reaches the target. The aim point
SolveTrajectory returns is origin plus launch velocity, so the arc is walked from it in ten
chords and each one cast: the first thing struck that is not the target's own character
blocks the shot. A straight sight-line check is not enough -- a bow's arc drops below the
line to the target and clips edges the line clears. `ignored`, when given, is asked per hit;
parts it accepts are added to the filter and the chord recast through them. ]]
function module.IsTrajectoryClear(origin, solution, gravity, flight, params, target, ignored)
	local velocity = solution - origin
	local clearRay = RaycastParams.new()
	clearRay.FilterType = params.FilterType
	clearRay.FilterDescendantsInstances = params.FilterDescendantsInstances
		and table.clone(params.FilterDescendantsInstances) or {}
	clearRay.IgnoreWater = params.IgnoreWater
	clearRay.RespectCanCollide = params.RespectCanCollide
	if params.CollisionGroup then
		clearRay.CollisionGroup = params.CollisionGroup
	end
	local character = typeof(target) == 'Instance' and target.Parent or nil
	local lastPosition = origin
	for step = 1, 10 do
		local t = flight * (step / 10)
		local position = origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
		local direction = position - lastPosition
		local hit = workspace:Raycast(lastPosition, direction, clearRay)
		local seen = 0
		while hit do
			seen += 1
			if seen > 8 then
				return false
			end
			local instance = hit.Instance
			if instance == target or (character and instance:IsDescendantOf(character)) then
				return true
			end
			if not ignored or not ignored(instance) then
				return false
			end
			clearRay:AddToFilter(instance)
			hit = workspace:Raycast(lastPosition, direction, clearRay)
		end
		lastPosition = position
	end
	return true
end

--[[ Aim point for a projectile (origin and launch speed) onto a moving target, and the flight time on
every solved path so a caller can walk the arc, or nil when no launch at this speed reaches it. ping
ages the target by up to 1 s; offset is the aimed part's offset from targetPos, carried along;
playerJump is unused.

Without params the target keeps a constant velocity. With params, playerGravity and an airborne
target (nil airborne is inferred from the vertical velocity), it falls under its own gravity, solved
exactly, until its feet (playerHeight below the root) meet a floor, and from then on keeps its run
speed along it, with the intercept after the landing. Passing targetRoot turns on filterMotion:
during a knockback the push is carried as a decaying impulse on top of the pre-hit velocity rather
than the full reading extrapolated for the whole flight, and that case is solved numerically. ]]
function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params, offset, ping, airborne, targetRoot)
	local aimOffset = offset or Vector3.zero
	local lead = (ping and ping > 0) and math.min(ping, 1) or 0

	if airborne == nil then
		airborne = math.abs(targetVelocity.Y) > 0.01
	end

	local motion
	if targetRoot ~= nil and typeof(targetRoot) == 'Instance' then
		local filtered
		filtered, motion = filterMotion(targetRoot, targetPos, targetVelocity, os.clock(), airborne)
		if filtered then
			targetVelocity = filtered
		end
	end

	local kbOffset
	if motion and motion.knocked and motion.kbImpulse and motion.kbBase then
		local impulse, decay, base = motion.kbImpulse, math.max(motion.kbDecay or 1.8, 1e-3), motion.kbBase
		kbOffset = function(total)
			return base * total + impulse * ((1 - math.exp(-decay * total)) / decay)
		end
	end

	if not (airborne and playerGravity and playerGravity > 0 and params) then
		if kbOffset then
			local velY = targetVelocity.Y
			return solveDecaying(origin, projectileSpeed, gravity, targetPos, aimOffset, lead, kbOffset,
				function(total)
					return targetPos.Y + velY * total
				end)
		end
		return intercept(origin, projectileSpeed, gravity,
			targetPos + targetVelocity * lead + aimOffset, targetVelocity, 0)
	end

	local height = playerHeight or 0
	local g = playerGravity

	if kbOffset then
		local horizon = lead + 2 * (targetPos - origin).Magnitude / math.max(projectileSpeed, 1e-3)
		local landTime, landPos = findLanding(targetPos, targetVelocity, g, height, params, horizon)
		local velY = targetVelocity.Y
		return solveDecaying(origin, projectileSpeed, gravity, targetPos, aimOffset, lead, kbOffset,
			function(total)
				if landTime and total >= landTime then
					return landPos.Y
				end
				return targetPos.Y + velY * total - 0.5 * g * total * total
			end)
	end

	local startPos = targetPos + targetVelocity * lead - Vector3.new(0, 0.5 * g * lead * lead, 0)
	local startVel = targetVelocity - Vector3.new(0, g * lead, 0)
	local aim, t = intercept(origin, projectileSpeed, gravity, startPos + aimOffset, startVel, g)

	local horizon = lead + (t or 2 * (startPos - origin).Magnitude / projectileSpeed)
	local landTime, landPos = findLanding(targetPos, targetVelocity, g, height, params, horizon)
	if not landTime then
		return aim, t
	end

	local flat = Vector3.new(targetVelocity.X, 0, targetVelocity.Z)
	local groundStart = landPos + flat * (lead - landTime) + aimOffset
	local groundAim, groundTime = intercept(origin, projectileSpeed, gravity, groundStart, flat, 0, landTime - lead)
	return groundAim, groundTime
end

return module
