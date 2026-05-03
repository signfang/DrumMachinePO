-- Drum Machine with Multi-Pattern Chaining and Project Save/Load
-- Target: Playdate SDK 3.0.3
-- B button starts/stops playback. Sequence does NOT auto-start.

isRunning = false

local snd = playdate.sound

-- global effects
o = snd.overdrive.new()
o:setGain(2.0)
o:setLimit(0.9)

-- Reverb: simulated with a multi-tap long-feedback delay
r = snd.delayline.new(0.8)
r:setFeedback(0)
r:setMix(0)
local rTap1 = r:addTap(0.03)
local rTap2 = r:addTap(0.07)
local rTap3 = r:addTap(0.15)
rTap1:setVolume(0.6)
rTap2:setVolume(0.4)
rTap3:setVolume(0.3)

crankQueuedPattern = nil   -- pattern to play next (set by crank, cleared after one bar)
crankShadowSlot    = nil   -- which chainStep position was shadowed, so we can resume correctly

performanceMode = false   -- global; checked by every input handler

-- perfStatus: kept for held-button tracking used by perf handlers
local perfStatus = {
	held = { up=false, down=false, left=false, right=false, a=false, b=false },
}
-- Stop any voices that may be sustaining from the previous pattern.
-- Called immediately after loadPatternIntoSequence on a chain advance.
local function cutActiveVoices()
    for _, tr in ipairs(tracks) do
        tr.inst:allNotesOff()
    end
end

-- ============================================================
-- TRACK / INSTRUMENT SETUP
-- ============================================================
-- Extensions to probe, in priority order.
--local USER_SAMPLE_EXTS = { ".wav", ".aif", ".mp3" ,".pda",".aiff"}
local USER_SAMPLE_EXTS = {".pda"} -- Only supports pda for now
local USER_SAMPLE_DIR  = "/Shared/DrumMachinePO/Samples/"

local MAX_BANK_SAMPLES = 10

-- Scans USER_SAMPLE_DIR for up to MAX_BANK_SAMPLES samples for a given track.
-- Priority: "KickDrum1.wav" style (name+number) over "Bank1_1.wav" style.
-- Returns a list of {sample, label} tables, always at least 1 entry.
local function loadSampleBank(name, trackIdx)
    local bank = {}

    -- Always load the base bundled asset as bank[1] first
    local ok, s, err = pcall(playdate.sound.sample.new, name)
    if ok and s then
        bank[#bank+1] = { sample=s, label=name }
    end

    -- Then scan for numbered user overrides e.g. KickDrum1.wav, KickDrum2.wav
    for n = 1, MAX_BANK_SAMPLES do
        for _, ext in ipairs(USER_SAMPLE_EXTS) do
            local path = USER_SAMPLE_DIR .. name .. n .. ext
			--print("checking:", path, "exists:", playdate.file.exists(path))
            if playdate.file.exists(path) then				
                local ok2, s2, err2 = pcall(playdate.sound.sample.new, path)
				--print("Pcall: ", ok2, s2, err2)
                if ok2 and s2 then
                    bank[#bank+1] = { sample=s2, label=name..n }
					--print(bank[#bank+1][label])
                    break
                end
            end
        end
    end

    -- Bank-style scan e.g. Bank1_1.wav
    if #bank <= 1 then
        for n = 1, MAX_BANK_SAMPLES do
            for _, ext in ipairs(USER_SAMPLE_EXTS) do
                local path = USER_SAMPLE_DIR .. "Bank" .. trackIdx .. "_" .. n .. ext
				--print("checking:", path, "exists:", playdate.file.exists(path))
                if playdate.file.exists(path) then
                    local ok2, s2, err2 = pcall(playdate.sound.sample.new, path)
					--print("Pcall: ", ok2, s2, err2)
                    if ok2 and s2 then
                        bank[#bank+1] = { sample=s2, label="Bank"..trackIdx.."_"..n }
						--print(bank[#bank+1][label])
                        break
                    end
                end
            end
        end
    end

    -- Last resort: silent placeholder
    if #bank == 0 then
        bank[#bank+1] = { sample=playdate.sound.sample.new(), label=name }
    end

	--print(bank)

    return bank
end


-- Single-sample loader kept for non-drum tracks (click, etc.)
local function loadSampleForTrack(name)
    for _, ext in ipairs(USER_SAMPLE_EXTS) do
        local path = USER_SAMPLE_DIR .. name .. ext
        if playdate.file.exists(path) then
            local ok, sample = pcall(playdate.sound.sample.new, path)
            if ok and sample then return sample end
        end
    end
    return playdate.sound.sample.new(name)
end

function newTrack(name, trackIdx)
    local t     = snd.track.new()
    local i     = snd.instrument.new()
    local bank  = loadSampleBank(name, trackIdx)
    local s     = snd.synth.new(bank[1].sample)
    s:setVolume(0.2)
    i:addVoice(s)
    t:setInstrument(i)
    return { track=t, name=name, label=bank[1].label, synth=s, inst=i,
             notes={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
             volume=1.0, muted=false,
             bank=bank, bankIdx=1
           }
end


local btnHoldAdj = false
local bUsedToExitPtn = false
local lastBTapTime = 0
local DOUBLE_TAP_MS = 300
local DOUBLE_TAP_A_MS = 200

-- Apply a track's volume/muted state to its synth.
-- Base synth volume is 0.2; per-track volume scales on top.
local function applyTrackVolume(tr)
	if tr.muted then
		tr.synth:setVolume(0)
	else
		tr.synth:setVolume(0.2 * tr.volume)
	end
end



local TRACK_NAMES = {
	'KickDrum', 'SnareDrum', 'HHClosed', 'HHOpen',
	'TomHi', 'TomMid', 'TomLow', 'Clap',
	'Clav', 'Rimshot', 'Cowbell', 'Maraca',
	'CongaHi', 'CongaMid', 'CongaLow',
}

tracks = {}
for ti, name in ipairs(TRACK_NAMES) do
	tracks[#tracks+1] = newTrack(name, ti)
end

local LEVEL_INCREMENTS = 9
local NUM_STEPS        = 16
local MAX_PATTERNS     = 18

-- ============================================================
-- MULTI-PATTERN STORAGE
-- ============================================================

patterns = {}
for p = 1, MAX_PATTERNS do
	patterns[p] = {}
	for t = 1, #tracks do
		patterns[p][t] = { notes = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0} }
	end
end

MAX_CHAINS        = 12
currentPattern    = 1
prevPattern = 1

-- Pre-allocate MAX_CHAINS chains; each starts with a single-slot chain pointing at pattern 1.
-- This makes every slot immediately usable without needing an "add chain" action.
chains            = {}
for _ci = 1, MAX_CHAINS do chains[_ci] = { 1 } end
currentChainIndex = 1           -- which chain is active
chainList         = chains[1]   -- alias: all existing code referencing chainList still works
chainEnabled      = false
chainStep         = 1
bpmValue          = 120
swingAmount       = 0.0
poSyncEnabled     = false   -- declared early; used by applyPanRouting during startup



-- ============================================================
-- SEQUENCE SETUP
-- ============================================================

sequence = snd.sequence.new()

-- Build drum tracks
for i = 1, #tracks do
	sequence:addTrack(tracks[i].track)
end

-- PO sync track
local poTrack      = snd.track.new()
local poInstrument = snd.instrument.new()

-- PO sync click: sine wave produces a cleaner, more detectable transient
-- through a headphone jack than a square wave (which gets bandwidth-limited).
-- ADSR: near-zero attack, 50ms decay, 0 sustain, 0 release — long enough
-- for the PO's comparator to latch on reliably.
local clickSample = loadSampleForTrack("click.wav")
local clickSynth   = snd.synth.new(clickSample)
--local clickSynth = snd.synth.new(playdate.sound.kWaveSquare)
clickSynth:setVolume(1.5)
--clickSynth:setADSR(0.003, 0.1, 0, 0)
poInstrument:addVoice(clickSynth)
poTrack:setInstrument(poInstrument)
sequence:addTrack(poTrack)


-- ============================================================
-- AUDIO CHANNEL ROUTING
--
-- The Playdate default channel plays any source not assigned to
-- a custom channel. Once a source IS assigned to a custom channel,
-- it plays ONLY through that channel.
--
-- Strategy: assign ALL sources to custom channels at startup so
-- nothing leaks through the default. Then control pan/volume on
-- the two channels to achieve the desired stereo split.
--
-- PO sync ON:  drumChannel pan=+1 (right), syncChannel pan=-1 (left), vol=1
-- PO sync OFF: drumChannel pan=0  (center), syncChannel vol=0 (silent)
-- ============================================================

local drumChannel = snd.channel.new()
local syncChannel = snd.channel.new()

-- Switch a track to a different bank sample index (Bug 4 safe: new inst/synth).
local function switchTrackBank(tr, newBankIdx)
    if #tr.bank <= 1 then return end
    newBankIdx = math.max(1, math.min(#tr.bank, newBankIdx))
    if newBankIdx == tr.bankIdx then return end
    tr.bankIdx = newBankIdx
    local entry   = tr.bank[newBankIdx]
    tr.label      = entry.label
    local newInst = snd.instrument.new()
    local newSynth = snd.synth.new(entry.sample)
    newSynth:setVolume(tr.muted and 0 or 0.2 * tr.volume)
    newInst:addVoice(newSynth)
    tr.track:setInstrument(newInst)
    drumChannel:addSource(newInst)   -- ← add new instrument to channel
    tr.inst  = newInst
    tr.synth = newSynth
end

-- Assign every drum instrument to drumChannel at startup.
-- The instrument is the SoundSource; the synth lives inside it.
-- Once assigned to a custom channel, it no longer plays on the default.
for _, tr in ipairs(tracks) do
	drumChannel:addSource(tr.inst)
	print("Sources added to drumChannel:", #tracks)
end

-- Effects must be on drumChannel (drums bypass the default channel)
drumChannel:addEffect(o)
drumChannel:addEffect(r)

-- Assign click instrument to syncChannel at startup.
syncChannel:addSource(poInstrument)

-- Pan routing: called whenever poSyncEnabled changes
local function applyPanRouting()
	if poSyncEnabled then
		drumChannel:setPan(1.0)    -- drums hard right
		syncChannel:setPan(-1.0)   -- click hard left
		syncChannel:setVolume(1.0)
	else
		drumChannel:setPan(0)      -- drums center (both channels)
		syncChannel:setVolume(0)   -- click silent (notes cleared separately)
	end
end


-- ============================================================
-- INTERNAL STEP RESOLUTION SCALING
--
-- The Playdate SDK's sequence:setNotes() step positions are truncated
-- to integers before scheduling. Swing delays even steps by amounts
-- like 0.05, 0.10 … 0.50 (in 1/16th-note units). To preserve these
-- as whole integers we multiply every internal step position and the
-- tempo by STEP_SCALE.
--
-- swingAmount comes in increments of 0.05 steps.
-- STEP_SCALE = 20 turns 0.05 → 1, 0.50 → 10 — all exact integers.
-- Every note step, loop bound, and tempo is multiplied by STEP_SCALE.
-- getCurrentStep() returns scaled steps; divide by STEP_SCALE to
-- recover the 1-based grid column for UI/chain logic.
-- ============================================================
local STEP_SCALE = 20   -- must be divisible by all swing increments (0.05 → ×20 = 1)

-- swingOffset: returns the swing delay for a given 1-based grid slot,
-- already multiplied by STEP_SCALE so the result is a whole integer.
-- Only even-indexed steps are delayed; odd steps always return 0.
local function swingOffset(gridSlot)
	if swingAmount == 0 or gridSlot % 2 == 1 then
		return 0
	end
	-- swingAmount is 0.05–0.50 in 1/16th-note units.
	-- × STEP_SCALE (20) → 1–10, always an exact integer.
	return math.floor(swingAmount * STEP_SCALE + 0.5)
end

-- Convert a 1-based grid slot to a scaled internal step position.
-- All positions passed to setNotes must go through this function.
local function toInternalStep(gridSlot)
	return (gridSlot - 1) * STEP_SCALE + 1
end

local function updateTrack(t, notes)
	local list = {}
	for i = 1, #notes do
		if notes[i] > 0 then
			list[#list+1] = {
				note     = 60,
				step     = toInternalStep(i) + swingOffset(i),
				length   = STEP_SCALE-3,   -- one grid step long
				velocity = notes[i] / LEVEL_INCREMENTS
			}
		end
	end
	t.track:setNotes(list)
	t.notes = notes   -- notes[] always holds integer velocities, never play positions
end
-- Reapply swing to all tracks (called when swingAmount changes)
local function applySwingToAllTracks()
	for _, tr in ipairs(tracks) do
		updateTrack(tr, tr.notes)
	end
end

local function saveCurrentPatternFromTracks()
	for ti = 1, #tracks do
		for s = 1, NUM_STEPS do
			patterns[currentPattern][ti].notes[s] = tracks[ti].notes[s]
		end
	end
end


edgeNextPattern = nil

local function loadPatternIntoSequence(patIdx)
	--dest = patIdx
	-- if currentPattern~=prevPattern and patIdx==currentPattern then
	-- 	print("Pattern edge:",prevPattern,"->",currentPattern)
	-- 	edgeNextPattern = patIdx -- to be updated in playdate.update()
	-- 	dest = prevPattern
	-- end
	
	for ti = 1, #tracks do
		local pnotes = patterns[patIdx][ti].notes
		local copy = {}
		for s = 1, NUM_STEPS do copy[s] = pnotes[s] end
		updateTrack(tracks[ti], copy)
	end
end

local function switchToPattern(patIdx)
	saveCurrentPatternFromTracks()
	currentPattern = patIdx
	loadPatternIntoSequence(currentPattern)
end

-- Switch active chain by index. Re-points the chainList alias so all
-- playback/edit code works without changes. Safe to call at any time.
local function switchToChain(idx)
	saveCurrentPatternFromTracks()
	currentChainIndex = math.max(1, math.min(MAX_CHAINS, idx))
	chainList         = chains[currentChainIndex]
	chainStep         = 1
	if chainEnabled and #chainList > 0 then
		currentPattern = chainList[1]
		loadPatternIntoSequence(currentPattern)
	end
end



local syncOffset = 0   -- in "step units"
local function updatePOSyncTrack()
	applyPanRouting()

	if not poSyncEnabled then
		poTrack:setNotes({})
		return
	end

	-- 2 PPQN: one pulse every 2 grid steps (on odd steps 1,3,5,...).
	-- PO sync standard is 2 pulses per quarter note. With a 16-step bar
	-- at 1/16th note resolution, that means a pulse on steps 1,3,5,7,9,11,13,15.
	-- syncOffset is in grid-step units; multiply by STEP_SCALE for internal coords.
	local list = {}
	for step = 1, NUM_STEPS, 2 do
		local internalPos = toInternalStep(step) - math.floor(syncOffset * STEP_SCALE + 0.5)
		if internalPos >= 1 then
			list[#list+1] = {
				note     = 30, 
				step     = internalPos,
				length   = STEP_SCALE,
				velocity = 1.0
			}
		end
	end
	poTrack:setNotes(list)
end

-- ============================================================
-- DEFAULT INITIAL DATA (pattern 1)
-- ============================================================

patterns[1][1].notes = { 9,0,0,0,  0,0,0,0,  0,0,6,0,  0,0,0,0 }
patterns[1][2].notes = { 0,0,0,0,  9,0,0,0,  0,7,0,0,  9,0,0,0 }
patterns[1][3].notes = { 8,0,5,0,  6,0,5,0,  8,0,5,0,  6,0,5,0 }
patterns[1][9].notes = { 0,0,0,3,  0,2,0,0,  0,0,0,3,  0,0,0,0 }

loadPatternIntoSequence(1)

function setBPM(bpm)
	bpmValue = bpm
	local stepsPerSecond = 4 * (bpm / 60) * STEP_SCALE
	sequence:setTempo(stepsPerSecond)
	updatePOSyncTrack()
end

setBPM(bpmValue)
-- Loop from internal step 1 to the last internal step of the bar.
-- NUM_STEPS grid steps × STEP_SCALE = total internal steps per bar.
sequence:setLoops(1, NUM_STEPS * STEP_SCALE-5, 1)
-- sequence:play() is NOT called here; B button starts playback

-- ============================================================
-- UI CONSTANTS
-- ============================================================

local ROW_HEIGHT      = 16   -- 15 tracks × 15px = 225px, status bar in remaining 15px
local TEXT_WIDTH      = 90
local CELL_INSET      = 2
local SELECTION_WIDTH = 2
local STATUS_Y        = 0  -- y position of the bottom status bar
local STATUS_X        = 350  -- x position of the bottom status bar

local gfx = playdate.graphics
-- SDK 3.0.3: setStrokeLocation is valid
gfx.setStrokeLocation(gfx.kStrokeOutside)
playdate.display.setInverted(true)

local grid = gfx.image.new(400, 240)

-- Modes: "grid" (step editing), "pattern" (pattern select / chain)
uiMode = "grid"

selectedRow    = 1
selectedColumn = 1   -- 0 = track name selected, 1..16 = step columns

-- B-held state (for swing crank modifier)
local bHeld      = false
local crankAccum = 0    -- shared accumulator for all crank modes

-- Pattern UI state
selectedPatternSlot = 1   -- 1..MAX_PATTERNS
patternUIRow        = 1   -- 1=pattern row, 3=chain row, 4=save/load, 4=PO sync
selectedChainSlot   = 1   -- 1..#chainList+1  (+1 = the "add" slot)

-- Pattern copy state
patternCopyMode     = false   -- true while A is held long enough to copy
patternCopySource   = nil     -- which pattern index was copied
patternAHoldFrames  = 0       -- frames A has been held in pattern row 1
local COPY_HOLD_FRAMES = 30   -- ~1s at 30fps

-- Pattern-clear B-hold state (patternUIRow == 1 only)
local patternBHoldFrames  = 0      -- counts frames B is held in pattern row 1
local patternBHoldUsed    = false  -- true once the hold action fired this press
local CLEAR_HOLD_FRAMES   = 30     -- ~1s at 30fps
local patternBConsumedByDialog = false  -- true when BButtonDown dismissed a dialog


-- ============================================================
-- DRAW HELPERS
-- ============================================================

local function drawCell(col, row)
	local strokeWidth = 1
	if selectedColumn > 0 and col == selectedColumn and row == selectedRow then
		strokeWidth = SELECTION_WIDTH
	end

	local x = TEXT_WIDTH + (col-1)*ROW_HEIGHT + CELL_INSET
	local y = (row-1)*ROW_HEIGHT + CELL_INSET
	local s = ROW_HEIGHT - 2*CELL_INSET

	gfx.setColor(gfx.kColorBlack)
	-- SDK: drawRect(x, y, w, h) — no lineWidth argument. Use setLineWidth instead.
	gfx.setLineWidth(strokeWidth)
	gfx.drawRect(x, y, s, s)

	local val = tracks[row].notes[col]
	if val ~= nil and val > 0 then
		gfx.setDitherPattern(1 - val/LEVEL_INCREMENTS, gfx.image.kDitherTypeBayer4x4)
		gfx.fillRect(x+1, y+1, s-2, s-2)
	end

	-- reset line width so other draws aren't affected
	gfx.setLineWidth(1)
end
local MAX_SAVE_SLOTS       = 8


-- Pattern UI layout (all Y positions explicit, no derived overlaps)
local PAT_BOX_W   = 17   -- width of each pattern box
local PAT_BOX_H   = 24   -- height of each pattern box
local PAT_START_X = 4    -- left margin

local PAT_TITLE_Y  = 0   -- "PATTERNS  BPM:xxx"
local PAT_BOXES_Y  = 18  -- top of pattern boxes row
local PAT_CHAIN_LABEL_Y = 48  -- "CHAIN: ON/OFF"
local PAT_CHAIN_ROW_Y   = 67  -- top of chain slots row (height 20)


local PAT_CHAIN_SEL_Y      = 95    -- new row 4: "PATTERN CHAIN: x / y"


local PAT_SAVE_SLOT_ROW_Y  = 115   -- was 98; shifted down 20px to make room for chain selector row
local PAT_SAVE_ROW_Y       = 135   -- was 118
local PAT_LOAD_ROW_Y       = 155   -- was 138
local PAT_PO_SYNC_Y        = 175   -- was 165; shifted down to fit

local PAT_HELP_SEP_Y = 193 -- help line separator
local PAT_HELP1_Y  = 197 -- first help line
local PAT_HELP2_Y  = 217 -- second help line




currentSaveSlot = 1          -- global; user slots 1–8; slot 0 is autosave (not user-selectable)

local function drawPatternUI()
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(1)

	-- Title

	-- Pattern selection boxes (8 boxes)
	for p = 1, MAX_PATTERNS do
		local x = PAT_START_X + (p-1) * (PAT_BOX_W + 4)
		local y = PAT_BOXES_Y
		local isCurrent  = (p == currentPattern)
		local isSelected = (patternUIRow == 1 and p == selectedPatternSlot)
		local isCopySrc  = (patternCopyMode and p == patternCopySource)

		gfx.setColor(gfx.kColorBlack)
		-- Selection = thick border; copy source = dashed inner mark
		if isSelected then
			gfx.setLineWidth(3)
			gfx.drawRect(x, y, PAT_BOX_W, PAT_BOX_H)
			gfx.setLineWidth(1)
		else
			gfx.setLineWidth(1)
			gfx.drawRect(x, y, PAT_BOX_W, PAT_BOX_H)
		end
		-- Current pattern: small filled dot top-right
		if isCurrent then
			gfx.fillRect(x + PAT_BOX_W - 6, y + 2, 4, 4)
		end
		-- Copy source: small 'C' marker bottom-right
		if isCopySrc then
			gfx.drawText("C", x + PAT_BOX_W - 8, y + PAT_BOX_H - 10)
		end
		gfx.drawText(tostring(p), x + 4, y + 6)
	end

	if patternUIRow == 1 then
		gfx.drawText("PATTERN " .. selectedPatternSlot .. " BPM:" .. bpmValue, PAT_START_X, PAT_TITLE_Y)
	else
		gfx.drawText("PATTERN BPM:" .. bpmValue, PAT_START_X, PAT_TITLE_Y)
	end
	-- Chain section label
	gfx.setColor(gfx.kColorBlack)
	if patternUIRow == 2 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_CHAIN_LABEL_Y - 2, 120, 16)
		gfx.setLineWidth(1)
	end
	gfx.setColor(gfx.kColorBlack)

	if patternUIRow == 3 and selectedChainSlot~=0 and selectedChainSlot < #chainList+1 then
		gfx.drawText("CHAIN: " .. (chainEnabled and "ON " or "OFF") .. "(selected pattern: " .. chainList[selectedChainSlot] ..")", PAT_START_X, PAT_CHAIN_LABEL_Y)
	else
		gfx.drawText("CHAIN: " .. (chainEnabled and "ON " or "OFF"), PAT_START_X, PAT_CHAIN_LABEL_Y)
	end



	-- [>] play-all button  (selectedChainSlot == 0)
	local PLAY_W = 28
	local isPlaySel = (patternUIRow == 3 and selectedChainSlot == 0)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(isPlaySel and 3 or 1)
	gfx.drawRect(PAT_START_X, PAT_CHAIN_ROW_Y, PLAY_W, 20)
	gfx.setLineWidth(1)
	gfx.drawText("[>]", PAT_START_X + 3, PAT_CHAIN_ROW_Y + 3)

	-- Chain slots
	local slotOffX = PAT_START_X + PLAY_W + 4
	local SLOT_W   = 18
	local SLOT_GAP = 4

	for ci = 1, #chainList do
		local x = slotOffX + (ci - 1) * (SLOT_W + SLOT_GAP)
		local isSelected = (patternUIRow == 3 and ci == selectedChainSlot)
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(isSelected and 3 or 1)
		gfx.drawRect(x, PAT_CHAIN_ROW_Y, SLOT_W, 20)
		gfx.setLineWidth(1)
		gfx.drawText(tostring(chainList[ci]), x + 5, PAT_CHAIN_ROW_Y + 3)
	end

	-- "+" append slot
	local addX     = slotOffX + #chainList * (SLOT_W + SLOT_GAP)
	local isAddSel = (patternUIRow == 3 and selectedChainSlot == #chainList + 1)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(isAddSel and 3 or 1)
	gfx.drawRect(addX, PAT_CHAIN_ROW_Y, SLOT_W, 20)
	gfx.setLineWidth(1)
	gfx.drawText("+", addX + 7, PAT_CHAIN_ROW_Y + 3)
	


	-- CHAIN SELECTOR row  (patternUIRow == 4)
	-- Shows "PATTERN CHAIN: x / y" with L/R to switch active chain.
	-- The chain slot editor (row 3) always edits the currently selected chain.
	gfx.setColor(gfx.kColorBlack)
	local chainSelText = "CURRENT PATTERN CHAIN: " .. currentChainIndex .. " / " .. MAX_CHAINS
	if patternUIRow == 4 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_CHAIN_SEL_Y - 2, 320, 16)
		gfx.setLineWidth(1)
	end
	gfx.drawText(chainSelText, PAT_START_X, PAT_CHAIN_SEL_Y)

	-- SAVE/LOAD slot row  (patternUIRow == 5)
	gfx.setColor(gfx.kColorBlack)
	local saveText = "PROJECT SLOT: " .. currentSaveSlot .. " / " .. MAX_SAVE_SLOTS
	if patternUIRow == 5 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_SAVE_SLOT_ROW_Y - 2, 220, 16)
		gfx.setLineWidth(1)
	end
	gfx.drawText(saveText, PAT_START_X, PAT_SAVE_SLOT_ROW_Y)
	
	gfx.setColor(gfx.kColorBlack)

	gfx.drawText("SAVE PROJECT", PAT_START_X, PAT_SAVE_ROW_Y)
	
	if patternUIRow == 6 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_SAVE_ROW_Y - 2, 120, 16)
		gfx.setLineWidth(1)
	end
	
	gfx.drawText("LOAD PROJECT", PAT_START_X, PAT_LOAD_ROW_Y)
	
	if patternUIRow == 7 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_LOAD_ROW_Y - 2, 120, 16)
		gfx.setLineWidth(1)
	end

	-- PO SYNC row  (patternUIRow == 8)
	gfx.setColor(gfx.kColorBlack)
	local syncText = "PO SYNC: " .. (poSyncEnabled and "ON" or "OFF")
	if patternUIRow == 8 then
		gfx.setLineWidth(3)
		gfx.drawRect(PAT_START_X - 2, PAT_PO_SYNC_Y - 2, 150, 16)
		gfx.setLineWidth(1)
	end
	gfx.drawText(syncText, PAT_START_X, PAT_PO_SYNC_Y)

	-- Divider line before help area
	gfx.drawLine(0, PAT_HELP_SEP_Y, 400, PAT_HELP_SEP_Y)

	-- Help text — changes based on mode
	gfx.setColor(gfx.kColorBlack)
	if patternUIRow == 1 then
		if patternCopyMode then
			gfx.drawText("COPY MODE: L/R to pick dest", PAT_START_X, PAT_HELP1_Y)
			gfx.drawText("Release A to paste  |  src: P" .. (patternCopySource or "?"), PAT_START_X, PAT_HELP2_Y)
		else
			gfx.drawText("A:load / Hold A 1s:copy / Hold B 1s:clear", PAT_START_X, PAT_HELP1_Y)
			gfx.drawText("Down:chain / Crank:BPM", PAT_START_X, PAT_HELP2_Y)
		end
	elseif patternUIRow == 2 then
		gfx.drawText("A: toggle chain mode", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 3 then
		if selectedChainSlot == 0 then
			gfx.drawText("A: PLAY ALL from start", PAT_START_X, PAT_HELP1_Y)
		elseif selectedChainSlot == #chainList + 1 then
			gfx.drawText("A: add current pat to chain", PAT_START_X, PAT_HELP1_Y)
		else
			gfx.drawText("A:set slot / Hold B 1s:del slot", PAT_START_X, PAT_HELP1_Y)
		end
		gfx.drawText("L/R:move / Crank:change val / B: Back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 4 then
		gfx.drawText("L/R: switch pattern chain", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 5 then
		gfx.drawText("L/R: change slot", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 6 then
		gfx.drawText("A: save", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 7 then
		gfx.drawText("A: load", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	elseif patternUIRow == 8 then
		gfx.drawText("A: toggle PO sync (SY1 equiv.)", PAT_START_X, PAT_HELP1_Y)
		gfx.drawText("B: back to grid", PAT_START_X, PAT_HELP2_Y)
	end
end

-- drawPerformanceMode is defined later in the performance mode section;
-- declared here so drawGrid() can call it as a forward reference.
local drawPerformanceMode

function drawGrid()
	if performanceMode then drawPerformanceMode(); return end
	gfx.lockFocus(grid)
	gfx.clear(gfx.kColorWhite)
	gfx.setLineWidth(1)

	if uiMode == "grid" then
		for row = 1, #tracks do
			local tr          = tracks[row]
			local nameSelected = (row == selectedRow and selectedColumn == 0)

			-- Mute: small filled square at far left when muted
			local nameX = 0
			if tr.muted then
				gfx.setColor(gfx.kColorBlack)
				gfx.fillRect(0, (row-1)*ROW_HEIGHT + 3, 4, 4)
				nameX = 6
			end

			-- Track name
			if nameSelected then
				gfx.setLineWidth(2)
				gfx.drawText(tr.label, nameX, (row-1)*ROW_HEIGHT)
				gfx.setLineWidth(1)
				gfx.drawLine(nameX, row*ROW_HEIGHT - 2, TEXT_WIDTH - 10, row*ROW_HEIGHT - 2)
				if #tr.bank > 1 then
					gfx.drawText("Bank:", STATUS_X, ROW_HEIGHT*7)
					gfx.drawText(tr.bankIdx.."/"..#tr.bank, STATUS_X, ROW_HEIGHT*8)
				end
			else
				gfx.setColor(gfx.kColorBlack)
				gfx.drawText(tr.label, nameX, (row-1)*ROW_HEIGHT)
			end

			-- Volume bar: thin vertical bar at right edge of name column (always visible)
			--[[
			local barX  = TEXT_WIDTH - 7
			local barY  = (row-1)*ROW_HEIGHT + 1
			local barH  = ROW_HEIGHT - 2
			local fillH = math.floor(barH * tr.volume + 0.5)
			
			gfx.setColor(gfx.kColorBlack)
			gfx.drawRect(barX, barY, 4, barH)
			if fillH > 0 then
				gfx.fillRect(barX, barY + barH - fillH, 4, fillH)
			end
			]]--

			for col = 1, NUM_STEPS do
				drawCell(col, row)
			end
			
		end
		-- Status bar
		local swingPct = math.floor(swingAmount * 100 + 0.5)
		local chainTag = chainEnabled and " C" or ""
		if crankQueuedPattern ~= nil then
			gfx.drawText(">" .. crankQueuedPattern, STATUS_X, ROW_HEIGHT * 5)
		end

		if selectedColumn == 0 then
			local tr     = tracks[selectedRow]
			local volPct = math.floor(tr.volume * 100 + 0.5)
			local muteHint = tr.muted and " MUTE" or ""
			gfx.drawText("A:", STATUS_X, 0)
			gfx.drawText("Mute", STATUS_X, ROW_HEIGHT)
			gfx.drawText(muteHint, STATUS_X, ROW_HEIGHT*2)			
			--gfx.drawText("Crank:", STATUS_X, ROW_HEIGHT*3)
			--gfx.drawText("Change", STATUS_X, ROW_HEIGHT*4)
			--gfx.drawText("Bank", STATUS_X, ROW_HEIGHT*5)

			

		elseif bHeld then
			gfx.drawText("SWING", STATUS_X, 0)
			gfx.drawText(":" .. swingPct, STATUS_X, ROW_HEIGHT)
			gfx.drawText("BPM", STATUS_X, ROW_HEIGHT*2)
			gfx.drawText(":" .. bpmValue, STATUS_X, ROW_HEIGHT*3)

		elseif adjusting then
			local swingTag = swingPct > 0 and ("SW:" .. swingPct .. "%") or ""
			gfx.drawText("P:" .. currentPattern .. chainTag, STATUS_X, 0)
			gfx.drawText("BPM", STATUS_X, ROW_HEIGHT)
			gfx.drawText(":" .. bpmValue, STATUS_X, ROW_HEIGHT*2)
			gfx.drawText(swingTag, STATUS_X, ROW_HEIGHT*3)		

		else
			local swingTag1 = swingPct > 0 and ("SW:") or ""
			local swingTag2 = swingPct > 0 and (swingPct .. "%") or ""
			gfx.drawText("P:" .. currentPattern .. chainTag, STATUS_X, 0)
			gfx.drawText("BPM", STATUS_X, ROW_HEIGHT)
			gfx.drawText(":" ..bpmValue, STATUS_X, ROW_HEIGHT*2)
			gfx.drawText(swingTag1, STATUS_X, ROW_HEIGHT*3)			
			gfx.drawText(swingTag2, STATUS_X, ROW_HEIGHT*4)				

		end
		
		local chainTag2 = chainEnabled and "C:" .. currentChainIndex or ""
		gfx.drawText(chainTag2, STATUS_X, ROW_HEIGHT*13)	
	elseif uiMode == "pattern" then
		drawPatternUI()
	end
	bUsedToExitPtn = false
	gfx.unlockFocus()
end

-- ============================================================
-- PROJECT SAVE / LOAD  (playdate.datastore — available since SDK 1.x)
-- ============================================================

local function projectToTable()
	saveCurrentPatternFromTracks()
	local proj = {
		version           = 2,
		bpm               = bpmValue,
		swing             = swingAmount,
		chainEnabled      = chainEnabled,
		chain             = {},
		chains            = {},
		currentChainIndex = currentChainIndex,
		patterns          = {},
		trackVolumes      = {},
		trackMutes        = {},
		trackBankIndices  = {},
	}
	for ci = 1, #chains do
		proj.chains[ci] = {}
		for i, v in ipairs(chains[ci]) do proj.chains[ci][i] = v end
	end
	for i, v in ipairs(chainList) do proj.chain[i] = v end
	for ti = 1, #tracks do
		proj.trackVolumes[ti]     = tracks[ti].volume
		proj.trackMutes[ti]       = tracks[ti].muted
		proj.trackBankIndices[ti] = tracks[ti].bankIdx
	end
	for p = 1, MAX_PATTERNS do
		proj.patterns[p] = {}
		for ti = 1, #tracks do
			proj.patterns[p][ti] = {}
			for s = 1, NUM_STEPS do
				proj.patterns[p][ti][s] = patterns[p][ti].notes[s]
			end
		end
	end
	return proj
end

local function projectFromTable(proj)
	if not proj then return false end
	bpmValue     = proj.bpm or 120
	swingAmount  = proj.swing or 0.0   -- v1 saved 0 here always (bug); v2 saves raw float
	chainEnabled = proj.chainEnabled or false

	-- Rebuild chains table with version migration
	if (proj.version or 1) >= 2 and proj.chains and #proj.chains > 0 then
		chains = {}
		for ci = 1, #proj.chains do
			chains[ci] = {}
			for i, v in ipairs(proj.chains[ci]) do chains[ci][i] = v end
		end
		currentChainIndex = proj.currentChainIndex or 1
		currentChainIndex = math.max(1, math.min(#chains, currentChainIndex))
	else
		-- v1: single chain → wrap as chains[1]
		chains = {}
		chains[1] = {}
		if proj.chain then
			for i, v in ipairs(proj.chain) do chains[1][i] = v end
		end
		if #chains[1] == 0 then chains[1] = {1} end
		currentChainIndex = 1
	end
	-- Re-point global alias so all existing code keeps working
	chainList = chains[currentChainIndex]
	if #chainList == 0 then chainList[1] = 1 end
	-- Ensure chains is always exactly MAX_CHAINS long (pad with default if save had fewer)
	while #chains < MAX_CHAINS do chains[#chains + 1] = { 1 } end

	for ti = 1, #tracks do
		tracks[ti].volume = (proj.trackVolumes and proj.trackVolumes[ti]) or 1.0
		tracks[ti].muted  = (proj.trackMutes   and proj.trackMutes[ti])   or false
		applyTrackVolume(tracks[ti])
		local savedBank = proj.trackBankIndices and proj.trackBankIndices[ti]
		if savedBank and savedBank ~= tracks[ti].bankIdx then
			switchTrackBank(tracks[ti], savedBank)
		end
	end
	if proj.patterns then
		for p = 1, MAX_PATTERNS do
			if proj.patterns[p] then
				for ti = 1, #tracks do
					if proj.patterns[p][ti] then
						for s = 1, NUM_STEPS do
							patterns[p][ti].notes[s] = proj.patterns[p][ti][s] or 0
						end
					end
				end
			end
		end
	end
	setBPM(bpmValue)
	currentPattern = 1
	chainStep      = 1
	loadPatternIntoSequence(currentPattern)
	return true
end

-- Toast: draw to the offscreen image, blit it, pause, then redraw normally.
-- SDK: playdate.wait(ms) is a valid call — it blocks update() for that many ms.
-- However, it must NOT be called from within playdate.update() itself.
-- Menu item callbacks fire outside update(), so this is safe here.
-- ============================================================
-- TOAST SYSTEM (NON-BLOCKING)
-- ============================================================

local toastMessage = nil
local toastTimer   = 0  -- frames (~30 FPS)

local function showToast(msg)
	toastMessage = msg
	toastTimer   = 24  -- ~0.8 sec
end

-- ============================================================
-- DIALOG SYSTEM  (reusable yes/no confirmation)
--
-- Usage:
--   showDialog("Your question here?", function(confirmed)
--       if confirmed then
--           -- user pressed A (Yes)
--       else
--           -- user pressed B (No/Cancel)
--       end
--   end)
--
-- The dialog draws itself in playdate.update() on top of everything.
-- While a dialog is visible all button handlers defer to it first.
-- ============================================================

local dialogMessage  = nil   -- string shown in the dialog box, or nil when hidden
local dialogCallback = nil   -- function(confirmed:bool) called on A or B

local function showDialog(message, callback)
	dialogMessage  = message
	dialogCallback = callback
end

local function dismissDialog(confirmed)
	local cb = dialogCallback
	dialogMessage  = nil
	dialogCallback = nil
	if cb then cb(confirmed) end
end

-- drawDialog: called from update() when dialogMessage ~= nil.
-- Draws a centred box with the message and [A] Yes / [B] No hints.
local function drawDialog()
	local BOX_W, BOX_H = 320, 72
	local BOX_X = (400 - BOX_W) / 2   -- 40
	local BOX_Y = (240 - BOX_H) / 2   -- 84
	-- Background fill (display is inverted: kColorWhite = visually black bg)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(BOX_X, BOX_Y, BOX_W, BOX_H)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(2)
	gfx.drawRect(BOX_X, BOX_Y, BOX_W, BOX_H)
	gfx.setLineWidth(1)
	-- Message (centred horizontally, upper half of box)
	gfx.drawText(dialogMessage, BOX_X + 12, BOX_Y + 12)
	-- Button hints
	gfx.drawText("[A] Yes         [B] No", BOX_X + 80, BOX_Y + 44)
end

local function projectToJSON(proj)
    local lines = {}
    lines[#lines+1] = '{'
    lines[#lines+1] = '  "version": '           .. tostring(proj.version) .. ','
    lines[#lines+1] = '  "bpm": '               .. tostring(proj.bpm) .. ','
    lines[#lines+1] = '  "swing": '             .. tostring(proj.swing) .. ','
    lines[#lines+1] = '  "chainEnabled": '      .. tostring(proj.chainEnabled) .. ','
    lines[#lines+1] = '  "currentChainIndex": ' .. tostring(proj.currentChainIndex) .. ','
    -- legacy single-chain field
    local chainParts = {}
    for _, v in ipairs(proj.chain) do chainParts[#chainParts+1] = tostring(v) end
    lines[#lines+1] = '  "chain": [' .. table.concat(chainParts, ', ') .. '],'
    -- all chains
    local chainArrayParts = {}
    for ci = 1, #proj.chains do
        local slotParts = {}
        for _, v in ipairs(proj.chains[ci]) do slotParts[#slotParts+1] = tostring(v) end
        chainArrayParts[#chainArrayParts+1] = '[' .. table.concat(slotParts, ', ') .. ']'
    end
    lines[#lines+1] = '  "chains": [' .. table.concat(chainArrayParts, ', ') .. '],'
    local volParts, muteParts, bankParts = {}, {}, {}
    for _, v in ipairs(proj.trackVolumes)              do volParts[#volParts+1]   = tostring(v) end
    for _, v in ipairs(proj.trackMutes)                do muteParts[#muteParts+1] = (v and 'true' or 'false') end
    for _, v in ipairs(proj.trackBankIndices or {})    do bankParts[#bankParts+1] = tostring(v) end
    lines[#lines+1] = '  "trackVolumes":     [' .. table.concat(volParts,   ', ') .. '],'
    lines[#lines+1] = '  "trackMutes":       [' .. table.concat(muteParts,  ', ') .. '],'
    lines[#lines+1] = '  "trackBankIndices": [' .. table.concat(bankParts,  ', ') .. '],'
    lines[#lines+1] = '  "patterns": {'
    for p = 1, MAX_PATTERNS do
        local trackParts = {}
        for ti = 1, #TRACK_NAMES do
            local stepParts = {}
            for s = 1, NUM_STEPS do
                stepParts[#stepParts+1] = tostring(proj.patterns[p][ti][s])
            end
            trackParts[#trackParts+1] = '[' .. table.concat(stepParts, ',') .. ']'
        end
        local comma = (p < MAX_PATTERNS) and ',' or ''
        lines[#lines+1] = '    "' .. p .. '": [' .. table.concat(trackParts, ', ') .. ']' .. comma
    end
    lines[#lines+1] = '  }'
    lines[#lines+1] = '}'
    return table.concat(lines, '\n')
end
-- Extract all JSON values from a string in document order.
-- Returns a flat list of Lua values (numbers and booleans only — enough for our format).
local function jsonExtractValues(s)
    local values = {}
    -- Match: true, false, or a number (int or float, optionally negative)
    for token in s:gmatch('[%-%d%.]+') do
        local n = tonumber(token)
        if n then values[#values+1] = n end
    end
    -- Re-scan for booleans (must be done separately, order interleaved with numbers)
    -- We rebuild in document order by scanning character by character.
    -- Simpler: re-parse the whole string for both in one pass using a combined pattern.
    values = {}
    local pos = 1
    while pos <= #s do
        -- Try boolean first
        if s:sub(pos, pos+3) == 'true' then
            values[#values+1] = true
            pos = pos + 4
        elseif s:sub(pos, pos+4) == 'false' then
            values[#values+1] = false
            pos = pos + 5
        else
            -- Try number (handles negatives and decimals)
            local numStr = s:match('^%-?%d+%.?%d*', pos)
            if numStr then
                values[#values+1] = tonumber(numStr)
                pos = pos + #numStr
            else
                pos = pos + 1
            end
        end
    end
    return values
end


local function projectFromJSON(jsonStr)
    if not jsonStr then return nil end

    local v = jsonExtractValues(jsonStr)
    -- Expected value order produced by projectToJSON:
    --   [1]       version
    --   [2]       bpm
    --   [3]       swing
    --   [4]       chainEnabled  (bool)
    --   [5 .. 5+chainLen-1]           chain values
    -- We can't know chainLen from position alone, so we use key-name anchoring instead.

    -- Anchored extraction: find each key by name, then read the value(s) after it.
    local function afterKey(key)
        -- Returns the position in the original string just after "key":
        local _, e = jsonStr:find('"' .. key .. '"%s*:%s*')
        return e
    end

    local function readNumber(key)
        local pos = afterKey(key)
        if not pos then return nil end
        local numStr = jsonStr:match('%-?%d+%.?%d*', pos)
        return tonumber(numStr)
    end

    local function readBool(key)
        local pos = afterKey(key)
        if not pos then return nil end
        local word = jsonStr:match('%a+', pos)
        return word == 'true'
    end

    local function readNumberArray(key)
        local _, e = jsonStr:find('"' .. key .. '"%s*:%s*%[')
        if not e then return {} end
        -- Read until the closing ]
        local closing = jsonStr:find('%]', e)
        local segment = jsonStr:sub(e, closing)
        local arr = {}
        for numStr in segment:gmatch('%-?%d+%.?%d*') do
            arr[#arr+1] = tonumber(numStr)
        end
        return arr
    end

    local function readBoolArray(key)
        local _, e = jsonStr:find('"' .. key .. '"%s*:%s*%[')
        if not e then return {} end
        local closing = jsonStr:find('%]', e)
        local segment = jsonStr:sub(e, closing)
        local arr = {}
        local pos = 1
        while pos <= #segment do
            if segment:sub(pos, pos+3) == 'true' then
                arr[#arr+1] = true;  pos = pos + 4
            elseif segment:sub(pos, pos+4) == 'false' then
                arr[#arr+1] = false; pos = pos + 5
            else
                pos = pos + 1
            end
        end
        return arr
    end

    -- Build project table matching the shape projectFromTable() expects.
    local proj = {
        version           = readNumber('version') or 1,
        bpm               = readNumber('bpm')     or 120,
        swing             = readNumber('swing')   or 0,
        chainEnabled      = readBool('chainEnabled') or false,
        currentChainIndex = readNumber('currentChainIndex') or 1,
        chain             = readNumberArray('chain'),
        trackVolumes      = readNumberArray('trackVolumes'),
        trackMutes        = readBoolArray('trackMutes'),
        trackBankIndices  = readNumberArray('trackBankIndices'),
        patterns          = {},
        chains            = {},
    }

    -- Parse "chains": [[1,2],[3,4],...] — an array of arrays.
    local _, chainsStart = jsonStr:find('"chains"%s*:%s*%[')
    if chainsStart then
        -- Walk forward tracking bracket depth to find the outer closing ']'.
        local depth = 0
        local chainsEnd = chainsStart
        for i = chainsStart, #jsonStr do
            local ch = jsonStr:sub(i, i)
            if     ch == '[' then depth = depth + 1
            elseif ch == ']' then
                depth = depth - 1
                if depth == 0 then chainsEnd = i; break end
            end
        end
        local segment = jsonStr:sub(chainsStart, chainsEnd)
        -- Start at 2 to skip the outer opening '['.
        local searchPos = 2
        while true do
            local arrOpen = segment:find('%[', searchPos)
            if not arrOpen then break end
            local arrClose = segment:find('%]', arrOpen)
            if not arrClose then break end
            local inner = segment:sub(arrOpen + 1, arrClose - 1)
            local chain = {}
            for numStr in inner:gmatch('%-?%d+%.?%d*') do
                chain[#chain+1] = tonumber(numStr)
            end
            if #chain > 0 then
                proj.chains[#proj.chains+1] = chain
            end
            searchPos = arrClose + 1
        end
    end
    -- Fallback: no chains field → derive from legacy "chain"
    if #proj.chains == 0 then
        proj.chains[1]        = (#proj.chain > 0) and proj.chain or {1}
        proj.currentChainIndex = 1
    end

    -- Parse patterns: "1": [[s,s,...], [s,s,...], ...], "2": [...], ...
    -- Find the "patterns" object opening brace.
    local _, patternsStart = jsonStr:find('"patterns"%s*:%s*{')
    if patternsStart then
        for p = 1, MAX_PATTERNS do
            proj.patterns[p] = {}
            -- Find "p": [ inside the patterns block
            local _, patStart = jsonStr:find('"' .. p .. '"%s*:%s*%[', patternsStart)
            if patStart then
                -- Each track is a [...] array; collect MAX_TRACKS of them
                local searchPos = patStart
                for ti = 1, #TRACK_NAMES do
                    local arrOpen = jsonStr:find('%[', searchPos)
                    if not arrOpen then break end
                    local arrClose = jsonStr:find('%]', arrOpen)
                    local segment  = jsonStr:sub(arrOpen + 1, arrClose - 1)
                    proj.patterns[p][ti] = {}
                    for numStr in segment:gmatch('%-?%d+%.?%d*') do
                        proj.patterns[p][ti][#proj.patterns[p][ti]+1] = tonumber(numStr)
                    end
                    searchPos = arrClose + 1
                end
            end
            -- Fill any missing tracks with zeros
            for ti = 1, #TRACK_NAMES do
                if not proj.patterns[p][ti] then
                    proj.patterns[p][ti] = {}
                end
                for s = 1, NUM_STEPS do
                    if not proj.patterns[p][ti][s] then
                        proj.patterns[p][ti][s] = 0
                    end
                end
            end
        end
    end

    return proj
end

local SHARED_PROJECT_DIR = "/Shared/DrumMachinePO/Projects/"

local function saveProject(slot)
    local proj = projectToTable()
    -- 1. Internal datastore (fast, used at runtime)
    playdate.datastore.write(proj, "project_" .. slot)
    -- 2. External visible JSON (human-readable, USB-accessible)
    local filename = SHARED_PROJECT_DIR .. "project_" .. slot .. ".json"
    local f = playdate.file.open(filename, playdate.file.kFileWrite)
    if f then
        f:write(projectToJSON(proj))
        f:close()
    end
end

local function loadProject(slot)
    -- External file takes priority over internal datastore.
    local filename = SHARED_PROJECT_DIR .. "project_" .. slot .. ".json"
    if playdate.file.exists(filename) then
        local f = playdate.file.open(filename, playdate.file.kFileRead)
        if f then
            local contents = ''
            local chunk = f:read(4096)
            while chunk and #chunk > 0 do
                contents = contents .. chunk
                chunk = f:read(4096)
            end
            f:close()
            local proj = projectFromJSON(contents)
            if proj then
                return projectFromTable(proj)
            end
        end
    end
    -- Fall back to internal datastore
    local data = playdate.datastore.read("project_" .. slot)
    return projectFromTable(data)
end


-- ============================================================
-- SYSTEM MENU  (3 items: Save, Load, Patterns)
-- Slot selection is done inside the Patterns screen (row 3).
-- ============================================================

local menu = playdate.getSystemMenu()



-- ============================================================
-- PERFORMANCE MODE
--
-- D-pad: each direction triggers a pre-assigned pattern chain.
--   Left=chain1  Up=chain2  Right=chain3  Down=chain4
--   Press mid-chain: finishes current pattern, then switches.
--   Hold direction + crank: reassigns which chain that direction plays.
--
-- B: start/stop (tap) / rewind to chain start (double-tap, stopped only)
-- A: cycle effect focus  BPM→Swing→BPM…  (Filter/Delay/Reverb TBD)
--    Crank controls the focused effect.
--    Double-tap A: reverse cycle direction.
-- ============================================================

-- ---- Effect objects for performance mode --------------------
-- Two-pole filter for LPF/HPF sweep (SDK 3.0.3: playdate.sound.twopolefilter)
-- ---- Performance state --------------------------------------

-- D-pad → chain index assignment (1-indexed into chains[])
local perfDirChain = { left=1, up=2, right=3, down=4 }
local perfDirNames = { left="LEFT", up="UP", right="RIGHT", down="DOWN" }
local perfLastDirTapMs = { left=0, up=0, right=0, down=0 }

-- Which direction is currently held (for crank-reassign)
local perfHeldDir  = nil   -- "left"|"up"|"right"|"down" or nil

-- Pending chain switch: set when user presses a dir mid-chain.
-- Applied at the next bar boundary (step 16→1) in update().
local perfPendingChainIdx = nil

-- Crank accumulator (reused from grid mode pattern)
local perfCrankAccum = 0

-- Effect focus cycling
-- Order: BPM → Swing → Filter → Delay → No effects → (wrap)
local PERF_FX_NAMES  = { "BPM", "Swing", "Filter", "Delay", "Bitcrusher", "No effects" }
local perfFxIndex    = 1    -- current focused effect (1-based)
local perfFxDir      = 1    -- +1 = forward, -1 = reverse cycle

-- Two-pole filters for performance mode LPF/HPF sweep
local perfFilterLPF = snd.twopolefilter.new("lowpass")
perfFilterLPF:setFrequency(20000)
perfFilterLPF:setResonance(0.5)
perfFilterLPF:setMix(0)
drumChannel:addEffect(perfFilterLPF)

local perfFilterHPF = snd.twopolefilter.new("highpass")
perfFilterHPF:setFrequency(20)
perfFilterHPF:setResonance(0.5)
perfFilterHPF:setMix(0)
drumChannel:addEffect(perfFilterHPF)

-- Bitcrusher for lo-fi crunch
local perfBitcrusher = snd.bitcrusher.new()
perfBitcrusher:setAmount(0)
perfBitcrusher:setUndersampling(0)
perfBitcrusher:setMix(0)
drumChannel:addEffect(perfBitcrusher)

local perfFilterParam  = 0   -- -1.0 (full LPF) to +1.0 (full HPF)
local perfReverbParam  = 0.0 -- 0=dry, 1=full reverb
local perfBitcrushParam = 0.0 -- 0=dry, 1=full crunch




-- A double-tap state
local perfLastATapMs = 0

-- B double-tap state (rewind)
local perfLastBTapMs = 0
local perfHeldDirCrankUsed = false  -- true if crank fired while a dir was held

local perfCurrentStep = 1

-- ---- Helpers ------------------------------------------------

-- Clamp helper
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Apply the focused effect change given a normalised crank delta direction (+1/-1)
local function perfApplyFxCrank(dir)
	local fx = PERF_FX_NAMES[perfFxIndex]
	if fx == "BPM" then
		bpmValue = clamp(bpmValue + dir * 1, 10, 300)
		setBPM(bpmValue)
	elseif fx == "Swing" then
		swingAmount = clamp(swingAmount + dir * 0.01, 0.0, 0.75)
		applySwingToAllTracks()
	elseif fx == "Filter" then
		perfFilterParam = clamp(perfFilterParam + dir * 0.05, -1.0, 1.0)
		if perfFilterParam < 0 then
			local t = -perfFilterParam
			perfFilterLPF:setFrequency(20000 * (1 - t) + 200 * t)
			perfFilterLPF:setMix(t)
			perfFilterHPF:setMix(0)
		elseif perfFilterParam > 0 then
			local t = perfFilterParam
			perfFilterHPF:setFrequency(20 * (1 - t) + 8000 * t)
			perfFilterHPF:setMix(t)
			perfFilterLPF:setMix(0)
		else
			perfFilterLPF:setMix(0)
			perfFilterHPF:setMix(0)
		end
	elseif fx == "Delay" then
		perfReverbParam = clamp(perfReverbParam + dir * 0.05, 0.0, 1.0)
		r:setMix(perfReverbParam * 0.8)
		r:setFeedback(perfReverbParam * 0.7)
	elseif fx == "Bitcrusher" then
		perfBitcrushParam = clamp(perfBitcrushParam + dir * 0.05, 0.0, 1.0)
		perfBitcrusher:setAmount(perfBitcrushParam * 0.8)
		perfBitcrusher:setUndersampling(perfBitcrushParam * 0.6)
		perfBitcrusher:setMix(math.min(perfBitcrushParam * 2, 1.0))
	end
end


local function onBarFinish(seq)
    if not isRunning then return end

    if performanceMode and perfPendingChainIdx ~= nil then
        saveCurrentPatternFromTracks()
        currentChainIndex   = perfPendingChainIdx
        chainList           = chains[currentChainIndex]
        chainStep           = 1
        perfPendingChainIdx = nil
        currentPattern      = chainList[1]
    elseif crankQueuedPattern ~= nil then
        saveCurrentPatternFromTracks()
        currentPattern     = crankQueuedPattern
        crankQueuedPattern = nil
        crankShadowSlot    = nil
    elseif chainEnabled and #chainList > 1 then
        saveCurrentPatternFromTracks()
        chainStep      = chainStep % #chainList + 1
        currentPattern = chainList[chainStep]
        chainList      = chains[currentChainIndex]
    end

    loadPatternIntoSequence(currentPattern)
    seq:goToStep(1)
    seq:play(onBarFinish)
    if performanceMode then
        drawPerformanceMode()
    else
        drawGrid()
    end
end
-- Switch performance chain immediately (start from step 1)
local function perfSwitchChain(chainIdx)
    perfPendingChainIdx = nil
    currentChainIndex   = chainIdx
    chainList           = chains[chainIdx]
    chainEnabled        = true
    chainStep           = 1
    currentPattern      = chainList[1]
    sequence:stop()
    cutActiveVoices()
    loadPatternIntoSequence(currentPattern)
    sequence:goToStep(1)
    if not isRunning then
        isRunning = true
    end
    sequence:play(onBarFinish)

    drawPerformanceMode()
end
-- Queue a chain switch for next bar boundary
local function perfQueueChain(chainIdx)
	perfPendingChainIdx = chainIdx
	drawPerformanceMode()
end

-- ---- Draw ---------------------------------------------------
drawPerformanceMode = function()
	gfx.lockFocus(grid)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(0, 0, 400, 240)
	gfx.setColor(gfx.kColorBlack)
	--print("perfcurrent:",perfCurrentStep)
	local phY, phW, phH = 15, 15, 15
	for i = 1, 16 do
		local phX = 75 + (i - 1) * (phW + 1)
		if i == perfCurrentStep then
			gfx.fillRect(phX, phY, phW, phH)
		else
			gfx.drawRect(phX, phY, phW, phH)
		end
	end

	-- Status line 1: chain assignments
	local dirOrder = { "left", "up", "right", "down" }
	local parts = {}
	for _, dir in ipairs(dirOrder) do
		parts[#parts+1] = string.upper(dir:sub(1,1)) .. ":" .. perfDirChain[dir]
	end
	gfx.drawText(table.concat(parts, " "), 4, 42)

	-- Status line 2: play state + effect
	local playTag = isRunning and "PLAY" or "STOP"
	local fx = PERF_FX_NAMES[perfFxIndex]
	local fxVal = ""
	if fx == "BPM" then
		fxVal = tostring(bpmValue)
	elseif fx == "Swing" then
		fxVal = math.floor(swingAmount * 100 + 0.5) .. "%"
	elseif fx == "Filter" then
		local dir = perfFilterParam < 0 and "Low Pass: " or "High Pass: "
		
		fxVal = dir .. " " .. string.format("%.2f", perfFilterParam)
	elseif fx == "Delay" then
		fxVal = math.floor(perfReverbParam * 100 + 0.5) .. "%"
	elseif fx == "Bitcrusher" then
		fxVal = math.floor(perfBitcrushParam * 100 + 0.5) .. "%"
	end
	gfx.drawText(playTag .. "  FX >[" .. fx .. "] " .. fxVal, 4, 58)

	-- Chain display: centered, chain name at top, boxes below
	local BOX_W   = 18
	local BOX_H   = 20
	local BOX_GAP = 4
	local chainLen   = #chainList
	local totalW     = chainLen * BOX_W + (chainLen - 1) * BOX_GAP
	local chainStartX = math.floor((400 - totalW) / 2)
	local chainNameY  = 82
	local boxY        = chainNameY + 24

	-- Chain name centred above boxes
	local chainName = "Chain " .. currentChainIndex
	if perfPendingChainIdx then
		chainName = chainName .. "  >  Chain " .. perfPendingChainIdx
	end
	local nameW = #chainName * 7  -- approx character width for system font
	gfx.drawText(chainName, math.floor((400 - nameW) / 2), chainNameY)

	-- Draw one box per chain slot
	for ci = 1, chainLen do
		local bx = chainStartX + (ci - 1) * (BOX_W + BOX_GAP)
		local pat = chainList[ci]
		local isCurrent = (pat == currentPattern and ci == chainStep)
		if isCurrent then
			gfx.setLineWidth(3)
			gfx.drawRect(bx, boxY, BOX_W, BOX_H)
			gfx.setLineWidth(1)
		else
			gfx.drawRect(bx, boxY, BOX_W, BOX_H)
		end
		gfx.drawText(tostring(pat), bx + (BOX_W - 7) / 2, boxY + 4)
	end

	-- Held dir hint
	local heldStr = perfHeldDir and ("Hold:" .. perfHeldDir) or ""
	gfx.drawText(heldStr, 4, boxY + BOX_H + 6)

	-- Button hints
	gfx.drawLine(0, 160, 400, 160)
	local firstLine = 162
	local lineDist = 17
	gfx.drawText("D-pad:play assigned pattern chains (queue)", 4, firstLine)
	gfx.drawText("Double tap D-pad:play pattern chains (immediate)", 4, firstLine+lineDist)
	gfx.drawText("D-pad hold + crank:re-assign pattern chains", 4, firstLine+lineDist*2)
	gfx.drawText("A/AA:cycle fx, B:play/stop, BB:rewind crank:fx val", 4, firstLine+lineDist*3)

	gfx.unlockFocus()
end

-- ---- Input handlers -----------------------------------------



local function perfUpDown()
	perfStatus.held.up   = true
	perfHeldDir          = "up"
	perfHeldDirCrankUsed = false
end

local function perfUpUp()
	perfStatus.held.up = false
	if perfHeldDir == "up" then
		perfHeldDir = nil
		if not perfHeldDirCrankUsed then
			local ci = perfDirChain["up"]
            local now = playdate.getCurrentTimeMilliseconds()
			--print("now:",now,"down pressed:",perfLastDirTapMs["up"])
            local isDouble = (now - perfLastDirTapMs["up"]) < DOUBLE_TAP_MS
            perfLastDirTapMs["up"] = now
            if isDouble or not isRunning  then
                perfSwitchChain(ci)
            else
                perfQueueChain(ci)
            end
			--[[			
			if isRunning and currentChainIndex ~= ci then
				perfQueueChain(ci)
			else
				perfSwitchChain(ci)
			end
			]]--
		end
	end
	perfCrankAccum = 0
	drawPerformanceMode()
end

local function perfDownDown()
	perfStatus.held.down   = true
	perfHeldDir          = "down"
	perfHeldDirCrankUsed = false
end
local function perfDownUp()
	perfStatus.held.down = false
	if perfHeldDir == "down" then
		perfHeldDir = nil
		if not perfHeldDirCrankUsed then
			local ci = perfDirChain["down"]
            local now = playdate.getCurrentTimeMilliseconds()
            local isDouble = (now - perfLastDirTapMs["down"]) < DOUBLE_TAP_MS
            perfLastDirTapMs["down"] = now
            if isDouble or not isRunning  then
                perfSwitchChain(ci)
            else
                perfQueueChain(ci)
            end			
			--[[
			if isRunning and currentChainIndex ~= ci then
				perfQueueChain(ci)
			else
				perfSwitchChain(ci)
			end
			]]--
		end
	end
	perfCrankAccum = 0
	drawPerformanceMode()
end


local function perfLeftDown()
	perfStatus.held.left   = true
	perfHeldDir          = "left"
	perfHeldDirCrankUsed = false
end
local function perfLeftUp()
	perfStatus.held.left = false
	if perfHeldDir == "left" then
		perfHeldDir = nil
		if not perfHeldDirCrankUsed then
			local ci = perfDirChain["left"]
            local now = playdate.getCurrentTimeMilliseconds()
            local isDouble = (now - perfLastDirTapMs["left"]) < DOUBLE_TAP_MS
            perfLastDirTapMs["left"] = now
            if isDouble or not isRunning then
                perfSwitchChain(ci)
            else
                perfQueueChain(ci)
            end
			--[[
			if isRunning and currentChainIndex ~= ci then
				perfQueueChain(ci)
			else
				perfSwitchChain(ci)
			end
			]]--
		end
	end
	perfCrankAccum = 0
	drawPerformanceMode()
end

local function perfRightDown()
	perfStatus.held.right   = true
	perfHeldDir          = "right"
	perfHeldDirCrankUsed = false
end
local function perfRightUp()
	perfStatus.held.right = false
	if perfHeldDir == "right" then
		perfHeldDir = nil
		if not perfHeldDirCrankUsed then
			local ci = perfDirChain["right"]
            local now = playdate.getCurrentTimeMilliseconds()
            local isDouble = (now - perfLastDirTapMs["right"]) < DOUBLE_TAP_MS
            perfLastDirTapMs["right"] = now
            if isDouble or not isRunning then
                perfSwitchChain(ci)
            else
                perfQueueChain(ci)
            end
			--[[
			if isRunning and currentChainIndex ~= ci then
				perfQueueChain(ci)
			else
				perfSwitchChain(ci)
			end
			]]--
		end
	end
	perfCrankAccum = 0
	drawPerformanceMode()
end

local perfAPendingAdvance = false  -- a single tap is waiting to fire
local perfALastDownMs = 0

local function perfADown()
    perfStatus.held.a = true
    perfALastDownMs = playdate.getCurrentTimeMilliseconds()
end

local function perfAUp()
    perfStatus.held.a = false
    local now = playdate.getCurrentTimeMilliseconds()
    if (now - perfLastATapMs) < DOUBLE_TAP_A_MS then
        -- Second tap released — cancel pending single tap, go back instead
        perfAPendingAdvance = false
        perfFxIndex = ((perfFxIndex - 2) % #PERF_FX_NAMES) + 1
        drawPerformanceMode()
    else
        -- First tap released — don't act yet, wait to see if second tap comes
        perfAPendingAdvance = true
    end
    perfLastATapMs = now
end

local function perfBDown()
	perfStatus.held.b = true
end
local function perfBUp()
	perfStatus.held.b = false
	local now = playdate.getCurrentTimeMilliseconds()
	local isDouble = (not isRunning) and (now - perfLastBTapMs) < DOUBLE_TAP_MS
	perfLastBTapMs = now
	if isDouble then
		-- Rewind to start of current chain
		sequence:stop()
		chainStep      = 1
		currentPattern = chainList[1]
		loadPatternIntoSequence(currentPattern)
		sequence:goToStep(1)
		perfPendingChainIdx = nil
	else
		-- Start / stop
		isRunning = not isRunning
		if isRunning then
			updatePOSyncTrack()
			sequence:play(onBarFinish)
		else
			sequence:stop()
			perfPendingChainIdx = nil
		end
	end
	drawPerformanceMode()
end

local function perfCranked(change, acceleratedChange)
	perfCrankAccum = perfCrankAccum + change
	if perfHeldDir ~= nil then
		-- Hold + crank: reassign which chain index this direction plays
		if math.abs(perfCrankAccum) >= 30 then
			local dir2 = perfCrankAccum > 0 and 1 or -1
			perfCrankAccum = 0
			perfHeldDirCrankUsed = true
			perfDirChain[perfHeldDir] = clamp(
				perfDirChain[perfHeldDir] + dir2, 1, MAX_CHAINS)
		end
	else
		-- Free crank: control active effect
		local threshold = 30
		if math.abs(perfCrankAccum) >= threshold then
			local dir2 = perfCrankAccum > 0 and 1 or -1
			perfCrankAccum = 0
			perfApplyFxCrank(dir2)
		end
	end
	drawPerformanceMode()
end

-- System menu toggle



-- ============================================================
-- MAIN UPDATE
-- ============================================================

local laststep         = 0
local lastStepForChain = 0  -- used to detect wrap from step 16 -> step 1
local prevRawStep = 0

function playdate.update()
	
	local rawStep = sequence:getCurrentStep()
	-- Convert internal scaled step back to a 1-based grid column (1..NUM_STEPS).
	-- math.ceil maps internal steps 1..STEP_SCALE → grid 1, STEP_SCALE+1..2×STEP_SCALE → grid 2, etc.
	local step = math.ceil(rawStep / STEP_SCALE)
	

	-- Chain advancement: when step wraps from NUM_STEPS back to 1
	
	
	if perfAPendingAdvance and playdate.getCurrentTimeMilliseconds() - perfLastATapMs >= DOUBLE_TAP_A_MS then
		perfAPendingAdvance = false
		perfFxIndex = (perfFxIndex % #PERF_FX_NAMES) + 1
		drawPerformanceMode()
	end


	-- if isRunning and step == NUM_STEPS and lastStepForChain == NUM_STEPS - 1 then
	-- 	if performanceMode and perfPendingChainIdx ~= nil then
	-- 		currentChainIndex   = perfPendingChainIdx
	-- 		chainList           = chains[currentChainIndex]
	-- 		chainStep           = 1
	-- 		perfPendingChainIdx = nil
	-- 		nextPattern         = chainList[1]
	-- 	elseif chainEnabled and #chainList > 1 then
	-- 		chainStep   = chainStep % #chainList + 1
	-- 		nextPattern = chainList[chainStep]
	-- 	end
	-- 	chainList = chains[currentChainIndex]   -- re-point alias defensively
	-- 	drawGrid()
	-- end
	
	lastStepForChain = step

	perfCurrentStep = step
	prevRawStep = rawStep
	if performanceMode then
		-- Performance mode: blit the static performance screen every frame.
		-- The sequencer keeps running (chain logic above still executes).
		if step ~= laststep then
        	laststep = step
        	drawPerformanceMode()
    	end
		grid:draw(0, 0)
		return
	end

	-- Always blit the offscreen image so mode changes appear immediately.
	-- Only redraw the playhead overlay when the step actually changes.
	if step ~= laststep then
		laststep = step
		drawGrid()  -- redraw into image (clears old playhead)
	end

	-- Blit image every frame
	grid:draw(0, 0)

	-- Draw playhead on top (only in grid mode, only while running)
	if uiMode == "grid" then
		local x = TEXT_WIDTH + step * ROW_HEIGHT - ROW_HEIGHT / 2
		--gfx.fillRect(x - 1, 0, 2, STATUS_Y - 1)
		gfx.fillRect(x - 1, 0, 2, 240)
	end
	
	if toastTimer > 0 and toastMessage then
		-- Display is inverted: kColorWhite = visually black, kColorBlack = visually white
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(80, 104, 240, 32)
		gfx.setColor(gfx.kColorBlack)
		gfx.drawRect(80, 104, 240, 32)
		gfx.drawText(toastMessage, 90, 112)
		toastTimer -= 1
	end

	-- Copy mode hold timer: while A is held in pattern row 1
	if uiMode == "pattern" and patternUIRow == 1 and playdate.buttonIsPressed(playdate.kButtonA) then
		btnHoldAdj = true
		if not patternCopyMode then
			patternAHoldFrames += 1
			if patternAHoldFrames >= COPY_HOLD_FRAMES then
				patternCopyMode   = true
				patternCopySource = selectedPatternSlot
				drawGrid()
			end
		end
	end

	-- B-hold timer: while B is held in pattern row 1, count toward pattern clear
	if uiMode == "pattern" and patternUIRow == 1
	   and not patternBHoldUsed
	   and not patternCopyMode
	   and dialogMessage == nil
	   and playdate.buttonIsPressed(playdate.kButtonB) then
		patternBHoldFrames += 1
		if patternBHoldFrames >= CLEAR_HOLD_FRAMES then
			patternBHoldUsed   = true   -- prevent re-fire while still held
			patternBHoldFrames = 0
			local targetPat    = selectedPatternSlot
			showDialog("Clear pattern " .. targetPat .. "?", function(confirmed)
				if confirmed then
					-- Clear all track notes in the target pattern
					for ti = 1, #tracks do
						for s = 1, NUM_STEPS do
							patterns[targetPat][ti].notes[s] = 0
						end
					end
					-- If it's the currently active pattern, flush to the sequencer too
					if targetPat == currentPattern then
						loadPatternIntoSequence(currentPattern)
					end
					showToast("Pattern " .. targetPat .. " cleared")
				end
				drawGrid()
			end)
			drawGrid()
		end
	elseif uiMode == "pattern" and patternUIRow == 3
		and selectedChainSlot >= 1 and selectedChainSlot <= #chainList
		and not patternBHoldUsed
		and dialogMessage == nil
		and playdate.buttonIsPressed(playdate.kButtonB) then
			patternBHoldFrames += 1
			if patternBHoldFrames >= CLEAR_HOLD_FRAMES then
				patternBHoldUsed   = true
				patternBHoldFrames = 0
				table.remove(chainList, selectedChainSlot)
				if #chainList == 0 then chainList[1] = 1 end
				selectedChainSlot = math.min(selectedChainSlot, #chainList)
				drawGrid()
			end
		end

	
	
	-- Reusable dialog: draw on top of everything when active
	if dialogMessage ~= nil then
		drawDialog()
	end
	
end

-- ============================================================
-- NOTE EDITING HELPERS
-- ============================================================

local function trackIndex(track)
	for ti, tr in ipairs(tracks) do if tr == track then return ti end end
	return nil
end

local function setTrackNote(track, pos, val)
	track.notes[pos] = val
	local ti = trackIndex(track)
	if ti then patterns[currentPattern][ti].notes[pos] = val end
	updateTrack(track, track.notes)
	drawGrid()
	-- SDK: instrument:playNote(note, volume, length, when)
	-- Omitting length and when plays indefinitely until noteOff; that's fine for preview.
	if not isRunning then
		track.inst:playNote(60, val/LEVEL_INCREMENTS)
	end
end

local adjusted = false
local adjusting = false

local function adjustSelectedNote(delta)
	local track = tracks[selectedRow]
	adjusted = true
	local val = track.notes[selectedColumn] + delta
	if val >= 0 and val <= LEVEL_INCREMENTS then
		setTrackNote(track, selectedColumn, val)
	end
end

-- ============================================================
-- PATTERN MODE ACTIONS
-- ============================================================

local function patternModeA()
	if patternUIRow == 1 then
		-- Pattern select
		switchToPattern(selectedPatternSlot)
		drawGrid()
		return
	elseif patternUIRow == 2 then
		-- CHAIN TOGGLE
		chainEnabled = not chainEnabled
		chainStep = 1
		drawGrid()
		return
	elseif patternUIRow == 3 then
		-- Chain row
		bUsedToExitPtn = true
		if selectedChainSlot == 0 then
			chainEnabled = true
			chainStep = 1
			currentPattern = chainList[1]
			loadPatternIntoSequence(currentPattern)
			sequence:goToStep(1)   -- ← always reset to bar start
			if not isRunning then
				isRunning = true
				sequence:play(onBarFinish)
			end
			bUsedToExitPtn = true    
			uiMode = "grid"
			drawGrid()
			return

		elseif selectedChainSlot == #chainList + 1 then
			chainList[#chainList+1] = currentPattern
			selectedChainSlot = #chainList
			drawGrid()
			return

		else
			chainList[selectedChainSlot] = selectedPatternSlot
			drawGrid()
			return
		end

	elseif patternUIRow == 6 then
		-- SAVE: confirm before overwriting
		local slot = currentSaveSlot
		showDialog("Save to slot " .. slot .. "?", function(confirmed)
			if confirmed then
				saveProject(slot)
				showToast("Saved: Slot " .. slot)
			end
			drawGrid()
		end)
		drawGrid()
		return

	elseif patternUIRow == 7 then
		-- LOAD: confirm before discarding unsaved changes
		local slot = currentSaveSlot
		showDialog("Load slot " .. slot .. "? Unsaved changes lost.", function(confirmed)
			if confirmed then
				local ok = loadProject(slot)
				if ok then showToast("Loaded: Slot " .. slot)
				else      showToast("Slot " .. slot .. ": empty") end
			end
			drawGrid()
		end)
		drawGrid()
		return

	elseif patternUIRow == 8 then
		-- PO SYNC TOGGLE
		poSyncEnabled = not poSyncEnabled
		updatePOSyncTrack()
		drawGrid()
		return
	end
end

-- patternModeB: tap action, called from BButtonUp only.
-- The 2s hold path (pattern clear) fires from update() and sets patternBHoldUsed,
-- so BButtonUp skips this function when a hold was consumed.
local function patternModeB()
	-- Cancel copy mode if active (any row)
	if patternCopyMode then
		patternCopyMode    = false
		patternCopySource  = nil
		patternAHoldFrames = 0
		drawGrid()
		return
	end

	-- Row 3: delete selected chain slot; otherwise fall through to back-to-grid
	--[[
	if patternUIRow == 3 and selectedChainSlot > 0 and selectedChainSlot <= #chainList then
		if #chainList > 1 then
			table.remove(chainList, selectedChainSlot)
			if selectedChainSlot > #chainList then selectedChainSlot = #chainList end
		end
		drawGrid()
		return
	end
	]]--

	-- All rows (including row 1 short-tap): B returns to grid
	uiMode = "grid"
	bUsedToExitPtn = true
	drawGrid()
end

-- ============================================================
-- BUTTON HANDLERS
-- NOTE: We define upButtonDown once below, replacing the earlier partial def.
-- ============================================================
local bSwingUsed = false   -- true if crank moved swing while B was held
local aBPMUsed = false   -- true if crank moved swing while A was held

function playdate.leftButtonDown()
	if performanceMode then perfLeftDown(); return end
	if dialogMessage ~= nil then return end
	if uiMode == "pattern" then
		if patternUIRow == 1 then
			if selectedPatternSlot > 1 then selectedPatternSlot = selectedPatternSlot - 1 end
		elseif patternUIRow == 4 then
			-- Chain selector: switch to previous chain
			if currentChainIndex > 1 then
				switchToChain(currentChainIndex - 1)				
				selectedChainSlot = 1				
			end
		elseif patternUIRow == 5 then
			if currentSaveSlot > 1 then currentSaveSlot = currentSaveSlot - 1 end
		elseif patternUIRow == 3 then
			if selectedChainSlot > 0 then selectedChainSlot = selectedChainSlot - 1 end
		end
		drawGrid()
		return
	end
	if adjusting then playdate.AButtonUp(); adjusted = true end
	-- column 0 = track name selected; left from col 1 enters name column
	if selectedColumn > 0 then
		selectedColumn = selectedColumn - 1
		drawGrid()
	end
end

function playdate.rightButtonDown()
	if performanceMode then perfRightDown(); return end
	if dialogMessage ~= nil then return end
	if uiMode == "pattern" then
		if patternUIRow == 1 then
			if selectedPatternSlot < MAX_PATTERNS then selectedPatternSlot = selectedPatternSlot + 1 end
		elseif patternUIRow == 4 then
			-- Chain selector: switch to next chain (up to MAX_CHAINS)
			if currentChainIndex < MAX_CHAINS then
				switchToChain(currentChainIndex + 1)
				selectedChainSlot = 1								
			end
		elseif patternUIRow == 5 then
			if currentSaveSlot < MAX_SAVE_SLOTS then currentSaveSlot = currentSaveSlot + 1 end
		elseif patternUIRow == 3 then
			if selectedChainSlot < #chainList + 1 then selectedChainSlot = selectedChainSlot + 1 end
		end
		drawGrid()
		return
	end
	if adjusting then playdate.AButtonUp(); adjusted = true end
	if selectedColumn < NUM_STEPS then
		selectedColumn = selectedColumn + 1
		drawGrid()
	end
end

-- upButtonDown: pressing Up while already on pattern row 1 toggles chain on/off.
-- This doubles as a simple toggle without needing a 4th menu item.
function playdate.upButtonDown()
	if performanceMode then perfUpDown(); return end
	if dialogMessage ~= nil then return end
	if uiMode == "pattern" then
		if patternUIRow > 1 then
			patternUIRow -= 1
		--else
			-- keep your existing chain toggle here
		--	chainEnabled = not chainEnabled
		--	chainStep = 1
		end
		drawGrid()
		return
	end
	--[[
	if selectedColumn == 0 then
		-- Track name selected: increase volume
		local tr = tracks[selectedRow]
		tr.volume = math.min(1.0, math.floor((tr.volume + 0.101) * 10 + 0.5) / 10)
		applyTrackVolume(tr)
		drawGrid()
		return
	end
	]]--
	if adjusting then
		adjustSelectedNote(1)
	else
		if selectedRow > 1 then selectedRow = selectedRow - 1; drawGrid() end
	end
end

function playdate.downButtonDown()
	if performanceMode then perfDownDown(); return end
	if dialogMessage ~= nil then return end
	if uiMode == "pattern" then
		if patternUIRow < 8 then
			patternUIRow += 1
		end
		drawGrid()
		return
	end
	--[[
	if selectedColumn == 0 then
		-- Track name selected: decrease volume
		local tr = tracks[selectedRow]
		tr.volume = math.max(0.0, math.floor((tr.volume - 0.101) * 10 + 0.5) / 10)
		applyTrackVolume(tr)
		drawGrid()
		return
	end
	]]--
	if adjusting then
		adjustSelectedNote(-1)
	else
		if selectedRow < #tracks then selectedRow = selectedRow + 1; drawGrid() end
	end
end

-- Release handlers for directional buttons.
-- In normal mode these are no-ops; performance mode routes them to perf stubs.
function playdate.upButtonUp()
	if performanceMode then perfUpUp(); return end
end

function playdate.downButtonUp()
	if performanceMode then perfDownUp(); return end
end

function playdate.leftButtonUp()
	if performanceMode then perfLeftUp(); return end
end

function playdate.rightButtonUp()
	if performanceMode then perfRightUp(); return end
end

function playdate.AButtonDown()
	if performanceMode then perfADown(); return end
	-- Dialog: A = Yes/Confirm (handled on AButtonUp to avoid same-press confirm)
	if dialogMessage ~= nil then return end

	if uiMode == "pattern" then
	
		-- Rows that open a dialog must be deferred to AButtonUp,
		-- otherwise the Up event immediately confirms the dialog that Down just opened.
		-- Row 1: hold timer runs in update(); tap handled in AButtonUp.
		-- Row 4 (save) and Row 5 (load): open a dialog, so also deferred to AButtonUp.
		local deferToUp = patternUIRow == 1
			or patternUIRow == 6
			or patternUIRow == 7
			or (patternUIRow == 2 and selectedChainSlot == 0)  -- [>] deferred
		if deferToUp then
			patternAHoldFrames = 0
		else
			patternModeA()
		end
		return
	end
	if selectedColumn == 0 then return end   -- track name selected: A reserved for future use
	adjusted = false
	adjusting = true
	aBPMUsed = false
end

function playdate.AButtonUp()
	if performanceMode then perfAUp(); return end
	-- Dialog: A = Yes/Confirm
	if dialogMessage ~= nil then
		dismissDialog(true)
		drawGrid()
		return
	end
	if uiMode == "pattern" then
		if patternUIRow == 1 then
			if patternCopyMode then
				local dest = selectedPatternSlot
				local src  = patternCopySource
				if dest ~= src then
					saveCurrentPatternFromTracks()
					for ti = 1, #tracks do
						for s = 1, NUM_STEPS do
							patterns[dest][ti].notes[s] = patterns[src][ti].notes[s]
						end
					end
					if dest == currentPattern then
						loadPatternIntoSequence(currentPattern)
					end
					showToast("P" .. src .. " copied to P" .. dest)
				end
				patternCopyMode    = false
				patternCopySource  = nil
				patternAHoldFrames = 0
				drawGrid()
			else
				if patternAHoldFrames < COPY_HOLD_FRAMES then
					patternModeA()
				end
				patternAHoldFrames = 0
			end
		elseif patternUIRow == 6 or patternUIRow == 7 then
			patternModeA()
		elseif patternUIRow == 3 and selectedChainSlot == 0 then
			patternModeA()   
		end
		return
	end
	if selectedColumn == 0 then
		-- Track name selected: A toggles mute
		local tr = tracks[selectedRow]
		tr.muted = not tr.muted
		applyTrackVolume(tr)
		drawGrid()
		return
	end
	adjusting = false
	if adjusted then return end
	local track = tracks[selectedRow]
	if not aBPMUsed then
		if track.notes[selectedColumn] == 0 then
			setTrackNote(track, selectedColumn, LEVEL_INCREMENTS)
		else
			setTrackNote(track, selectedColumn, 0)
		end
	end
	aBPMUsed = false
end


function playdate.BButtonDown()
	if performanceMode then perfBDown(); return end
	-- Dialog: B = No/Cancel
	if dialogMessage ~= nil then
		dismissDialog(false)
		patternBConsumedByDialog = true
		drawGrid()
		return
	end

	if uiMode == "pattern" then
		-- Start tracking the hold; patternModeB fires on BButtonUp (tap)
		-- or the hold path fires from update() after CLEAR_HOLD_FRAMES.
		patternBHoldFrames = 0
		patternBHoldUsed   = false
		return
	end
	bHeld      = true
	bSwingUsed = false
	--bUsedToExitPtn = false
	crankAccum = 0   -- reset accumulator so stray degrees don't bleed in
	drawGrid()       -- immediately show "SWING: x%" in status bar
end


function playdate.BButtonUp()
	if performanceMode then perfBUp(); return end
	if uiMode == "pattern" then
		-- Only fire the tap action if neither the hold nor a dialog consumed this press
		if not patternBHoldUsed and not patternBConsumedByDialog then
			patternModeB()
		end
		-- Always reset hold and dialog-consumed state on release
		patternBHoldFrames        = 0
		patternBHoldUsed          = false
		patternBConsumedByDialog  = false
		return
	end
	bHeld = false
	if not bSwingUsed and not bUsedToExitPtn then
		local now = playdate.getCurrentTimeMilliseconds()
		local isDoubleTap = (not isRunning) and (now - lastBTapTime < DOUBLE_TAP_MS)
		lastBTapTime = now

		if isDoubleTap then
			sequence:goToStep(1)
			if chainEnabled and #chainList > 1 then
				chainStep = 1
				currentPattern = chainList[1]
				loadPatternIntoSequence(currentPattern)
			end
			drawGrid()
		else
			isRunning = not isRunning
			if isRunning then
				updatePOSyncTrack()
				sequence:play(onBarFinish)
			else
				sequence:stop()
			end
			if crankQueuedPattern ~= nil then
				currentPattern     = crankQueuedPattern
				crankQueuedPattern = nil
				crankShadowSlot    = nil
				loadPatternIntoSequence(currentPattern)
			end
		end
	end
	bSwingUsed = false
	bUsedToExitPtn = false
	crankAccum = 0
	drawGrid()
end

-- ============================================================
-- CRANK
-- Grid mode:
--   B held + crank  → swing (0–50%, steps of 1%, threshold 20°)
--   A held + crank  → fine BPM ±1 (threshold 10°)
-- Pattern mode:
--   chain row 2     → chain slot value
--   elsewhere       → coarse BPM ±5
-- ============================================================

function playdate.cranked(change, acceleratedChange)
	if performanceMode then perfCranked(change, acceleratedChange); return end
		--print(patternUIRow,currentChainIndex,selectedPatternSlot)
	crankAccum = crankAccum + change

	if uiMode == "grid" then
		if bHeld then
			-- Swing adjust: ±5% per 20° of crank
			if math.abs(crankAccum) >= 20 then				
				local dir = crankAccum > 0 and 1 or -1
				crankAccum = 0
				swingAmount = math.max(0.0, math.min(0.75, swingAmount + dir * 0.01))
				bSwingUsed = true
				applySwingToAllTracks()
				drawGrid()
			end
		elseif adjusting then
			-- Fine BPM: ±1 per 10°
			if math.abs(crankAccum) >= 10 then				
				local dir = crankAccum > 0 and 1 or -1
				crankAccum = 0
				bpmValue = math.max(10, math.min(300, bpmValue + dir))
				aBPMUsed = true
				setBPM(bpmValue)
				drawGrid()
			end
		else
			if math.abs(crankAccum) >= 10 then
				local dir = crankAccum > 0 and 1 or -1
				crankAccum = 0
				-- Track name selected + multi-sample: switch bank
				if selectedColumn == 0 then
					local tr = tracks[selectedRow]
					if #tr.bank > 1 then
						switchTrackBank(tr, tr.bankIdx + dir)
						drawGrid()
						
					end
					return
				end
				local target = math.max(1, math.min(MAX_PATTERNS,
					(crankQueuedPattern or currentPattern) + dir))
				if not isRunning then
					-- Stopped: switch immediately, no queue needed
					crankQueuedPattern = nil
					crankShadowSlot    = nil
					switchToPattern(target)
				else
					-- Playing: queue for next bar boundary
					if target ~= currentPattern then
						crankQueuedPattern = target
					else
						crankQueuedPattern = nil
					end
				end
				drawGrid()
			end
		end
	else
		-- Pattern mode
		if math.abs(crankAccum) >= 30 then
			btnHoldAdj = true
			local dir = crankAccum > 0 and 1 or -1
			crankAccum = 0
			if patternUIRow == 3 and selectedChainSlot >= 1 and selectedChainSlot <= #chainList then
				local v = math.max(1, math.min(MAX_PATTERNS, chainList[selectedChainSlot] + dir))
				chainList[selectedChainSlot] = v
			else
				bpmValue = math.max(60, math.min(300, bpmValue + dir * 5))
				setBPM(bpmValue)
			end
			drawGrid()
		end
	end
end

-- ============================================================
-- AUTOSAVE / AUTOLOAD  (slot 0)
-- ============================================================

-- Silently autoload slot 0 on startup (no dialog — this is our own autosave)
loadProject(0)

-- Autosave to slot 0 whenever the game is about to terminate
function playdate.gameWillTerminate()
	saveProject(0)
end


menu:addMenuItem("Performance", function()
	performanceMode = not performanceMode
	if performanceMode then
		-- Reset transient state
		perfStatus.held     = { up=false, down=false, left=false, right=false, a=false, b=false }
		perfHeldDir         = nil
		perfPendingChainIdx = nil
		perfCrankAccum      = 0
		perfFxIndex         = 1
		perfFxDir           = 1
		perfLastATapMs      = 0
		perfLastBTapMs      = 0
		uiMode              = "grid"
		drawPerformanceMode()
	else
		-- Reset effects to neutral on exit
		perfFilterParam = 0
		perfFilterLPF:setMix(0)
		perfFilterHPF:setMix(0)
		perfReverbParam = 0
		r:setMix(0)
		r:setFeedback(0)
		perfBitcrushParam = 0
		perfBitcrusher:setAmount(0)
		perfBitcrusher:setUndersampling(0)
		perfBitcrusher:setMix(0)
		drawGrid()
	end
end)

menu:addMenuItem("PTNs/settings", function()
	performanceMode = false   -- leaving performance mode via any other menu item
	uiMode = "pattern"
	patternUIRow = 1
	drawGrid()
end)
-- ============================================================
-- INITIAL DRAW
-- ============================================================

-- AFTER
if not playdate.file.isdir("/Shared/DrumMachinePO") then
    playdate.file.mkdir("/Shared/DrumMachinePO")
end
if not playdate.file.isdir("/Shared/DrumMachinePO/Projects") then
    playdate.file.mkdir("/Shared/DrumMachinePO/Projects")
end
if not playdate.file.isdir("/Shared/DrumMachinePO/Samples") then
    playdate.file.mkdir("/Shared/DrumMachinePO/Samples")
end

drawGrid()
updatePOSyncTrack()