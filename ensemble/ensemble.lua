-- ENSEMBLE
-- Penderecki String Texture Generator
-- v3.1 - Smooth Grains + Continuous Activity
--
-- K2: Toggle active (recording + processing)
-- K3: Manual burst
-- E1: Intensity (sparse → dense)
-- E2: Character (percussive → sustained)
-- E3: Movement (static → wild)

sc = softcut

------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------

local PHI = 1.618033988749895
local TAU = 2 * math.pi
local BUFFER_LENGTH = 60
local NUM_PLAY_VOICES = 4

-- Fragment length ranges (ms) - longer for smoother sound
local FRAG_MICRO = {30, 80}
local FRAG_SHORT = {80, 200}
local FRAG_MEDIUM = {200, 500}
local FRAG_LONG = {500, 1200}

-- Compressed Fibonacci for cascade
local FIB = {0, 21, 34, 55, 89, 144, 233, 377, 610, 987}

------------------------------------------------------------
-- LFSR for organic randomness
------------------------------------------------------------

local lfsr = 0xACE1
local function lfsr_next()
  local bit = ((lfsr >> 0) ~ (lfsr >> 2) ~ (lfsr >> 3) ~ (lfsr >> 5)) & 1
  lfsr = (lfsr >> 1) | (bit << 15)
  return lfsr / 65536
end

local function lfsr_range(min, max)
  return min + lfsr_next() * (max - min)
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local active = false
local positions = {0, 0}
local current_amp = 0
local smoothed_amp = 0
local peak_amp = 0
local time_elapsed = 0

-- Voice state with velocity
local voices = {}
for i = 1, NUM_PLAY_VOICES do
  voices[i] = {
    busy = false,
    pan = 0,
    pan_velocity = 0,
    target_pan = 0,
    generation = 0,
    start_time = 0
  }
end

-- Fragment pool
local fragments = {}
local MAX_FRAGMENTS = 60

-- Evolving parameters
local evolving = {
  cascade_size = 5,
  cluster_spread = 80,
  weave_speed = 1.0,
  frag_bias = 0.5,
  density = 0.5,
  movement = 0.5,
  filter_center = 5000,
  detune_drift = 15,
}

-- LFO phases
local lfo = {
  breath = 0,
  swirl = 0,
  density = 0,
  pitch = 0,
}

-- Timing
local last_trigger_time = 0
local continuous_trigger_time = 0

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function cents_to_rate(cents)
  return math.pow(2, cents / 1200)
end

local function get_frag_length()
  local bias = evolving.frag_bias
  local r = lfsr_next()
  
  local ranges
  if r < 0.2 * (1 - bias) then
    ranges = FRAG_MICRO
  elseif r < 0.5 then
    ranges = FRAG_SHORT
  elseif r < 0.8 then
    ranges = FRAG_MEDIUM
  else
    ranges = FRAG_LONG
  end
  
  return lfsr_range(ranges[1], ranges[2]) / 1000
end

------------------------------------------------------------
-- INPUT ROUTING
------------------------------------------------------------

local function set_input_stereo()
  sc.level_input_cut(1, 1, 1)
  sc.level_input_cut(2, 1, 0)
  sc.level_input_cut(1, 2, 0)
  sc.level_input_cut(2, 2, 1)
end

------------------------------------------------------------
-- POSITION CALLBACK
------------------------------------------------------------

local function update_positions(i, x)
  positions[i] = x
end

------------------------------------------------------------
-- FRAGMENT CAPTURE
------------------------------------------------------------

local function capture_fragment()
  local pos = positions[1]
  if pos < 2 then return nil end
  
  local len = get_frag_length()
  local frag_pos = pos - len - 0.05
  if frag_pos < 1 then
    frag_pos = frag_pos + BUFFER_LENGTH
  end
  
  local frag = {
    pos = frag_pos,
    length = len,
    brightness = smoothed_amp,
    time = time_elapsed
  }
  
  table.insert(fragments, 1, frag)
  while #fragments > MAX_FRAGMENTS do
    table.remove(fragments)
  end
  
  return frag
end

local function get_fragment()
  if #fragments == 0 then return nil end
  local idx = math.floor(lfsr_next() * lfsr_next() * #fragments) + 1
  return fragments[math.min(idx, #fragments)]
end

------------------------------------------------------------
-- VOICE MANAGEMENT
------------------------------------------------------------

local function find_voice()
  local oldest_idx = 1
  local oldest_time = voices[1].start_time
  
  for i = 1, NUM_PLAY_VOICES do
    if not voices[i].busy then
      return i
    end
    if voices[i].start_time < oldest_time then
      oldest_time = voices[i].start_time
      oldest_idx = i
    end
  end
  
  return oldest_idx
end

local function update_voice_motion(dt)
  local movement = evolving.movement
  
  for i = 1, NUM_PLAY_VOICES do
    local v = voices[i]
    local sc_voice = i + 2
    
    if v.busy then
      -- Smooth pan movement toward target
      local diff = v.target_pan - v.pan
      v.pan = v.pan + diff * dt * 3
      
      -- Add swirl
      local swirl = math.sin(lfo.swirl * 2 + i * PHI) * movement * 0.15
      local final_pan = util.clamp(v.pan + swirl, -1, 1)
      
      sc.pan(sc_voice, final_pan)
    end
  end
end

------------------------------------------------------------
-- PLAY FRAGMENT WITH PROPER ENVELOPE
------------------------------------------------------------

local function play_fragment(frag, delay_ms, pitch_cents, pan, level, generation)
  local voice_idx = find_voice()
  local sc_voice = voice_idx + 2
  
  clock.run(function()
    if delay_ms > 0 then
      clock.sleep(delay_ms / 1000)
    end
    
    -- Bucket brigade degradation
    local filter_mult = math.pow(0.6, generation)
    local cutoff = evolving.filter_center * filter_mult
    cutoff = math.max(cutoff, 200)
    
    local drift = evolving.detune_drift * generation * (lfsr_next() - 0.5)
    local final_pitch = pitch_cents + drift
    local rate = cents_to_rate(final_pitch)
    local final_level = level * math.pow(0.8, generation)
    
    -- IMPORTANT: Set up for smooth envelope
    -- Start at zero, then fade in
    sc.level(sc_voice, 0)
    sc.level_slew_time(sc_voice, 0.01)  -- Quick initial set
    
    -- Configure playback
    sc.rate(sc_voice, rate)
    sc.loop_start(sc_voice, frag.pos)
    sc.loop_end(sc_voice, frag.pos + frag.length)
    sc.position(sc_voice, frag.pos)
    sc.post_filter_fc(sc_voice, cutoff)
    
    -- Set voice state
    voices[voice_idx].pan = pan
    voices[voice_idx].target_pan = pan + (lfsr_next() - 0.5) * evolving.movement
    voices[voice_idx].busy = true
    voices[voice_idx].generation = generation
    voices[voice_idx].start_time = time_elapsed
    
    sc.pan(sc_voice, pan)
    sc.play(sc_voice, 1)
    
    -- ATTACK: Fade in smoothly
    local attack_time = 0.01 + frag.length * 0.1
    attack_time = math.min(attack_time, 0.1)
    sc.level_slew_time(sc_voice, attack_time)
    sc.level(sc_voice, final_level)
    
    clock.sleep(attack_time)
    
    -- SUSTAIN: Play the fragment
    local sustain_time = frag.length * (1 + lfsr_next() * 0.5)
    clock.sleep(sustain_time)
    
    -- RELEASE: Fade out smoothly
    local release_time = 0.05 + frag.length * 0.2
    release_time = math.min(release_time, 0.3)
    sc.level_slew_time(sc_voice, release_time)
    sc.level(sc_voice, 0)
    
    clock.sleep(release_time + 0.02)
    
    sc.play(sc_voice, 0)
    voices[voice_idx].busy = false
  end)
end

------------------------------------------------------------
-- CASCADE TRIGGER
------------------------------------------------------------

local function trigger_cascade(intensity)
  local frag = get_fragment()
  if not frag then
    frag = capture_fragment()
    if not frag then return end
  end
  
  local base_size = evolving.cascade_size
  local size = math.floor(base_size * (0.6 + intensity))
  size = util.clamp(size, 2, 10)
  
  local breath = math.sin(lfo.breath) * 0.5 + 0.5
  local timing_mult = 0.4 + breath * 1.2
  
  for i = 1, size do
    local base_delay = FIB[math.min(i, #FIB)]
    local delay = (base_delay * timing_mult) / evolving.weave_speed
    
    -- Microtonal cluster
    local pitch_lfo = math.sin(lfo.pitch + i * 0.8) * 15
    local pitch = (lfsr_next() - 0.5) * 2 * evolving.cluster_spread + pitch_lfo
    
    -- Spiral panning
    local angle = i * PHI * TAU + lfo.swirl
    local radius = 0.4 + intensity * 0.5
    local pan = math.sin(angle) * radius * (params:get("movement") / 100)
    
    local level_decay = math.pow(0.88, i - 1)
    local level = level_decay * (0.8 + intensity * 0.2)
    
    local gen = math.floor((i - 1) / 2)
    
    play_fragment(frag, delay, pitch, pan, level, gen)
  end
end

------------------------------------------------------------
-- EVOLVE PARAMETERS
------------------------------------------------------------

local function evolve_parameters(dt)
  local drift_rate = 0.03 * dt
  
  local target_size = 4 + smoothed_amp * 6 + lfsr_next() * 2
  evolving.cascade_size = evolving.cascade_size + (target_size - evolving.cascade_size) * drift_rate * 4
  
  local target_spread = 50 + lfsr_next() * 80 + peak_amp * 50
  evolving.cluster_spread = evolving.cluster_spread + (target_spread - evolving.cluster_spread) * drift_rate
  
  local target_weave = 0.8 + lfsr_next() * 1.2 + smoothed_amp * 0.5
  evolving.weave_speed = evolving.weave_speed + (target_weave - evolving.weave_speed) * drift_rate * 2
  
  local target_bias = 0.3 + smoothed_amp * 0.4 + lfsr_next() * 0.3
  evolving.frag_bias = evolving.frag_bias + (target_bias - evolving.frag_bias) * drift_rate * 2
  
  local target_movement = 0.3 + lfsr_next() * 0.5 + (params:get("movement") / 100) * 0.3
  evolving.movement = evolving.movement + (target_movement - evolving.movement) * drift_rate
  
  local target_filter = 3000 + lfsr_next() * 5000 + smoothed_amp * 2000
  evolving.filter_center = evolving.filter_center + (target_filter - evolving.filter_center) * drift_rate
  
  local base_density = params:get("intensity") / 100
  evolving.density = base_density * (0.3 + smoothed_amp * 2) + 0.1
end

------------------------------------------------------------
-- UPDATE LFOs
------------------------------------------------------------

local function update_lfos(dt)
  local movement = params:get("movement") / 100
  
  lfo.breath = (lfo.breath + dt * 0.4 * (0.5 + evolving.density)) % TAU
  lfo.swirl = (lfo.swirl + dt * 1.2 * movement) % TAU
  lfo.density = (lfo.density + dt * 0.2) % TAU
  lfo.pitch = (lfo.pitch + dt * 0.5) % TAU
end

------------------------------------------------------------
-- AUTOMATIC TRIGGERS
------------------------------------------------------------

local function maybe_trigger()
  if not active then return end
  
  local now = time_elapsed
  
  -- Continuous background activity (even without input)
  local continuous_interval = 0.15 + (1 - evolving.density) * 0.4
  if now - continuous_trigger_time > continuous_interval then
    if #fragments > 3 then
      -- Background cascade from existing fragments
      local intensity = 0.3 + lfsr_next() * 0.3
      trigger_cascade(intensity)
      continuous_trigger_time = now
    end
  end
  
  -- Input-reactive triggers
  local min_interval = 0.05 + (1 - evolving.density) * 0.1
  if now - last_trigger_time < min_interval then return end
  
  -- Trigger probability based on amplitude and density
  local density_mod = math.sin(lfo.density) * 0.3 + 0.7
  local trigger_prob = evolving.density * density_mod * (0.3 + smoothed_amp * 2)
  
  if lfsr_next() < trigger_prob * 0.2 then
    -- Capture new fragment when we have input
    if smoothed_amp > 0.01 then
      capture_fragment()
    end
    
    local intensity = 0.4 + smoothed_amp * 0.6 + lfsr_next() * 0.2
    trigger_cascade(intensity)
    last_trigger_time = now
  end
end

------------------------------------------------------------
-- INPUT PROCESSING
------------------------------------------------------------

local function process_input(amp)
  current_amp = amp
  smoothed_amp = smoothed_amp * 0.9 + amp * 0.1
  
  if amp > peak_amp then
    peak_amp = amp
  else
    peak_amp = peak_amp * 0.993
  end
end

------------------------------------------------------------
-- SOFTCUT SETUP
------------------------------------------------------------

local function setup_softcut()
  sc.buffer_clear()
  
  -- Voices 1-2: Recording (higher output level)
  for i = 1, 2 do
    sc.enable(i, 1)
    sc.buffer(i, i)
    sc.level(i, 1.0)  -- Full monitoring level
    sc.rec_level(i, 1.0)
    sc.loop(i, 1)
    sc.loop_start(i, 1)
    sc.loop_end(i, BUFFER_LENGTH)
    sc.position(i, 1)
    sc.play(i, 1)
    sc.fade_time(i, 0.01)
    sc.pre_level(i, 0.75)
    sc.rec(i, 0)
    sc.rate(i, 1)
    sc.phase_quant(i, 0.05)
    sc.rate_slew_time(i, 0.1)
    sc.level_slew_time(i, 0.05)
    sc.pre_filter_dry(i, 1)
    sc.pre_filter_lp(i, 0)
    sc.pre_filter_hp(i, 0)
    sc.pre_filter_bp(i, 0)
    sc.pre_filter_br(i, 0)
  end
  
  sc.pan(1, 0.3)
  sc.pan(2, -0.3)
  
  -- Voices 3-6: Playback (higher base level)
  for i = 3, 6 do
    sc.enable(i, 1)
    sc.buffer(i, 1)
    sc.level(i, 0)
    sc.rec_level(i, 0)
    sc.loop(i, 1)
    sc.loop_start(i, 1)
    sc.loop_end(i, 2)
    sc.position(i, 1)
    sc.play(i, 0)
    sc.fade_time(i, 0.02)
    sc.pre_level(i, 0)
    sc.rec(i, 0)
    sc.rate(i, 1)
    sc.rate_slew_time(i, 0.03)
    sc.level_slew_time(i, 0.05)
    sc.pan_slew_time(i, 0.1)
    sc.pan(i, 0)
    sc.post_filter_dry(i, 0)
    sc.post_filter_lp(i, 1)
    sc.post_filter_hp(i, 0)
    sc.post_filter_bp(i, 0)
    sc.post_filter_br(i, 0)
    sc.post_filter_fc(i, 10000)
    sc.post_filter_rq(i, 2)
  end
  
  set_input_stereo()
  sc.event_phase(update_positions)
  sc.poll_start_phase()
end

------------------------------------------------------------
-- PARAMS
------------------------------------------------------------

local function setup_params()
  params:add_separator("ENSEMBLE")
  
  params:add_number("intensity", "Intensity", 0, 100, 60)
  params:add_number("character", "Character", 0, 100, 50)
  params:add_number("movement", "Movement", 0, 100, 70)
  
  params:add_separator("MIX")
  params:add_number("rev_amt", "Reverb", 0, 100, 35)
  params:add_number("monitor", "Monitor", 0, 100, 50)
  
  params:set_action("rev_amt", function(x)
    audio.level_cut_rev(x / 100)
  end)
  
  params:set_action("monitor", function(x)
    for i = 1, 2 do
      sc.level(i, x / 100)
    end
  end)
  
  params:set_action("character", function(x)
    evolving.frag_bias = x / 100
  end)
end

------------------------------------------------------------
-- UI
------------------------------------------------------------

function redraw()
  screen.clear()
  
  -- Title and status
  screen.level(active and 15 or 4)
  screen.move(64, 8)
  screen.text_center(active and "● ACTIVE" or "○ STANDBY")
  
  -- Macro controls
  screen.level(8)
  screen.move(4, 20)
  screen.text("INT")
  screen.move(46, 20)
  screen.text("CHR")
  screen.move(88, 20)
  screen.text("MOV")
  
  screen.level(15)
  screen.move(4, 30)
  screen.text(params:get("intensity"))
  screen.move(46, 30)
  screen.text(params:get("character"))
  screen.move(88, 30)
  screen.text(params:get("movement"))
  
  -- Evolving state
  screen.level(4)
  screen.move(4, 42)
  screen.text("sz:" .. string.format("%.1f", evolving.cascade_size))
  screen.move(40, 42)
  screen.text("sp:" .. string.format("%.0f", evolving.cluster_spread))
  screen.move(80, 42)
  screen.text("wv:" .. string.format("%.1f", evolving.weave_speed))
  
  -- Fragment count and voice activity
  screen.level(6)
  screen.move(4, 54)
  screen.text("frags:" .. #fragments)
  
  -- Voice indicators with pan position
  for i = 1, NUM_PLAY_VOICES do
    local x = 55 + i * 14
    local v = voices[i]
    
    -- Pan position indicator
    if v.busy then
      screen.level(12)
      local pan_x = x + v.pan * 5
      screen.circle(pan_x, 52, 3)
      screen.fill()
    else
      screen.level(2)
      screen.circle(x, 52, 2)
      screen.stroke()
    end
  end
  
  -- Horizontal amplitude meter
  screen.level(2)
  screen.rect(4, 58, 80, 4)
  screen.stroke()
  
  local fill_w = math.min(78, smoothed_amp * 400)
  screen.level(active and 10 or 4)
  screen.rect(5, 59, fill_w, 2)
  screen.fill()
  
  -- Breathing indicator
  local breath_y = 52 + math.sin(lfo.breath) * 3
  screen.level(8)
  screen.circle(120, breath_y, 3)
  screen.fill()
  
  -- Swirl indicator
  local swirl_x = 120 + math.cos(lfo.swirl) * 4
  local swirl_y = 52 + math.sin(lfo.swirl) * 4
  screen.level(4)
  screen.pixel(swirl_x, swirl_y)
  screen.fill()
  
  screen.update()
end

------------------------------------------------------------
-- CONTROLS
------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    params:delta("intensity", d)
  elseif n == 2 then
    params:delta("character", d)
  elseif n == 3 then
    params:delta("movement", d)
  end
end

function key(n, z)
  if z == 0 then return end
  
  if n == 2 then
    active = not active
    for i = 1, 2 do
      sc.rec(i, active and 1 or 0)
    end
    print(active and "=== ACTIVE ===" or "=== STANDBY ===")
    
  elseif n == 3 then
    if positions[1] > 2 then
      capture_fragment()
      trigger_cascade(0.9)
      print(">>> BURST")
    end
  end
end

------------------------------------------------------------
-- MAIN UPDATE
------------------------------------------------------------

local function main_update()
  local dt = 1/30
  time_elapsed = time_elapsed + dt
  
  update_lfos(dt)
  evolve_parameters(dt)
  update_voice_motion(dt)
  maybe_trigger()
  
  redraw()
end

------------------------------------------------------------
-- INIT
------------------------------------------------------------

function init()
  print("")
  print("================================")
  print("ENSEMBLE v3.1")
  print("Smooth Grains + Continuous")
  print("================================")
  print("")
  print("K2: Toggle active")
  print("K3: Manual burst")
  print("E1: Intensity")
  print("E2: Character")
  print("E3: Movement")
  print("================================")
  
  -- Higher output levels
  audio.level_cut(1)
  audio.level_adc_cut(1)
  audio.level_eng_cut(1)
  
  setup_params()
  setup_softcut()
  
  local amp_poll = poll.set("amp_in_l")
  amp_poll.time = 0.025
  amp_poll.callback = process_input
  amp_poll:start()
  
  local update_metro = metro.init()
  update_metro.time = 1/30
  update_metro.event = main_update
  update_metro:start()
  
  audio.rev_on()
  params:bang()
end

function cleanup()
  sc.poll_stop_phase()
end
