local ui = require("warp.ui")

local M = {}

local DEFAULT_KEYS = { "<Leader>w", "<Leader>W" }

local DEFAULT_MODELS = {
    {
        id = "inception/mercury-2",
        name = "MERCURY",
        enabled = false,
    },
    {
        id = "openai/gpt-oss-120b",
        name = "RAPID",
        provider = {
            only = { "cerebras/fp16" },
            allow_fallbacks = false,
        },
    },
    {
        id = "openai/gpt-5.6-luna",
        name = "ADVANCED",
        reasoning = { effort = "medium" },
    },
}

local DEFAULT_SYSTEM_PROMPT =
    "Provide straightforward responses and commands quickly. Do not mention Ghostty or Neovim unless the user asks."

M.models = vim.deepcopy(DEFAULT_MODELS)
M.active_model = 2
M.fallback_model_name = "MERCURY"
M.max_context_lines = 500
M.max_context_bytes = 65536
M.explain_prompt = "What does this file do in a nutshell?"
M.system_prompt = DEFAULT_SYSTEM_PROMPT
M.secrets_file = nil

local mapped_keys = {}

local augroup = vim.api.nvim_create_augroup("Warp", { clear = true })
local ns = vim.api.nvim_create_namespace("warp")
local float_win = nil
local warp_buf = nil
local active_job = nil
local current_phase = "input"
local messages = {}
local input_start_line = 0
local session_cost = 0
local code_block_label_ids = {}
local allow_transcript_cursor = false
local file_context = nil
local pending_stream_text = ""
local stream_paint_timer = nil
local stream_active = false
local stream_flush_queued = false
local stream_undolevels = nil
local stream_first_paint = false

-- ── Diagnostics ───────────────────────────────────────────────────────
local LOG_PATH = vim.fn.stdpath("data") .. "/warp.log"
local log_lines = {}

local function log(msg)
    table.insert(log_lines, msg)
end

local function flush_log()
    if #log_lines == 0 then return end
    local file = io.open(LOG_PATH, "a")
    if not file then return end
    file:write(table.concat(log_lines, "\n"), "\n")
    file:close()
    log_lines = {}
end


local function current_model()
    return M.models[M.active_model]
end

function M.fallback_model()
    for _, mdl in ipairs(M.models) do
        if mdl.name == M.fallback_model_name then
            return mdl
        end
    end
    return nil
end

function M.collect_file_context(buf)
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end
    if vim.bo[buf].buftype ~= "" then return nil end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return nil end
    local total = vim.api.nvim_buf_line_count(buf)
    local take = math.min(total, M.max_context_lines)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, take, false)
    local text = table.concat(lines, "\n")
    if text:find("\0", 1, true) then return nil end
    local truncated = take < total
    if #text > M.max_context_bytes then
        text = text:sub(1, M.max_context_bytes)
        truncated = true
    end
    return {
        path = path,
        display = vim.fn.fnamemodify(path, ":t"),
        filetype = vim.bo[buf].filetype,
        text = text,
        truncated = truncated,
    }
end

function M.format_file_context(ctx)
    if not ctx then return nil end
    local lang = ctx.filetype ~= "" and ctx.filetype or ""
    local body = "The user opened Warp from this Neovim file. Use it when they refer to this file, this buffer, or the code on screen.\n\n"
        .. "Path: " .. ctx.path .. "\n"
        .. "Filetype: " .. (ctx.filetype ~= "" and ctx.filetype or "unknown") .. "\n\n"
        .. "```" .. lang .. "\n" .. ctx.text .. "\n```"
    if ctx.truncated then
        body = body .. "\n\n(truncated)"
    end
    return body
end

function M.current_file_context()
    return file_context
end

local function buf_valid()
    return warp_buf and vim.api.nvim_buf_is_valid(warp_buf)
end

local function win_valid()
    return float_win and vim.api.nvim_win_is_valid(float_win)
end

local function set_buf_modifiable(modifiable)
    if buf_valid() then vim.bo[warp_buf].modifiable = modifiable end
end

function M.fill_input(text)
    if not buf_valid() then return false end
    set_buf_modifiable(true)
    local lines = vim.split(text, "\n", { plain = true })
    if input_start_line == 0 then
        vim.api.nvim_buf_set_lines(warp_buf, 0, -1, false, lines)
    else
        vim.api.nvim_buf_set_lines(warp_buf, input_start_line, -1, false, lines)
    end
    return true
end

local function stop_stream_timer()
    if stream_paint_timer then
        stream_paint_timer:stop()
        stream_paint_timer:close()
        stream_paint_timer = nil
    end
    stream_flush_queued = false
end

local function cancel_job()
    pending_stream_text = ""
    stop_stream_timer()
    stream_active = false
    stream_first_paint = false
    if buf_valid() and stream_undolevels then
        vim.bo[warp_buf].undolevels = stream_undolevels
        stream_undolevels = nil
    end
    if active_job then
        pcall(vim.fn.jobstop, active_job)
        active_job = nil
    end
end

local function cost_label()
    if session_cost <= 0 then return "" end
    if session_cost < 0.01 then
        return string.format(" $%.6f ", session_cost)
    end
    return string.format(" $%.4f ", session_cost)
end

function M.close()
    cancel_job()
    if not win_valid() then
        float_win = nil
        return
    end
    vim.cmd("nohlsearch")
    pcall(vim.api.nvim_win_close, float_win, true)
    float_win = nil
    if buf_valid() then
        pcall(vim.api.nvim_buf_delete, warp_buf, { force = true })
    end
    warp_buf = nil
    current_phase = "input"
    messages = {}
    input_start_line = 0
    session_cost = 0
    code_block_label_ids = {}
    allow_transcript_cursor = false
    file_context = nil
end

local function mode_chip(mode)
    if mode and mode:find("^i") then
        return { " INSERT ", "WarpInsert" }
    end
    return { " NORMAL ", "WarpNormal" }
end

local function float_title(phase, mode)
    local model_name = current_model().name
    local cost = cost_label()
    local cost_chip = cost ~= "" and { cost, "WarpCost" } or nil

    local title = { { " WARP ", "WarpTitle" } }
    if phase == "waiting" then
        table.insert(title, { " thinking… ", "WarpWaiting" })
        table.insert(title, { " esc: cancel ", "FloatTitle" })
    else
        table.insert(title, mode_chip(mode))
        table.insert(title, { " " .. model_name .. " ", "WarpModel" })
        if file_context then
            table.insert(title, { " " .. file_context.display .. " ", "WarpCost" })
        end
        if cost_chip then table.insert(title, cost_chip) end
        if phase == "input" and input_start_line == 0 then
            table.insert(title, { " enter: send · esc: close ", "FloatTitle" })
        elseif phase == "input" then
            table.insert(title, { " enter: send · drag copy · esc ", "FloatTitle" })
        else
            table.insert(title, { " drag copy · 1-9 · m · esc ", "FloatTitle" })
        end
    end
    return title
end

local function update_title(phase)
    current_phase = phase
    if not win_valid() then return end
    vim.api.nvim_win_set_config(float_win, {
        title = float_title(phase, vim.fn.mode()),
        title_pos = "center",
    })
end

vim.api.nvim_create_autocmd("ModeChanged", {
    group = augroup,
    callback = function()
        if not win_valid() then return end
        if vim.api.nvim_get_current_win() ~= float_win then return end
        if current_phase == "waiting" then return end
        vim.api.nvim_win_set_config(float_win, {
            title = float_title(current_phase, vim.v.event.new_mode),
            title_pos = "center",
        })
    end,
})

local function get_current_input()
    if not buf_valid() then return "" end
    local lines = vim.api.nvim_buf_get_lines(warp_buf, input_start_line, -1, false)
    return table.concat(lines, "\n")
end

local function get_last_response()
    for i = #messages, 1, -1 do
        if messages[i].role == "assistant" then
            return messages[i].content
        end
    end
    return ""
end

local function tint_response_lines(start_0, end_0)
    if not buf_valid() then return end
    for i = start_0, end_0 do
        vim.api.nvim_buf_set_extmark(warp_buf, ns, i, 0, {
            hl_group = "WarpResponse",
            hl_eol = true,
        })
    end
end

-- ── Visual: dim submitted query ───────────────────────────────────────
local function dim_query_lines(start_0, end_0)
    if not buf_valid() then return end
    for i = start_0, end_0 do
        vim.api.nvim_buf_set_extmark(warp_buf, ns, i, 0, {
            hl_group = "WarpDimmed",
            end_row = i + 1,
            end_col = 0,
            priority = 200,
        })
    end
end


-- ── Visual: code block labels ─────────────────────────────────────────
local function find_code_blocks()
    if not buf_valid() then return {} end
    local lines = vim.api.nvim_buf_get_lines(warp_buf, 0, -1, false)
    local blocks = {}
    local in_block = false
    local block_start, block_lang
    for i, line in ipairs(lines) do
        if not in_block and line:match("^```") then
            in_block = true
            block_start = i
            block_lang = line:match("^```(%S+)") or ""
        elseif in_block and line:match("^```%s*$") then
            in_block = false
            local content_lines = vim.api.nvim_buf_get_lines(
                warp_buf, block_start, i - 1, false)
            table.insert(blocks, {
                start_line = block_start,
                end_line = i,
                lang = block_lang,
                content = table.concat(content_lines, "\n"),
            })
        end
    end
    return blocks
end

local function copy_text(text)
    vim.fn.setreg("+", text)
    vim.fn.setreg("*", text)
end

local function copy_block(block)
    copy_text(block.content)
    local label = block.lang ~= "" and block.lang or "Code"
    ui.flash(label .. " block copied.", 1500)
end

local function label_code_blocks()
    if not buf_valid() then return end
    for _, id in ipairs(code_block_label_ids) do
        pcall(vim.api.nvim_buf_del_extmark, warp_buf, ns, id)
    end
    code_block_label_ids = {}
    local blocks = find_code_blocks()
    for idx, block in ipairs(blocks) do
        local id = vim.api.nvim_buf_set_extmark(warp_buf, ns, block.start_line - 1, 0, {
            virt_text = { { " [copy " .. idx .. "] ", "WarpBlockLabel" } },
            virt_text_pos = "eol",
        })
        table.insert(code_block_label_ids, id)
    end
end

local function fence_block_at(line)
    for _, block in ipairs(find_code_blocks()) do
        if line == block.start_line or line == block.end_line then
            return block
        end
    end
    return nil
end

local function copy_code_block()
    local blocks = find_code_blocks()
    if #blocks == 0 then
        ui.flash("No code blocks.", 1500)
        return false
    end
    if not win_valid() then return false end
    local cursor_line = vim.api.nvim_win_get_cursor(float_win)[1]
    local best = blocks[#blocks]
    for _, block in ipairs(blocks) do
        if cursor_line >= block.start_line and cursor_line <= block.end_line then
            best = block
            break
        end
    end
    copy_block(best)
    return true
end

function M.find_code_blocks()
    return find_code_blocks()
end

function M.copy_block_index(index)
    local block = find_code_blocks()[index]
    if not block then
        ui.flash("No code block " .. tostring(index) .. ".", 1500)
        return false
    end
    copy_block(block)
    return true
end

function M.load_transcript(lines)
    if not buf_valid() then return false end
    set_buf_modifiable(true)
    vim.api.nvim_buf_set_lines(warp_buf, 0, -1, false, lines)
    input_start_line = 0
    for i, line in ipairs(lines) do
        if line == "───" then
            input_start_line = i
        end
    end
    allow_transcript_cursor = false
    label_code_blocks()
    update_title("input")
    return true
end

function M.handle_left_mouse_at(line, column)
    if not buf_valid() or not win_valid() then return "passthrough" end
    if type(line) ~= "number" or line < 1 then return "passthrough" end
    local col = math.max((column or 1) - 1, 0)
    if input_start_line > 0 and line <= input_start_line then
        allow_transcript_cursor = true
        vim.cmd("stopinsert")
        local block = fence_block_at(line)
        if block then
            pcall(vim.api.nvim_win_set_cursor, float_win, { line, 0 })
            copy_block(block)
            return "copied-block"
        end
        pcall(vim.api.nvim_win_set_cursor, float_win, { line, col })
        return "select"
    end
    if input_start_line > 0 and line > input_start_line then
        allow_transcript_cursor = false
        pcall(vim.api.nvim_win_set_cursor, float_win, { line, col })
        vim.cmd("startinsert")
        return "input"
    end
    return "passthrough"
end

function M.copy_visual_selection()
    local mode = vim.fn.mode()
    if not mode:find("[vV\22]") then return false end
    local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
    if not lines or #lines == 0 then return false end
    copy_text(table.concat(lines, "\n"))
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    ui.flash("Copied.", 1500)
    return true
end

-- ── Buffer operations ─────────────────────────────────────────────────
local function show_error(msg)
    if not buf_valid() then return end
    set_buf_modifiable(true)
    local line_count = vim.api.nvim_buf_line_count(warp_buf)
    vim.api.nvim_buf_set_lines(warp_buf, line_count, line_count, false, { "", "Error: " .. msg })
    set_buf_modifiable(false)
    update_title("done")
end

local function resize_float(opts)
    if not win_valid() or not buf_valid() then return end
    opts = opts or {}
    local width = math.floor(vim.o.columns * 0.27)
    local max_height = math.floor(vim.o.lines * 0.9)
    local visual_lines = 0
    local lines = vim.api.nvim_buf_get_lines(warp_buf, 0, -1, false)
    for _, line in ipairs(lines) do
        local display_width = vim.fn.strdisplaywidth(line)
        visual_lines = visual_lines + math.max(1, math.ceil(display_width / width))
    end
    local new_height = math.min(math.max(visual_lines + 2, 4), max_height)
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - new_height) / 2)
    local cfg = vim.api.nvim_win_get_config(float_win)
    if opts.keep_top then
        local current_row = cfg.row
        if type(current_row) == "table" then
            current_row = current_row[false] or current_row[1]
        end
        if type(current_row) == "number" then
            row = math.min(current_row, math.max(0, vim.o.lines - new_height - 1))
        end
        if new_height <= cfg.height then return end
    elseif cfg.height == new_height and cfg.width == width then
        return
    end
    vim.api.nvim_win_set_config(float_win, {
        relative = "editor",
        width = width,
        height = new_height,
        col = col,
        row = row,
    })
end

local function append_stream_text(text)
    if not buf_valid() then return end
    local ignore = vim.o.eventignore
    vim.o.eventignore = "TextChanged,TextChangedI,CursorMoved,CursorMovedI,WinScrolled"
    local ok, err = pcall(function()
        local line_count = vim.api.nvim_buf_line_count(warp_buf)
        local last_line = vim.api.nvim_buf_get_lines(warp_buf, line_count - 1, line_count, false)[1] or ""
        local new_lines = vim.split(text, "\n", { plain = true })
        new_lines[1] = last_line .. new_lines[1]
        vim.api.nvim_buf_set_text(
            warp_buf,
            line_count - 1, 0,
            line_count - 1, #last_line,
            new_lines)
        local new_count = vim.api.nvim_buf_line_count(warp_buf)
        if win_valid() then
            local cursor = vim.api.nvim_win_get_cursor(float_win)
            if cursor[1] ~= new_count then
                pcall(vim.api.nvim_win_set_cursor, float_win, { new_count, 0 })
            end
        end
    end)
    vim.o.eventignore = ignore
    if not ok then
        log("PAINT-ERR " .. tostring(err))
    end
end

local function flush_stream_paint()
    if pending_stream_text == "" then return end
    local text = pending_stream_text
    pending_stream_text = ""
    append_stream_text(text)
    if not win_valid() then return end
    local needed = math.min(
        vim.api.nvim_buf_line_count(warp_buf) + 2,
        math.floor(vim.o.lines * 0.9))
    if needed > vim.api.nvim_win_get_height(float_win) then
        resize_float({ keep_top = true })
    end
end

local function begin_stream_paint()
    if buf_valid() and not stream_undolevels then
        stream_undolevels = vim.bo[warp_buf].undolevels
        vim.bo[warp_buf].undolevels = -1
        vim.bo[warp_buf].modifiable = true
        pcall(vim.treesitter.stop, warp_buf)
    end
    stream_active = true
    stream_first_paint = false
    if stream_paint_timer then return end
    stream_paint_timer = vim.uv.new_timer()
    stream_paint_timer:start(8, 8, function()
        if pending_stream_text == "" or stream_flush_queued then return end
        stream_flush_queued = true
        vim.schedule(function()
            stream_flush_queued = false
            flush_stream_paint()
        end)
    end)
end

local function end_stream_paint()
    stop_stream_timer()
    flush_stream_paint()
    stream_active = false
    stream_first_paint = false
    if buf_valid() then
        if stream_undolevels then
            vim.bo[warp_buf].undolevels = stream_undolevels
            stream_undolevels = nil
        end
        local lines = vim.api.nvim_buf_get_lines(warp_buf, 0, -1, false)
        local divider = 0
        for i, line in ipairs(lines) do
            if line == "───" then divider = i end
        end
        if divider > 0 and divider < #lines then
            tint_response_lines(divider, #lines - 1)
        end
        pcall(vim.treesitter.start, warp_buf, "markdown")
        set_buf_modifiable(false)
    end
end

local function queue_stream_text(text)
    pending_stream_text = pending_stream_text .. text
    if not stream_active then
        begin_stream_paint()
    end
    if stream_first_paint or stream_flush_queued then return end
    stream_first_paint = true
    stream_flush_queued = true
    vim.schedule(function()
        stream_flush_queued = false
        flush_stream_paint()
    end)
end

function M.ensure_input_area()
    if not buf_valid() then return false end
    if #messages == 0 and input_start_line == 0 then return false end
    local lines = vim.api.nvim_buf_get_lines(warp_buf, 0, -1, false)
    local divider = 0
    for i, line in ipairs(lines) do
        if line == "───" then divider = i end
    end
    if divider > 0 and divider >= input_start_line and divider < #lines then
        input_start_line = divider
        return false
    end
    if divider > 0 and divider >= input_start_line and divider == #lines then
        set_buf_modifiable(true)
        vim.api.nvim_buf_set_lines(warp_buf, #lines, #lines, false, { "" })
        input_start_line = divider
        return true
    end
    set_buf_modifiable(true)
    vim.api.nvim_buf_set_lines(warp_buf, #lines, #lines, false, { "───", "" })
    input_start_line = #lines + 1
    return true
end

function M.start_input()
    if not buf_valid() or not win_valid() then return end
    M.ensure_input_area()
    allow_transcript_cursor = false
    local last = vim.api.nvim_buf_line_count(warp_buf)
    pcall(vim.api.nvim_win_set_cursor, float_win, { last, 0 })
    vim.cmd("startinsert!")
end

function M.scroll_view(delta)
    if not win_valid() or not buf_valid() or type(delta) ~= "number" or delta == 0 then
        return false
    end
    if input_start_line == 0 then return false end
    allow_transcript_cursor = true
    if vim.fn.mode():find("^i") then
        vim.cmd("stopinsert")
    end
    local before_line, before_top
    vim.api.nvim_win_call(float_win, function()
        before_line = vim.fn.line(".")
        before_top = vim.fn.line("w0")
        local key = delta < 0 and "gk" or "gj"
        vim.cmd("normal! " .. math.abs(delta) .. key)
        local cur = vim.fn.line(".")
        if cur > input_start_line then
            allow_transcript_cursor = false
            vim.api.nvim_win_set_cursor(0, { input_start_line + 1, 0 })
        end
    end)
    local after_line = vim.api.nvim_win_get_cursor(float_win)[1]
    local after_top = vim.api.nvim_win_call(float_win, function()
        return vim.fn.line("w0")
    end)
    return after_line ~= before_line or after_top ~= before_top
end

local function clamp_cursor_to_input()
    if allow_transcript_cursor then return end
    if not win_valid() or not buf_valid() then return end
    if vim.api.nvim_get_current_win() ~= float_win then return end
    M.ensure_input_area()
    if input_start_line == 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(float_win)
    if cursor[1] <= input_start_line then
        local last = vim.api.nvim_buf_line_count(warp_buf)
        pcall(vim.api.nvim_win_set_cursor, float_win, { last, 0 })
    end
end

function M.pin_input_to_bottom()
    if not win_valid() or not buf_valid() then return false end
    local height = vim.api.nvim_win_get_height(float_win)
    local last = vim.api.nvim_buf_line_count(warp_buf)
    local view = vim.api.nvim_win_call(float_win, function()
        return vim.fn.winsaveview()
    end)
    local new_top = math.max(1, last - height + 1)
    if view.topline == new_top then return false end
    view.topline = new_top
    vim.api.nvim_win_call(float_win, function()
        vim.fn.winrestview(view)
    end)
    return true
end

local function open_input_area()
    if not buf_valid() then return end
    set_buf_modifiable(true)
    local line_count = vim.api.nvim_buf_line_count(warp_buf)
    vim.api.nvim_buf_set_lines(warp_buf, line_count, line_count, false, { "───", "" })

    input_start_line = line_count + 1
    allow_transcript_cursor = false
    if win_valid() then
        local new_count = vim.api.nvim_buf_line_count(warp_buf)
        pcall(vim.api.nvim_win_set_cursor, float_win, { new_count, 0 })
    end
    label_code_blocks()
    resize_float()
    M.pin_input_to_bottom()
    update_title("input")
    vim.cmd("startinsert!")
    vim.schedule(function()
        M.pin_input_to_bottom()
    end)
end

local function error_message_from(parsed)
    if type(parsed) ~= "table" or type(parsed.error) ~= "table" then
        return nil
    end
    return tostring(parsed.error.message or parsed.error.code or "request failed")
end

local function start_stream(mdl, api_messages, opts)
    opts = opts or {}
    local allow_fallback = opts.allow_fallback
    local api_key = opts.api_key
    local claimed_fallback = false

    local function try_fallback(reason)
        if claimed_fallback then return true end
        if not allow_fallback then return false end
        local fb = M.fallback_model()
        if not fb or fb.id == mdl.id then return false end
        claimed_fallback = true
        cancel_job()
        log("FALLBACK  " .. mdl.name .. " -> " .. fb.name .. " (" .. reason .. ")")
        ui.flash("Fallback: " .. fb.name, 1500)
        start_stream(fb, api_messages, {
            allow_fallback = false,
            api_key = api_key,
        })
        return true
    end

    local request = {
        model = mdl.id,
        messages = api_messages,
        stream = true,
    }
    if mdl.reasoning then request.reasoning = mdl.reasoning end
    if mdl.provider then request.provider = mdl.provider end

    local body = vim.json.encode(request)

    log("────────────────────────────────────────")
    log("model:   " .. mdl.id .. " (" .. mdl.name .. ")")
    begin_stream_paint()

    local response_chunks = {}
    local partial_line = ""
    local chunk_count = 0
    local stderr_parts = {}
    local stream_error = nil

    local function note_error(msg)
        if stream_error then return end
        stream_error = msg
        cancel_job()
    end

    local function process_line(line)
        if line:match("^data: %[DONE%]") then
            log("SSE      [DONE]")
            return
        end
        if not line:match("^data: ") then
            if line ~= "" then
                local ok, parsed = pcall(vim.json.decode, line)
                local err = ok and error_message_from(parsed)
                if err then
                    log("SSE-ERR  " .. err)
                    note_error(err)
                else
                    log("SSE-skip " .. line:sub(1, 80))
                end
            end
            return
        end
        chunk_count = chunk_count + 1
        local json_str = line:sub(7):gsub("%s+$", "")
        local ok, parsed = pcall(vim.json.decode, json_str)
        if not ok or not parsed then
            log("SSE-ERR  parse failed: " .. json_str:sub(1, 120))
            return
        end

        local err = error_message_from(parsed)
        if err then
            log("SSE-ERR  " .. err)
            note_error(err)
            return
        end

        if parsed.usage and parsed.usage.cost then
            local cost = tonumber(parsed.usage.cost) or 0
            log("SSE-cost " .. tostring(cost))
            if cost > 0 then
                session_cost = session_cost + cost
                vim.schedule(function() update_title("done") end)
            end
        end

        if parsed.choices and parsed.choices[1] then
            local delta = parsed.choices[1].delta
            if not delta then
                log("SSE-" .. chunk_count .. "  no delta")
                return
            end
            local ct = type(delta.content) == "string" and delta.content or ""
            local rt = type(delta.reasoning) == "string" and delta.reasoning or ""
            local fr = parsed.choices[1].finish_reason
            if (ct ~= "" or rt ~= "" or fr) and (chunk_count <= 3 or fr) then
                log(string.format("SSE-%-4d content=%d reasoning=%d finish=%s",
                    chunk_count, #ct, #rt, tostring(fr)))
            end
            if type(delta.content) == "string" and delta.content ~= "" then
                table.insert(response_chunks, delta.content)
                queue_stream_text(delta.content)
            end
        end
    end

    local function on_stdout(_, data, _)
        if not data then return end
        data[1] = partial_line .. data[1]
        partial_line = data[#data]
        for i = 1, #data - 1 do
            process_line(data[i])
        end
    end

    local function on_stderr(_, data, _)
        if data then
            for _, line in ipairs(data) do
                if line ~= "" then table.insert(stderr_parts, line) end
            end
        end
    end

    local function on_exit(_, exit_code, _)
        vim.schedule(function()
            if claimed_fallback then return end
            active_job = nil
            local raw_partial = partial_line
            if partial_line ~= "" then
                log("FLUSH    partial_line: " .. partial_line:sub(1, 200))
                process_line(partial_line)
                partial_line = ""
            end
            if claimed_fallback then return end
            if #stderr_parts > 0 then
                log("STDERR   " .. table.concat(stderr_parts, " "):sub(1, 200))
            end
            local full_response = table.concat(response_chunks, "")
            log("────────────────────────────────────────")
            log(string.format("EXIT     code=%d chunks=%d content_len=%d",
                exit_code, chunk_count, #full_response))
            if vim.trim(full_response) ~= "" then
                log("RESULT   ok — " .. full_response:sub(1, 120))
                table.insert(messages, { role = "assistant", content = full_response })
            else
                local err_detail = stream_error
                if exit_code ~= 0 then
                    log("RESULT   curl failed")
                    err_detail = err_detail or ("Request failed (exit code " .. exit_code .. ")")
                else
                    log("RESULT   empty response — no content chunks received")
                end
                if not err_detail and #stderr_parts > 0 then
                    err_detail = table.concat(stderr_parts, " ")
                end
                local ok, parsed = pcall(vim.json.decode, raw_partial)
                if ok then
                    err_detail = err_detail or error_message_from(parsed)
                end
                err_detail = err_detail or "Empty response — try again or switch models (Tab)."
                if try_fallback(err_detail) then
                    flush_log()
                    return
                end
                show_error(err_detail:sub(1, 120))
            end
            end_stream_paint()
            flush_log()
            open_input_area()
        end)
    end

    active_job = vim.fn.jobstart({
        "curl", "-sN", "--compressed",
        "https://openrouter.ai/api/v1/chat/completions",
        "-H", "Authorization: Bearer " .. api_key,
        "-H", "Content-Type: application/json",
        "-H", "Accept: text/event-stream",
        "-d", body,
    }, {
        stdout_buffered = false,
        on_stdout = on_stdout,
        on_stderr = on_stderr,
        on_exit = on_exit,
    })

    if active_job <= 0 then
        active_job = nil
        if not try_fallback("Failed to start curl") then
            show_error("Failed to start curl")
        end
    end
end

function M.submit()
    if active_job then return end
    if not buf_valid() then return end
    M.ensure_input_area()

    M.load_api_key()
    local api_key = vim.env.OPENROUTER_API_KEY
    if not api_key or api_key == "" then
        show_error("OPENROUTER_API_KEY not set. Press m then a to enter a key.")
        return
    end

    local input = get_current_input()
    if vim.trim(input) == "" then
        ui.flash("Nothing to send.", 1500)
        return
    end

    table.insert(messages, { role = "user", content = input })

    local query_end = vim.api.nvim_buf_line_count(warp_buf) - 1
    set_buf_modifiable(true)
    local line_count = vim.api.nvim_buf_line_count(warp_buf)
    vim.api.nvim_buf_set_lines(warp_buf, line_count, line_count, false, { "───", "" })

    local api_messages = {}
    if M.system_prompt and M.system_prompt ~= "" then
        table.insert(api_messages, { role = "system", content = M.system_prompt })
    end
    local ctx_text = M.format_file_context(file_context)
    if ctx_text then
        table.insert(api_messages, { role = "system", content = ctx_text })
    end
    for _, msg in ipairs(messages) do
        table.insert(api_messages, { role = msg.role, content = msg.content })
    end

    start_stream(current_model(), api_messages, {
        allow_fallback = true,
        api_key = api_key,
    })

    dim_query_lines(input_start_line, query_end)
    update_title("waiting")
    log("════════════════════════════════════════")
    log("REQUEST  " .. os.date("%Y-%m-%d %H:%M:%S"))
    log("input:   " .. input:sub(1, 200))
    log("msgs:    " .. #messages .. " in history")
end

function M.cycle_model()
    local n = #M.models
    for _ = 1, n do
        M.active_model = (M.active_model % n) + 1
        local mdl = M.models[M.active_model]
        if mdl and mdl.enabled ~= false then
            break
        end
    end
    update_title(current_phase)
    ui.flash("Model: " .. current_model().name, 1500)
end

function M.api_key_present()
    local key = vim.env.OPENROUTER_API_KEY
    return type(key) == "string" and vim.trim(key) ~= ""
end

function M.default_secrets_path()
    local root = vim.env.PROTOCOL_CONFIG_ROOT
    if type(root) == "string" and root ~= "" then
        return root .. "/shell/" .. "protocol" .. ".secrets.env"
    end
    return vim.fn.stdpath("data") .. "/warp.env"
end

function M.secrets_env_path()
    if type(M.secrets_file) == "string" and M.secrets_file ~= "" then
        return M.secrets_file
    end
    return M.default_secrets_path()
end

function M.load_api_key()
    if M.api_key_present() then return true end
    local path = M.secrets_env_path()
    if vim.fn.filereadable(path) ~= 1 then return false end
    for _, line in ipairs(vim.fn.readfile(path)) do
        local key = line:match("^export%s+OPENROUTER_API_KEY=(.*)$")
            or line:match("^OPENROUTER_API_KEY=(.*)$")
        if key then
            key = vim.trim(key:gsub("^[\"']", ""):gsub("[\"']$", ""))
            if key ~= "" then
                vim.env.OPENROUTER_API_KEY = key
                return true
            end
        end
    end
    return false
end

function M.save_api_key(key)
    key = vim.trim(key or "")
    if key == "" then return false end
    vim.env.OPENROUTER_API_KEY = key
    local path = M.secrets_env_path()
    local lines = {}
    if vim.fn.filereadable(path) == 1 then
        lines = vim.fn.readfile(path)
    end
    local written = "export OPENROUTER_API_KEY=" .. key
    local found = false
    for i, line in ipairs(lines) do
        if line:match("^export%s+OPENROUTER_API_KEY=")
            or line:match("^OPENROUTER_API_KEY=") then
            lines[i] = written
            found = true
        end
    end
    if not found then
        table.insert(lines, written)
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    pcall(vim.fn.setfperm, path, "600")
    return true
end

local function api_key_menu()
    M.load_api_key()
    vim.cmd("redraw")
    if M.api_key_present() then
        vim.api.nvim_echo({
            { " OpenRouter ", "Normal" },
            { " ok ", "WarpInsert" },
            { "key set", "Normal" },
            { "   (e)nter new   Esc cancel", "FloatTitle" },
        }, false, {})
    else
        vim.api.nvim_echo({
            { " OpenRouter ", "Normal" },
            { "no key", "ErrorMsg" },
            { "   (e)nter key   Esc cancel", "FloatTitle" },
        }, false, {})
    end
    local char = ui.read_menu_char():lower()
    if char ~= "e" then
        ui.flash("Cancelled.", 1000)
        return
    end
    local entered = vim.fn.inputsecret("OpenRouter API key: ")
    vim.cmd("redraw")
    if vim.trim(entered) == "" then
        ui.flash("Cancelled.", 1000)
        return
    end
    if M.save_api_key(entered) then
        ui.flash("OpenRouter key saved.", 2000)
    end
end

local function warp_menu()
    vim.schedule(function()
        print("WARP: (c)opy response (e)xplain (a)pi")
        local char = ui.read_menu_char():lower()
        if char == "c" then
            local resp = get_last_response()
            if vim.trim(resp) == "" then
                ui.flash("No response to copy.", 1500)
            else
                copy_text(resp)
                ui.flash("Response copied.", 2000)
            end
        elseif char == "e" then
            if not file_context then
                ui.flash("Open Warp from a file first.", 1500)
                return
            end
            M.fill_input(M.explain_prompt)
            M.submit()
        elseif char == "a" then
            api_key_menu()
        else
            ui.flash("Cancelled.", 1000)
        end
    end)
end

function M.open()
    if win_valid() then
        M.close()
        return
    end

    M.load_api_key()
    file_context = M.collect_file_context(vim.api.nvim_get_current_buf())

    warp_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[warp_buf].filetype = "markdown"
    vim.bo[warp_buf].bufhidden = "wipe"
    current_phase = "input"
    messages = {}
    input_start_line = 0
    session_cost = 0
    code_block_label_ids = {}
    allow_transcript_cursor = false

    pcall(vim.treesitter.start, warp_buf, "markdown")

    local width = math.floor(vim.o.columns * 0.27)
    local height = 4
    float_win = vim.api.nvim_open_win(warp_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        border = "rounded",
        title = float_title("input", "i"),
        title_pos = "center",
    })
    vim.wo[float_win].linebreak = true
    vim.wo[float_win].wrap = true
    vim.wo[float_win].conceallevel = 2
    vim.wo[float_win].scrolloff = 0
    pcall(vim.uv.getaddrinfo, "openrouter.ai", "443", {}, function() end)

    local opts = { buffer = warp_buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", M.submit, opts)
    vim.keymap.set("i", "<CR>", function()
        vim.cmd("stopinsert")
        M.submit()
    end, opts)
    vim.keymap.set("n", "<Esc>", M.close, opts)
    vim.keymap.set("n", "m", warp_menu, opts)
    vim.keymap.set("n", "<Tab>", M.cycle_model, opts)
    vim.keymap.set("n", "s", M.cycle_model, opts)
    for _, key in ipairs({ "i", "a", "I", "A", "o", "O" }) do
        vim.keymap.set("n", key, M.start_input, opts)
    end
    vim.keymap.set({ "n", "i" }, "<ScrollWheelUp>", function()
        M.scroll_view(-3)
    end, opts)
    vim.keymap.set({ "n", "i" }, "<ScrollWheelDown>", function()
        M.scroll_view(3)
    end, opts)
    vim.keymap.set("n", "b", copy_code_block, opts)
    for i = 1, 9 do
        vim.keymap.set("n", tostring(i), function()
            M.copy_block_index(i)
        end, opts)
    end
    vim.keymap.set("v", "y", M.copy_visual_selection, opts)
    vim.keymap.set("v", "<LeftRelease>", M.copy_visual_selection, opts)
    vim.keymap.set({ "n", "i" }, "<LeftMouse>", function()
        local pos = vim.fn.getmousepos()
        local result = "passthrough"
        if win_valid() and pos.winid == float_win then
            result = M.handle_left_mouse_at(pos.line, pos.column)
        end
        if result == "copied-block" then return end
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true),
            "n", false)
    end, opts)

    vim.api.nvim_create_autocmd("InsertEnter", {
        group = augroup,
        buffer = warp_buf,
        callback = function()
            allow_transcript_cursor = false
            clamp_cursor_to_input()
        end,
    })
    vim.api.nvim_create_autocmd("CursorMovedI", {
        group = augroup,
        buffer = warp_buf,
        callback = clamp_cursor_to_input,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        buffer = warp_buf,
        once = true,
        callback = function()
            cancel_job()
            float_win = nil
            warp_buf = nil
            messages = {}
            input_start_line = 0
            session_cost = 0
            code_block_label_ids = {}
            allow_transcript_cursor = false
            file_context = nil
        end,
    })

    if file_context then
        ui.flash("Context: " .. file_context.display, 1500)
    end
    vim.cmd("startinsert")
end

local function apply_keys(keys)
    for _, lhs in ipairs(mapped_keys) do
        pcall(vim.keymap.del, "n", lhs)
    end
    mapped_keys = {}
    if type(keys) ~= "table" then
        return
    end
    for _, lhs in ipairs(keys) do
        vim.keymap.set("n", lhs, function()
            M.open()
        end, { silent = true, desc = "Warp LLM query" })
        table.insert(mapped_keys, lhs)
    end
end

function M.setup(opts)
    opts = opts or {}

    if opts.models ~= nil then
        M.models = opts.models
    else
        M.models = vim.deepcopy(DEFAULT_MODELS)
    end

    if opts.system_prompt ~= nil then
        M.system_prompt = opts.system_prompt
    else
        M.system_prompt = DEFAULT_SYSTEM_PROMPT
    end

    if opts.max_context_lines ~= nil then
        M.max_context_lines = opts.max_context_lines
    else
        M.max_context_lines = 500
    end

    if opts.max_context_bytes ~= nil then
        M.max_context_bytes = opts.max_context_bytes
    else
        M.max_context_bytes = 65536
    end

    if type(opts.secrets_file) == "string" and opts.secrets_file ~= "" then
        M.secrets_file = opts.secrets_file
    else
        M.secrets_file = nil
    end

    M.active_model = 2
    if M.models[M.active_model] == nil then
        M.active_model = 1
    end

    local keys = DEFAULT_KEYS
    if opts.keys ~= nil then
        keys = opts.keys
    end
    apply_keys(keys)

    require("warp.highlights").setup()
    return M
end

return M
