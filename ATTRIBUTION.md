# Attribution

The `:JReview` UI in this plugin was designed after studying the UX of
[codediff.nvim](https://github.com/esmuellert/codediff.nvim) by Yanuo Ma. The
review tab layout (explorer on the left, two side-by-side panes), the use of
filler rows plus native `scrollbind` for alignment, the compact/fold approach
and the character-level highlight scheme are inspired by it.

The implementation here is a small, Jujutsu-native reimplementation driven by
Neovim primitives (`vim.diff`, extmarks, virtual lines, folds, `scrollbind`)
rather than CodeDiff's VS Code C/FFI engine. CodeDiff is distributed under the
MIT license, reproduced below.

For comparison, the modules studied in CodeDiff were:

- `lua/codediff/ui/core.lua` – line/character highlights, filler alignment;
- `lua/codediff/ui/filler.lua` – virtual filler lines;
- `lua/codediff/ui/view/compact.lua` – fold-unchanged-regions;
- `lua/codediff/ui/view/render.lua` – scrollbind anchoring;
- `lua/codediff/ui/explorer/*` – file list and navigation;
- `lua/codediff/ui/layout.lua` and `lua/codediff/ui/lifecycle/*` – window layout
  and session teardown.

---

## codediff.nvim license

MIT License

Copyright (c) 2025 Yanuo Ma

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
