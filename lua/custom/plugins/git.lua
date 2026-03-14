-- Git workflow plugins: diffview + fugitive
-- Provides side-by-side diffs, merge conflict resolution, and a full git porcelain

---@module 'lazy'
---@type LazySpec
return {
  -- vim-fugitive: Git porcelain for Neovim
  -- :Git for interactive status, :Git blame for blame, :Git push/pull, etc.
  {
    'tpope/vim-fugitive',
    cmd = { 'Git', 'G', 'Gdiffsplit', 'Gvdiffsplit' },
    keys = {
      { '<leader>gs', '<cmd>Git<cr>', desc = '[G]it [s]tatus' },
      { '<leader>gb', '<cmd>Git blame<cr>', desc = '[G]it [b]lame' },
      { '<leader>gl', '<cmd>Git log --oneline<cr>', desc = '[G]it [l]og' },
      { '<leader>gp', '<cmd>Git push<cr>', desc = '[G]it [p]ush' },
      { '<leader>gP', '<cmd>Git pull<cr>', desc = '[G]it [P]ull' },
      { '<leader>gc', '<cmd>Git commit<cr>', desc = '[G]it [c]ommit' },
    },
  },

  -- diffview.nvim: Tabpage interface for diffs and merge conflicts
  -- :DiffviewOpen for working tree diff, :DiffviewOpen HEAD~2 for range
  -- During merge conflicts: :DiffviewOpen gives a 3-way merge view
  {
    'sindrets/diffview.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory', 'DiffviewToggleFiles' },
    keys = {
      { '<leader>gd', '<cmd>DiffviewOpen<cr>', desc = '[G]it [d]iff view' },
      { '<leader>gD', '<cmd>DiffviewOpen HEAD~1<cr>', desc = '[G]it [D]iff last commit' },
      { '<leader>gf', '<cmd>DiffviewFileHistory %<cr>', desc = '[G]it [f]ile history' },
      { '<leader>gF', '<cmd>DiffviewFileHistory<cr>', desc = '[G]it [F]ile history (all)' },
      { '<leader>gq', '<cmd>DiffviewClose<cr>', desc = '[G]it diff [q]uit' },
      { '<leader>gm', '<cmd>DiffviewOpen<cr>', desc = '[G]it [m]erge conflict view' },
    },
    opts = {
      enhanced_diff_hl = true,
      view = {
        -- Default to side-by-side diff (like VS Code)
        default = { layout = 'diff2_horizontal' },
        merge_tool = {
          -- 3-way merge: LOCAL | BASE | REMOTE on top, MERGED on bottom
          layout = 'diff3_mixed',
          disable_diagnostics = true,
        },
        file_history = { layout = 'diff2_horizontal' },
      },
      file_panel = {
        listing_style = 'tree',
        win_config = { position = 'left', width = 35 },
      },
    },
  },

  -- NOTE: lazygit.nvim can be added here later if you want a full terminal UI
  -- for git. It provides interactive rebase, cherry-pick, stash management,
  -- and line-by-line staging in a single floating window — features that
  -- fugitive and diffview don't cover as conveniently.
  -- Plugin: 'kdheepak/lazygit.nvim'
  -- Suggested keymap: <leader>gg for lazygit toggle
}
