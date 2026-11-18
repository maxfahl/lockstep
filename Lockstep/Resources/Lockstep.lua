--[[
Lockstep: puts the clips sent from Lockstep on the open timeline.

Lockstep installs this file as Fusion/Scripts/Utility/Lockstep.lua in DaVinci Resolve's folder (Settings >
DaVinci in Lockstep), and Resolve then lists it as Workspace > Scripts > Lockstep. It is written for the free
edition of DaVinci Resolve 21.0.4 and uses only what Resolve's own Lua has.

What it does, each time it is chosen:
 1. Reads the list Lockstep wrote at the last Send to DaVinci:
    ~/Library/Application Support/Lockstep/DaVinci/clips.lua
 2. For every clip in it that it has not placed yet:
    - checks that the open timeline has the frame rate and the start the clip was exported for,
    - imports the file into a bin called "Lockstep",
    - finds the audio track with the name of the clip's track in Lockstep, or adds one and names it: a
      stereo track for a clip sent with its sound, which is a stereo file, and a mono track otherwise,
    - puts the clip there, sound only, on its frame.
    A clip sent with its sound rings on after its end, so it can still be heard when the next clip of its
    track starts. One audio track holds one clip at a time, so of two such clips of one send the later one
    goes to a second track, named like the first with " B" after it (then " C", and so on).
 3. Notes each placed clip in placed.txt beside the list, so choosing it again places nothing twice.
 4. Says in a dialog what it placed and what it did not, and why. The same words go to Resolve's Console
    (Workspace > Console) and to "Last run.txt" beside the list.

It never removes or moves anything that was on the timeline, never changes a setting and never saves the project.
So a stereo clip that goes to a track that is mono is placed all the same, and the report says to change that
track to stereo in Resolve.

The calls are the ones in Resolve's Developer/Scripting/README.txt. Every call goes through `call`, which never
stops the script: a call that fails or does not exist counts as "no answer", and the report says what could
not be done.
]]

local LIST_VERSION = 1
local BIN_NAME = "Lockstep"
local AUDIO_ONLY = 2

-- ---------------------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------------------

local unpackList = unpack or table.unpack

-- A global of Resolve's Lua by name, or nil. Asked this way so a missing one is never an error.
local function global(name)
    local found, value = pcall(function() return _G[name] end)
    if found then return value end
    return nil
end

-- Calls object:method(...) and gives its first answer, or nil when the call failed or is not there.
local function call(object, method, ...)
    if object == nil then return nil end
    local arguments = { ... }
    local count = select("#", ...)
    local worked, answer = pcall(function()
        return object[method](object, unpackList(arguments, 1, count))
    end)
    if worked then return answer end
    return nil
end

-- A list from Resolve as a plain array, in order. Resolve gives lists as tables with numbers as keys.
-- Anything else counts as an empty list.
local function listOf(value)
    local items = {}
    if type(value) ~= "table" then return items end
    local keys = {}
    for key in pairs(value) do
        if type(key) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        items[#items + 1] = value[key]
    end
    return items
end

-- A whole number from an answer that may be a number or a text, or nil.
local function wholeNumber(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.floor(number + 0.5)
end

-- A frame rate from an answer such as 25, "25", "25.0" or "23.976", or nil. "29.97 DF" gives 29.97.
local function frameRateOf(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then return nil end
    return tonumber(string.match(value, "^%s*(%d+%.?%d*)"))
end

local function plural(count, one, many)
    if count == 1 then return "1 " .. one end
    return tostring(count) .. " " .. many
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file == nil then return false end
    file:close()
    return true
end

-- ---------------------------------------------------------------------------------------------------------
-- Telling Max
-- ---------------------------------------------------------------------------------------------------------

-- Shows a text in a dialog of macOS, without waiting for it to be closed, so Resolve never hangs on it.
-- Resolve's own dialogs for scripts are not in the free edition. If this cannot be done either, the words
-- are still in the Console and in "Last run.txt".
local function showDialog(text)
    if type(os) ~= "table" or type(os.execute) ~= "function" then return end
    -- First as a text inside AppleScript, then as one word for the shell.
    local inScript = text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "\\n")
    local dialog = 'display dialog "' .. inScript .. '" with title "Lockstep" buttons {"OK"} default button "OK"'
    local function word(value)
        return "'" .. value:gsub("'", "'\\''") .. "'"
    end
    local command = "/usr/bin/osascript -e 'try' -e 'activate' -e 'end try' -e " .. word(dialog)
        .. " >/dev/null 2>&1 &"
    pcall(os.execute, command)
end

-- Ends a run: the report goes to the Console, to "Last run.txt" in `folder` (when there is one) and to a dialog.
local function tell(lines, folder)
    local report = table.concat(lines, "\n")
    print("Lockstep\n" .. report)
    local kept = false
    if folder ~= nil then
        local file = io.open(folder .. "/Last run.txt", "w")
        if file ~= nil then
            file:write(report .. "\n")
            file:close()
            kept = true
        end
    end
    -- A dialog cannot scroll, so a long report is cut there and the rest is read in the file.
    local shown = report
    local limit = 24
    if #lines > limit then
        local first = {}
        for index = 1, limit do first[index] = lines[index] end
        first[#first + 1] = ""
        if kept then
            first[#first + 1] = "There is more. The whole report is in " .. folder .. "/Last run.txt"
        else
            first[#first + 1] = "There is more. Read it in Resolve under Workspace > Console."
        end
        shown = table.concat(first, "\n")
    end
    showDialog(shown)
end

-- ---------------------------------------------------------------------------------------------------------
-- The list from Lockstep
-- ---------------------------------------------------------------------------------------------------------

-- Reads the list. Gives the list, or nil and a sentence for Max.
local function readList(path)
    if not fileExists(path) then
        return nil, "Lockstep has not sent any clips yet. In Lockstep, select the clips and choose Send to DaVinci."
    end
    local chunk, problem
    if type(loadfile) == "function" then
        chunk, problem = loadfile(path)
    end
    if chunk == nil then
        return nil, "The list from Lockstep could not be read (" .. tostring(problem) .. "). Send the clips again from Lockstep."
    end
    -- The list is only a table of texts and numbers. It is run with nothing in reach, so it can do nothing else.
    if type(setfenv) == "function" then setfenv(chunk, {}) end
    local worked, list = pcall(chunk)
    if not worked or type(list) ~= "table" then
        return nil, "The list from Lockstep is not in the form this script reads. Send the clips again from Lockstep."
    end
    -- Asked before anything else of the list, because another version may keep its clips differently.
    if list.version ~= LIST_VERSION then
        return nil, "The list from Lockstep and this script are of different versions (list "
            .. tostring(list.version) .. ", script " .. tostring(LIST_VERSION)
            .. "). In Lockstep, open Settings > DaVinci and install the script again, quit Resolve and open it again, then send the clips again."
    end
    if type(list.clips) ~= "table" then
        return nil, "The list from Lockstep is not in the form this script reads. Send the clips again from Lockstep."
    end
    return list, nil
end

-- A clip of the list with every value checked, or nil and what is wrong with it.
local function checkedClip(entry)
    if type(entry) ~= "table" then return nil, "its entry in the list is not readable" end
    local clip = {
        id = entry.id,
        file = entry.file,
        name = entry.clip,
        track = entry.track,
        frame = wholeNumber(entry.frame),
        frames = wholeNumber(entry.frames),
        -- A list from before clips were sent with their sound does not say, and every file was mono then.
        channels = wholeNumber(entry.channels) or 1,
        timecode = entry.timecode,
        frameRate = frameRateOf(entry.frameRate),
        frameRateText = tostring(entry.frameRate),
        timelineStart = entry.timelineStart,
        timelineStartFrame = wholeNumber(entry.timelineStartFrame),
    }
    for _, key in ipairs({ "id", "file", "name", "track", "timecode", "timelineStart" }) do
        if type(clip[key]) ~= "string" then return nil, "its entry in the list has no " .. key end
    end
    for _, key in ipairs({ "frame", "frames", "frameRate", "timelineStartFrame" }) do
        if clip[key] == nil then return nil, "its entry in the list has no " .. key end
    end
    if clip.id == "" or clip.file == "" then return nil, "its entry in the list is empty" end
    if clip.frames < 1 then return nil, "the list says its file is empty" end
    if clip.track == "" then clip.track = "Lockstep" end
    if clip.channels < 1 then clip.channels = 1 end
    return clip, nil
end

-- Says for every clip of the list which audio track it goes to (`placeTrack`), and which track of its own
-- track's it is (`lane`, 1 for the track with the Lockstep track's name).
--
-- In Lockstep two clips of one track never lie over each other, but their files can: a clip sent with its
-- sound rings on after its end, and every file is a whole number of frames long. Resolve holds one clip at a
-- time on an audio track. So the clips of each track are gone through in the order they start, and a clip
-- that starts before the one before it on that track has ended goes to the next track that is free there:
-- "Double", then "Double B", then "Double C". Only the list is read, so choosing the script again gives every
-- clip the same track.
local function giveTracks(clips)
    local inOrder = {}
    for index, clip in ipairs(clips) do inOrder[index] = clip end
    table.sort(inOrder, function(one, other)
        if one.frame ~= other.frame then return one.frame < other.frame end
        return one.id < other.id
    end)
    local endsOfTrack = {}
    for _, clip in ipairs(inOrder) do
        local ends = endsOfTrack[clip.track]
        if ends == nil then
            ends = {}
            endsOfTrack[clip.track] = ends
        end
        local lane = 1
        while ends[lane] ~= nil and ends[lane] > clip.frame do lane = lane + 1 end
        ends[lane] = clip.frame + clip.frames
        clip.lane = lane
        if lane == 1 then
            clip.placeTrack = clip.track
        elseif lane <= 26 then
            clip.placeTrack = clip.track .. " " .. string.char(64 + lane)
        else
            clip.placeTrack = clip.track .. " " .. lane
        end
    end
end

-- What a clip is called in the report.
local function described(clip)
    if clip.name ~= nil and clip.name ~= "" then
        return '"' .. clip.name .. '" (track "' .. clip.track .. '", ' .. clip.timecode .. ")"
    end
    return 'the clip for track "' .. clip.track .. '" at ' .. clip.timecode
end

-- The ids this script has noted as placed, as a set.
local function readPlaced(path)
    local placed = {}
    local file = io.open(path, "r")
    if file == nil then return placed end
    for line in file:lines() do
        local id = line:gsub("%s+", "")
        if id ~= "" then placed[id] = true end
    end
    file:close()
    return placed
end

-- Notes one clip as placed. False when the note could not be written.
local function notePlaced(path, id)
    local file = io.open(path, "a")
    if file == nil then return false end
    file:write(id .. "\n")
    file:close()
    return true
end

-- ---------------------------------------------------------------------------------------------------------
-- Resolve
-- ---------------------------------------------------------------------------------------------------------

local function findResolve()
    local make = global("Resolve")
    if make ~= nil then
        local worked, found = pcall(make)
        if worked and found ~= nil then return found end
    end
    local ready = global("resolve")
    if ready ~= nil then return ready end
    local bmd = global("bmd")
    if bmd ~= nil then
        local worked, found = pcall(function() return bmd.scriptapp("Resolve") end)
        if worked and found ~= nil then return found end
    end
    return nil
end

-- The bin called "Lockstep" at the top of the media pool, made when it is not there. Nil when it cannot be had.
local function lockstepBin(mediaPool)
    local root = call(mediaPool, "GetRootFolder")
    if root == nil then return nil end
    for _, folder in ipairs(listOf(call(root, "GetSubFolderList"))) do
        if call(folder, "GetName") == BIN_NAME then return folder end
    end
    local made = call(mediaPool, "AddSubFolder", root, BIN_NAME)
    if made == nil or made == false then return nil end
    return made
end

-- The file as a clip of the media pool, in the Lockstep bin. Gives the clip, or nil and why.
-- `reused` is true when Resolve already had the file in the bin and that clip is used again.
-- The bin is looked for, or made, at the first file, so a run that places nothing leaves no empty bin.
local function importFile(resolveSide, path)
    local mediaPool = resolveSide.mediaPool
    if resolveSide.bin == nil then
        resolveSide.bin = lockstepBin(mediaPool)
    end
    local bin = resolveSide.bin
    if bin == nil then
        return nil, 'Resolve would not make the bin "' .. BIN_NAME .. '" in the media pool', false
    end
    if not call(mediaPool, "SetCurrentFolder", bin) then
        return nil, 'Resolve would not open the bin "' .. BIN_NAME .. '"', false
    end
    local imported = listOf(call(mediaPool, "ImportMedia", { path }))
    if imported[1] ~= nil then return imported[1], nil, false end
    -- Nothing came back. Resolve does that for a file that is in the bin already.
    for _, item in ipairs(listOf(call(bin, "GetClipList"))) do
        if call(item, "GetClipProperty", "File Path") == path then return item, nil, true end
    end
    return nil, "Resolve would not import the file " .. path, false
end

-- The number of the audio track with this name, or nil.
local function trackNamed(timeline, name)
    local count = wholeNumber(call(timeline, "GetTrackCount", "audio")) or 0
    for index = 1, count do
        if call(timeline, "GetTrackName", "audio", index) == name then return index end
    end
    return nil
end

-- The kind of an audio track as Resolve names it ("mono", "stereo", "5.1" and so on), or nil where Resolve
-- does not say: an older Resolve has no such call.
local function trackKind(timeline, index)
    local kind = call(timeline, "GetTrackSubType", "audio", index)
    if type(kind) ~= "string" or kind == "" then return nil end
    return string.lower(kind)
end

-- Adds an audio track of a kind ("mono" or "stereo") at the bottom and names it. Gives its number and a note
-- for the report (or nil), or nil and why it could not be added.
local function addTrack(timeline, name, kind)
    local before = wholeNumber(call(timeline, "GetTrackCount", "audio"))
    if before == nil then return nil, "Resolve did not say how many audio tracks the timeline has" end
    local after = before
    if call(timeline, "AddTrack", "audio", kind) then
        after = wholeNumber(call(timeline, "GetTrackCount", "audio")) or before
    end
    if after ~= before + 1 then
        -- The same without asking for a kind, for a Resolve that takes none here. Resolve then adds a mono
        -- track. For a stereo clip that is found out after the clip is placed, and the report says so.
        if call(timeline, "AddTrack", "audio") then
            after = wholeNumber(call(timeline, "GetTrackCount", "audio")) or before
        end
    end
    if after ~= before + 1 then
        return nil, 'Resolve would not add an audio track for "' .. name .. '". Add an audio track by hand, name it "'
            .. name .. '" and choose Lockstep again'
    end
    if not call(timeline, "SetTrackName", "audio", after, name)
        or call(timeline, "GetTrackName", "audio", after) ~= name then
        return after, "Audio track " .. after .. ' was added but Resolve would not name it "' .. name
            .. '". Name it by hand, or the next clips of that track get one more new track.'
    end
    return after, nil
end

-- What already lies on a track where a clip is to go: the name of the first clip found there, or nil.
local function clipInTheWay(timeline, trackIndex, firstFrame, frames)
    for _, item in ipairs(listOf(call(timeline, "GetItemListInTrack", "audio", trackIndex))) do
        local start = tonumber(call(item, "GetStart"))
        local finish = tonumber(call(item, "GetEnd"))
        if start ~= nil and finish ~= nil and start < firstFrame + frames and finish > firstFrame then
            return tostring(call(item, "GetName") or "a clip")
        end
    end
    return nil
end

-- Where a clip that was just put on the timeline is: "right", "wrong" with a sentence, or "unknown".
local function placeOf(item, trackIndex, firstFrame)
    local start = tonumber(call(item, "GetStart"))
    if start == nil then return "unknown", nil end
    if math.floor(start + 0.5) ~= firstFrame then
        return "wrong", "Resolve put it on frame " .. math.floor(start + 0.5) .. " in place of frame " .. firstFrame
    end
    local track = call(item, "GetTrackTypeAndIndex")
    if type(track) == "table" then
        local where = listOf(track)
        local kind, index = where[1], wholeNumber(where[2])
        if kind ~= nil and index ~= nil and (kind ~= "audio" or index ~= trackIndex) then
            return "wrong", "Resolve put it on " .. tostring(kind) .. " track " .. index .. " in place of audio track "
                .. trackIndex
        end
    end
    return "right", nil
end

-- Puts a clip of the media pool on an audio track at a frame, sound only. Gives the clip on the timeline (or
-- true when Resolve said yes without handing it over) and a note for the report, or nil and why not.
--
-- Resolve's description leaves open whether the stretch of the file may be left out and whether its last
-- frame is counted in. So the forms are tried in turn: first the whole file, then the stretch written both
-- ways. It does not say either whether the frame to put the clip on is counted from 00:00:00:00, as the
-- frames Resolve gives back are, or from the start of the timeline. The first is tried first, then the other.
-- Where the clip landed is read back each time, and a try that landed in the wrong place is taken away
-- again before the next one.
local function appendClip(mediaPool, timeline, item, trackIndex, firstFrame, frames, frameFromStart)
    local stretches = { {}, { startFrame = 0, endFrame = frames }, { startFrame = 0, endFrame = frames - 1 } }
    local tries = {}
    for _, stretch in ipairs(stretches) do
        tries[#tries + 1] = { recordFrame = firstFrame, stretch = stretch }
    end
    if frameFromStart ~= firstFrame then
        for _, stretch in ipairs(stretches) do
            tries[#tries + 1] = { recordFrame = frameFromStart, stretch = stretch }
        end
    end
    local trouble = "Resolve did not put the clip on the timeline"
    for _, try in ipairs(tries) do
        local stretch = try.stretch
        local info = {
            mediaPoolItem = item,
            mediaType = AUDIO_ONLY,
            trackIndex = trackIndex,
            recordFrame = try.recordFrame,
            startFrame = stretch.startFrame,
            endFrame = stretch.endFrame,
        }
        local answer = call(mediaPool, "AppendToTimeline", { info })
        local placed = listOf(answer)[1]
        if placed ~= nil then
            local where, problem = placeOf(placed, trackIndex, firstFrame)
            if where == "right" then
                local length = tonumber(call(placed, "GetDuration"))
                if length ~= nil and math.floor(length + 0.5) ~= frames then
                    return placed, "In Resolve it is " .. plural(math.floor(length + 0.5), "frame", "frames")
                        .. " long, but the file is " .. plural(frames, "frame", "frames")
                        .. ". If Resolve had an older file of the same name in its Lockstep bin, remove it there and send the clip again."
                end
                return placed, nil
            end
            if where == "unknown" then
                return placed, "Resolve did not say where it put the clip. Check that it starts at its timecode."
            end
            trouble = problem
            if not call(timeline, "DeleteClips", { placed }, false) then
                return nil, problem .. ", and would not take it away again. Remove that clip by hand"
            end
        elseif answer == true then
            -- An older answer: yes, without the clip. Look for it where it should be.
            for _, onTrack in ipairs(listOf(call(timeline, "GetItemListInTrack", "audio", trackIndex))) do
                local start = tonumber(call(onTrack, "GetStart"))
                if start ~= nil and math.floor(start + 0.5) == firstFrame then return onTrack, nil end
            end
            return true, "Resolve did not say where it put the clip. Check that it starts at its timecode."
        end
    end
    return nil, trouble
end

-- Places one clip of the list. Gives true and a note (or nil), or false and why not.
local function place(clip, resolveSide)
    local timeline, mediaPool = resolveSide.timeline, resolveSide.mediaPool

    if math.abs(resolveSide.frameRate - clip.frameRate) > 0.01 then
        return false, "The timeline runs at " .. resolveSide.frameRateText .. " frames per second, but the clip was exported for "
            .. clip.frameRateText .. ". In Lockstep's Send to DaVinci panel, set Frame rate to the timeline's and send again."
    end
    if resolveSide.startFrame ~= clip.timelineStartFrame then
        return false, "The timeline starts at " .. resolveSide.startText .. ", but the clip was exported for a timeline that starts at "
            .. clip.timelineStart .. ". In Lockstep's Send to DaVinci panel, set Timeline start to the timeline's and send again."
    end
    if clip.frame < 0 then
        return false, "It starts before the start of the timeline, where Resolve has no room for it."
    end
    if not fileExists(clip.file) then
        return false, "Its file is gone: " .. clip.file .. ". Send the clip again from Lockstep."
    end

    local firstFrame = resolveSide.startFrame + clip.frame
    local notes = {}

    -- A track that is there is looked at before anything is changed: nothing is imported or added for a
    -- clip that cannot go where it should.
    local trackName = clip.placeTrack or clip.track
    local trackIndex = trackNamed(timeline, trackName)
    if trackIndex ~= nil then
        if call(timeline, "GetIsTrackLocked", "audio", trackIndex) then
            return false, 'The audio track "' .. trackName .. '" is locked in Resolve. Unlock it and choose Lockstep again.'
        end
        local inTheWay = clipInTheWay(timeline, trackIndex, firstFrame, clip.frames)
        if inTheWay ~= nil then
            return false, 'There is already a clip there on the audio track "' .. trackName .. '" (' .. inTheWay
                .. "). Remove it in Resolve and choose Lockstep again."
        end
    end

    local item, problem, reused = importFile(resolveSide, clip.file)
    if item == nil then return false, problem .. "." end

    local isStereo = clip.channels >= 2
    if trackIndex == nil then
        local added, note = addTrack(timeline, trackName, isStereo and "stereo" or "mono")
        if added == nil then return false, note .. "." end
        trackIndex = added
        if note ~= nil then notes[#notes + 1] = note end
    end

    local placed, note = appendClip(mediaPool, timeline, item, trackIndex, firstFrame, clip.frames, clip.frame)
    if placed == nil then return false, note .. "." end
    if note ~= nil then
        notes[#notes + 1] = note
    elseif reused then
        notes[#notes + 1] = "Resolve already had a file of this name in its Lockstep bin and used that one."
    end
    if trackName ~= clip.track then
        notes[#notes + 1] = 'It is on the audio track "' .. trackName .. '", because it is heard together with another clip of "'
            .. clip.track .. '".'
    end
    -- A mono track plays only one side of a stereo clip. The track is Max's to change: it is only noted, once
    -- for each track, and said at the end of the report.
    if isStereo and trackKind(timeline, trackIndex) == "mono" and not resolveSide.isNotedMono[trackName] then
        resolveSide.isNotedMono[trackName] = true
        table.insert(resolveSide.monoTracks, trackName)
    end
    if #notes == 0 then return true, nil end
    return true, table.concat(notes, " ")
end

-- ---------------------------------------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------------------------------------

local function run()
    local home = os.getenv("HOME")
    if type(home) ~= "string" or home == "" then
        tell({ "Lockstep could not find your home folder, so it does not know where the list of clips is." }, nil)
        return
    end
    local folder = home .. "/Library/Application Support/Lockstep/DaVinci"
    local placedPath = folder .. "/placed.txt"

    local list, problem = readList(folder .. "/clips.lua")
    if list == nil then
        -- The folder is Lockstep's to make. Before the first send there is none, and nothing is written.
        tell({ problem }, fileExists(folder .. "/clips.lua") and folder or nil)
        return
    end

    -- What is still to place.
    local alreadyPlaced = readPlaced(placedPath)
    local waiting, unreadable, earlier, readable = {}, {}, 0, {}
    for position, entry in ipairs(listOf(list.clips)) do
        local clip, wrong = checkedClip(entry)
        if clip == nil then
            unreadable[#unreadable + 1] = "- Clip " .. position .. " of the list: " .. wrong .. "."
        else
            readable[#readable + 1] = clip
            if alreadyPlaced[clip.id] then
                earlier = earlier + 1
            else
                waiting[#waiting + 1] = clip
            end
        end
    end
    -- From every clip of the list, the ones placed before among them, so a clip gets the same track each time.
    giveTracks(readable)
    if #waiting == 0 and #unreadable == 0 then
        if earlier == 0 then
            tell({ "The list from Lockstep is empty. In Lockstep, select the clips and choose Send to DaVinci." }, folder)
        else
            tell({
                "Nothing new to place. " .. (earlier == 1 and "The clip" or ("All " .. earlier .. " clips"))
                    .. " of the last send " .. (earlier == 1 and "is" or "are") .. " already on the timeline.",
                "To place " .. (earlier == 1 and "it" or "them") .. " once more, send again from Lockstep.",
            }, folder)
        end
        return
    end

    -- Resolve's side.
    local resolve = findResolve()
    local project = call(call(resolve, "GetProjectManager"), "GetCurrentProject")
    if project == nil then
        tell({ "Nothing was placed: Resolve has no project open. Open your project and choose Lockstep again." }, folder)
        return
    end
    local timeline = call(project, "GetCurrentTimeline")
    if timeline == nil then
        tell({ "Nothing was placed: no timeline is open in Resolve. Open the timeline of the song and choose Lockstep again." }, folder)
        return
    end
    local mediaPool = call(project, "GetMediaPool")
    if mediaPool == nil then
        tell({ "Nothing was placed: Resolve did not give its media pool to the script." }, folder)
        return
    end
    local timelineName = tostring(call(timeline, "GetName") or "the open timeline")

    local startFrame = wholeNumber(call(timeline, "GetStartFrame"))
    local rateAnswer = call(timeline, "GetSetting", "timelineFrameRate")
    if frameRateOf(rateAnswer) == nil then
        rateAnswer = call(project, "GetSetting", "timelineFrameRate")
    end
    local frameRate = frameRateOf(rateAnswer)
    if startFrame == nil or frameRate == nil then
        tell({
            "Nothing was placed: Resolve did not say " .. (startFrame == nil and "where the timeline starts" or "which frame rate the timeline has")
                .. ", so the script cannot know that the clips would land on the right frames.",
            "Place them by hand with the timecodes in Lockstep's Send to DaVinci panel, and tell this to whoever looks after Lockstep.",
        }, folder)
        return
    end

    local resolveSide = {
        timeline = timeline,
        mediaPool = mediaPool,
        startFrame = startFrame,
        startText = tostring(call(timeline, "GetStartTimecode") or ("frame " .. startFrame)),
        frameRate = frameRate,
        frameRateText = tostring(rateAnswer),
        -- The mono tracks that got a stereo clip in this run, in the order they were found, for the report.
        monoTracks = {},
        isNotedMono = {},
    }

    -- Importing opens the Lockstep bin. The bin that was open is opened again after.
    local openFolder = call(mediaPool, "GetCurrentFolder")

    -- Clips that were not placed are kept by their reason, so a reason all of them share is said once.
    local placed, reasons, clipsByReason, noteFailed = {}, {}, {}, false
    local function notPlacedBecause(clip, reason)
        if clipsByReason[reason] == nil then
            clipsByReason[reason] = {}
            reasons[#reasons + 1] = reason
        end
        table.insert(clipsByReason[reason], described(clip))
    end
    for _, clip in ipairs(waiting) do
        local worked, done, words = pcall(place, clip, resolveSide)
        if not worked then
            notPlacedBecause(clip, "The script stopped on it (" .. tostring(done) .. ").")
        elseif done then
            placed[#placed + 1] = "- " .. described(clip) .. (words and (". " .. words) or "")
            if not notePlaced(placedPath, clip.id) then noteFailed = true end
        else
            notPlacedBecause(clip, tostring(words))
        end
    end
    if openFolder ~= nil then call(mediaPool, "SetCurrentFolder", openFolder) end

    -- The report.
    local lines = {}
    if #placed > 0 then
        lines[#lines + 1] = "Lockstep placed " .. plural(#placed, "clip", "clips") .. ' on the timeline "' .. timelineName .. '":'
        for _, line in ipairs(placed) do lines[#lines + 1] = line end
    else
        lines[#lines + 1] = 'Lockstep placed nothing on the timeline "' .. timelineName .. '".'
    end
    if #resolveSide.monoTracks > 0 then
        local names = {}
        for index, name in ipairs(resolveSide.monoTracks) do names[index] = '"' .. name .. '"' end
        lines[#lines + 1] = ""
        if #names == 1 then
            lines[#lines + 1] = "The audio track " .. names[1] .. " is mono in Resolve, but the clips placed on it are stereo."
                .. " A mono track plays only one side of them."
            lines[#lines + 1] = "Right-click the track's header in Resolve and choose Change Track Type To > Stereo."
        else
            lines[#lines + 1] = "These audio tracks are mono in Resolve, but the clips placed on them are stereo: "
                .. table.concat(names, ", ") .. ". A mono track plays only one side of them."
            lines[#lines + 1] = "Right-click each track's header in Resolve and choose Change Track Type To > Stereo."
        end
    end
    if #reasons + #unreadable > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Not placed:"
        for _, reason in ipairs(reasons) do
            lines[#lines + 1] = "- " .. table.concat(clipsByReason[reason], ", ") .. ": " .. reason
        end
        for _, line in ipairs(unreadable) do lines[#lines + 1] = line end
    end
    if earlier > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = plural(earlier, "clip", "clips") .. " of this send " .. (earlier == 1 and "was" or "were")
            .. " placed before and left alone."
    end
    if noteFailed then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Lockstep could not note what it placed (" .. placedPath
            .. "). Choosing Lockstep again would place these clips a second time."
    end
    tell(lines, folder)
end

-- Whatever goes wrong, Max is told, and Resolve is left as it is at that moment.
local worked, problem = pcall(run)
if not worked then
    tell({
        "Lockstep's script stopped before it was done: " .. tostring(problem),
        "Look at the timeline: some clips may have been placed. Copy these words to whoever looks after Lockstep.",
    }, nil)
end
