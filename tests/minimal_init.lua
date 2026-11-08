vim.opt.rtp:append(vim.fn.getcwd())
vim.opt.rtp:append(vim.env.PLENARY_PATH or '.deps/plenary.nvim')

-- Parallel test processes may open the same fixture/source buffers.
vim.opt.swapfile = false
