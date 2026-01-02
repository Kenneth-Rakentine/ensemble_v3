-- ENSEMBLE v3.4
-- Penderecki String Texture Generator
-- Dual-Layer: MASS (smeared bowing) + DUST (stippled friction)
--
-- K2: Toggle active | K3: Clear buffer
-- E1: Intensity | E2: Character (dust↔mass) | E3: Movement

sc = softcut

local PHI = 1.618033988749895
local TAU = 2 * math.pi
local BUFFER_LENGTH = 60

-- Voice allocation: 1-2 record, 3-4 MASS, 5-6 DUST
local MASS_VOICES = {3, 4}
local DUST_VOICES = {5, 6}

local lfsr = 0xACE1
local function lfsr_next()
  local bit = ((lfsr >> 0) ~ (lfsr >> 2) ~ (lfsr >> 3) ~ (lfsr >> 5)) & 1
  lfsr = (lfsr >> 1) | (bit << 15)
  return lfsr / 65536
end
local function lfsr_range(min, max) return min + lfsr_next() * (max - min) end

-- State
local active = false
local positions = {0, 0}
local current_amp, smoothed_amp, peak_amp = 0, 0, 0
local time_elapsed = 0

-- Voice states
local mass_state = {{busy=false, start=0}, {busy=false, start=0}}
local dust_state = {{busy=false, start=0}, {busy=false, start=0}}

local fragments = {}
local MAX_FRAGMENTS = 60

local evolving = { intensity = 85, character = 60, movement = 90 }
local lfo = { mass = 0, dust = 0, swirl = 0 }

local last_mass_time = 0
local last_dust_time = 0

-- Fragment capture
local function capture_fragment(target_length)
  local pos = positions[1]
  if pos < 2 then return nil end
  local len = target_length or lfsr_range(0.3, 1.5)
  local frag_pos = pos - len - 0.1
  if frag_pos < 1 then frag_pos = frag_pos + BUFFER_LENGTH end
  local frag = { pos = frag_pos, length = len }
  table.insert(fragments, 1, frag)
  while #fragments > MAX_FRAGMENTS do table.remove(fragments) end
  return frag
end

local function get_fragment()
  if #fragments == 0 then return nil end
  return fragments[math.floor(lfsr_next() * lfsr_next() * #fragments) + 1]
end

local function clear_all()
  sc.buffer_clear()
  fragments = {}
  for _, v in ipairs(MASS_VOICES) do sc.level(v, 0); sc.play(v, 0) end
  for _, v in ipairs(DUST_VOICES) do sc.level(v, 0); sc.play(v, 0) end
  mass_state = {{busy=false, start=0}, {busy=false, start=0}}
  dust_state = {{busy=false, start=0}, {busy=false, start=0}}
  print(">>> CLEARED")
end

-- Position callback
local function update_positions(i, x) positions[i] = x end

------------------------------------------------------------
-- MASS LAYER: Long smeared bowing gestures
------------------------------------------------------------

local function play_mass(frag, pan, level)
  -- Find free mass voice
  local idx, voice = nil, nil
  for i, s in ipairs(mass_state) do
    if not s.busy then idx, voice = i, MASS_VOICES[i]; break end
  end
  if not voice then
    -- Steal oldest
    idx = mass_state[1].start < mass_state[2].start and 1 or 2
    voice = MASS_VOICES[idx]
  end
  
  clock.run(function()
    mass_state[idx].busy = true
    mass_state[idx].start = time_elapsed
    
    local len = lfsr_range(0.8, 2.0)  -- Long grains
    
    sc.loop_start(voice, frag.pos)
    sc.loop_end(voice, frag.pos + math.min(frag.length, len))
    sc.position(voice, frag.pos)
    sc.rate(voice, 1)
    sc.pan(voice, pan)
    
    -- VERY SLOW ATTACK (smeared onset)
    sc.level(voice, 0)
    sc.level_slew_time(voice, lfsr_range(0.15, 0.35))
    sc.play(voice, 1)
    sc.level(voice, level)
    
    -- Sustain with slow pan drift
    local sustain = len * lfsr_range(0.8, 1.2)
    local drift_time = 0
    while drift_time < sustain do
      clock.sleep(0.1)
      drift_time = drift_time + 0.1
      local drift = math.sin(lfo.swirl + drift_time) * evolving.movement / 100 * 0.15
      sc.pan(voice, util.clamp(pan + drift, -1, 1))
    end
    
    -- VERY SLOW RELEASE (smeared decay)
    sc.level_slew_time(voice, lfsr_range(0.25, 0.5))
    sc.level(voice, 0)
    clock.sleep(0.5)
    
    sc.play(voice, 0)
    mass_state[idx].busy = false
  end)
end

------------------------------------------------------------
-- DUST LAYER: Short stippled friction
------------------------------------------------------------

local function play_dust(frag, pan, level)
  -- Find free dust voice
  local idx, voice = nil, nil
  for i, s in ipairs(dust_state) do
    if not s.busy then idx, voice = i, DUST_VOICES[i]; break end
  end
  if not voice then
    idx = dust_state[1].start < dust_state[2].start and 1 or 2
    voice = DUST_VOICES[idx]
  end
  
  clock.run(function()
    dust_state[idx].busy = true
    dust_state[idx].start = time_elapsed
    
    local len = lfsr_range(0.03, 0.12)  -- Short grains
    
    sc.loop_start(voice, frag.pos)
    sc.loop_end(voice, frag.pos + len)
    sc.position(voice, frag.pos)
    sc.rate(voice, 1)
    sc.pan(voice, pan)
    
    -- Soft but quicker attack (not harsh, but defined)
    sc.level(voice, 0)
    sc.level_slew_time(voice, 0.015)
    sc.play(voice, 1)
    sc.level(voice, level)
    
    clock.sleep(len * 1.2)
    
    -- Quick but soft release
    sc.level_slew_time(voice, 0.025)
    sc.level(voice, 0)
    clock.sleep(0.03)
    
    sc.play(voice, 0)
    dust_state[idx].busy = false
  end)
end

------------------------------------------------------------
-- TRIGGER LOGIC
------------------------------------------------------------

local function maybe_trigger()
  if not active then return end
  if #fragments < 1 then
    capture_fragment(lfsr_range(0.5, 1.5))
    return
  end
  
  local now = time_elapsed
  local int = evolving.intensity / 100
  local char = evolving.character / 100  -- 0=dust, 1=mass
  local mov = evolving.movement / 100
  
  -- Capture new fragments from input
  if smoothed_amp > 0.02 and lfsr_next() < 0.15 then
    capture_fragment(lfsr_range(0.3, 1.2))
  end
  
  -- MASS triggers (slow, glacial)
  local mass_interval = 1.5 - int * 0.8 - char * 0.4
  local mass_mod = math.sin(lfo.mass) * 0.3 + 0.7
  if now - last_mass_time > mass_interval * mass_mod then
    if lfsr_next() < 0.4 + char * 0.5 then
      local frag = get_fragment()
      if frag then
        local pan = (lfsr_next() - 0.5) * 1.6 * mov
        local level = 0.5 + char * 0.3 + lfsr_next() * 0.2
        play_mass(frag, pan, level)
      end
    end
    last_mass_time = now
  end
  
  -- DUST triggers (quicker, but breathing)
  local dust_interval = 0.15 - int * 0.08 - (1 - char) * 0.04
  local dust_mod = math.sin(lfo.dust) * 0.4 + 0.6
  if now - last_dust_time > dust_interval * dust_mod then
    if lfsr_next() < 0.3 + (1 - char) * 0.5 + smoothed_amp then
      local frag = get_fragment()
      if frag then
        local pan = (lfsr_next() - 0.5) * 2 * mov
        local level = 0.35 + (1 - char) * 0.25 + lfsr_next() * 0.15
        play_dust(frag, pan, level)
      end
    end
    last_dust_time = now
  end
end

------------------------------------------------------------
-- EVOLUTION & LFOs
------------------------------------------------------------

local function evolve_parameters(dt)
  local drift = 0.008 * dt
  evolving.intensity = evolving.intensity + (util.clamp(78 + lfsr_next()*22 + smoothed_amp*8, 70, 100) - evolving.intensity) * drift * 0.3
  evolving.character = evolving.character + (util.clamp(45 + lfsr_next()*40 + smoothed_amp*10, 35, 85) - evolving.character) * drift * 0.5
  evolving.movement = evolving.movement + (util.clamp(80 + lfsr_next()*18, 75, 98) - evolving.movement) * drift * 0.2
end

local function update_lfos(dt)
  lfo.mass = (lfo.mass + dt * 0.08) % TAU      -- Very slow
  lfo.dust = (lfo.dust + dt * 0.25) % TAU      -- Breathing
  lfo.swirl = (lfo.swirl + dt * 0.4 * evolving.movement / 100) % TAU
end

------------------------------------------------------------
-- INPUT & SETUP
------------------------------------------------------------

local function process_input(amp)
  current_amp = amp
  smoothed_amp = smoothed_amp * 0.92 + amp * 0.08
  peak_amp = amp > peak_amp and amp or peak_amp * 0.994
end

local function setup_softcut()
  sc.buffer_clear()
  
  -- Recording voices (1-2)
  for i = 1, 2 do
    sc.enable(i, 1)
    sc.buffer(i, i)
    sc.level(i, 0.6)
    sc.rec_level(i, 1.0)
    sc.pre_level(i, 0.85)  -- High feedback for layering!
    sc.loop(i, 1)
    sc.loop_start(i, 1)
    sc.loop_end(i, BUFFER_LENGTH)
    sc.position(i, 1)
    sc.play(i, 1)
    sc.rec(i, 0)
    sc.rate(i, 1)
    sc.fade_time(i, 0.02)
    sc.pre_filter_dry(i, 1)
  end
  sc.pan(1, 0.25); sc.pan(2, -0.25)
  sc.level_input_cut(1, 1, 1); sc.level_input_cut(2, 1, 0)
  sc.level_input_cut(1, 2, 0); sc.level_input_cut(2, 2, 1)
  
  -- MASS voices (3-4): warm, slightly filtered
  for _, v in ipairs(MASS_VOICES) do
    sc.enable(v, 1)
    sc.buffer(v, 1)
    sc.level(v, 0)
    sc.loop(v, 1)
    sc.play(v, 0)
    sc.rec(v, 0)
    sc.rate(v, 1)
    sc.fade_time(v, 0.01)
    sc.level_slew_time(v, 0.2)
    sc.pan_slew_time(v, 0.15)
    -- Slight warmth
    sc.post_filter_dry(v, 0.7)
    sc.post_filter_lp(v, 0.3)
    sc.post_filter_fc(v, 5000)
  end
  
  -- DUST voices (5-6): brighter, sul ponticello character
  for _, v in ipairs(DUST_VOICES) do
    sc.enable(v, 1)
    sc.buffer(v, 1)
    sc.level(v, 0)
    sc.loop(v, 1)
    sc.play(v, 0)
    sc.rec(v, 0)
    sc.rate(v, 1)
    sc.fade_time(v, 0.005)
    sc.level_slew_time(v, 0.02)
    sc.pan_slew_time(v, 0.05)
    -- Brighter, slight HP for glassy character
    sc.post_filter_dry(v, 0.6)
    sc.post_filter_hp(v, 0.2)
    sc.post_filter_lp(v, 0.2)
    sc.post_filter_fc(v, 3000)
    sc.post_filter_rq(v, 2.5)
  end
  
  sc.event_phase(update_positions)
  sc.poll_start_phase()
end

local function setup_params()
  params:add_separator("ENSEMBLE")
  params:add_number("intensity", "Intensity", 0, 100, 85)
  params:add_number("character", "Character", 0, 100, 60)
  params:add_number("movement", "Movement", 0, 100, 90)
  params:add_separator("MIX")
  params:add_number("rev_amt", "Reverb", 0, 100, 65)
  params:add_number("monitor", "Monitor", 0, 100, 60)
  params:add_number("feedback", "Feedback", 0, 100, 85)
  
  params:set_action("rev_amt", function(x) audio.level_cut_rev(x/100) end)
  params:set_action("monitor", function(x) for i=1,2 do sc.level(i, x/100) end end)
  params:set_action("feedback", function(x) for i=1,2 do sc.pre_level(i, x/100) end end)
  params:set_action("intensity", function(x) evolving.intensity = x end)
  params:set_action("character", function(x) evolving.character = x end)
  params:set_action("movement", function(x) evolving.movement = x end)
end

------------------------------------------------------------
-- UI
------------------------------------------------------------

function redraw()
  screen.clear()
  
  screen.level(active and 15 or 4)
  screen.move(64, 8)
  screen.text_center(active and "● ENSEMBLE" or "○ STANDBY")
  
  -- Parameters
  screen.level(8)
  screen.move(4, 20); screen.text("INT")
  screen.move(46, 20); screen.text("CHR")
  screen.move(88, 20); screen.text("MOV")
  screen.level(15)
  screen.move(4, 30); screen.text(string.format("%.0f", evolving.intensity))
  screen.move(46, 30); screen.text(string.format("%.0f", evolving.character))
  screen.move(88, 30); screen.text(string.format("%.0f", evolving.movement))
  
  -- Layer visualization
  local y = 44
  
  -- MASS voices (left side, larger circles)
  screen.level(10)
  screen.move(10, 38); screen.text("M")
  for i, s in ipairs(mass_state) do
    local x = 25 + (i-1) * 20
    if s.busy then
      screen.level(12)
      screen.circle(x, y, 5)
      screen.fill()
    else
      screen.level(3)
      screen.circle(x, y, 4)
      screen.stroke()
    end
  end
  
  -- DUST voices (right side, smaller dots)
  screen.level(10)
  screen.move(75, 38); screen.text("D")
  for i, s in ipairs(dust_state) do
    local x = 90 + (i-1) * 18
    if s.busy then
      screen.level(15)
      screen.circle(x, y, 2)
      screen.fill()
    else
      screen.level(2)
      screen.circle(x, y, 2)
      screen.stroke()
    end
  end
  
  -- Fragment count & LFO indicators
  screen.level(5)
  screen.move(4, 54); screen.text("f:" .. #fragments)
  
  -- Breathing indicator
  local breath = math.sin(lfo.mass) * 3
  screen.level(6)
  screen.circle(60, 52 + breath, 2)
  screen.fill()
  
  -- Input meter
  screen.level(2); screen.rect(4, 58, 100, 4); screen.stroke()
  screen.level(active and 10 or 4)
  screen.rect(5, 59, math.min(98, smoothed_amp * 500), 2); screen.fill()
  screen.level(15)
  screen.move(5 + math.min(97, peak_amp * 500), 58)
  screen.line_rel(0, 4); screen.stroke()
  
  screen.update()
end

------------------------------------------------------------
-- CONTROLS
------------------------------------------------------------

function enc(n, d)
  if n == 1 then params:delta("intensity", d); evolving.intensity = params:get("intensity")
  elseif n == 2 then params:delta("character", d); evolving.character = params:get("character")
  elseif n == 3 then params:delta("movement", d); evolving.movement = params:get("movement") end
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    active = not active
    for i = 1, 2 do sc.rec(i, active and 1 or 0) end
    print(active and "=== ACTIVE ===" or "=== STANDBY ===")
  elseif n == 3 then
    clear_all()
  end
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------

local function main_update()
  local dt = 1/30
  time_elapsed = time_elapsed + dt
  update_lfos(dt)
  evolve_parameters(dt)
  maybe_trigger()
  redraw()
end

function init()
  print("")
  print("================================")
  print("ENSEMBLE v3.4")
  print("MASS + DUST dual-layer")
  print("================================")
  print("Character: dust ← → mass")
  print("================================")
  
  audio.level_cut(1)
  audio.level_adc_cut(1)
  audio.level_eng_cut(0)
  
  setup_params()
  setup_softcut()
  
  local p = poll.set("amp_in_l")
  p.time = 0.025
  p.callback = process_input
  p:start()
  
  metro.init(main_update, 1/30):start()
  
  audio.rev_on()
  params:bang()
end

function cleanup()
  sc.poll_stop_phase()
end
