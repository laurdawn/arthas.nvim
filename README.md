# arthas.nvim

Copy common [Arthas](https://arthas.aliyun.com/) commands to the clipboard from a Java file. Nothing is executed locally.

On a class name, a method name, or inside a method body, treesitter supplies the current class and method. On a call, jdtls hover supplies that call's class and method. If hover fails, the current class and method are used. Inner classes use the JVM `$` binary name.

`stop`, `shutdown`, `reset`, `redefine`, and `mc` are omitted.

## Install

[vim.pack](https://neovim.io/doc/user/pack.html) (Neovim 0.12+):

```lua
vim.pack.add({
  { src = "https://github.com/laurdawn/arthas.nvim" },
})
require("arthas").setup()
```

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "laurdawn/arthas.nvim",
  ft = "java",
  config = function()
    require("arthas").setup()
  end,
}
```

Requires the Java treesitter parser. Resolving a call needs jdtls attached to the buffer. which-key labels `<leader>ya` as `arthas`. The keys still work without it.

## Keys

Press `<leader>ya`, then the key below. A second command that shares a first letter uses the uppercase key. When that letter is already taken, the key is another free letter from the command name.

| Key | Command |
| --- | --- |
| `j` | `jad`. Includes the method name when the cursor is on a method |
| `J` | `jvm` |
| `s` | `sc -d` |
| `S` | `sm` |
| `w` | `watch` params, return value, and exception |
| `t` | `trace` |
| `T` | `thread -n 5` |
| `b` | `thread -b` |
| `d` | `dashboard` |
| `m` | `monitor` |
| `M` | `memory` |
| `c` | `classloader -l` |
| `l` | `logger` |
| `o` | `ognl` |
| `h` | `heapdump` |
| `g` | `getstatic` |
| `k` | `stack` |
| `u` | `tt` |
| `p` / `P` | `profiler start` / `profiler stop` |
| `v` | `vmtool` gets one instance of the class |
| `r` | `sysprop` |
| `e` | `sysenv` |

If the method or field name is missing, you are prompted once. The command is copied to the `+` and `"` registers.
