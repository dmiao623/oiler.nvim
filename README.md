# oil-tree.nvim

A fork of [oil.nvim](https://github.com/stevearc/oil.nvim) that supports file tree view.

## Requirements

- Neovim 0.8+
- Icon provider plugin (optional)
  - [mini.icons](https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-icons.md) for file and folder icons
  - [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for file icons

## Installation

oil-tree.nvim supports all the usual plugin managers

<details>
  <summary>lazy.nvim</summary>

```lua
{
  'dmiao623/oil-tree.nvim',
  ---@module 'oil-tree'
  ---@type oil-tree.SetupOpts
  opts = {},
  -- Optional dependencies
  dependencies = { { "nvim-mini/mini.icons", opts = {} } },
  -- dependencies = { "nvim-tree/nvim-web-devicons" }, -- use if you prefer nvim-web-devicons
  -- Lazy loading is not recommended because it is very tricky to make it work correctly in all situations.
  lazy = false,
}
```

</details>

<details>
  <summary>Packer</summary>

```lua
require("packer").startup(function()
  use({
    "dmiao623/oil-tree.nvim",
    config = function()
      require("oil-tree").setup()
    end,
  })
end)
```

</details>

<details>
  <summary>Paq</summary>

```lua
require("paq")({
  { "dmiao623/oil-tree.nvim" },
})
```

</details>

<details>
  <summary>vim-plug</summary>

```vim
Plug 'dmiao623/oil-tree.nvim'
```

</details>

<details>
  <summary>dein</summary>

```vim
call dein#add('dmiao623/oil-tree.nvim')
```

</details>

<details>
  <summary>Pathogen</summary>

```sh
git clone --depth=1 https://github.com/dmiao623/oil-tree.nvim.git ~/.vim/bundle/
```

</details>

<details>
  <summary>Neovim native package</summary>

```sh
git clone --depth=1 https://github.com/dmiao623/oil-tree.nvim.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/pack/oil-tree/start/oil-tree.nvim
```

</details>

## Options

```lua
require("oil-tree").setup({
  -- see oil.nvim repository for other config options

  keymaps = {
    -- oil.nvim default keybinds are left unchanged
    ["gT"] = { "actions.toggle_tree_view", mode = "n" },
    ["zo"] = { "actions.tree_open", mode = "n" },
    ["zc"] = { "actions.tree_close", mode = "n" },
    ["zO"] = { "actions.tree_open_all", mode = "n" },
    ["zM"] = { "actions.tree_close_all", mode = "n" },
    ["zr"] = { "actions.tree_set_root", mode = "n" },
    [">>"] = { "actions.tree_indent", mode = "n" },
    ["<<"] = { "actions.tree_unindent", mode = "n" },
  },

  -- Configuration for tree view
  tree = {
    -- Default view mode when opening oil-tree: "flat" or "tree"
    default_view = "flat",
    -- Number of spaces per indentation level in tree view
    indent = 2,
    -- Icons for expand/collapse indicators
    icons = {
      expanded = "▾",
      collapsed = "▸",
    },
    -- Depth to auto-expand when opening tree view (0 = only root)
    auto_expand_depth = 0,
  },
})
```