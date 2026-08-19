local M = {}

function M.setup()
    vim.cmd("highlight WarpTitle ctermbg=17 ctermfg=15 cterm=bold")
    vim.cmd("highlight WarpInsert ctermbg=10 ctermfg=0 cterm=bold")
    vim.cmd("highlight WarpNormal ctermbg=12 ctermfg=0 cterm=bold")
    vim.cmd("highlight WarpModel ctermbg=13 ctermfg=0 cterm=bold")
    vim.cmd("highlight WarpWaiting ctermbg=11 ctermfg=0 cterm=bold")
    vim.cmd("highlight WarpCost ctermbg=8 ctermfg=15 cterm=NONE")
    vim.cmd("highlight WarpResponse ctermbg=236 guibg=#303030")
    vim.cmd("highlight WarpDimmed ctermfg=242 guifg=#6c6c6c")
    vim.cmd("highlight WarpBlockLabel ctermfg=14 guifg=#00d7d7 cterm=bold gui=bold")
end

return M
