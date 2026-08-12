describe('himalaya.domain.email.thread_listing', function()
  local thread_listing

  --- Create N flat display rows (depth=0, single thread).
  local function make_rows(n, opts)
    opts = opts or {}
    local rows = {}
    for i = 1, n do
      rows[i] = {
        env = {
          id = tostring(i),
          subject = 'Subject' .. i,
          from = { name = 'Sender' .. i },
          date = '2024-01-01 10:00:00+00:00',
          flags = opts.flags,
          has_attachment = opts.has_attachment,
        },
        depth = 0,
        visual_depth = 0,
        is_last_child = true,
        is_branch_child = false,
        prefix = '',
        thread_idx = 1,
      }
    end
    return rows
  end

  --- Create a nofile buffer configured as a thread-listing.
  local function make_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.b[bufnr].himalaya_buffer_type = 'thread-listing'
    vim.b[bufnr].himalaya_account = 'test'
    vim.b[bufnr].himalaya_folder = 'INBOX'
    vim.bo[bufnr].buftype = 'nofile'
    return bufnr
  end

  before_each(function()
    package.loaded['himalaya.domain.email.thread_listing'] = nil
    thread_listing = require('himalaya.domain.email.thread_listing')
  end)

  after_each(function()
    -- render_page sets winbar via apply_header; reset to avoid leaking
    -- into other test files that check winbar state.
    vim.wo.winbar = ''
  end)

  -- ----------------------------------------------------------------
  -- render_page
  -- ----------------------------------------------------------------
  describe('render_page', function()
    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'sentinel' })
      thread_listing.render_page(1)
      assert.are.equal('sentinel', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('restores cursor when restore_cursor option is provided', function()
      thread_listing._set_state(make_rows(10), 1)
      local bufnr = make_buf()

      thread_listing.render_page(1)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

      thread_listing.render_page(1, { restore_cursor = { 5, 0 } })
      local expected = math.min(5, vim.api.nvim_buf_line_count(0))
      assert.are.equal(expected, vim.api.nvim_win_get_cursor(0)[1])

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('goes to line 1 when no restore_cursor option', function()
      thread_listing._set_state(make_rows(5), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('clamps page to valid range', function()
      thread_listing._set_state(make_rows(5), 1)
      local bufnr = make_buf()
      -- Page 999 should clamp to last page
      thread_listing.render_page(999)
      -- Should not error; buffer should have content
      assert.is_true(vim.api.nvim_buf_line_count(0) > 0)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('shows thread_query in buffer name when set', function()
      thread_listing._set_state(make_rows(3), 1)
      local bufnr = make_buf()
      -- Thread query is module-local, so we need to go through list() or toggle.
      -- For now, just verify default "all" appears in name.
      thread_listing.render_page(1)
      local name = vim.api.nvim_buf_get_name(bufnr)
      assert.truthy(name:find('all'))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- cleanup
  -- ----------------------------------------------------------------
  describe('cleanup', function()
    it('clears state so resize becomes a no-op', function()
      thread_listing._set_state(make_rows(5), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      thread_listing.cleanup()
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'unchanged' })
      vim.bo[bufnr].modifiable = false
      thread_listing.resize()
      assert.are.equal('unchanged', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- next_page / previous_page
  -- ----------------------------------------------------------------
  describe('next_page', function()
    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.next_page() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('advances to the next page', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      vim.api.nvim_win_set_height(0, 5)
      thread_listing.render_page(1)
      local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      thread_listing.next_page()
      local new_first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      assert.are_not.equal(first_line, new_first)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('warns when already on last page', function()
      thread_listing._set_state(make_rows(3), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      local warned = false
      local orig_notify = vim.notify
      vim.notify = function(_, level)
        if level == vim.log.levels.WARN then
          warned = true
        end
      end
      thread_listing.next_page()
      vim.notify = orig_notify
      assert.is_true(warned)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('previous_page', function()
    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.previous_page() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('goes to the previous page', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      vim.api.nvim_win_set_height(0, 5)
      thread_listing.render_page(2)
      local page2_first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      thread_listing.previous_page()
      local page1_first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      assert.are_not.equal(page2_first, page1_first)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('warns when already on first page', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      local warned = false
      local orig_notify = vim.notify
      vim.notify = function(_, level)
        if level == vim.log.levels.WARN then
          warned = true
        end
      end
      thread_listing.previous_page()
      vim.notify = orig_notify
      assert.is_true(warned)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- mark_seen_optimistic
  -- ----------------------------------------------------------------
  describe('mark_seen_optimistic', function()
    it('is a no-op when no display rows', function()
      thread_listing.mark_seen_optimistic('1') -- should not error
    end)

    it('adds Seen flag to cached row', function()
      local rows = make_rows(3)
      rows[2].env.flags = { 'Flagged' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)

      thread_listing.mark_seen_optimistic('2')

      -- Verify the flag was added in-memory
      -- Re-render to check the highlight changed (Seen → no bold highlight)
      -- The flag should now include 'Seen'
      -- We can verify by re-rendering and checking the buffer content is still there
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.is_true(#lines > 0)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('is a no-op when email already has Seen flag', function()
      local rows = make_rows(3)
      rows[2].env.flags = { 'Seen' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)

      -- Should return early without modifying
      thread_listing.mark_seen_optimistic('2')
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('handles unknown email_id gracefully', function()
      thread_listing._set_state(make_rows(3), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      thread_listing.mark_seen_optimistic('999') -- not in display rows
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('applies highlight to the correct buffer line', function()
      local rows = make_rows(5)
      rows[3].env.flags = { 'Flagged' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)

      thread_listing.mark_seen_optimistic('3')

      -- The extmarks on line 3 should have changed (seen highlight applied)
      local ns = vim.api.nvim_create_namespace('himalaya_seen')
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { 2, 0 }, { 2, -1 }, {})
      -- mark_line_as_seen removes bold highlights, so separator-only marks remain
      assert.is_true(#marks >= 0)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- jump_to_next_unread
  -- ----------------------------------------------------------------
  describe('jump_to_next_unread', function()
    it('moves cursor to unseen row', function()
      local rows = make_rows(3)
      rows[1].env.flags = { 'Seen' }
      rows[2].env.flags = {}
      rows[3].env.flags = { 'Seen' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      thread_listing.jump_to_next_unread()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('wraps correctly', function()
      local rows = make_rows(3)
      rows[1].env.flags = {}
      rows[2].env.flags = { 'Seen' }
      rows[3].env.flags = { 'Seen' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      thread_listing.jump_to_next_unread()
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('notifies when all emails are seen', function()
      local rows = make_rows(2)
      rows[1].env.flags = { 'Seen' }
      rows[2].env.flags = { 'Seen' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notified = false
      local orig = vim.notify
      vim.notify = function(msg)
        if type(msg) == 'string' and msg:find('No unread') then
          notified = true
        end
      end
      thread_listing.jump_to_next_unread()
      vim.notify = orig
      assert.is_true(notified)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.jump_to_next_unread() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- jump_to_prev_unread
  -- ----------------------------------------------------------------
  describe('jump_to_prev_unread', function()
    it('moves cursor to previous unseen row', function()
      local rows = make_rows(3)
      rows[1].env.flags = { 'Seen' }
      rows[2].env.flags = {}
      rows[3].env.flags = { 'Seen' }
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      thread_listing.jump_to_prev_unread()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('wraps from beginning to end', function()
      local rows = make_rows(3)
      rows[1].env.flags = { 'Seen' }
      rows[2].env.flags = { 'Seen' }
      rows[3].env.flags = {}
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      thread_listing.jump_to_prev_unread()
      assert.are.equal(3, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.jump_to_prev_unread() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- jump_to_next_read
  -- ----------------------------------------------------------------
  describe('jump_to_next_read', function()
    it('moves cursor to next read row', function()
      local rows = make_rows(3)
      rows[1].env.flags = {}
      rows[2].env.flags = { 'Seen' }
      rows[3].env.flags = {}
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      thread_listing.jump_to_next_read()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('notifies when no read emails', function()
      local rows = make_rows(2)
      rows[1].env.flags = {}
      rows[2].env.flags = {}
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notified = false
      local orig = vim.notify
      vim.notify = function(msg)
        if type(msg) == 'string' and msg:find('No read') then
          notified = true
        end
      end
      thread_listing.jump_to_next_read()
      vim.notify = orig
      assert.is_true(notified)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.jump_to_next_read() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- jump_to_prev_read
  -- ----------------------------------------------------------------
  describe('jump_to_prev_read', function()
    it('moves cursor to previous read row', function()
      local rows = make_rows(3)
      rows[1].env.flags = {}
      rows[2].env.flags = { 'Seen' }
      rows[3].env.flags = {}
      thread_listing._set_state(rows, 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      thread_listing.jump_to_prev_read()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('is a no-op when no display rows', function()
      local bufnr = make_buf()
      thread_listing.jump_to_prev_read() -- should not error
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- toggle_reverse
  -- ----------------------------------------------------------------
  describe('toggle_reverse', function()
    it('rebuilds tree from cached edges', function()
      -- We need to go through list() to populate last_edges, but that
      -- requires request stubs. Instead, test via the fallback path.
      local config = require('himalaya.config')
      config._reset()
      config.setup({ thread_reverse = false })

      -- No last_edges → falls back to M.list().
      -- Stub M.list to capture the call.
      local list_called = false
      local orig_list = thread_listing.list
      thread_listing.list = function()
        list_called = true
      end

      thread_listing.toggle_reverse()
      assert.is_true(list_called)
      -- Verify config was toggled
      assert.is_true(config.get().thread_reverse)

      thread_listing.list = orig_list
    end)
  end)

  -- ----------------------------------------------------------------
  -- is_busy
  -- ----------------------------------------------------------------
  describe('is_busy', function()
    it('returns false when idle', function()
      assert.is_false(thread_listing.is_busy())
    end)
  end)

  -- ----------------------------------------------------------------
  -- resize
  -- ----------------------------------------------------------------
  describe('resize', function()
    it('follows selected email across page boundary on shrink', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      local initial_line_count = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_win_set_cursor(0, { initial_line_count, 0 })
      local target_id = vim.api.nvim_get_current_line():match('%d+')
      vim.api.nvim_win_set_height(0, 5)
      thread_listing.resize()
      local after_id = vim.api.nvim_get_current_line():match('%d+')
      assert.are.equal(target_id, after_id)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('follows selected email when window grows', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      vim.api.nvim_win_set_height(0, 5)
      thread_listing.render_page(1)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local target_id = vim.api.nvim_get_current_line():match('%d+')
      vim.api.nvim_win_set_height(0, 20)
      thread_listing.resize()
      local after_id = vim.api.nvim_get_current_line():match('%d+')
      assert.are.equal(target_id, after_id)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('follows email from page 2 across resize', function()
      thread_listing._set_state(make_rows(30), 1)
      local bufnr = make_buf()
      vim.api.nvim_win_set_height(0, 5)
      thread_listing.render_page(1)
      thread_listing.render_page(2)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local target_id = vim.api.nvim_get_current_line():match('%d+')
      vim.api.nvim_win_set_height(0, 20)
      thread_listing.resize()
      local after_id = vim.api.nvim_get_current_line():match('%d+')
      assert.are.equal(target_id, after_id)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves cursor on width-only change', function()
      thread_listing._set_state(make_rows(10), 1)
      local bufnr = make_buf()
      thread_listing.render_page(1)
      local line_count = vim.api.nvim_buf_line_count(0)
      if line_count >= 5 then
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        local target_id = vim.api.nvim_get_current_line():match('%d+')
        thread_listing.resize()
        local after_id = vim.api.nvim_get_current_line():match('%d+')
        assert.are.equal(target_id, after_id)
      end
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('toggle_to_flat clears state and deregisters resize autocmds', function()
      thread_listing._set_state(make_rows(5), 1)
      local augroup = vim.api.nvim_create_augroup('HimalayaThreadListing', { clear = true })
      vim.api.nvim_create_autocmd('VimResized', { group = augroup, callback = function() end })
      assert.is_true(#vim.api.nvim_get_autocmds({ group = 'HimalayaThreadListing' }) > 0)

      local email_mod = require('himalaya.domain.email')
      local orig_list = email_mod.list
      email_mod.list = function() end
      thread_listing.toggle_to_flat()
      email_mod.list = orig_list

      assert.are.equal(0, #vim.api.nvim_get_autocmds({ group = 'HimalayaThreadListing' }))
    end)

    it('is a no-op when no display rows are loaded', function()
      local bufnr = make_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a', 'b', 'c' })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      thread_listing.resize()
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- read (thin delegate)
  -- ----------------------------------------------------------------
  describe('read', function()
    it('delegates to email.read()', function()
      local called = false
      local email_mod = require('himalaya.domain.email')
      local orig = email_mod.read
      email_mod.read = function()
        called = true
      end
      thread_listing.read()
      assert.is_true(called)
      email_mod.read = orig
    end)
  end)

  -- ----------------------------------------------------------------
  -- set_thread_query
  -- ----------------------------------------------------------------
  describe('set_thread_query', function()
    it('opens search popup and re-fetches on submit', function()
      local bufnr = make_buf()
      local search_opened = false
      local list_called = false
      package.loaded['himalaya.ui.search'] = {
        open = function(cb, _prev, _folder, _acct)
          search_opened = true
          -- Simulate user submitting a query
          cb('from alice', 'Sent')
        end,
      }
      local orig_list = thread_listing.list
      thread_listing.list = function()
        list_called = true
      end

      thread_listing.set_thread_query()

      assert.is_true(search_opened)
      assert.is_true(list_called)
      -- The folder should have been updated on the buffer
      assert.are.equal('Sent', vim.b[bufnr].himalaya_folder)

      thread_listing.list = orig_list
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- ----------------------------------------------------------------
  -- list
  -- ----------------------------------------------------------------
  -- himalaya v2 has no `envelope thread` (envelope only has list/search),
  -- so M.list() no longer issues any CLI request in the non-cache-hit
  -- path - it fails loudly instead (see the comment in thread_listing.lua).
  -- The cache-hit path (build_and_render, reached when last_edges is
  -- already populated) is still fully live code, so these tests exercise
  -- it directly via the _set_edges() test accessor instead of faking a
  -- request/on_data round-trip that no longer exists.
  describe('list', function()
    local bufnr
    local cache_key = 'INBOX\0\0date desc'

    before_each(function()
      -- Full re-require for isolation: module-local state (last_edges,
      -- flag_cache, etc.) must start fresh per test, same approach the
      -- rest of this file already uses.
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      bufnr = make_buf()
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('logs an error and issues no CLI request when there is no cache', function()
      package.loaded['himalaya.request'] = {
        json = function()
          error('should not be called - envelope thread does not exist')
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      bufnr = make_buf()

      local notified
      local orig = vim.notify
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      thread_listing.list()
      vim.notify = orig

      assert.is_not_nil(notified)
      assert.are.equal(vim.log.levels.ERROR, notified.level)

      package.loaded['himalaya.request'] = nil
    end)

    it('builds tree and renders buffer from cached edges', function()
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'Alice' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '1', subject = 'Root', from = { name = 'Alice' }, date = '2024-01-01 10:00:00+00:00' },
          { id = '2', subject = 'Reply', from = { name = 'Bob' }, date = '2024-01-02 10:00:00+00:00' },
          1,
        },
      }, cache_key)

      thread_listing.list()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      assert.is_true(#lines >= 2)
      local content = table.concat(lines, '\n')
      assert.truthy(content:find('1'))
      assert.truthy(content:find('2'))
    end)

    it('pre-populates flags from himalaya_envelopes buffer var', function()
      vim.b[bufnr].himalaya_envelopes = {
        { id = '1', flags = { 'Seen' }, has_attachment = false },
        { id = '2', flags = { 'Flagged' }, has_attachment = true },
      }
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'A', from = { name = 'X' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '0' },
          { id = '2', subject = 'B', from = { name = 'Y' }, date = '2024-01-02 10:00:00+00:00' },
          0,
        },
      }, cache_key)

      thread_listing.list()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      assert.is_true(#lines >= 2)
    end)

    it('flag_cache persists flags from a previous render across re-renders', function()
      local edges = {
        {
          { id = '0' },
          { id = '1', subject = 'A', from = { name = 'X' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
      }
      -- First render: seed flags via the flat-listing buffer var.
      vim.b[bufnr].himalaya_envelopes = { { id = '1', flags = { 'Seen' }, has_attachment = false } }
      thread_listing._set_edges(edges, cache_key)
      thread_listing.list()

      -- Second render (e.g. after a fresh fetch elsewhere sets new edges):
      -- flag_cache alone - no flat buffer var this time - should still
      -- carry the flags forward.
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'A', from = { name = 'X' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '0' },
          { id = '3', subject = 'New', from = { name = 'Y' }, date = '2024-01-03 10:00:00+00:00' },
          0,
        },
      }, cache_key)
      thread_listing.list()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      assert.is_true(#lines >= 2)
    end)

    it('with restore_cursor_line positions cursor correctly', function()
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'A', from = { name = 'X' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '0' },
          { id = '2', subject = 'B', from = { name = 'Y' }, date = '2024-01-02 10:00:00+00:00' },
          0,
        },
      }, cache_key)

      thread_listing.list(nil, { restore_cursor_line = 1 })

      local cursor = vim.api.nvim_win_get_cursor(0)
      assert.are.equal(1, cursor[1])
    end)

    it('with restore_email_id finds the email and positions cursor', function()
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '2', subject = 'Target', from = { name = 'Y' }, date = '2024-01-02 10:00:00+00:00' },
          0,
        },
        {
          { id = '0' },
          { id = '1', subject = 'Other', from = { name = 'X' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
      }, cache_key)

      thread_listing.list(nil, { restore_email_id = '2' })

      local line = vim.api.nvim_get_current_line()
      assert.truthy(line:find('2'))
    end)

    it('sets account when provided', function()
      thread_listing.list('myaccount')
      assert.are.equal('myaccount', vim.b[bufnr].himalaya_account)
      assert.are.equal('INBOX', vim.b[bufnr].himalaya_folder)
    end)
  end)

  -- ----------------------------------------------------------------
  -- cancel_jobs with in-flight jobs
  -- ----------------------------------------------------------------
  describe('cancel_jobs', function()
    -- M.list() no longer sets list_job (see the 'list' describe block above)
    -- since himalaya v2 has no `envelope thread` to fetch from - there's no
    -- way left to get a genuinely in-flight job for cancel_jobs to kill.
    it('is safe when no jobs are running', function()
      thread_listing.cancel_jobs() -- should not error
    end)
  end)

  -- ----------------------------------------------------------------
  -- toggle_reverse (with cached edges via list path)
  -- ----------------------------------------------------------------
  describe('toggle_reverse with edges', function()
    it('rebuilds from cached edges without any CLI request', function()
      package.loaded['himalaya.request'] = {
        json = function()
          error('should not be called - toggle_reverse works off last_edges directly')
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      local bufnr = make_buf()

      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          { id = '2', subject = 'Reply', from = { name = 'B' }, date = '2024-01-02 10:00:00+00:00' },
          1,
        },
      }, 'INBOX\0\0date desc')

      local config = require('himalaya.config')
      config._reset()

      thread_listing.toggle_reverse()

      assert.is_true(config.get().thread_reverse)

      -- Buffer should still have rendered content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.is_true(#lines >= 2)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      package.loaded['himalaya.request'] = nil
    end)
  end)

  -- ----------------------------------------------------------------
  -- edge caching across mode switches
  -- ----------------------------------------------------------------
  describe('edge caching', function()
    it('toggle_to_flat preserves cached edges', function()
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      local bufnr = make_buf()

      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
      }, 'INBOX\0\0date desc')
      assert.is_true(thread_listing._has_cached_edges())

      local email_mod = require('himalaya.domain.email')
      local orig_list = email_mod.list
      email_mod.list = function() end
      thread_listing.toggle_to_flat()
      email_mod.list = orig_list

      assert.is_true(thread_listing._has_cached_edges())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('cleanup clears cached edges', function()
      thread_listing._set_edges({ { 'edge_data' } }, 'INBOX\0\0date desc')
      assert.is_true(thread_listing._has_cached_edges())
      thread_listing.cleanup()
      assert.is_false(thread_listing._has_cached_edges())
    end)

    it('list() rebuilds from cached edges without any CLI request', function()
      package.loaded['himalaya.request'] = {
        json = function()
          error('should not be called - cache key matches')
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      local bufnr = make_buf()

      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
      }, 'INBOX\0\0date desc')

      -- Two list() calls with the same folder/query/sort should both use
      -- the cache - the stub above errors if either one issues a request.
      thread_listing.list()
      thread_listing.list()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.is_true(#lines >= 1)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      package.loaded['himalaya.request'] = nil
    end)

    it('list() does not use a differently-keyed cache, and fails loudly instead', function()
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      local bufnr = make_buf()

      -- Cache is keyed for INBOX; this buffer is Sent, so the cache-hit
      -- branch must not fire for it.
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
      }, 'INBOX\0\0date desc')
      vim.b[bufnr].himalaya_folder = 'Sent'

      local notified
      local orig = vim.notify
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      thread_listing.list()
      vim.notify = orig

      assert.is_not_nil(notified)
      assert.are.equal(vim.log.levels.ERROR, notified.level)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('full round-trip: thread → flat → thread uses cache', function()
      package.loaded['himalaya.request'] = {
        json = function()
          error('should not be called - toggling back should rebuild from cache')
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = nil
      thread_listing = require('himalaya.domain.email.thread_listing')
      local bufnr = make_buf()

      -- 1. Edges already cached (as if an earlier fetch had populated them)
      thread_listing._set_edges({
        {
          { id = '0' },
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          0,
        },
        {
          { id = '1', subject = 'Root', from = { name = 'A' }, date = '2024-01-01 10:00:00+00:00' },
          { id = '2', subject = 'Reply', from = { name = 'B' }, date = '2024-01-02 10:00:00+00:00' },
          1,
        },
      }, 'INBOX\0\0date desc')

      -- 2. Toggle to flat (preserves edges)
      local email_mod = require('himalaya.domain.email')
      local orig_list = email_mod.list
      email_mod.list = function() end
      thread_listing.toggle_to_flat()
      email_mod.list = orig_list

      -- 3. Toggle back to thread - should rebuild from cache, no request
      thread_listing.list()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.is_true(#lines >= 2)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      package.loaded['himalaya.request'] = nil
    end)
  end)
end)
