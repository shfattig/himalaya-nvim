describe('himalaya.domain.email', function()
  local email
  local compose

  before_each(function()
    package.loaded['himalaya.domain.email'] = nil
    package.loaded['himalaya.domain.email.compose'] = nil
    package.loaded['himalaya.config'] = nil
    package.loaded['himalaya.state.account'] = nil
    package.loaded['himalaya.state.context'] = nil
    require('himalaya.config')._reset()
    email = require('himalaya.domain.email')
    compose = require('himalaya.domain.email.compose')
  end)

  it('exposes all public functions', function()
    assert.is_function(email.list)
    assert.is_function(email.list_with)
    assert.is_function(email.read)
    assert.is_function(email.delete)
    assert.is_function(email.copy)
    assert.is_function(email.move)
    assert.is_function(email.select_folder_then_copy)
    assert.is_function(email.select_folder_then_move)
    assert.is_function(email.flag_add)
    assert.is_function(email.flag_remove)
    assert.is_function(email.download_attachments)
    assert.is_function(email.open_browser)
    assert.is_function(email.complete_contact)
    assert.is_function(email.set_list_envelopes_query)
    assert.is_function(email.apply_search_preset)
    assert.is_function(email.resize_listing)
    assert.is_function(email.cleanup)
    assert.is_function(email.jump_to_next_unread)
    assert.is_function(email.jump_to_prev_unread)
    assert.is_function(email.jump_to_next_read)
    assert.is_function(email.jump_to_prev_read)
    assert.is_function(email.toggle_sort)
  end)

  it('exposes compose functions', function()
    assert.is_function(compose.write)
    assert.is_function(compose.reply)
    assert.is_function(compose.reply_all)
    assert.is_function(compose.forward)
    assert.is_function(compose.save_draft)
    assert.is_function(compose.process_draft)
  end)

  describe('get_email_id_from_line', function()
    it('extracts numeric id from a listing line', function()
      assert.are.equal(
        '123',
        email._get_email_id_from_line(
          ' 123    \xe2\x94\x82 *   \xe2\x94\x82 Subject              \xe2\x94\x82 Sender               \xe2\x94\x82 2024-01-01 00:00:00'
        )
      )
    end)

    it('returns empty for header line', function()
      assert.are.equal(
        '',
        email._get_email_id_from_line(
          ' ID     \xe2\x94\x82 FLGS \xe2\x94\x82 SUBJECT              \xe2\x94\x82 FROM                 \xe2\x94\x82 DATE               '
        )
      )
    end)

    it('returns empty for separator line', function()
      assert.are.equal(
        '',
        email._get_email_id_from_line(
          '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'
        )
      )
    end)
  end)

  describe('build_cli_query', function()
    it('returns filter only when sort is empty', function()
      assert.are.equal('subject hello', email._build_cli_query('subject hello', ''))
    end)

    it('omits order-by for the default sort (date desc)', function()
      -- `envelope list` already returns most-recent-first with no query at
      -- all - some backends (Gmail) accept `list` bare but reject any
      -- query argument, even a no-op "order by date desc".
      assert.are.equal('', email._build_cli_query('', 'date desc'))
    end)

    it('returns order-by for a non-default sort', function()
      assert.are.equal('order by date asc', email._build_cli_query('', 'date asc'))
    end)

    it('combines filter and sort', function()
      assert.are.equal('subject hello order by date asc', email._build_cli_query('subject hello', 'date asc'))
    end)

    it('returns empty when both are empty', function()
      assert.are.equal('', email._build_cli_query('', ''))
    end)
  end)

  describe('mark_envelope_seen', function()
    it('dispatches to thread_listing for thread-listing buffers', function()
      local marked_id
      package.loaded['himalaya.domain.email.thread_listing'] = {
        mark_seen_optimistic = function(id)
          marked_id = id
        end,
      }

      -- Set up current buffer as thread-listing
      vim.api.nvim_buf_set_var(0, 'himalaya_buffer_type', 'thread-listing')
      email._mark_envelope_seen('42')

      assert.are.equal('42', marked_id)
      vim.api.nvim_buf_del_var(0, 'himalaya_buffer_type')
    end)

    it('does not dispatch when no listing buffer exists', function()
      local marked_id
      package.loaded['himalaya.domain.email.thread_listing'] = {
        mark_seen_optimistic = function(id)
          marked_id = id
        end,
      }

      email._mark_envelope_seen('42')
      assert.is_nil(marked_id)
    end)
  end)

  describe('bufwidth', function()
    it('returns a positive number', function()
      local width = email._bufwidth()
      assert.is_true(width > 0)
    end)
  end)

  describe('line_to_complete_item', function()
    it('formats email-only contact', function()
      local result = email._line_to_complete_item('user@example.com')
      assert.are.equal('<user@example.com>', result)
    end)

    it('formats contact with name', function()
      local result = email._line_to_complete_item('user@example.com\tJohn Doe')
      assert.are.equal('"John Doe"<user@example.com>', result)
    end)
  end)

  describe('complete_contact caching', function()
    local system_calls
    local orig_system

    before_each(function()
      system_calls = {}
      local cfg = require('himalaya.config').get()
      cfg.complete_contact_cmd = 'contacts %s'
      orig_system = vim.fn.system
      vim.fn.system = function(cmd)
        table.insert(system_calls, cmd)
        if cmd:find('jo') then
          return 'john@ex.com\tJohn Doe\njoan@ex.com\tJoan Smith\n'
        elseif cmd:find('ma') then
          return 'mary@ex.com\tMary Jones\n'
        end
        return ''
      end
    end)

    after_each(function()
      vim.fn.system = orig_system
    end)

    it('calls external command on first query', function()
      local items = email.complete_contact(0, 'jo')
      assert.are.equal(1, #system_calls)
      assert.are.equal(2, #items)
    end)

    it('filters from cache when query is refined', function()
      email.complete_contact(0, 'jo')
      assert.are.equal(1, #system_calls)
      local items = email.complete_contact(0, 'john')
      assert.are.equal(1, #system_calls)
      assert.are.equal(1, #items)
      assert.is_truthy(items[1]:find('John Doe'))
    end)

    it('calls external command when query is not a refinement', function()
      email.complete_contact(0, 'jo')
      assert.are.equal(1, #system_calls)
      email.complete_contact(0, 'ma')
      assert.are.equal(2, #system_calls)
    end)
  end)
end)

describe('himalaya.domain.email (extended)', function()
  local email
  -- captured_json is the most recent request.json() call - fine for tests
  -- that only check request shape (cmd/args/is_stale), since M.list_with's
  -- do_fetch now fires one request.json() call per listing row rather than
  -- one per page (see the progressive-fetch rewrite). Tests that need to
  -- drive the fetch to completion use captured_json_calls instead, to
  -- resolve every row, not just whichever happened to be captured last.
  local captured_json, captured_json_calls, captured_plain
  local job_kill_count
  local emitted_events

  local function make_listing_buf(ids)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local lines = {}
    for _, id in ipairs(ids) do
      lines[#lines + 1] = string.format(' %d    │ *   │ Subject │ Sender │ 2024-01-01', id)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].himalaya_buffer_type = 'listing'
    vim.b[buf].himalaya_account = 'test-acct'
    vim.b[buf].himalaya_folder = 'INBOX'
    vim.b[buf].himalaya_page = 1
    vim.b[buf].himalaya_page_size = 50
    vim.b[buf].himalaya_query = ''
    vim.bo[buf].buftype = 'nofile'
    return buf
  end

  local tracked_bufs = {}
  local function track(buf)
    tracked_bufs[#tracked_bufs + 1] = buf
    return buf
  end

  before_each(function()
    -- Clear email module (and html_view, which M.read() now calls into) so
    -- both re-capture upvalues from this test's fresh request stub below.
    package.loaded['himalaya.domain.email'] = nil
    package.loaded['himalaya.domain.email.html_view'] = nil
    package.loaded['himalaya.config'] = nil

    captured_json = nil
    captured_json_calls = {}
    captured_plain = nil
    job_kill_count = 0
    emitted_events = {}

    package.loaded['himalaya.events'] = {
      emit = function(event, data)
        table.insert(emitted_events, { event = event, data = data })
      end,
      _reset = function() end,
    }
    package.loaded['himalaya.request'] = {
      json = function(opts)
        captured_json = opts
        captured_json_calls[#captured_json_calls + 1] = opts
        return { kill = function() end }
      end,
      plain = function(opts)
        captured_plain = opts
        return { kill = function() end }
      end,
      _build_cmd = function()
        return { 'true' }
      end,
    }
    package.loaded['himalaya.domain.email.probe'] = {
      reset_if_changed = function() end,
      set_total_from_data = function() end,
      total_pages_str = function()
        return '?'
      end,
      start = function() end,
      cancel = function(cb)
        if cb then
          cb()
        end
      end,
      cancel_sync = function() end,
      restart = function() end,
    }
    package.loaded['himalaya.job'] = {
      kill_and_wait = function()
        job_kill_count = job_kill_count + 1
      end,
    }
    package.loaded['himalaya.domain.email.thread_listing'] = {
      cancel_jobs = function() end,
      list = function() end,
      mark_seen_optimistic = function() end,
      is_busy = function()
        return false
      end,
    }
    package.loaded['himalaya.state.context'] = {
      resolve = function()
        return vim.b.himalaya_account or '', vim.b.himalaya_folder or 'INBOX'
      end,
    }
    package.loaded['himalaya.domain.email.flags'] = nil
    local real_flags = require('himalaya.domain.email.flags')
    package.loaded['himalaya.domain.email.flags'] = {
      complete_list = function()
        return { 'seen', 'flagged', 'answered', 'draft' }
      end,
      flag_name = real_flags.flag_name,
      has = real_flags.has,
      is_unseen = real_flags.is_unseen,
      is_seen = real_flags.is_seen,
      count_unseen = real_flags.count_unseen,
      count_unseen_rows = real_flags.count_unseen_rows,
      debug_flags = real_flags.debug_flags,
    }
    package.loaded['himalaya.domain.folder'] = {
      open_picker = function(cb)
        cb('Archive')
      end,
    }

    require('himalaya.config')._reset()
    require('himalaya.config').get().always_confirm = false
    email = require('himalaya.domain.email')
  end)

  after_each(function()
    for _, b in ipairs(tracked_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    tracked_bufs = {}
    -- Close extra windows (splits from read())
    while #vim.api.nvim_tabpage_list_wins(0) > 1 do
      local wins = vim.api.nvim_tabpage_list_wins(0)
      pcall(vim.api.nvim_win_close, wins[#wins], true)
    end
    vim.wo.winbar = ''
  end)

  describe('context_email_id', function()
    it('returns cursor line id in listing buffer', function()
      track(make_listing_buf({ 42, 43 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.are.equal('42', email.context_email_id())
    end)

    it('returns buffer var in non-listing buffer', function()
      vim.b.himalaya_current_email_id = '99'
      assert.are.equal('99', email.context_email_id())
      vim.b.himalaya_current_email_id = nil
    end)

    it('returns empty when no context', function()
      local buf = track(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal('', email.context_email_id())
    end)
  end)

  describe('is_busy', function()
    it('returns false when no jobs in flight', function()
      assert.is_false(email.is_busy())
    end)
  end)

  describe('cleanup', function()
    it('resets module state without error', function()
      email.cleanup()
      assert.is_false(email.is_busy())
    end)
  end)

  describe('complete_contact findstart=1', function()
    it('returns -3 when no complete_contact_cmd', function()
      local orig = vim.api.nvim_err_writeln
      vim.api.nvim_err_writeln = function() end
      assert.are.equal(-3, email.complete_contact(1, ''))
      vim.api.nvim_err_writeln = orig
    end)

    it('finds start position in To: line', function()
      local cfg = require('himalaya.config').get()
      cfg.complete_contact_cmd = 'echo %s'
      local buf = track(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'To: john' })
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      local result = email.complete_contact(1, '')
      assert.is_true(result >= 3) -- after "To: "
    end)

    it('handles line with spaces after separator', function()
      local cfg = require('himalaya.config').get()
      cfg.complete_contact_cmd = 'echo %s'
      local buf = track(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'To: a@b.com,  user' })
      vim.api.nvim_win_set_cursor(0, { 1, 19 })
      local result = email.complete_contact(1, '')
      assert.is_true(result >= 0)
    end)
  end)

  describe('list', function()
    it('switches account and resets state', function()
      local buf = track(make_listing_buf({ 1 }))
      email.list('new-acct')
      assert.are.equal('new-acct', vim.b[buf].himalaya_account)
      assert.are.equal('INBOX', vim.b[buf].himalaya_folder)
      assert.are.equal(1, vim.b[buf].himalaya_page)
      assert.is_not_nil(captured_json)
    end)

    it('preserves existing state without account arg', function()
      local buf = track(make_listing_buf({ 1 }))
      vim.b[buf].himalaya_page = 3
      email.list()
      assert.is_not_nil(captured_json)
    end)

    it('falls back to default account on empty resolve', function()
      package.loaded['himalaya.state.context'] = {
        resolve = function()
          return '', 'INBOX'
        end,
      }
      -- Re-require to pick up new stub
      package.loaded['himalaya.domain.email'] = nil
      email = require('himalaya.domain.email')
      track(make_listing_buf({ 1 }))
      email.list()
      assert.is_not_nil(captured_json)
    end)

    it('sets restore_email_id from opts', function()
      track(make_listing_buf({ 1, 2 }))
      email.list(nil, { restore_email_id = '2' })
      assert.is_not_nil(captured_json)
    end)
  end)

  describe('list_with', function()
    it('issues json request', function()
      track(make_listing_buf({ 1 }))
      email.list_with('acct', 'INBOX', 1, '')
      assert.is_not_nil(captured_json)
      assert.truthy(captured_json.cmd:find('envelope list'))
    end)

    it('restores the previous winbar if a refresh of an already-open listing fails', function()
      -- make_listing_buf's buffer type makes this the "already showing a
      -- listing" case (single batched call, see do_fetch's not-show_progress
      -- branch) - simulate a real prior header, not a bare "loading..." -
      -- so restoration is actually observable rather than a no-op.
      track(make_listing_buf({ 1 }))
      vim.wo.winbar = 'Himalaya/envelopes [INBOX] [all] [page 1⁄1]'
      email.list_with('acct', 'INBOX', 1, '')
      assert.are.equal(1, #captured_json_calls)
      assert.truthy(vim.wo.winbar:find('loading'))
      captured_json_calls[1].on_error()
      assert.is_falsy(vim.wo.winbar:find('loading'))
      assert.truthy(vim.wo.winbar:find('page 1'))
    end)

    it('stale check returns true after new list_with', function()
      track(make_listing_buf({ 1 }))
      email.list_with('acct', 'INBOX', 1, '')
      local first = captured_json
      email.list_with('acct', 'INBOX', 2, '')
      assert.is_true(first.is_stale())
      assert.is_false(captured_json.is_stale())
    end)
  end)

  describe('list_with progressive fetch', function()
    -- do_fetch() fires one request.json() call per listing row (page-size 1
    -- each) instead of one call for the whole page, so it can paint rows as
    -- they land instead of leaving the listing blank for the whole wait -
    -- but only on first-ever open (no listing buffer exists anywhere yet),
    -- where there's nothing on screen for that to visibly improve. Once a
    -- listing is already showing (paging, folder switch, plain refresh),
    -- one batched call replaces it instead - firing `ps` separate CLI
    -- processes there no longer pays off now that the backend itself pools
    -- connections internally (measured ~14s vs ~1.2s for a 20-row page).
    -- ps in this headless test env is winheight(0)-1 = 21 (well above
    -- MAX_CONCURRENT_ROW_FETCHES = 10), so the first-open assertions below
    -- exercise real queuing/backfill behavior, not just "one request
    -- happened".
    local function make_plain_buf()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      return buf
    end

    it(
      'on first open (no existing listing buffer), paints placeholder rows immediately, capped at MAX_CONCURRENT_ROW_FETCHES',
      function()
        track(make_plain_buf())
        vim.wo.winbar = ''
        email.list_with('acct', 'INBOX', 1, '')
        assert.are.equal(10, #captured_json_calls)
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local found_loading = false
        for _, l in ipairs(lines) do
          if l:find('Loading') then
            found_loading = true
          end
        end
        assert.is_true(found_loading)
      end
    )

    it('fills a row in and launches the next queued one as a slot frees up', function()
      track(make_plain_buf())
      vim.wo.winbar = ''
      email.list_with('acct', 'INBOX', 1, '')
      local launched_before = #captured_json_calls
      assert.are.equal(10, launched_before)

      captured_json_calls[1].on_data({ { id = '100', subject = 'Real subject' } })

      assert.are.equal(launched_before + 1, #captured_json_calls)
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local found_real = false
      for _, l in ipairs(lines) do
        if l:find('Real subject') then
          found_real = true
        end
      end
      assert.is_true(found_real)
    end)

    it('fetches an already-visible listing as one batched call, without repainting it', function()
      -- make_listing_buf already sets himalaya_buffer_type = 'listing', so
      -- this is the "already showing a listing" case, not first-open - one
      -- batched request, not `ps` separate per-row ones.
      track(make_listing_buf({ 1 }))
      local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      email.list_with('acct', 'INBOX', 1, '')
      assert.are.equal(1, #captured_json_calls)
      assert.truthy(captured_json_calls[1].cmd:find('envelope list'))
      -- ...and the buffer is untouched until on_data's on_list_with() call
      -- runs - no placeholder rows painted over the existing content.
      local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.same(before, after)
    end)

    it('_cancel_jobs resets progressive-fetch state so is_busy() clears', function()
      track(make_plain_buf())
      vim.wo.winbar = ''
      email.list_with('acct', 'INBOX', 1, '')
      assert.is_true(email.is_busy())
      email._cancel_jobs()
      assert.is_false(email.is_busy())
    end)
  end)

  describe('toggle_sort', function()
    --- Helper: open toggle_sort float, press a key, clean up any leftover float.
    local function sort_press(key)
      email.toggle_sort()
      -- The float is now open and focused; simulate the keypress.
      vim.api.nvim_feedkeys(key, 'x', false)
    end

    after_each(function()
      -- Clean up any leftover floating windows.
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local cfg = vim.api.nvim_win_get_config(winid)
        if cfg.relative and cfg.relative ~= '' then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end)

    it('applies selected sort and refreshes', function()
      -- 'from asc' is choice 4 (date desc=1, date asc=2, from desc=3, from asc=4)
      local buf = track(make_listing_buf({ 1 }))
      vim.b[buf].himalaya_page = 3
      sort_press('4')
      assert.are.equal('from asc', vim.b[buf].himalaya_sort)
      assert.are.equal(1, vim.b[buf].himalaya_page)
      assert.is_not_nil(captured_json)
    end)

    it('does nothing when user cancels picker', function()
      local buf = track(make_listing_buf({ 1 }))
      vim.b[buf].himalaya_sort = 'date desc'
      vim.b[buf].himalaya_page = 3
      sort_press('q')
      assert.are.equal('date desc', vim.b[buf].himalaya_sort)
      assert.are.equal(3, vim.b[buf].himalaya_page)
    end)

    it('delegates to thread_listing.list for thread-listing buffers', function()
      local thread_list_called = false
      package.loaded['himalaya.domain.email.thread_listing'].list = function()
        thread_list_called = true
      end
      -- 'subject desc' is choice 5
      local buf = track(make_listing_buf({ 1 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      sort_press('5')
      assert.is_true(thread_list_called)
      assert.are.equal('subject desc', vim.b[buf].himalaya_sort)
    end)

    it('selects via Enter on cursor line', function()
      local buf = track(make_listing_buf({ 1 }))
      email.toggle_sort()
      -- Move cursor to line 3 ('from desc') and press Enter
      local float_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(float_win, { 3, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
      assert.are.equal('from desc', vim.b[buf].himalaya_sort)
    end)
  end)

  describe('list_with sort integration', function()
    it('includes order by in CLI query for a non-default sort, via envelope search', function()
      track(make_listing_buf({ 1 }))
      email.list_with('acct', 'INBOX', 1, 'subject hello', 'date asc')
      assert.is_not_nil(captured_json)
      -- The last arg should contain the full CLI query
      local args = captured_json.args
      local cli_qry = args[#args]
      assert.truthy(cli_qry:find('order by date asc'))
      assert.truthy(cli_qry:find('subject hello'))
      assert.truthy(captured_json.cmd:find('^envelope search'))
    end)

    it('omits order by for the default sort (date desc), via plain envelope list', function()
      -- 'date desc' is envelope list's own native order - some backends
      -- (Gmail) accept `list` bare but reject any query, even a no-op
      -- "order by date desc", so the default sort must produce no query
      -- at all rather than switching to `envelope search`.
      track(make_listing_buf({ 1 }))
      email.list_with('acct', 'INBOX', 1, '')
      assert.is_not_nil(captured_json)
      local args = captured_json.args
      local cli_qry = args[#args]
      assert.are.equal('', cli_qry)
      assert.truthy(captured_json.cmd:find('^envelope list'))
    end)
  end)

  describe('_cancel_jobs', function()
    it('kills every in-flight per-row fetch job', function()
      track(make_listing_buf({ 1 }))
      email.list_with('acct', 'INBOX', 1, '')
      local jobs_launched = #captured_json_calls
      assert.is_true(jobs_launched > 0)
      job_kill_count = 0
      email._cancel_jobs()
      assert.are.equal(jobs_launched, job_kill_count)
    end)
  end)

  describe('delete', function()
    -- himalaya v2 has no `message delete` - deleting moves to the
    -- configured trash mailbox instead (see M.delete / config.trash_mailbox).
    it('sends a move-to-trash command for cursor line', function()
      track(make_listing_buf({ 42, 43 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message move'))
      assert.are.equal('trash', captured_plain.args[3])
    end)

    it('sends a move-to-trash command for visual range', function()
      track(make_listing_buf({ 10, 20, 30 }))
      email.delete(1, 3)
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message move'))
      assert.are.equal('trash', captured_plain.args[3])
    end)

    it('prompts for confirmation when always_confirm=true', function()
      local cfg = require('himalaya.config').get()
      cfg.always_confirm = true
      local orig = vim.fn.inputdialog
      vim.fn.inputdialog = function()
        return 'y'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      vim.fn.inputdialog = orig
      assert.is_not_nil(captured_plain)
    end)

    it('cancels on confirmation rejection', function()
      local cfg = require('himalaya.config').get()
      cfg.always_confirm = true
      local orig = vim.fn.inputdialog
      vim.fn.inputdialog = function()
        return 'n'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      vim.fn.inputdialog = orig
      assert.is_nil(captured_plain)
    end)

    it('cancels on escape (inputdialog returns _cancel_)', function()
      local cfg = require('himalaya.config').get()
      cfg.always_confirm = true
      local orig = vim.fn.inputdialog
      vim.fn.inputdialog = function()
        return '_cancel_'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      vim.fn.inputdialog = orig
      assert.is_nil(captured_plain)
    end)

    it('on_data refreshes listing', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      captured_plain.on_data()
      -- refresh_listing calls list_with which sets captured_json
      assert.is_not_nil(captured_json)
    end)

    it('on_data emits EmailDeleted event', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailDeleted' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          found = true
        end
      end
      assert.is_true(found)
    end)

    it('on_data notifies once the move actually lands', function()
      track(make_listing_buf({ 42, 43 }))
      email.delete(1, 2)
      local notified
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      captured_plain.on_data()
      vim.notify = orig_notify
      assert.is_not_nil(notified)
      assert.is_truthy(notified.msg:find('2'))
      assert.is_truthy(notified.msg:find('emails'))
      assert.are.equal(vim.log.levels.INFO, notified.level)
    end)

    it('optimistically closes the reading pane, before the request resolves', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))

      -- gD from the reading pane itself: current window is the reading split.
      email.delete()
      assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
      -- Closed synchronously, before the move-to-trash request even resolves.
      assert.is_not_nil(captured_plain)
    end)

    describe('optimistic removal (himalaya_envelopes present)', function()
      local function make_listing_buf_with_envelopes(ids)
        local buf = make_listing_buf(ids)
        local envelopes = {}
        for _, id in ipairs(ids) do
          envelopes[#envelopes + 1] = { id = id, subject = 'Subject ' .. id }
        end
        vim.b[buf].himalaya_envelopes = envelopes
        return buf
      end

      it('removes the row from the buffer immediately, before the request completes', function()
        local buf = track(make_listing_buf_with_envelopes({ 42, 43 }))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        email.delete()
        -- Row is gone right away — no on_data call needed yet.
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(1, #lines)
        assert.is_nil(lines[1]:find('42'))
        assert.are.equal(1, #vim.b[buf].himalaya_envelopes)
        assert.are.equal(43, vim.b[buf].himalaya_envelopes[1].id)
      end)

      it('does not trigger a full refresh_listing on success', function()
        track(make_listing_buf_with_envelopes({ 42 }))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        email.delete()
        captured_plain.on_data()
        -- refresh_listing would call list_with -> json request; optimistic
        -- removal already reflects the outcome, so no second round-trip.
        assert.is_nil(captured_json)
      end)

      it('restores the row if the move fails', function()
        local buf = track(make_listing_buf_with_envelopes({ 42, 43 }))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        email.delete()
        assert.are.equal(1, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))

        captured_plain.on_error()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(2, #lines)
        assert.are.equal(2, #vim.b[buf].himalaya_envelopes)
      end)

      it('names the subject in the notification for a single delete', function()
        track(make_listing_buf_with_envelopes({ 42, 43 }))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        email.delete()
        local notified
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
          notified = { msg = msg, level = level }
        end
        captured_plain.on_data()
        vim.notify = orig_notify
        assert.are.equal('Deleted email: "Subject 42"', notified.msg)
        assert.are.equal(vim.log.levels.INFO, notified.level)
      end)

      it('lists subjects for a multi-delete, trimming long ones', function()
        local buf = make_listing_buf_with_envelopes({ 42, 43 })
        local envelopes = vim.api.nvim_buf_get_var(buf, 'himalaya_envelopes')
        envelopes[2].subject = string.rep('x', 50)
        vim.api.nvim_buf_set_var(buf, 'himalaya_envelopes', envelopes)
        track(buf)
        email.delete(1, 2)
        local notified
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
          notified = { msg = msg, level = level }
        end
        captured_plain.on_data()
        vim.notify = orig_notify
        assert.are.equal('Deleted 2 emails: "Subject 42", "' .. string.rep('x', 39) .. '…"', notified.msg)
      end)
    end)
  end)

  describe('copy', function()
    it('sends copy command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.copy('Archive')
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message copy'))
    end)

    it('on_data refreshes listing', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.copy('Archive')
      captured_plain.on_data()
      assert.is_not_nil(captured_json)
    end)

    it('on_data emits EmailCopied event', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.copy('Archive')
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailCopied' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          assert.are.equal('Archive', e.data.target_folder)
          found = true
        end
      end
      assert.is_true(found)
    end)

    it('supports visual range', function()
      track(make_listing_buf({ 10, 20 }))
      email.copy('Archive', 1, 2)
      assert.is_not_nil(captured_plain)
    end)
  end)

  describe('move', function()
    it('sends move command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.move('Trash')
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message move'))
    end)

    it('prompts for confirmation when always_confirm=true', function()
      local cfg = require('himalaya.config').get()
      cfg.always_confirm = true
      local orig = vim.fn.inputdialog
      vim.fn.inputdialog = function()
        return 'y'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.move('Trash')
      vim.fn.inputdialog = orig
      assert.is_not_nil(captured_plain)
    end)

    it('cancels on rejection', function()
      local cfg = require('himalaya.config').get()
      cfg.always_confirm = true
      local orig = vim.fn.inputdialog
      vim.fn.inputdialog = function()
        return 'n'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.move('Trash')
      vim.fn.inputdialog = orig
      assert.is_nil(captured_plain)
    end)

    it('on_data refreshes listing', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.move('Trash')
      captured_plain.on_data()
      assert.is_not_nil(captured_json)
    end)

    it('on_data emits EmailMoved event', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.move('Trash')
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailMoved' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          assert.are.equal('Trash', e.data.target_folder)
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)

  describe('select_folder_then_copy', function()
    it('opens picker then copies', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.select_folder_then_copy()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message copy'))
    end)

    it('supports visual range', function()
      track(make_listing_buf({ 10, 20 }))
      email.select_folder_then_copy(1, 2)
      assert.is_not_nil(captured_plain)
    end)
  end)

  describe('select_folder_then_move', function()
    it('opens picker then moves', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.select_folder_then_move()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message move'))
    end)
  end)

  describe('mark_seen', function()
    it('sends flag add Seen command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.mark_seen()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('flag add'))
      assert.truthy(captured_plain.cmd:find('%-%-flag seen'))
    end)

    it('on_data refreshes listing via saved_view', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.mark_seen()
      captured_plain.on_data()
      -- refresh_listing → list_with sets captured_json
      assert.is_not_nil(captured_json)
    end)

    it('on_data emits EmailMarkedSeen event', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.mark_seen()
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailMarkedSeen' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          found = true
        end
      end
      assert.is_true(found)
    end)

    it('supports visual range', function()
      track(make_listing_buf({ 10, 20 }))
      email.mark_seen(1, 2)
      assert.is_not_nil(captured_plain)
    end)
  end)

  describe('mark_unseen', function()
    it('sends flag remove Seen command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.mark_unseen()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('flag remove'))
      assert.truthy(captured_plain.cmd:find('%-%-flag seen'))
    end)

    it('on_data emits EmailMarkedUnseen event', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.mark_unseen()
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailMarkedUnseen' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          found = true
        end
      end
      assert.is_true(found)
    end)

    it('supports visual range', function()
      track(make_listing_buf({ 10, 20, 30 }))
      email.mark_unseen(1, 3)
      assert.is_not_nil(captured_plain)
    end)
  end)

  describe('flag_add', function()
    it('presents flag picker and sends add command', function()
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[2]) -- 'Flagged'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_add()
      vim.ui.select = orig_select
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('flag add'))
    end)

    it('does nothing when user cancels picker', function()
      local orig_select = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb(nil)
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_add()
      vim.ui.select = orig_select
      assert.is_nil(captured_plain)
    end)

    it('on_data emits EmailFlagAdded event', function()
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[2]) -- 'flagged'
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_add()
      vim.ui.select = orig_select
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailFlagAdded' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          assert.are.equal('flagged', e.data.flag)
          found = true
        end
      end
      assert.is_true(found)
    end)

    it('supports visual range', function()
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      track(make_listing_buf({ 10, 20 }))
      email.flag_add(1, 2)
      vim.ui.select = orig_select
      assert.is_not_nil(captured_plain)
    end)
  end)

  describe('flag_remove', function()
    it('uses current flags from envelope cache', function()
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 42, flags = { 'Seen', 'Flagged' } },
      }
      local picker_items
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        picker_items = items
        cb(items[1])
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_remove()
      vim.ui.select = orig_select
      -- get_current_flags() normalizes to lowercase names, matching what
      -- --flag expects to receive back.
      assert.are.same({ 'seen', 'flagged' }, picker_items)
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('flag remove'))
    end)

    it('falls back to complete_list when no flags cached', function()
      track(make_listing_buf({ 42 }))
      local picker_items
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        picker_items = items
        cb(items[1])
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_remove()
      vim.ui.select = orig_select
      -- Falls back to complete_list: Seen, Flagged, Answered, Draft
      assert.are.equal(4, #picker_items)
    end)

    it('does nothing when user cancels', function()
      local orig_select = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb(nil)
      end
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_remove()
      vim.ui.select = orig_select
      assert.is_nil(captured_plain)
    end)

    it('on_data emits EmailFlagRemoved event', function()
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 42, flags = { 'Seen', 'Flagged' } },
      }
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[1]) -- 'seen'
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.flag_remove()
      vim.ui.select = orig_select
      captured_plain.on_data()
      local found = false
      for _, e in ipairs(emitted_events) do
        if e.event == 'EmailFlagRemoved' then
          assert.are.equal('test-acct', e.data.account)
          assert.are.equal('INBOX', e.data.folder)
          assert.are.equal('42', e.data.ids)
          assert.are.equal('seen', e.data.flag)
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)

  describe('download_attachments', function()
    it('sends attachment download command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.download_attachments()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('attachment download'))
    end)

    it('on_data reports no attachments', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.download_attachments()
      local orig = vim.notify
      vim.notify = function() end
      captured_plain.on_data('')
      vim.notify = orig
    end)

    it('on_data reports downloaded files', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.download_attachments()
      local orig = vim.notify
      vim.notify = function() end
      captured_plain.on_data('file1.pdf\nfile2.txt')
      vim.notify = orig
    end)
  end)

  describe('open_browser', function()
    -- himalaya v2 removed `message export` outright (not renamed), so
    -- there's nothing left to shell out to - see the comment on
    -- M.open_browser. This should fail loudly, not send any CLI command.
    it('logs an error instead of sending a CLI command', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notified
      local orig = vim.notify
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      email.open_browser()
      vim.notify = orig
      assert.is_nil(captured_plain)
      assert.is_not_nil(notified)
      assert.are.equal(vim.log.levels.ERROR, notified.level)
    end)
  end)

  describe('read', function()
    it('opens email in split window', function()
      track(make_listing_buf({ 42, 43 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      assert.is_not_nil(captured_plain)
      assert.truthy(captured_plain.cmd:find('message read'))

      -- Simulate on_data
      captured_plain.on_data('Subject: Test\n\nHello world\n')
      -- A new split should exist
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.are.equal('himalaya-email-reading', vim.bo.filetype)
      assert.are.equal('42', vim.b.himalaya_current_email_id)
    end)

    it('trims trailing empty line', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('line1\nline2\n')
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are_not.equal('', lines[#lines])
    end)

    it('also fetches HTML in the background for the preferred-view upgrade', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')
      assert.is_not_nil(captured_json)
      assert.truthy(captured_json.cmd:find('message read'))
      assert.are.equal('42', captured_json.args[3])
    end)

    it('upgrades the initial body to HTML once the HTML fetch resolves', function()
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 0 or orig_executable(bin)
      end

      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('Subject: Test\n\nOriginal plain body')
      assert.is_not_nil(captured_json)
      captured_json.on_data({
        html_body = { 0 },
        parts = { { body = { Html = '<p>Rendered <b>HTML</b> body</p>' } } },
      })
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are.equal('Rendered **HTML** body', lines[#lines])
      assert.is_true(vim.b.himalaya_html_view)

      vim.fn.executable = orig_executable
    end)

    it('leaves the plain body alone when the message has no HTML part', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('Subject: Test\n\nOriginal plain body')
      captured_json.on_data({ html_body = {}, parts = {} })
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are.equal('Original plain body', lines[#lines])
      assert.is_falsy(vim.b.himalaya_html_view)
    end)

    it('clears stale HTML-toggle state when a reused reading buffer shows a new email', function()
      local listing_win = vim.api.nvim_get_current_win()
      track(make_listing_buf({ 42, 43 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_data('Subject: First\n\nFirst body')
      local reading_buf = vim.api.nvim_get_current_buf()
      -- Simulate this buffer having ended up in the HTML-toggled state.
      vim.b[reading_buf].himalaya_html_view = true
      vim.b[reading_buf].himalaya_html_view_orig_body = { 'stale plain body' }

      vim.api.nvim_set_current_win(listing_win)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      email.read()
      captured_plain.on_data('Subject: Second\n\nSecond body')

      assert.is_falsy(vim.b[reading_buf].himalaya_html_view)
      assert.is_nil(vim.b[reading_buf].himalaya_html_view_orig_body)
    end)

    it('reuses existing reading window', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Create an existing email reading window
      local email_buf = vim.api.nvim_create_buf(true, true)
      track(email_buf)
      vim.api.nvim_open_win(email_buf, false, { split = 'below' })
      vim.api.nvim_buf_set_name(email_buf, 'Himalaya/read email [old]')
      local win_count = #vim.api.nvim_tabpage_list_wins(0)

      email.read()
      captured_plain.on_data('New email content')

      -- Should reuse, not create a new split
      assert.are.equal(win_count, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('over threshold uses over direction (right)', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = width,
        over = 'right',
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local listing_col = vim.api.nvim_win_get_position(listing_win)[2]
      local reading_win = vim.api.nvim_get_current_win()
      local reading_col = vim.api.nvim_win_get_position(reading_win)[2]
      assert.is_true(reading_col > listing_col)
    end)

    it('under threshold uses under direction (below)', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = width + 1,
        under = 'below',
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local listing_row = vim.api.nvim_win_get_position(listing_win)[1]
      local reading_win = vim.api.nvim_get_current_win()
      local reading_row = vim.api.nvim_win_get_position(reading_win)[1]
      assert.is_true(reading_row > listing_row)
    end)

    it('always splits right when threshold is 0', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      require('himalaya.config').get().reading_split = {
        threshold = 0,
        over = 'right',
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local listing_col = vim.api.nvim_win_get_position(listing_win)[2]
      local reading_win = vim.api.nvim_get_current_win()
      local reading_col = vim.api.nvim_win_get_position(reading_win)[2]
      assert.is_true(reading_col > listing_col)
    end)

    it('only threshold set uses defaults for everything else', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = width,
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      -- defaults: over = 'right', size = 0.6
      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local listing_col = vim.api.nvim_win_get_position(listing_win)[2]
      local reading_win = vim.api.nvim_get_current_win()
      local reading_col = vim.api.nvim_win_get_position(reading_win)[2]
      assert.is_true(reading_col > listing_col)
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      local expected = math.floor(width * 0.6)
      assert.are.equal(expected, reading_width)
    end)

    it('top-level size applies to string branches', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local orig_width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = 0,
        size = 0.7,
        over = 'right',
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local reading_win = vim.api.nvim_get_current_win()
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      local expected = math.floor(orig_width * 0.7)
      assert.are.equal(expected, reading_width)
    end)

    it('table branch overrides top-level size', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local orig_width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = 0,
        size = 0.5,
        over = { side = 'right', size = 0.7 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local reading_win = vim.api.nvim_get_current_win()
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      local expected = math.floor(orig_width * 0.7)
      assert.are.equal(expected, reading_width)
    end)

    it('absolute size for right split', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      require('himalaya.config').get().reading_split = {
        threshold = 0,
        over = { side = 'right', size = 30 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local reading_win = vim.api.nvim_get_current_win()
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      assert.are.equal(30, reading_width)
    end)

    it('absolute height for below split', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      require('himalaya.config').get().reading_split = {
        threshold = math.huge,
        under = { side = 'below', size = 10 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local reading_win = vim.api.nvim_get_current_win()
      local reading_height = vim.api.nvim_win_get_height(reading_win)
      assert.are.equal(10, reading_height)
    end)

    it('non-default direction: left split', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local orig_width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = 0,
        over = { side = 'left', size = 0.5 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local reading_win = vim.api.nvim_get_current_win()
      local reading_col = vim.api.nvim_win_get_position(reading_win)[2]
      local listing_col = vim.api.nvim_win_get_position(listing_win)[2]
      assert.is_true(reading_col < listing_col)
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      local expected = math.floor(orig_width * 0.5)
      assert.are.equal(expected, reading_width)
    end)

    it('above split', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      require('himalaya.config').get().reading_split = {
        threshold = math.huge,
        under = { side = 'above', size = 0.4 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local reading_win = vim.api.nvim_get_current_win()
      local reading_row = vim.api.nvim_win_get_position(reading_win)[1]
      local listing_row = vim.api.nvim_win_get_position(listing_win)[1]
      assert.is_true(reading_row < listing_row)
    end)

    it('both branches right with different sizes', function()
      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local listing_win = vim.api.nvim_get_current_win()
      local width = vim.api.nvim_win_get_width(listing_win)
      require('himalaya.config').get().reading_split = {
        threshold = width + 1,
        over = { side = 'right', size = 0.6 },
        under = { side = 'right', size = 0.4 },
      }

      email.read()
      captured_plain.on_data('Subject: Test\n\nHello world\n')

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.are.equal(2, #wins)
      local reading_win = vim.api.nvim_get_current_win()
      local reading_col = vim.api.nvim_win_get_position(reading_win)[2]
      local listing_col = vim.api.nvim_win_get_position(listing_win)[2]
      assert.is_true(reading_col > listing_col)
      local reading_width = vim.api.nvim_win_get_width(reading_win)
      local expected = math.floor(width * 0.4)
      assert.are.equal(expected, reading_width)
    end)

    it('on_error calls probe.restart', function()
      local restarted = false
      package.loaded['himalaya.domain.email.probe'].restart = function()
        restarted = true
      end
      package.loaded['himalaya.domain.email'] = nil
      email = require('himalaya.domain.email')

      track(make_listing_buf({ 42 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.read()
      captured_plain.on_error()
      assert.is_true(restarted)
    end)
  end)

  describe('set_list_envelopes_query', function()
    it('opens search and refreshes on callback', function()
      local search_opened = false
      package.loaded['himalaya.ui.search'] = {
        open = function(cb)
          search_opened = true
          cb('subject hello', 'Sent')
        end,
      }
      local buf = track(make_listing_buf({ 1 }))
      email.set_list_envelopes_query()
      assert.is_true(search_opened)
      assert.are.equal('subject hello', vim.b[buf].himalaya_query)
      assert.are.equal('Sent', vim.b[buf].himalaya_folder)
      assert.are.equal(1, vim.b[buf].himalaya_page)
    end)

    it('preserves folder when callback returns empty folder', function()
      package.loaded['himalaya.ui.search'] = {
        open = function(cb)
          cb('test', '')
        end,
      }
      local buf = track(make_listing_buf({ 1 }))
      email.set_list_envelopes_query()
      assert.are.equal('INBOX', vim.b[buf].himalaya_folder)
    end)
  end)

  describe('jump_to_next_unread', function()
    it('moves cursor to first unseen line', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = { 'Seen' }, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = {}, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = { 'Seen' }, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.jump_to_next_unread()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('wraps from end to beginning', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = {}, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = { 'Seen' }, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = { 'Seen' }, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      email.jump_to_next_unread()
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('notifies when all emails are seen', function()
      local buf = track(make_listing_buf({ 10, 20 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = { 'Seen' }, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = { 'Seen' }, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notified = false
      local orig = vim.notify
      vim.notify = function(msg)
        if type(msg) == 'string' and msg:find('No unread') then
          notified = true
        end
      end
      email.jump_to_next_unread()
      vim.notify = orig
      assert.is_true(notified)
    end)

    it('delegates to thread_listing for thread-listing buffers', function()
      local jumped = false
      package.loaded['himalaya.domain.email.thread_listing'].jump_to_next_unread = function()
        jumped = true
      end
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      email.jump_to_next_unread()
      assert.is_true(jumped)
    end)
  end)

  describe('jump_to_prev_unread', function()
    it('moves cursor to previous unseen line', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = { 'Seen' }, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = {}, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = { 'Seen' }, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      email.jump_to_prev_unread()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('wraps from beginning to end', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = { 'Seen' }, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = { 'Seen' }, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = {}, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.jump_to_prev_unread()
      assert.are.equal(3, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('delegates to thread_listing for thread-listing buffers', function()
      local jumped = false
      package.loaded['himalaya.domain.email.thread_listing'].jump_to_prev_unread = function()
        jumped = true
      end
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      email.jump_to_prev_unread()
      assert.is_true(jumped)
    end)
  end)

  describe('jump_to_next_read', function()
    it('moves cursor to next read line', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = {}, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = { 'Seen' }, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = {}, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.jump_to_next_read()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('notifies when no read emails', function()
      local buf = track(make_listing_buf({ 10, 20 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = {}, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = {}, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notified = false
      local orig = vim.notify
      vim.notify = function(msg)
        if type(msg) == 'string' and msg:find('No read') then
          notified = true
        end
      end
      email.jump_to_next_read()
      vim.notify = orig
      assert.is_true(notified)
    end)

    it('delegates to thread_listing for thread-listing buffers', function()
      local jumped = false
      package.loaded['himalaya.domain.email.thread_listing'].jump_to_next_read = function()
        jumped = true
      end
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      email.jump_to_next_read()
      assert.is_true(jumped)
    end)
  end)

  describe('jump_to_prev_read', function()
    it('moves cursor to previous read line', function()
      local buf = track(make_listing_buf({ 10, 20, 30 }))
      vim.b[buf].himalaya_envelopes = {
        { id = 10, flags = {}, subject = 'A', from = { name = 'X' }, date = '2024-01-01' },
        { id = 20, flags = { 'Seen' }, subject = 'B', from = { name = 'Y' }, date = '2024-01-01' },
        { id = 30, flags = {}, subject = 'C', from = { name = 'Z' }, date = '2024-01-01' },
      }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      email.jump_to_prev_read()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('delegates to thread_listing for thread-listing buffers', function()
      local jumped = false
      package.loaded['himalaya.domain.email.thread_listing'].jump_to_prev_read = function()
        jumped = true
      end
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      email.jump_to_prev_read()
      assert.is_true(jumped)
    end)
  end)

  describe('resolve_target_ids from read buffer', function()
    it('returns buffer var when not in listing', function()
      vim.b.himalaya_current_email_id = '77'
      email.delete()
      assert.is_not_nil(captured_plain)
      vim.b.himalaya_current_email_id = nil
    end)
  end)

  describe('refresh_listing thread mode', function()
    it('delegates to thread_listing.list', function()
      local thread_list_called = false
      package.loaded['himalaya.domain.email.thread_listing'].list = function()
        thread_list_called = true
      end
      local buf = track(make_listing_buf({ 42 }))
      vim.b[buf].himalaya_buffer_type = 'thread-listing'
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      email.delete()
      captured_plain.on_data()
      assert.is_true(thread_list_called)
    end)
  end)

  describe('mark_envelope_seen flat listing', function()
    it('returns early when no envelopes var', function()
      track(make_listing_buf({ 42 }))
      -- Don't set himalaya_envelopes — should return early without error
      email._mark_envelope_seen('42')
    end)
  end)

  describe('restore_cursor saved_view path', function()
    it('restores view after mark_seen + refresh', function()
      track(make_listing_buf({ 1, 2, 3 }))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      -- mark_seen sets saved_view before refresh
      email.mark_seen()
      assert.is_not_nil(captured_plain)

      -- Invoke on_data → sets saved_view + calls refresh_listing → list_with
      captured_plain.on_data()
      assert.is_not_nil(captured_json)

      -- Invoke list_with on_data → on_list_with → restore_cursor uses saved_view
      captured_json.on_data({
        { id = 1, subject = 'A', from = { name = 'X' }, date = '2024-01-01', flags = {} },
        { id = 2, subject = 'B', from = { name = 'Y' }, date = '2024-01-01', flags = {} },
        { id = 3, subject = 'C', from = { name = 'Z' }, date = '2024-01-01', flags = {} },
      })
      -- Should not error — saved_view path was exercised
    end)
  end)
end)
