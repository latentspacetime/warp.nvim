vim.api.nvim_create_user_command("Warp", function()
    local warp = require("warp")
    if type(warp.open) ~= "function" then
        print("Warp float is not loaded.")
        return
    end
    warp.open()
end, { desc = "Open Warp" })

vim.api.nvim_create_user_command("WarpLog", function()
    local path = vim.fn.stdpath("data") .. "/warp.log"
    if vim.fn.filereadable(path) == 0 then
        print("No Warp log yet.")
        return
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(path))
    vim.cmd("normal! G")
end, { desc = "Open the Warp diagnostics log" })
