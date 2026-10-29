# printlog.nvim

Insert a print/log line prefixed with "folder/file.c:24 function_name: ",
tagged with a trailing "@print" comment so it's easy to delete later.

## install

```
{ 'ailrk/printlog.nvim',
  config = function()
    require('printlog').setup()
  end
}
```
## Keys

```
<leader>lo   insert log line below
<leader>lO   insert log line above
<leader>ld   delete all @print lines in the buffer (:PrintLogClean)
```

## Config

See more from `lua/printlog.lua`
