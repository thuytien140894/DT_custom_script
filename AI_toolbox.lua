local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "moduleExample")
local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

local function get_ollama_path()
  local osname = dt.configuration.running_os
  if osname == "windows" then
    return "ollama"
  end
  local paths = {
    "/opt/homebrew/bin/ollama",
    "/usr/local/bin/ollama",
    "/usr/bin/ollama",
    "/Applications/Ollama.app/Contents/Resources/ollama"
  }
  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end
  return "ollama"
end

local function pad_multiline_text(text, min_lines)
  if not text or text == "" then
    return string.rep("\n", min_lines)
  end
  local _, count = text:gsub("\n", "")
  local missing = min_lines - count
  if missing > 0 then
    return text .. string.rep("\n", missing)
  end
  return text
end

local function clean_ollama_output(output, start_pattern)
  if not output then return "" end
  
  -- Strip ANSI escape codes
  output = output:gsub("\27%[[%d;]*%a", "")
  
  -- Strip backspaces (ASCII 8) if any
  output = output:gsub("\8", "")

  -- Find start pattern and trim prefix
  if start_pattern then
    local lower_output = output:lower()
    local start_idx = lower_output:find(start_pattern:lower())
    if not start_idx then
      -- If not found, try finding start_pattern without its trailing colon/spaces
      local trimmed_pattern = start_pattern:gsub("[:%s]+$", "")
      start_idx = lower_output:find(trimmed_pattern:lower())
    end
    if start_idx then
      output = output:sub(start_idx)
    end
  end

  -- Strip leading/trailing whitespace
  output = output:gsub("^%s*(.-)%s*$", "%1")

  return output
end

local script_data = {}
script_data.metadata = {
  name = "AI Tollbox",
  purpose = _("Use AI to tag and rate pictures"),
  author = "Ayéda Okambawa",
}
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false
local txt_evaluation = nil

local log_file_path = dt.configuration.config_dir .. "/rejection_debug.log"
local known_ratings = {}
local ai_action_active = false
local darkroom_image = nil
local previously_selected_images = {}

local function log_debug(event_type, filename, details)
  local f = io.open(log_file_path, "a")
  if f then
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    f:write(string.format("[%s] [%s] Image: %s | %s\n", timestamp, event_type, filename, details))
    f:close()
  end
  dt.print_log(string.format("[AI_DEBUG] [%s] Image: %s | %s", event_type, filename, details))
end

local function check_and_log_changes(images)
  if not images then return end
  for _, img in ipairs(images) do
    local id = img.id
    local current_rating = img.rating
    local old_rating = known_ratings[id]
    if old_rating ~= nil then
      if current_rating ~= old_rating then
        if ai_action_active then
          log_debug("AI_ACTION", img.filename, string.format("rating changed from %d to %d", old_rating, current_rating))
        else
          log_debug("MANUAL_ACTION", img.filename, string.format("rating changed from %d to %d", old_rating, current_rating))
        end
        known_ratings[id] = current_rating
      end
    else
      known_ratings[id] = current_rating
    end
  end
end

local function on_selection_changed(event)
  -- 1. Check if any previously selected image's rating changed
  if #previously_selected_images > 0 then
    pcall(function()
      check_and_log_changes(previously_selected_images)
    end)
  end

  -- 2. Store the current selection for future rating tracking
  pcall(function()
    local current_selection = dt.gui.selection()
    previously_selected_images = {}
    if current_selection then
      for _, img in ipairs(current_selection) do
        table.insert(previously_selected_images, img)
        known_ratings[img.id] = img.rating
      end
    end
  end)

  pcall(function()
    if txt_evaluation then
      local images = dt.gui.selection()
      if #images == 1 then
        local img = images[1]
        local desc = img.description or ""
        if desc == "" then
          desc = "(No technical evaluation generated yet)"
        end
        txt_evaluation.label = pad_multiline_text("Selected: " .. img.filename .. "\n\n" .. desc, 8)
      elseif #images > 1 then
        local list = {}
        for i, img in ipairs(images) do
          if i > 10 then
            table.insert(list, "... and " .. (#images - 10) .. " more")
            break
          end
          table.insert(list, "- " .. img.filename)
        end
        txt_evaluation.label = pad_multiline_text("Selected photos (" .. #images .. "):\n" .. table.concat(list, "\n"), 8)
      else
        txt_evaluation.label = pad_multiline_text("No image selected.", 8)
      end
    end
  end)
end

local function run_command_background(command)
  local done = false
  local result = nil
  dt.control.dispatch(function()
    local handle = io.popen(command)
    result = handle:read("*a")
    handle:close()
    done = true
  end)
  while not done do
    dt.control.sleep(50)
  end
  return result
end

local function set_image_rating(img, rating)
  if rating == -1 then
    img.rating = 0
    dt.destroy_event("AIToolbox_selection", "selection-changed")
    local old_selection = dt.gui.selection()
    dt.gui.selection({img})
    dt.gui.action("views/thumbtable/rating", "reject", "activate", 1.000)
    dt.control.sleep(150)
    dt.gui.selection(old_selection)
    dt.register_event("AIToolbox_selection", "selection-changed", on_selection_changed)
  else
    img.rating = rating
  end
end

-----------------------------------------------------------------------
-- Helper function: translate host path to docker /tmp path
-----------------------------------------------------------------------
local function host_to_docker_path(host_path)
  local temp_dir = dt.configuration.tmp_dir
  local osname = dt.configuration.running_os

  if osname == "windows" then
    -- Normalize Windows path: replace backslashes with slashes
    local norm = host_path:gsub("\\", "/")
    -- Try to strip off host temp dir and remap into /tmp
    local subpath = norm:match(".-[Tt]emp/(.+)$")
    if subpath then
      return "/tmp/" .. subpath
    else
      return subpath -- fallback if regex fails
    end
  else
    -- On Linux, /tmp is already correct
    return host_path
  end
end

-----------------------------------------------------------------------
-- UI Widgets
-----------------------------------------------------------------------
local cbb_tag = dt.new_widget("combobox") {
  label = _("Nb of tags"),
  value = 1,
  "1","2","3","4","5"
}
local cbb_model = dt.new_widget("combobox") {
  label = _("Model"),
  value = 6,
  "gemma3:27b","gemma3:12b","gemma3:4b","llama3.2-vision:11b","minicpm-v:8b","qwen2.5vl:7b-ctx8k","llava:7b"
}
local cbb_lvl = dt.new_widget("combobox") {
  label = _("Strictness"),
  value = 1,
  "Clement","Moderate","Rigorous"
}
local cbb_crt = dt.new_widget("combobox") {
  label = _("Criteria"),
  value = 1,
  "Balance","Sharpness","Composition","Color","Light","Emotion"
}
local sld_quality = dt.new_widget("slider") {
  label = _("Temporary JPG quality "),
  soft_min = 0, soft_max = 100, hard_min = 0, hard_max = 100,
  step = 1, digits = 0, value = 95
}
local sld_size = dt.new_widget("slider") {
  label = _("Temporary JPG size"),
  soft_min = 0, soft_max = 4096, hard_min = 0, hard_max = 4096,
  step = 1, digits = 0, value = 0
}
local cbb_ollama = dt.new_widget("combobox") {
  label = _("Ollama installation"),
  value = 2,
  "Docker","Native"
}
txt_evaluation = dt.new_widget("label") {
  label = pad_multiline_text(_("Select a photo and click 'Generate' to see the technical assessment."), 8)
}
local cbt_clear = dt.new_widget("check_button"){label = _("Clear tags first"), value = true}
local separator1 = dt.new_widget("separator"){}

-----------------------------------------------------------------------
-- Export helper
-----------------------------------------------------------------------
local function export_to_temp_jpeg(img, max_size_override)
  local temp_file = os.tmpname() .. ".jpg"
  local jpeg_exporter = dt.new_format("jpeg")
  jpeg_exporter.quality = sld_quality.value
  
  local export_size = sld_size.value
  if max_size_override and (export_size == 0 or export_size > max_size_override) then
    export_size = max_size_override
  end

  jpeg_exporter.max_width = export_size
  jpeg_exporter.max_height = export_size
  jpeg_exporter:write_image(img, temp_file, true)
  dt.print_log(string.format("Exported %s to temp file %s (size: %d)", img.filename, temp_file, export_size))
  return temp_file
end

-----------------------------------------------------------------------
-- Tagging
-----------------------------------------------------------------------
local function tag_button()
  local images = dt.gui.selection()
  if #images == 0 then
    dt.print("No image selected")
    return
  end

  local selected_model = cbb_model.value
  local nb_tag = cbb_tag.value

  dt.control.dispatch(function()
    local job = dt.gui.create_job("AI Tag Assistant: analyzing " .. #images .. " image(s)...", false)

    for idx, img in ipairs(images) do
      if txt_evaluation then
        txt_evaluation.label = pad_multiline_text("AI Tagging: Analyzing image " .. idx .. " of " .. #images .. "...\n(Analyzing...)", 8)
      end
      dt.print(string.format("AI Tagging: Analyzing %d/%d (%s)...", idx, #images, img.filename))
      dt.control.sleep(50) -- Yield to GUI thread to draw progress

      local full_path = img.path .. "/" .. img.filename
      local members = img:get_group_members()

      -- Optionally clear existing tags
      if cbt_clear.value == true then
        for _, m in ipairs(members) do
          local current_tags = dt.tags.get_tags(m)
          for _, tag in ipairs(current_tags) do
            dt.tags.detach(tag, m)
          end
        end
      end

      dt.print("Processing: " .. full_path)
      local jpeg_path = export_to_temp_jpeg(img)
      local docker_path = host_to_docker_path(jpeg_path)

      -- Build prompt
      local prompt = "Analyze this image. Provide exactly " .. nb_tag ..
                     " descriptive tags for it. " ..
                     "Only output the tags separated with commas. Do not include any other text, explanations, or introductory phrases."

      -- Commands for Docker vs Native Ollama
      local command_docker = string.format(
        'docker exec ollama ollama run "%s" "%s" "%s"',
        selected_model, prompt, docker_path
      )
      local command_native = string.format(
        '"%s" run "%s" "%s" "%s" < /dev/null',
        get_ollama_path(), selected_model, prompt, jpeg_path
      )

      -- Run depending on selected installation
      local output
      if cbb_ollama.value == "Docker" then
        print("Running in Docker mode: " .. command_docker)
        local handle = io.popen(command_docker)
        output = handle:read("*a")
        handle:close()
      else -- Native
        print("Running in Native mode: " .. command_native)
        local handle = io.popen(command_native)
        output = handle:read("*a")
        handle:close()
      end

      output = clean_ollama_output(output)

      dt.print("Ollama output for " .. img.filename .. ": " .. output)

      -- Parse comma-separated tags
      for tag in string.gmatch(output, '([^,]+)') do
        local cleaned_tag = tag:match("^%s*(.-)%s*$")
        if cleaned_tag ~= "" then
          local tag_obj = dt.tags.create(cleaned_tag)
          for _, m in ipairs(members) do
            dt.tags.attach(tag_obj, m)
          end
          print("Added tag: " .. cleaned_tag .. " to group members of " .. img.filename)
        end
      end

      os.remove(jpeg_path) -- clean up
    end
    job.valid = false
    if txt_evaluation then
      txt_evaluation.label = pad_multiline_text("Tagging complete for " .. #images .. " image(s).", 8)
    end
    dt.print("Tagging complete for " .. #images .. " image(s).")
  end)
end

-----------------------------------------------------------------------
-- Rating
-----------------------------------------------------------------------
local function make_progress_bar(percent, width)
  width = width or 10
  local filled = math.floor(percent * width)
  local empty = width - filled
  return "[" .. string.rep("█", filled) .. string.rep("░", empty) .. "] " .. math.floor(percent * 100) .. "%"
end


local function btt_rating()
  local images = dt.gui.selection()
  if #images == 0 then
    dt.print("No image selected") return
  end
  local selected_model = cbb_model.value
  local strictness = cbb_lvl.value

  local job = dt.gui.create_job("AI Rating: evaluating " .. #images .. " image(s)...", false)

  for idx, img in ipairs(images) do
    if txt_evaluation then
      txt_evaluation.label = pad_multiline_text("AI Rating: Evaluating image " .. idx .. " of " .. #images .. "...\n(Evaluating...)", 8)
    end
    dt.print(string.format("AI Rating: Evaluating %d/%d (%s)...", idx, #images, img.filename))
    dt.control.sleep(50) -- Yield to GUI thread to draw progress

    local full_path = img.path .. "/" .. img.filename
    dt.print("Processing: " .. full_path)

    local jpeg_path = export_to_temp_jpeg(img)
    local docker_path = host_to_docker_path(jpeg_path)

    local prompt = "You are a " .. strictness .. " professional photography evaluator. " ..
                   "Assess this image's potential. " ..
                   "Start your response with 'Rating: <number>' (using a scale from -1 to 5: -1 Reject, 1 Very Bad, 2 Bad, 3 Okay, 4 Good, 5 Very Good) followed by a newline. " ..
                   "Then, provide a detailed technical assessment of composition, lighting, and color. Do not write anything else before the rating."

    -- Commands for Docker vs Native Ollama
    local command_docker = string.format(
      'docker exec ollama ollama run "%s" "%s" "%s"',
      selected_model, prompt, docker_path
    )
    local command_native = string.format(
      '"%s" run "%s" "%s" "%s" < /dev/null',
      get_ollama_path(), selected_model, prompt, jpeg_path
    )

    -- Run depending on selected installation
    local output
    if cbb_ollama.value == "Docker" then
      print("Running in Docker mode: " .. command_docker)
      output = run_command_background(command_docker)
    else -- Native
      print("Running in Native mode: " .. command_native)
      output = run_command_background(command_native)
    end

    output = clean_ollama_output(output, "rating:")

    local rating = tonumber(output:lower():match("rating:%s*(-?%d+)"))
    local members = img:get_group_members()
    if rating then
      if rating < -1 then rating = -1 end
      if rating > 5 then rating = 5 end
      ai_action_active = true
      if known_ratings[img.id] == nil then
        known_ratings[img.id] = img.rating
      end
      set_image_rating(img, rating)
      check_and_log_changes({img})
      ai_action_active = false
      print("Set rating for " .. img.filename .. " to " .. rating)
    else
      print("No valid rating found for " .. img.filename)
    end
    for _, m in ipairs(members) do
      pcall(function()
        m.description = output
      end)
    end
    if txt_evaluation then
      txt_evaluation.label = pad_multiline_text(output, 8)
    end
    os.remove(jpeg_path)
  end
  job.valid = false
  dt.print("Rating complete for " .. #images .. " image(s).")
end

-----------------------------------------------------------------------
-- Select Best Image
-----------------------------------------------------------------------
local function btt_select_best()
  local images = dt.gui.selection()
  if #images < 2 then
    dt.print("Select at least two images")
    return
  end
  local selected_model = cbb_model.value
  
  local job = dt.gui.create_job("AI Top Pick: comparing " .. #images .. " images...", false)
  if txt_evaluation then
    txt_evaluation.label = pad_multiline_text("AI Top Pick: Comparing " .. #images .. " images...\n(Analyzing...)", 8)
  end
  dt.print("AI Top Pick: Comparing " .. #images .. " images...")
  dt.control.sleep(50) -- Yield to GUI thread to draw spinner

  local criteria = cbb_crt.value
  local prompt = "Compare these images. Select ONLY the best one (the one with the highest potential for photography). " ..
                 "Focus on " .. criteria .. ". " ..
                 "Start your response with 'Best Image: <number>' (using the 1-based index of the image in the order provided, e.g. Best Image: 1) followed by a newline. " ..
                 "Then, provide a detailed comparison and technical justification explaining why you selected it over the other images. " ..
                 "Do not write anything else before the 'Best Image' header."

  local docker_paths = {}          -- container‑visible paths
  local native_paths = {}          -- host‑visible paths
  local tempfile_paths = {}        -- keep track for cleanup

  for idx, img in ipairs(images) do
    local jpeg_path = export_to_temp_jpeg(img, 1024)
    if not jpeg_path then
      dt.print("Export failed for " .. img.filename)
      job.valid = false
      return
    end
    local docker_path = host_to_docker_path(jpeg_path)
    table.insert(docker_paths, '"' .. docker_path .. '"')
    table.insert(native_paths, '"' .. jpeg_path .. '"')
    table.insert(tempfile_paths, { img = img, path = jpeg_path })
  end

  -- Commands for Docker vs Native Ollama
  local command_docker = string.format(
    'docker exec ollama ollama run "%s" "%s" %s',
    selected_model, prompt, table.concat(docker_paths, " ")
  )
  local command_native = string.format(
    '"%s" run "%s" "%s" %s < /dev/null',
    get_ollama_path(), selected_model, prompt, table.concat(native_paths, " ")
  )

  -- Run depending on selected installation
  local output
  if cbb_ollama.value == "Docker" then
    print("Running in Docker mode: " .. command_docker)
    output = run_command_background(command_docker)
  else -- Native
    print("Running in Native mode: " .. command_native)
    output = run_command_background(command_native)
  end

  output = clean_ollama_output(output, "best image:")

  dt.print("Ollama output: " .. output)
  
  local chosen_index = nil
  local clean_match_text = output:gsub("[*%#%_]", "")
  local lower_match_text = clean_match_text:lower()
  
  -- Try standard match first: "best image: 1"
  chosen_index = tonumber(lower_match_text:match("best image:%s*(%d+)"))
  
  if not chosen_index then
    -- Try match without colon: "best image 1"
    chosen_index = tonumber(lower_match_text:match("best image%s*(%d+)"))
  end
  
  if not chosen_index then
    -- Find the position of "best image" and find the first number that follows it
    local start_pos = lower_match_text:find("best image")
    if start_pos then
      local after_phrase = lower_match_text:sub(start_pos)
      chosen_index = tonumber(after_phrase:match("(%d+)"))
    end
  end
  
  if not chosen_index then
    -- Fallback to "best: <number>" or "best <number>"
    chosen_index = tonumber(lower_match_text:match("best:%s*(%d+)")) or tonumber(lower_match_text:match("best%s*(%d+)"))
  end

  if not chosen_index or chosen_index < 1 or chosen_index > #images then
    dt.print("Could not determine best image index")
    for _, t in ipairs(tempfile_paths) do os.remove(t.path) end
    job.valid = false
    return
  end

  ai_action_active = true
  local best_img = tempfile_paths[chosen_index].img
  local best_members = best_img:get_group_members()
  local keep_group_ids = {}
  for _, m in ipairs(best_members) do
    keep_group_ids[m.id] = true
  end

  local to_reject = {}
  local rejected_ids = {}

  for idx, t in ipairs(tempfile_paths) do
    local members = t.img:get_group_members()
    if idx ~= chosen_index then
      for _, m in ipairs(members) do
        if not keep_group_ids[m.id] and not rejected_ids[m.id] then
          rejected_ids[m.id] = true
          if known_ratings[m.id] == nil then
            known_ratings[m.id] = m.rating
          end
          table.insert(to_reject, m)
        end
      end
      print("Rejected group: " .. t.img.filename)
    else
      if known_ratings[t.img.id] == nil then
        known_ratings[t.img.id] = t.img.rating
      end
      set_image_rating(t.img, 0)
      for _, m in ipairs(members) do
        pcall(function()
          m.description = output
        end)
      end
      check_and_log_changes({t.img})
      print("Best image group kept: " .. t.img.filename)
    end
    os.remove(t.path)
  end

  -- Apply batch rejection for all collected images
  if #to_reject > 0 then
    for _, m in ipairs(to_reject) do
      m.rating = 0
    end
    dt.destroy_event("AIToolbox_selection", "selection-changed")
    local old_selection = dt.gui.selection()
    dt.gui.selection(to_reject)
    dt.gui.action("views/thumbtable/rating", "reject", "activate", 1.000)
    dt.control.sleep(150)
    dt.gui.selection(old_selection)
    dt.register_event("AIToolbox_selection", "selection-changed", on_selection_changed)
    
    for _, m in ipairs(to_reject) do
      check_and_log_changes({m})
    end
  end

  ai_action_active = false
  
  -- Select only the best image chosen by the AI
  local best_img = tempfile_paths[chosen_index].img
  dt.gui.selection({best_img})

  if txt_evaluation then
    txt_evaluation.label = pad_multiline_text(output, 8)
  end
  job.valid = false
  dt.print("Best image kept. Others rejected.")
end

-----------------------------------------------------------------------
-- GUI / Module lifecycle
-----------------------------------------------------------------------
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      "AIToolbox",
      _("AI Toolbox"),
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box") { orientation = "vertical", table.unpack(mE.widgets) },
      nil,nil
    )
    mE.module_installed = true
  end
end
local function destroy() dt.gui.libs["AIToolbox"].visible = false end
local function restart() dt.gui.libs["AIToolbox"].visible = true end

-- Labels
local lbl_tag = dt.new_widget("section_label"); lbl_tag.label = _("AI Tag Assistant")
local lbl_rating = dt.new_widget("section_label"); lbl_rating.label = _("AI Rating")
local lbl_evaluation = dt.new_widget("section_label"); lbl_evaluation.label = _("AI Technical Evaluation")
local lbl_setting = dt.new_widget("section_label"); lbl_setting.label = _("Settings")
local lbl_reject = dt.new_widget("section_label"); lbl_reject.label = _("AI's Top Pick'")

-- Buttons
local generate_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) tag_button() end}
local rating_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) btt_rating() end}
local reject_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) btt_select_best() end}
mE.widgets = {
  lbl_tag, cbt_clear, cbb_tag, separator1, generate_button,
  lbl_rating, cbb_lvl, rating_button,
  lbl_evaluation, txt_evaluation,
  lbl_reject, cbb_crt, reject_button,
  lbl_setting, cbb_ollama, cbb_model, sld_quality, sld_size
}

dt.register_event("AIToolbox_darkroom_load", "darkroom-image-loaded", function(event, clean, image)
  darkroom_image = image
  if image then
    check_and_log_changes({image})
  end
end)

dt.register_event("AIToolbox_view_sync", "view-changed", function(event, old_view, new_view)
  if new_view.id == "lighttable" then
    install_module()
  end
  if old_view and old_view.id == "darkroom" and new_view.id == "lighttable" then
    if darkroom_image then
      check_and_log_changes({darkroom_image})
    end
    darkroom_image = nil
  end
end)

dt.register_event("AIToolbox_exit", "exit", function(event)
  if darkroom_image then
    check_and_log_changes({darkroom_image})
  end
end)

if dt.gui.current_view().id == "lighttable" then
  install_module()
end


dt.register_event("AIToolbox_selection", "selection-changed", on_selection_changed)

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart
return script_data
