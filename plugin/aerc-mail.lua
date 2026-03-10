-- aerc-mail.lua
--
-- Drop this in ~/.config/nvim/plugin/ and nvim will source it automatically.
-- All behaviour is gated behind a FileType mail autocmd — zero startup cost.
--
-- Provides:
--   1. Spell check (enabled automatically for mail filetype)
--   2. Missing attachment warning on save
--   3. AI-powered email review via :MailReview (requires ANTHROPIC_API_KEY)
--   4. AI rewrite of visual selection via :MailRewrite
--   5. Column width toggle: narrow plaintext (72) vs wide (100)
--   6. Quality-of-life settings for composing email in aerc

-- ─── Configuration ──────────────────────────────────────────────────────────

local config = {
  -- Model options (set AERC_AI_MODEL to override):
  --   claude-haiku-4-5-20251001  — $1/$5 per MTok, fast, great for email review
  --   claude-sonnet-4-6          — $3/$15 per MTok, latest balanced model
  --   claude-opus-4-6            — $5/$25 per MTok, flagship
  model = os.getenv 'AERC_AI_MODEL' or 'claude-haiku-4-5-20251001',
  narrow_width = 72, -- plaintext / terminal mail convention
  wide_width = 100, -- for "normal people" mail
  api_version = '2023-06-01',
}

-- ─── Helpers ────────────────────────────────────────────────────────────────

--- Get the Anthropic API key from the environment.
---@return string|nil
local function get_api_key()
  local key = os.getenv 'ANTHROPIC_API_KEY'
  if not key or key == '' then
    vim.notify('ANTHROPIC_API_KEY not set. Export it in your shell profile.', vim.log.levels.ERROR)
    return nil
  end
  return key
end

--- Get the email body (everything after the first blank-line header separator).
---@return string body
---@return integer body_start_line  1-indexed line where the body begins
local function get_email_body()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local body_start = nil
  for i, line in ipairs(lines) do
    if line == '' then
      body_start = i + 1
      break
    end
  end
  if not body_start then return table.concat(lines, '\n'), 1 end
  local body_lines = {}
  for i = body_start, #lines do
    body_lines[#body_lines + 1] = lines[i]
  end
  return table.concat(body_lines, '\n'), body_start
end

--- Get the full buffer contents (headers + body).
---@return string
local function get_full_email()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return table.concat(lines, '\n')
end

--- Get the current visual selection as a string and its line range.
--- Must be called after leaving visual mode so '< '> marks are set.
---@return string text
---@return integer start_line  1-indexed
---@return integer end_line    1-indexed
local function get_visual_selection()
  local start_pos = vim.fn.getpos "'<"
  local end_pos = vim.fn.getpos "'>"
  local raw = vim.fn.getline(start_pos[2], end_pos[2])

  -- vim.fn.getline can return a single string when start == end;
  -- normalise to a list so table.concat always works.
  ---@type string[]
  local lines
  if type(raw) == 'string' then
    lines = { raw }
  else
    lines = raw
  end

  if #lines == 0 then return '', start_pos[2], end_pos[2] end

  -- Trim to the selected columns.
  if #lines == 1 then
    lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
  else
    lines[1] = lines[1]:sub(start_pos[3])
    lines[#lines] = lines[#lines]:sub(1, end_pos[3])
  end

  return table.concat(lines, '\n'), start_pos[2], end_pos[2]
end

--- Call the Anthropic messages API asynchronously.
--- Writes the request body to a temp file to sidestep shell-escaping issues.
---@param prompt string
---@param max_tokens integer
---@param on_text fun(text: string)  called (in vim.schedule) with the response text
---@param on_error? fun(msg: string) called (in vim.schedule) on failure
local function call_anthropic(prompt, max_tokens, on_text, on_error)
  local api_key = get_api_key()
  if not api_key then return end

  on_error = on_error or function(msg) vim.notify(msg, vim.log.levels.ERROR) end

  -- Escape for JSON string value.
  local escaped = prompt:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')

  local json_body = string.format('{"model":"%s","max_tokens":%d,"messages":[{"role":"user","content":"%s"}]}', config.model, max_tokens, escaped)

  local tmp = vim.fn.tempname()
  local f = io.open(tmp, 'w')
  if not f then
    vim.schedule(function() on_error 'Failed to create temp file for API request.' end)
    return
  end
  f:write(json_body)
  f:close()

  local cmd = string.format(
    'curl -s -X POST https://api.anthropic.com/v1/messages '
      .. '-H "content-type: application/json" '
      .. '-H "x-api-key: %s" '
      .. '-H "anthropic-version: %s" '
      .. '-d @%s',
    api_key,
    config.api_version,
    tmp
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      os.remove(tmp)
      if not data or #data == 0 then
        vim.schedule(function() on_error 'No response from API.' end)
        return
      end

      local response = table.concat(data, '\n')

      -- Use proper JSON decoding instead of regex.
      local ok, decoded = pcall(vim.json.decode, response)
      if not ok or not decoded then
        vim.schedule(function() on_error 'Failed to parse API response.' end)
        return
      end

      -- Check for API-level errors.
      if decoded.error then
        vim.schedule(function() on_error('API error: ' .. (decoded.error.message or vim.inspect(decoded.error))) end)
        return
      end

      -- Extract the text from the first text content block.
      local text = nil
      if decoded.content then
        for _, block in ipairs(decoded.content) do
          if block.type == 'text' then
            text = block.text
            break
          end
        end
      end

      if not text then
        vim.schedule(function() on_error 'No text in API response.' end)
        return
      end

      vim.schedule(function() on_text(text) end)
    end,
    on_stderr = function(_, data)
      if data and #data > 0 and data[1] ~= '' then
        vim.schedule(function()
          local msg = table.concat(data, '\n')
          if msg:match '[Ee]rror' or msg:match '[Ff]ailed' then on_error('curl error: ' .. msg) end
        end)
      end
    end,
  })
end

-- ─── 1. Attachment Warning ──────────────────────────────────────────────────

local attachment_patterns = {
  'attach',
  'attached',
  'attaching',
  'attachment',
  'attachments',
  'enclosed',
  'enclosing',
  'see the file',
  'see the document',
  'i.?ve included',
  'i.?m including',
  'please find',
  'PFA',
}

local function check_attachments()
  local body = get_email_body()
  local lines = vim.split(body:lower(), '\n')

  -- Strip quoted lines before checking.
  local unquoted = {}
  for _, line in ipairs(lines) do
    if not line:match '^%s*>' then unquoted[#unquoted + 1] = line end
  end
  local text = table.concat(unquoted, '\n')

  for _, pattern in ipairs(attachment_patterns) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

local function warn_missing_attachment()
  if check_attachments() then
    local choice = vim.fn.confirm(
      '⚠ Your email mentions attachments.\n' .. 'aerc attachments are added in the review screen (not in nvim).\n' .. 'Continue saving?',
      '&Yes\n&No',
      2
    )
    if choice ~= 1 then return false end
  end
  return true
end

-- ─── 2. AI Email Review ─────────────────────────────────────────────────────

local function ai_review()
  local email_text = get_full_email()
  if email_text:gsub('%s', '') == '' then
    vim.notify('Email is empty.', vim.log.levels.WARN)
    return
  end

  vim.notify('Reviewing email with AI...', vim.log.levels.INFO)

  local prompt = string.format(
    [[Review the following email draft. Provide concise, actionable feedback:

1. **Tone & Clarity**: Is the tone appropriate? Unclear or easily misread sentences?
2. **Grammar & Style**: Errors, awkward phrasing, or wordiness?
3. **Completeness**: Anything missing the recipient would need?
4. **Suggested Edits**: Rewrite any problematic sentences.

Be direct and brief. Only flag real issues. If the email is fine, say so in one line.

---
%s
---]],
    email_text
  )

  call_anthropic(prompt, 1024, function(text)
    -- Close any existing review buffer first.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match '%[Mail Review%]$' then vim.api.nvim_buf_delete(b, { force = true }) end
    end

    -- Show review in a scratch split.
    vim.cmd 'botright new'
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_name(buf, '[Mail Review]')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n'))
    vim.bo[buf].modifiable = false

    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, silent = true })
    vim.notify('Review complete. Press q to close.', vim.log.levels.INFO)
  end)
end

-- ─── 3. AI Rewrite of Visual Selection ──────────────────────────────────────

local function ai_rewrite()
  local selected, start_line, end_line = get_visual_selection()
  if selected == '' then return end

  vim.notify('Rewriting selection...', vim.log.levels.INFO)

  local prompt = string.format(
    'Rewrite the following email text to be clearer, more concise, and professional. '
      .. 'Return ONLY the rewritten text with no explanation or preamble.\n\n%s',
    selected
  )

  call_anthropic(prompt, 512, function(text)
    local new_lines = vim.split(text, '\n')
    vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, new_lines)
    vim.notify('Text rewritten. Undo with u if you prefer the original.', vim.log.levels.INFO)
  end)
end

-- ─── 4. Column Width Toggle ─────────────────────────────────────────────────

-- Tracks the current mode per-buffer: true = narrow (default), false = wide.
local narrow_mode = {}

local function apply_width(buf, narrow)
  local width = narrow and config.narrow_width or config.wide_width
  vim.bo[buf].textwidth = width
  vim.wo.colorcolumn = tostring(width)
  narrow_mode[buf] = narrow
end

local function toggle_width()
  local buf = vim.api.nvim_get_current_buf()
  local currently_narrow = narrow_mode[buf]
  if currently_narrow == nil then currently_narrow = true end
  local new_narrow = not currently_narrow
  apply_width(buf, new_narrow)
  vim.notify(
    string.format('Column width: %s (%d)', new_narrow and 'narrow (plaintext)' or 'wide', new_narrow and config.narrow_width or config.wide_width),
    vim.log.levels.INFO
  )
end

-- ─── Autocmds & Keymaps ────────────────────────────────────────────────────

local group = vim.api.nvim_create_augroup('AercMail', { clear = true })

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'mail',
  callback = function(args)
    local buf = args.buf

    -- ── Spell check ──
    vim.wo.spell = true
    vim.bo.spelllang = 'en_us'

    -- ── Text formatting — default to narrow plaintext style ──
    apply_width(buf, true)
    vim.bo[buf].formatoptions = 'tcqjn'
    vim.wo.wrap = true
    vim.wo.linebreak = true
    vim.wo.conceallevel = 0

    -- ── Attachment warning on save ──
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = group,
      buffer = buf,
      callback = function() return warn_missing_attachment() end,
    })

    -- Clean up tracking when the buffer is wiped.
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = group,
      buffer = buf,
      callback = function() narrow_mode[buf] = nil end,
    })

    -- ── Keymaps (buffer-local) ──

    local opts = { buffer = buf, silent = true }

    vim.keymap.set(
      'n',
      '<leader>mr',
      ai_review,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: AI Review',
      })
    )

    vim.keymap.set(
      'v',
      '<leader>mw',
      function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
        vim.schedule(ai_rewrite)
      end,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: AI Rewrite selection',
      })
    )

    vim.keymap.set(
      'n',
      '<leader>ms',
      function()
        vim.wo.spell = not vim.wo.spell
        vim.notify('Spell check: ' .. (vim.wo.spell and 'ON' or 'OFF'))
      end,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: Toggle spell check',
      })
    )

    vim.keymap.set(
      'n',
      '<leader>ma',
      function()
        if check_attachments() then
          vim.notify('⚠ Email mentions attachments — remember to add them in the aerc review screen!', vim.log.levels.WARN)
        else
          vim.notify('No attachment language detected.', vim.log.levels.INFO)
        end
      end,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: Check attachment mentions',
      })
    )

    vim.keymap.set(
      'n',
      '<leader>mt',
      toggle_width,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: Toggle narrow/wide column width',
      })
    )

    vim.keymap.set(
      'n',
      '<leader>mh',
      function()
        vim.notify(
          table.concat({
            'aerc-mail.lua keymaps:',
            '',
            '  <leader>mr  — AI review full email',
            '  <leader>mw  — AI rewrite selection (visual)',
            '  <leader>ms  — Toggle spell check',
            '  <leader>ma  — Check attachment mentions',
            '  <leader>mt  — Toggle narrow/wide columns',
            '  <leader>mh  — Show this help',
            '',
            'Spell shortcuts (built-in):',
            '  ]s / [s     — Next/prev misspelled word',
            '  z=          — Suggest corrections',
            '  zg          — Add word to dictionary',
            '  zw          — Mark word as wrong',
          }, '\n'),
          vim.log.levels.INFO
        )
      end,
      vim.tbl_extend('force', opts, {
        desc = 'Mail: Show keybindings help',
      })
    )

    vim.notify('aerc mail mode active. <leader>mh for help.', vim.log.levels.INFO)
  end,
})

-- ─── User Commands ──────────────────────────────────────────────────────────

vim.api.nvim_create_user_command('MailReview', ai_review, {
  desc = 'AI review of current email draft',
})

vim.api.nvim_create_user_command('MailRewrite', ai_rewrite, {
  range = true,
  desc = 'AI rewrite of selected text',
})
