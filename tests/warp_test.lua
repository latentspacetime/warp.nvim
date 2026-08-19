-- Headless contract test for warp.nvim setup, models, key file, and float.
--
-- Run from the repository root:
--   env -u NVIM nvim --headless -u NONE \
--     -c "set rtp+=." \
--     -c "lua vim.g.mapleader = ' '" \
--     -c "lua require('warp').setup()" \
--     -c "luafile tests/warp_test.lua"
-- env -u NVIM matters: inside an embedded nvim terminal the interceptor
-- would route this invocation into the host editor instead.
--
-- Prints one PASS/FAIL line per check; exits non-zero if any check fails.

local results = {}
local function check(name, cond)
    table.insert(results, (cond and "PASS  " or "FAIL  ") .. name)
end
local function finish()
    io.stdout:write(table.concat(results, "\n") .. "\n")
    for _, line in ipairs(results) do
        if line:find("^FAIL") then vim.cmd("cq") end
    end
    vim.cmd("qa!")
end

vim.opt.runtimepath:prepend(".")
package.loaded["warp"] = nil
package.loaded["warp.ui"] = nil
package.loaded["warp.highlights"] = nil
local warp = require("warp")
warp.setup()

local clip_store = { ["+"] = "", ["*"] = "" }
local function clip_copy(reg)
    return function(lines, _)
        clip_store[reg] = table.concat(lines, "\n")
    end
end
local function clip_paste(reg)
    return function()
        return vim.split(clip_store[reg] or "", "\n", { plain = true }), "v"
    end
end
vim.g.clipboard = {
    name = "test",
    copy = {
        ["+"] = clip_copy("+"),
        ["*"] = clip_copy("*"),
    },
    paste = {
        ["+"] = clip_paste("+"),
        ["*"] = clip_paste("*"),
    },
    cache_enabled = 0,
}
vim.g.loaded_clipboard_provider = nil
vim.cmd("runtime autoload/provider/clipboard.vim")

check("Mercury remains defined but disabled",
    warp.models[1] and warp.models[1].name == "MERCURY"
    and warp.models[1].id == "inception/mercury-2"
    and warp.models[1].enabled == false)
check("default model is RAPID gpt-oss-120b",
    warp.models[warp.active_model]
    and warp.models[warp.active_model].name == "RAPID"
    and warp.models[warp.active_model].id == "openai/gpt-oss-120b")
check("RAPID is pinned to Cerebras fp16",
    warp.models[2].provider
    and warp.models[2].provider.only
    and warp.models[2].provider.only[1] == "cerebras/fp16"
    and warp.models[2].provider.allow_fallbacks == false)
check("ADVANCED is Luna",
    warp.models[3] and warp.models[3].name == "ADVANCED"
    and warp.models[3].id == "openai/gpt-5.6-luna")
check("ADVANCED reasoning effort is medium",
    warp.models[3].reasoning and warp.models[3].reasoning.effort == "medium")
check("fallback setting points at MERCURY",
    warp.fallback_model_name == "MERCURY"
    and warp.fallback_model() ~= nil
    and warp.fallback_model().name == "MERCURY"
    and warp.fallback_model().id == "inception/mercury-2")
local previous_fallback = warp.fallback_model_name
warp.fallback_model_name = "ADVANCED"
check("fallback model is a single settable name",
    warp.fallback_model() ~= nil and warp.fallback_model().name == "ADVANCED")
warp.fallback_model_name = "missing"
check("unknown fallback name returns nil", warp.fallback_model() == nil)
warp.fallback_model_name = previous_fallback

local started_at = warp.active_model
warp.cycle_model()
check("cycle moves RAPID to ADVANCED",
    warp.models[warp.active_model].name == "ADVANCED")
warp.cycle_model()
check("cycle wraps ADVANCED to RAPID",
    warp.models[warp.active_model].name == "RAPID")
warp.active_model = started_at

local warp_w = vim.fn.maparg("<Leader>w", "n", false, true)
local warp_W = vim.fn.maparg("<Leader>W", "n", false, true)
check("Space+w opens warp", warp_w.desc == "Warp LLM query")
check("Space+W opens warp", warp_W.desc == "Warp LLM query")

local previous_key = vim.env.OPENROUTER_API_KEY
local previous_secrets = warp.secrets_file
local tmp_secrets = vim.fn.tempname() .. ".secrets.env"
warp.secrets_file = tmp_secrets
vim.env.OPENROUTER_API_KEY = ""
check("empty OPENROUTER_API_KEY is reported missing",
    warp.api_key_present() == false)
check("save_api_key stores the env var",
    warp.save_api_key("sk-test-warp") == true
    and vim.env.OPENROUTER_API_KEY == "sk-test-warp"
    and warp.api_key_present() == true)
local saved_lines = vim.fn.readfile(tmp_secrets)
local saw_export = false
for _, line in ipairs(saved_lines) do
    if line == "export OPENROUTER_API_KEY=sk-test-warp" then
        saw_export = true
    end
end
check("save_api_key writes export line to secrets file", saw_export)
vim.env.OPENROUTER_API_KEY = ""
check("load_api_key reads the secrets file",
    warp.load_api_key() == true
    and vim.env.OPENROUTER_API_KEY == "sk-test-warp")
local previous_root = vim.env.PROTOCOL_CONFIG_ROOT
warp.secrets_file = nil
vim.env.PROTOCOL_CONFIG_ROOT = ""
check("friend default secrets path is stdpath data",
    warp.default_secrets_path() == vim.fn.stdpath("data") .. "/warp.env")
vim.env.PROTOCOL_CONFIG_ROOT = previous_root
vim.env.OPENROUTER_API_KEY = previous_key
warp.secrets_file = previous_secrets
os.remove(tmp_secrets)

local scratch = vim.api.nvim_create_buf(false, true)
check("scratch buffer has no file context",
    warp.collect_file_context(scratch) == nil)
local named = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "-- sample" }, named)
local nbuf = vim.fn.bufadd(named)
vim.fn.bufload(nbuf)
local from_named = warp.collect_file_context(nbuf)
check("named file buffer yields a path",
    from_named ~= nil and type(from_named.path) == "string" and from_named.path ~= "")
check("formatted context includes path and fence",
    type(warp.format_file_context(from_named)) == "string"
    and warp.format_file_context(from_named):find(from_named.path, 1, true) ~= nil)
local tmp = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "one", "two", "three" }, tmp)
local tbuf = vim.fn.bufadd(tmp)
vim.fn.bufload(tbuf)
local prev_cap = warp.max_context_lines
warp.max_context_lines = 1
local cut = warp.collect_file_context(tbuf)
check("context truncates to the line cap",
    cut ~= nil and cut.truncated == true and cut.text == "one")
warp.max_context_lines = prev_cap
vim.api.nvim_buf_delete(tbuf, { force = true })
os.remove(tmp)

check("WarpTitle highlight exists after setup",
    vim.fn.hlexists("WarpTitle") == 1)

local leak_needle = "protocol" .. "-local"
local rg = vim.fn.system({
    "rg", "-l", "--hidden",
    "--glob", "!.git",
    "--glob", "!scripts/check.zsh",
    leak_needle, ".",
})
check("rg " .. leak_needle .. " on the tree is empty",
    vim.trim(rg) == "")

local transcript = {
    "how do I list files?",
    "───",
    "Use this:",
    "```bash",
    "ls -la",
    "echo hi",
    "```",
    "Or lua:",
    "```lua",
    "print(1)",
    "```",
    "───",
    "",
}

local function float_title_text()
    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    local text = ""
    for _, chunk in ipairs(cfg.title or {}) do text = text .. chunk[1] end
    return text
end

local step2

vim.api.nvim_set_current_buf(nbuf)

vim.defer_fn(function()
    check("click before a transcript is a passthrough",
        warp.handle_left_mouse_at(1, 1) == "passthrough")

    warp.open()
    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    check("opens a floating window", cfg.relative == "editor")
    check("buffer-local Tab cycles models",
        vim.fn.maparg("<Tab>", "n", false, true).buffer == 1)
    check("buffer-local s still cycles models",
        vim.fn.maparg("s", "n", false, true).buffer == 1)
    check("insert mode Tab is not remapped",
        vim.fn.maparg("<Tab>", "i", false, true).buffer ~= 1)
    check("title shows RAPID",
        float_title_text():find("RAPID", 1, true) ~= nil)
    check("open from a file attaches context",
        warp.current_file_context() ~= nil
        and warp.current_file_context().display ~= "")
    check("fill_input writes the explain prompt",
        warp.fill_input(warp.explain_prompt) == true
        and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
            == warp.explain_prompt)
    check("buffer-local m menu map exists",
        vim.fn.maparg("m", "n", false, true).buffer == 1)
    check("buffer-local ScrollWheelUp map exists",
        vim.fn.maparg("<ScrollWheelUp>", "n", false, true).buffer == 1
        and vim.fn.maparg("<ScrollWheelUp>", "i", false, true).buffer == 1)
    check("buffer-local b copy map exists",
        vim.fn.maparg("b", "n", false, true).buffer == 1)
    check("buffer-local 1 copy map exists",
        vim.fn.maparg("1", "n", false, true).buffer == 1)
    check("buffer-local visual yank map exists",
        vim.fn.maparg("y", "v", false, true).buffer == 1)
    check("buffer-local mouse map exists",
        vim.fn.maparg("<LeftMouse>", "n", false, true).buffer == 1)

    vim.cmd("stopinsert")
    check("load_transcript accepts a finished turn",
        warp.load_transcript(transcript) == true)

    local blocks = warp.find_code_blocks()
    check("finds both fenced blocks", #blocks == 2)
    check("first block is bash with both lines",
        #blocks == 2 and blocks[1].lang == "bash"
        and blocks[1].content == "ls -la\necho hi")
    check("second block is lua",
        #blocks == 2 and blocks[2].lang == "lua"
        and blocks[2].content == "print(1)")

    local labels = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("warp"), 0, -1, { details = true })
    local saw_copy_label = false
    for _, mark in ipairs(labels) do
        local virt = mark[4] and mark[4].virt_text
        if virt then
            for _, chunk in ipairs(virt) do
                if type(chunk[1]) == "string" and chunk[1]:find("%[copy 1%]", 1) then
                    saw_copy_label = true
                end
            end
        end
    end
    check("labels the first fence with [copy 1]", saw_copy_label)

    vim.fn.setreg("+", "sentinel")
    check("copy_block_index 1 copies bash content",
        warp.copy_block_index(1) == true
        and vim.fn.getreg("+") == "ls -la\necho hi")
    check("copy_block_index 2 copies lua content",
        warp.copy_block_index(2) == true
        and vim.fn.getreg("+") == "print(1)")
    vim.fn.setreg("+", "sentinel")
    check("copy_block_index 9 refuses a missing block",
        warp.copy_block_index(9) == false
        and vim.fn.getreg("+") == "sentinel")

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal! V")
    check("visual selection copies the selected line",
        vim.fn.mode():find("[vV]") ~= nil
        and warp.copy_visual_selection() == true
        and vim.fn.getreg("+") == "Use this:")
    check("transcript title mentions drag copy",
        float_title_text():find("drag copy", 1, true) ~= nil)

    local win = vim.api.nvim_get_current_win()
    local wincfg = vim.api.nvim_win_get_config(win)
    wincfg.height = 5
    vim.api.nvim_win_set_config(win, wincfg)
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(win, { last, 0 })
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zt")
    end)
    warp.pin_input_to_bottom()
    local height = vim.api.nvim_win_get_height(win)
    local expected_top = math.max(1, last - height + 1)
    local top, bot
    vim.api.nvim_win_call(win, function()
        top = vim.fn.line("w0")
        bot = vim.fn.line("w$")
    end)
    check("pin_input_to_bottom keeps the last line on screen",
        last >= top and last <= bot and top == expected_top)
    check("scroll_view reaches the start of the chat",
        warp.scroll_view(-50) == true
        and vim.api.nvim_win_get_cursor(win)[1] == 1
        and vim.fn.line("w0") == 1)

    vim.api.nvim_buf_set_lines(0, 11, -1, false, {})
    check("ensure_input_area restores a missing input box",
        warp.ensure_input_area() == true)
    local restored = vim.api.nvim_buf_get_lines(0, -3, -1, false)
    check("restored tail is a divider plus input line",
        #restored == 2 and restored[1] == "───" and restored[2] == "")

    warp.start_input()
    vim.defer_fn(step2, 50)
end, 700)

step2 = function()
    check("starts insert so the mouse path can leave it",
        vim.api.nvim_get_mode().mode == "i")

    vim.fn.setreg("+", "sentinel")
    local fence_result = warp.handle_left_mouse_at(4, 1)
    check("clicking a fence copies that block",
        fence_result == "copied-block"
        and vim.fn.getreg("+") == "ls -la\necho hi")

    local select_result = warp.handle_left_mouse_at(3, 2)
    check("clicking response text is a selection start",
        select_result == "select")
    local cur = vim.api.nvim_win_get_cursor(0)
    check("response click places the cursor on that line", cur[1] == 3)
    vim.cmd("doautocmd CursorMovedI")
    check("clamp does not snap a transcript click back to input",
        vim.api.nvim_win_get_cursor(0)[1] == 3)

    local input_result = warp.handle_left_mouse_at(13, 1)
    check("clicking the input area restores insert",
        input_result == "input")

    warp.close()
    check("close hides the float",
        vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative == "")

    vim.api.nvim_buf_delete(nbuf, { force = true })
    os.remove(named)
    finish()
end
