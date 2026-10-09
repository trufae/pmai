# Vim integration

Install the integration directly from any pmai release, without a repository
checkout or a download:

```sh
pmai --vim install
pmai --vim update
pmai --vim uninstall
```

The Vim script and initial prompts are embedded in the executable. `update`
installs the version bundled with the running pmai, so run `pmai --update` first
to get the latest release. Repeated installs also refresh the script.

Vim 8 or later loads the package automatically from
`~/.vim/pack/pmai/start/pmai/plugin/pmai.vim` after restarting. Windows uses
`~/vimfiles` instead. For a different Vim runtime directory, add
`--vim-dir /path/to/vim` to any of these commands. Installation does not edit
your vimrc. Updates preserve `prompts.txt`; uninstall removes the plugin while
keeping prompts and any other custom files.

Select text in visual mode and press `m`, or press `<leader>m` in normal mode
to use the current line (`<leader>` is backslash by default). `:Pmai` also uses
the current line, and `:2,5Pmai` uses an explicit range. Selections send whole
lines, including for character and block selections. Existing mappings are
preserved.

Choose a saved prompt, `i` to enter one, or `e` to edit the prompt list. Vim waits
for pmai to finish, displays its reply, then asks how to apply it:

1. Ignore
2. Replace selected text
3. Append below
4. Wrap the original and reply in a C preprocessor conditional
5. Show in a scratch split
6. Append as a C comment
7. Append as Python comments

Failed commands leave the buffer untouched and show the error. The integration
requests only the transformed text and disables tool calls and subagents.

It uses the `pmai` executable from PATH and your saved pmai provider/model
settings. Optional vimrc settings override them:

```vim
let g:pmai_command = '/path/to/pmai'
let g:pmai_provider = 'local'             " A configured pmai provider ID
let g:pmai_model = 'qwen3:8b'             " Also accepts PROVIDER::MODEL
let g:pmai_args = ['--agent', 'editor']   " Additional pmai CLI arguments
let g:pmai_color = 0
let g:pmai_defaction = 3                 " Default output action (1-7)
```

Edit the package's `prompts.txt` to customize the menu, or set
`g:pmai_prompts_file` to another file. Each line is one prompt.
To provide your own mappings, set `g:pmai_no_mappings = 1` in your vimrc and use:

```vim
nnoremap <leader>m :Pmai<CR>
xnoremap <leader>m :<C-U>'<,'>Pmai<CR>
```

The script is adapted from mai's Vim integration and kept in
`MaiCore/Sources/mai/VimIntegration.swift` so standalone pmai binaries include it.
