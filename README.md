# sort-java-fields.nvim

A small Neovim plugin that sorts Java member fields alphabetically using Treesitter.

## What it does

- Walks the syntax tree and finds every class / interface / enum / record / annotation body in the buffer.
- Within each body, finds contiguous runs of `field_declaration` nodes (≥ 2 fields) and sorts them.
- `static` fields sort to the top of each block (alphabetically), then non-static fields (alphabetically). A blank line is inserted at the boundary. (Both behaviors are configurable.)
- Leading line comments and block comments / Javadoc travel with their field.
- Does **not** reorder across non-field declarations (e.g. methods between two field blocks). Each block is sorted independently.

Cursor position is irrelevant — every field block in the file is sorted in one pass.

## Requirements

- Neovim 0.10+
- The `tree-sitter-java` parser (e.g. via [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter): `:TSInstall java`)

## Installation

### lazy.nvim

```lua
{
  "wunsmat/sort-java-fields.nvim",
  ft = "java",
  cmd = "SortJavaFields",
  opts = {}, -- pass any options here, or omit to use defaults
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/wunsmat/sort-java-fields.nvim" })
```

### packer.nvim

```lua
use({ "wunsmat/sort-java-fields.nvim" })
```

## Usage

Run the command from any Java buffer:

```
:SortJavaFields
```

### Suggested keymap

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "java",
  callback = function(event)
    vim.keymap.set("n", "<leader>js", "<cmd>SortJavaFields<cr>", {
      buffer = event.buf,
      desc = "Sort Java fields",
    })
  end,
})
```

## Configuration

`setup()` is optional — defaults are applied automatically. Call it only if you want to override.

```lua
require("sort-java-fields").setup({
  group_by = { "static" },   -- partition keys, applied in order. See below.
  group_separator = "",      -- string inserted between groups (split on \n).
                             -- "" → one blank line. false → no separator.
                             -- "// --- instance ---" → custom marker.
  ignore_case = true,        -- case-insensitive alphabetical sort
  format_on_save = false,    -- run :SortJavaFields on BufWritePre for *.java
})
```

### Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `group_by` | `string[]` | `{ "static" }` | Partition keys applied in order. Available: `"static"` (statics first), `"final"` (finals first), `"visibility"` (public → protected → package → private). Use `{}` to disable grouping and sort everything alphabetically. |
| `group_separator` | `string \| false` | `""` | Inserted between groups. The string is split on `\n`, so `""` produces one blank line. Pass `false` to omit. Has no effect when `group_by = {}`. |
| `ignore_case` | `boolean` | `true` | When `true`, the sort is case-insensitive (`apple < Banana < cherry`). When `false`, ASCII order applies (uppercase before lowercase). |
| `format_on_save` | `boolean` | `false` | When `true`, `setup()` registers a `BufWritePre` autocmd that runs `:SortJavaFields` on save for any `*.java` buffer. |

### `group_by` examples

| Value | Effect |
| --- | --- |
| `{ "static" }` | Statics grouped above instance fields (default). |
| `{ "static", "final" }` | Static-final → static-mutable → instance-final → instance-mutable. |
| `{ "visibility" }` | `public` → `protected` → package-private → `private`. |
| `{ "static", "visibility" }` | Statics first, then by visibility within each tier. |
| `{}` | No grouping; pure alphabetical. |

## Example

Before:

```java
public class Foo {
    private final ObjectMapper objectMapper;
    private static final String TYPE = "type";
    private final WorkspaceService workspaceService;
    private static final String ID = "id";
}
```

After `:SortJavaFields`:

```java
public class Foo {
    private static final String ID = "id";
    private static final String TYPE = "type";

    private final ObjectMapper objectMapper;
    private final WorkspaceService workspaceService;
}
```

## Limitations

- Multi-variable declarations (`private int x, y, z;`) are sorted by the first variable's name.
- A non-field declaration (a method, nested class, etc.) ends the current run; it does not get reordered.
- Pre-existing blank lines between fields within a run are not preserved — the output is the sorted fields with a single blank line at the static boundary.
