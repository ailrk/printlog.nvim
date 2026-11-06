# printlog.nvim

Insert a print/log line prefixed with "folder/file.c:24 function_name: ",
tagged with a trailing "@print" comment so it's easy to delete later.

![gif](https://github.com/user-attachments/assets/31773b96-d663-4c0a-9d8b-015edfd08d46)

## install

```
{ 'ailrk/printlog.nvim',
  config = function()
    require('printlog').setup {}
  end
}
```
## Keys

```lua
{
  keymap_below = "<leader>lo",
  keymap_inline = "<leader>li",
  keymap_clean = "<leader>ld",
}
```

## Config

See more from `lua/printlog.lua`.
