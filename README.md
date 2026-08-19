# warp.nvim

warp.nvim is a Neovim floating window that sends a prompt to high TPS provider/model combinations on OpenRouter such as diffusion LLMs running on LMUs and streams the reply in place.

<img width="658" height="480" alt="demo-warp" src="https://github.com/user-attachments/assets/179eee09-2ffd-43c9-96b8-c05b8bf5c7cd" />


## Requirements

- Neovim 0.10 or newer
- `curl` on your `PATH`
- An [OpenRouter](https://openrouter.ai) account

`:TSInstall markdown` is optional and only affects highlighting inside the float.

## Install

Add this block to your lazy.nvim spec, then restart Neovim:

```lua
{
  "latentspacetime/warp.nvim",
  keys = { "<Leader>w" },
  config = function()
    require("warp").setup()
  end,
}
```

`setup()` creates `<Leader>w` and `<Leader>W`. Pass `keys = nil` if you want to map the open command yourself. `:Warp` also opens the float.

## API key

Submit refuses to run until an OpenRouter key is available. Use one of these two paths.

**Inside the float (usual path)**

1. Open a file in Neovim and press `<Leader>w`.
2. Press `m`, then `a`. The status line reports whether a key is already set.
3. Press `e`, paste the key, and press Enter.
4. Warp writes the key to `stdpath("data")/warp.env` with mode 600 and sets `OPENROUTER_API_KEY` for the current session. Later launches load that file on their own.

**From the environment**

Export `OPENROUTER_API_KEY` before starting Neovim. Warp reads that variable first and skips the file when it is already set.

`setup({ secrets_file = "/path/to/file" })` changes where Warp reads and writes the key. Leave it unset to use `stdpath("data")/warp.env`.

## Keys

Every mapping the float installs:

| Key | Where | Action |
| --- | --- | --- |
| `<Leader>w` / `<Leader>W` | normal | Open or close |
| `:Warp` | command | Open |
| `Enter` | insert or normal | Submit |
| `Tab` or `s` | normal | Cycle RAPID to ADVANCED |
| Scroll wheel | insert or normal | Browse the transcript. The cursor moves with the view. |
| `i` `a` `I` `A` `o` `O` | normal | Jump to a restored input box at the bottom |
| `m` | normal | `(c)opy response`, `(e)xplain` file, `(a)pi` |
| `m` then `c` | after a reply | Copy the last response |
| `m` then `e` | after opening from a file | Fill `What does this file do in a nutshell?` and submit |
| `m` then `a`, then `e` | normal | Enter or replace the OpenRouter key |
| `b` or `1`-`9` | normal, after a reply | Copy fenced block N |
| click `[copy N]` | after a reply | Copy that block |
| drag-select, release | after a reply | Copy the highlighted text |
| `y` | visual | Copy the highlighted text |
| `Esc` | any | Close and cancel curl |
| `:WarpLog` | command | Open `stdpath("data")/warp.log` |

Insert-mode Tab stays a real tab. `m` then any other character cancels the menu.

## Models

`Tab` and `s` walk the enabled rows and skip Mercury.

| Chip | OpenRouter id | In Tab cycle | Notes |
| --- | --- | --- | --- |
| RAPID | `openai/gpt-oss-120b` | yes, default | `provider.only = { "cerebras/fp16" }`, `allow_fallbacks = false` |
| ADVANCED | `openai/gpt-5.6-luna` | yes | `reasoning.effort = "medium"` |
| MERCURY | `inception/mercury-2` | no (`enabled = false`) | Left in the table. A thrown RAPID or ADVANCED request retries once on Mercury. |

Override the table with `setup({ models = ... })`. The default system prompt can be replaced with `setup({ system_prompt = "..." })`.

## File context

Opening Warp from a named file buffer (`buftype` empty, a non-empty path, no NUL bytes) snapshots that buffer, capped at 500 lines and 64 KiB. The filename appears as a title chip. Submit adds a second system message with path, filetype, and a fenced copy of the text. Opening from a terminal or scratch buffer attaches nothing. Change the caps with `setup({ max_context_lines = 500, max_context_bytes = 65536 })`.

## Limitations

- OpenRouter only in v1. Other providers are a later `setup` option.
- Requires Neovim 0.10 and `curl`.
- Streaming is a curl job, not the OpenAI Lua SDK.
- Default models, the Cerebras fp16 pin, and prices change when OpenRouter changes them.
- File context is the buffer at open time, capped, and only from a named file.
- This is not the Warp terminal.
