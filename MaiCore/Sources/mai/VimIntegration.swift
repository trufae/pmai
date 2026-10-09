import Foundation
import MaiCore

/// The script is compiled into pmai so installing a standalone release needs no checkout or resources.
enum VimIntegration {
  enum Action: String {
    case install, update, uninstall
  }

  static func run(_ action: Action, directory: String?, environment: [String: String]) throws {
    let home =
      environment["HOME"] ?? environment["USERPROFILE"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    #if os(Windows)
      let defaultDirectory = home + "/vimfiles"
    #else
      let defaultDirectory = home + "/.vim"
    #endif
    let root = URL(
      fileURLWithPath: AgentHome.expandUserPath(
        directory ?? defaultDirectory, environment: environment,
        fallback: URL(fileURLWithPath: home, isDirectory: true)), isDirectory: true
    )
    .appendingPathComponent("pack/pmai/start/pmai", isDirectory: true)
    let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
    let plugin = pluginDirectory.appendingPathComponent("pmai.vim")
    let prompts = root.appendingPathComponent("prompts.txt")
    let files = FileManager.default
    if action == .uninstall {
      if files.fileExists(atPath: plugin.path) { try files.removeItem(at: plugin) }
      for directory in [pluginDirectory, root] {
        if files.fileExists(atPath: directory.path),
          try files.contentsOfDirectory(atPath: directory.path).isEmpty
        {
          try files.removeItem(at: directory)
        }
      }
      print("Uninstalled pmai Vim integration. Existing prompts and other files are preserved.")
      return
    }
    try files.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
    try script.write(to: plugin, atomically: true, encoding: .utf8)
    if !files.fileExists(atPath: prompts.path) {
      try defaultPrompts.write(to: prompts, atomically: true, encoding: .utf8)
    }
    print("\(action == .update ? "Updated" : "Installed") pmai Vim integration: \(plugin.path)")
    print("Restart Vim, then use :Pmai, <leader>m on the current line, or m on a visual selection.")
  }

  private static let defaultPrompts = """
    translate to catalan, output ONLY the translated text
    re-structure this text into a TODO list with markdown checkboxes
    summarize in a sentence
    improve wording
    fix typos, output only the corrected text
    add an emoji at the beginning of each sentence

    """

  // Adapted from ../mai/vim/mai.vim. Keep the Vim source here as the single bundled copy.
  private static let script = #"""
    if exists('g:loaded_pmai')
      finish
    endif
    let g:loaded_pmai = 1
    let s:prompts_file = expand('<sfile>:p:h:h') . '/prompts.txt'

    function! Pmai() range abort
      " 1) Read prompts and let the user select one.
      let l:file = expand(get(g:, 'pmai_prompts_file', s:prompts_file))
      if !filereadable(l:file)
        echoerr 'File not found: ' . l:file
        return
      endif
      let l:lines = readfile(l:file)
      let l:color = get(g:, 'pmai_color', 1)
      if l:color
        echohl Question
      endif
      for i in range(len(l:lines))
        echo printf('%d. %s', i + 1, l:lines[i])
      endfor
      echo 'e. Edit prompts'
      echo 'i. Inline prompt'
      if l:color
        echohl None
      endif
      let l:choice = input('Enter choice (1-' . len(l:lines) . ' or e, i (empty to cancel)): ')
      if l:choice == 'e'
        execute 'edit ' . fnameescape(l:file)
        return
      elseif l:choice == 'i'
        let l:prompt = input('Enter your custom prompt: ')
        if empty(l:prompt)
          return
        endif
      else
        let l:choice = str2nr(l:choice)
        if l:choice < 1 || l:choice > len(l:lines)
          echo 'Cancelled'
          return
        endif
        let l:prompt = l:lines[l:choice - 1]
      endif

      " 2) Send the selected lines as stdin. Use pmai's saved provider/model by default.
      let l:first = a:firstline
      let l:last = a:lastline
      let l:stdin = join(getline(l:first, l:last), "\n")
      let l:args = [get(g:, 'pmai_command', 'pmai'), '--stdin', '--no-markdown', '--no-stream',
            \ '--max-tool-calls', '0', '--max-subagents', '0', '--system',
            \ 'Apply the request to the attached text. Return only the resulting text, without explanations or Markdown fences. Do not use tools or modify files.']
      if !empty(get(g:, 'pmai_provider', ''))
        let l:args += ['--provider', g:pmai_provider]
      endif
      if !empty(get(g:, 'pmai_model', ''))
        let l:args += ['--model', g:pmai_model]
      endif
      let l:args += get(g:, 'pmai_args', [])
      " Prefixing the request keeps prompts such as --help from becoming CLI options.
      let l:args += ['Request: ' . l:prompt]
      let l:errors = tempname()
      try
        let l:cmd = join(map(copy(l:args), 'shellescape(v:val)'), ' ') . ' 2>' . shellescape(l:errors)
        let l:out = systemlist(l:cmd, l:stdin)
        let l:status = v:shell_error
        let l:stderr = filereadable(l:errors) ? readfile(l:errors) : []
      finally
        call delete(l:errors)
      endtry
      if l:status != 0
        echoerr 'pmai failed (' . l:status . '): ' . join(l:stderr + l:out, "\n")
        return
      endif
      call map(l:out, 'substitute(v:val, "\r", "", "g")')
      echo "\n----\n" . join(l:out, "\n") . "\n"

      " 3) Review the output before changing the buffer.
      let l:defaction = get(g:, 'pmai_defaction', 2)
      if l:color
        echohl Question
      endif
      echo 'What do you want to do with the output?'
      echo '  1. Ignore'
      echo '  2. Replace selected text'
      echo '  3. Append below'
      echo '  4. C preprocessor block'
      echo '  5. Show in a separate split'
      echo '  6. Append as comment'
      echo '  7. Append as Python comment'
      if l:color
        echohl None
      endif
      let l:ans = input('Enter choice (1-7, default ' . l:defaction . '): ')
      let l:ans = empty(l:ans) ? l:defaction : str2nr(l:ans)
      if l:ans == 1
        echo 'Ignored.'
        return
      endif
      if empty(l:out)
        echo 'No output to apply.'
        return
      endif
      if l:ans == 5
        botright new
        setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap
        call setline(1, l:out)
        file Pmai\ Output
      elseif l:ans == 2 || l:ans == 4
        let l:replacement = l:ans == 2 ? l:out
              \ : ['#if 0'] + getline(l:first, l:last) + ['#else'] + l:out + ['#endif']
        " Insert first so replacing the entire buffer leaves no extra empty line.
        call append(l:last, l:replacement)
        undojoin
        execute l:first . ',' . l:last . 'delete _'
        echo 'Replaced.'
      elseif l:ans == 3
        call append(l:last, l:out)
        echo 'Appended.'
      elseif l:ans == 6
        let l:commented = map(copy(l:out), '"  " . v:val')
        call append(l:last, ['/*'] + l:commented + ['*/'])
        echo 'Appended as comment.'
      elseif l:ans == 7
        let l:commented = map(copy(l:out), '"# " . v:val')
        call append(l:last, l:commented)
        echo 'Appended as Python comment.'
      else
        echo 'Invalid option.'
      endif
    endfunction

    command! -bar -range Pmai <line1>,<line2>call Pmai()
    if !get(g:, 'pmai_no_mappings', 0)
      if empty(maparg('<leader>m', 'n'))
        nnoremap <silent> <leader>m :Pmai<CR>
      endif
      if empty(maparg('m', 'x'))
        xnoremap <silent> m :<C-U>'<,'>Pmai<CR>
      endif
    endif

    """#
}
