local M = {}

function M.flash(message, duration_ms)
    print(message)
    vim.defer_fn(function()
        vim.cmd("echo ''")
        vim.cmd("redraw")
    end, duration_ms)
end

function M.read_menu_char()
    local ok, char_code = pcall(vim.fn.getchar)
    vim.cmd("redraw")
    if not ok then return "" end
    if type(char_code) == "number" then return vim.fn.nr2char(char_code) end
    if type(char_code) == "string" then return char_code end
    return ""
end

return M
