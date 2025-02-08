local simple = require("notify_me.simple")

simple.setup({})

vim.api.nvim_create_user_command("GHCheck", function()
  simple.fetch_notifications()
end, {})

vim.keymap.set("n", "gn", function()
  vim.cmd("GHCheck")
end, { noremap = true, silent = true, desc = "Check GitHub notifications" })

return simple
