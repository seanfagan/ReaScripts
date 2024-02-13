-- @description Import VA for Skywind processing
-- @author ganz
-- @version 0.1
-- @about
--   Prepares the current Reaper project for Skywind VA processing. This is a 3-step
--   process. An pop-up will ask if you want to proceed with all 3 steps when you
--   run the script.
--   
--   Step 1. Import all wav files from the "[PROJECT]/media/importva" path. Create
--           new tracks for each subfolder in the path.
--   Step 2. Sort each track's items by RMS, from quietest to loudest.
--   Step 3. Glue each track's items together and place named region markers to mark
--           every item's bounds. Glueing the items together allows you to bring the
--           entire track into an audio editor, whereas the regions allow you to
--           export the items separately after editing is completed.
--
--   Special thanks to cfillion, x-raym, mordi, and SWS for your expertise.

-- CONFIG VARS --------------------------------------------------------------
local DIR_NAME = 'importva'
local STARTING_PATH = reaper.GetProjectPath()

-- ITERABLES ----------------------------------------------------------------

local function subdir_iter(path)
  local ix = -1
  return function()
    ix = ix + 1
    return reaper.EnumerateSubdirectories(path, ix)
  end
end


local function file_iter(path)
  local ix = -1
  return function()
    ix = ix + 1
    return reaper.EnumerateFiles(path, ix)
  end
end


local function tracks_iter()
  local ix = -1
  return function()
    ix = ix + 1
    return reaper.GetTrack(0, ix)
  end
end


local function items_in_track_iter(track)
  local ix = -1
  return function()
    ix = ix + 1
    return reaper.GetTrackMediaItem(track, ix)
  end
end

-- HELPER FUNCTIONS ---------------------------------------------------------

local function log(str)
  reaper.ShowConsoleMsg(str .. "\n")
end


local function is_wav(path)
  return string.find(path, '%.[wW][aA][vV]', -4) and true or false
end


local function get_path_to_va()
  local va_dir
  for subdir in subdir_iter(STARTING_PATH) do
    if subdir == DIR_NAME then
      va_dir = subdir  -- found the VA Folder
      break
    end
  end

  if not va_dir then
    return nil -- Could not find VA folder
  end
  return STARTING_PATH .. '/' .. va_dir
end


function sort_by_loudness(t)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do
      table.insert(keys, k)
    end

    -- sort the keys by their table value's loudness index
    table.sort(keys, function(a,b) return t[a]['loudness'] < t[b]['loudness'] end)

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return t[keys[i]]['item']
        end
    end
end

-- MAIN LOGIC ---------------------------------------------------------------

local function import_audio(va_path, dry_run)
  reaper.SetEditCurPos(0, true, false) -- move cursor to project start

  local ct = 0
  for subdir in subdir_iter(va_path) do
    if not dry_run then
      -- Create a track with subdirectory's name
      reaper.InsertTrackAtIndex(0, true)
      local new_track = reaper.GetTrack(0, 0)
      reaper.GetSetMediaTrackInfo_String(new_track, 'P_NAME', subdir, true)
      reaper.SetOnlyTrackSelected(new_track, true)
    end
    
    -- Iterate through files within subdirectory
    local va_subdir_path = va_path .. '/' .. subdir
    for file in file_iter(va_subdir_path) do
      if is_wav(file) then
        -- Insert WAV file to selected track
        ct = ct + 1
        if not dry_run then
          reaper.InsertMedia(va_subdir_path..'/'..file, 0)
        end
      end
    end
  end
  return ct
end


local function organize_all_items()
  local track_ctr = 0
  for track in tracks_iter() do
    track_ctr = track_ctr + 1

    local trackitems = {}
    for item in items_in_track_iter(track) do
      local src = reaper.GetMediaItemTake_Source(reaper.GetActiveTake(item))
      local loudness = reaper.CalculateNormalization(src, 1, 0, 0, 0) * -1  -- rms distance from 0dbfs
      table.insert(trackitems, {['item'] = item, ['loudness'] = loudness})
    end
    
    local first_item = reaper.GetTrackMediaItem(track, 0)
    if first_item then
      local dstart = reaper.GetMediaItemInfo_Value(first_item, 'D_POSITION')
      for item in sort_by_loudness(trackitems) do
        local item_length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
        reaper.SetMediaItemInfo_Value(item, 'D_POSITION', dstart)
        dstart = dstart + item_length
      end
    end
  end
end


local function glue_all_items()
  local items={}
  for i=1, reaper.CountSelectedMediaItems(0) do
    items[i] = {}
    local item = reaper.GetSelectedMediaItem(0, i-1)
    if item ~= nil then
      items[i].pos_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      items[i].pos_end = items[i].pos_start + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      
      local take = reaper.GetActiveTake(item)
      retval, items[i].name = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
    end
  end
  
  reaper.Main_OnCommand(40362, 0) -- glue selected items

  for i=1, #items do
    reaper.AddProjectMarker(0, true, items[i].pos_start, items[i].pos_end, items[i].name, -1)
  end
end


local function main()
  inp_prompts = {
    'Import audio files? y/n',
    'Sort items by RMS? y/n',
    'Glue items? y/n',
  }
  inp_defaults = {
    'y',
    'y',
    'y',
  }
  accept, csv = reaper.GetUserInputs("Skywind VA Importer", #inp_prompts, table.concat(inp_prompts, ','), table.concat(inp_defaults, ','))
  if accept then
    responses = {}
    for v in string.gmatch(csv, '[^,]+') do
      table.insert(responses, v)
    end
    
    if responses[1] == 'y' then
      -- Import audio files
      va_path = get_path_to_va()
      if not va_path then
        reaper.ShowMessageBox('Could not find folder "'..DIR_NAME..'" in path "'..STARTING_PATH..'"', 'Skywind VA Importer', 0)
        return nil
      else
        count = import_audio(va_path, true)
        local ir = reaper.ShowMessageBox('Import '..count..' audio files from folder "'..DIR_NAME..'"?', 'Skywind VA Importer', 1)
        if ir == 1 then
          reaper.Undo_BeginBlock()
          import_audio(va_path, false)
          reaper.Undo_EndBlock('SKYW: Import audio files', -1)
        end
      end
    end
    if responses[2] == 'y' then
      -- Sort items by RMS
      reaper.Undo_BeginBlock()
      organize_all_items()
      reaper.Undo_EndBlock('SKYW: Sort items by RMS', -1)
    end
    if responses[3] == 'y' then
      -- Glue items and place markers
      reaper.Undo_BeginBlock()
      glue_all_items()
      reaper.Undo_EndBlock('SKYW: Glue items and place markers', -1)
    end
  end
end

main()
