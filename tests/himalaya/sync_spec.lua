describe('himalaya.sync', function()
  local sync, config

  before_each(function()
    -- Reset all relevant modules
    package.loaded['himalaya.sync'] = nil
    package.loaded['himalaya.config'] = nil
    package.loaded['himalaya.request'] = nil
    package.loaded['himalaya.events'] = nil

    -- Stub request module
    package.loaded['himalaya.request'] = {
      json = function(_opts)
        return { kill = function() end }
      end,
    }

    config = require('himalaya.config')
    config._reset()
    require('himalaya.events')._reset()
    sync = require('himalaya.sync')
  end)

  after_each(function()
    sync._reset()
  end)

  describe('start', function()
    it('creates a timer when background_sync is enabled', function()
      config.setup({ background_sync = true, sync_interval = 60 })
      sync.start()
      assert.is_not_nil(sync._get_timer())
    end)

    it('does not create a timer when background_sync is disabled', function()
      config.setup({ background_sync = false })
      sync.start()
      assert.is_nil(sync._get_timer())
    end)

    it('is idempotent — second call is a no-op', function()
      config.setup({ background_sync = true, sync_interval = 60 })
      sync.start()
      local first_timer = sync._get_timer()
      sync.start()
      assert.are.equal(first_timer, sync._get_timer())
    end)
  end)

  describe('stop', function()
    it('cleans up timer', function()
      config.setup({ background_sync = true, sync_interval = 60 })
      sync.start()
      assert.is_not_nil(sync._get_timer())
      sync.stop()
      assert.is_nil(sync._get_timer())
    end)

    it('is safe to call when no timer is running', function()
      sync.stop()
      assert.is_nil(sync._get_timer())
    end)
  end)

  describe('cancel', function()
    it('increments generation', function()
      local gen_before = sync._get_generation()
      sync.cancel()
      assert.are.equal(gen_before + 1, sync._get_generation())
    end)
  end)

  describe('poll', function()
    it('skips when no listing buffer is visible', function()
      -- No listing buffer exists, poll should just return without error
      sync.poll()
      assert.is_nil(sync._get_sync_job())
    end)

    it('skips when email.is_busy() returns true', function()
      -- Create a listing buffer to pass the first check
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'

      -- Stub email.is_busy to return true
      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return true
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }

      sync.poll()
      assert.is_nil(sync._get_sync_job())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('skips when thread_listing.is_busy() returns true', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return true
        end,
      }

      sync.poll()
      assert.is_nil(sync._get_sync_job())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('issues a CLI call for flat listing when not busy', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local request_called = false
      package.loaded['himalaya.request'] = {
        json = function(_opts)
          request_called = true
          return { kill = function() end }
        end,
      }

      -- Re-require sync to pick up new stubs
      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()
      assert.is_true(request_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('does not modify buffer when IDs are unchanged', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      -- Set existing buffer lines with IDs 1, 2, 3
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '1 │flags│subject1│sender1│date1',
        '2 │flags│subject2│sender2│date2',
        '3 │flags│subject3│sender3│date3',
      })
      vim.bo[bufnr].modifiable = false

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local captured_on_data
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured_on_data = opts.on_data
          return { kill = function() end }
        end,
      }

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()

      -- Return same IDs
      local notify_called = false
      local orig_notify = vim.notify
      vim.notify = function()
        notify_called = true
      end

      captured_on_data({
        { id = 1 },
        { id = 2 },
        { id = 3 },
      })

      vim.notify = orig_notify
      assert.is_false(notify_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('updates buffer and notifies when IDs change', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      -- Set existing buffer lines with IDs 1, 2
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '1 │flags│subject1│sender1│date1',
        '2 │flags│subject2│sender2│date2',
      })
      vim.bo[bufnr].modifiable = false

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local captured_on_data
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured_on_data = opts.on_data
          return { kill = function() end }
        end,
      }

      -- Stub renderer and listing for the refresh path
      package.loaded['himalaya.ui.renderer'] = {
        render = function(data, _width)
          local lines = {}
          for _, env in ipairs(data) do
            lines[#lines + 1] = tostring(env.id) .. ' │flags│subj│sender│date'
          end
          return { header = 'ID │FLGS│SUBJECT│FROM│DATE', lines = lines }
        end,
      }
      package.loaded['himalaya.ui.listing'] = {
        get_email_id_from_line = function(line)
          return line:match('%d+') or ''
        end,
        apply_header = function() end,
        apply_highlights = function() end,
      }

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()

      local notify_msg
      local orig_notify = vim.notify
      vim.notify = function(msg)
        notify_msg = msg
      end

      local events = require('himalaya.events')
      local emitted
      events.on('NewMail', function(data)
        emitted = data
      end)

      -- Return new set with ID 3 added
      captured_on_data({
        { id = 1 },
        { id = 2 },
        { id = 3 },
      })

      vim.notify = orig_notify
      assert.is_not_nil(notify_msg)
      assert.truthy(notify_msg:find('1 new'))
      assert.is_not_nil(emitted)
      assert.are.equal(1, emitted.count)
      assert.are.equal('INBOX', emitted.folder)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('skips when account is empty', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = ''
      vim.b[bufnr].himalaya_folder = 'INBOX'

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }

      sync.poll()
      assert.is_nil(sync._get_sync_job())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('skips when sync_job is already running', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local json_call_count = 0
      package.loaded['himalaya.request'] = {
        json = function(_opts)
          json_call_count = json_call_count + 1
          return { kill = function() end }
        end,
      }

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      -- First poll starts the sync job
      sync.poll()
      assert.are.equal(1, json_call_count)

      -- Second poll should skip because sync_job is already set
      sync.poll()
      assert.are.equal(1, json_call_count)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('flat on_error clears sync_job', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local captured_on_error
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured_on_error = opts.on_error
          return { kill = function() end }
        end,
      }

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()
      assert.is_not_nil(sync._get_sync_job())
      captured_on_error()
      assert.is_nil(sync._get_sync_job())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('flat is_stale returns true after cancel', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local captured_is_stale
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured_is_stale = opts.is_stale
          return { kill = function() end }
        end,
      }

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()
      assert.is_false(captured_is_stale())
      sync.cancel()
      assert.is_true(captured_is_stale())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('flat on_data skips when window is invalid', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.b[bufnr].himalaya_buffer_type = 'listing'
      vim.b[bufnr].himalaya_account = 'test'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_page = 1
      vim.b[bufnr].himalaya_page_size = 50

      package.loaded['himalaya.domain.email'] = {
        is_busy = function()
          return false
        end,
        _bufwidth = function()
          return 80
        end,
      }
      package.loaded['himalaya.domain.email.thread_listing'] = {
        is_busy = function()
          return false
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return '--account ' .. acct
        end,
      }

      local captured_on_data
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured_on_data = opts.on_data
          return { kill = function() end }
        end,
      }

      -- Open a second window so we can close the listing one
      vim.cmd('split')
      local split_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(winid)

      package.loaded['himalaya.sync'] = nil
      sync = require('himalaya.sync')

      sync.poll()

      -- Close the listing window before on_data fires
      vim.api.nvim_win_close(winid, true)

      -- Should not error — just returns early
      local orig_notify = vim.notify
      vim.notify = function() end
      captured_on_data({ { id = 99 } })
      vim.notify = orig_notify

      vim.api.nvim_buf_delete(bufnr, { force = true })
      -- Close the extra split
      if vim.api.nvim_win_is_valid(split_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(split_win, true)
      end
    end)
  end)
end)

-- himalaya v2 has no `envelope thread` (envelope only has list/search), so
-- thread-listing buffers can't background-sync until that's reimplemented
-- client-side - see the comment in sync.lua's M.poll. This replaces what
-- used to be a full describe block exercising the thread sync request/
-- response cycle; that cycle no longer exists, so there's nothing left to
-- test except that poll() recognizes a thread-listing buffer and bails out
-- without issuing any CLI request.
describe('himalaya.sync thread-listing path', function()
  local sync

  local function setup_thread_sync()
    package.loaded['himalaya.sync'] = nil
    package.loaded['himalaya.config'] = nil
    package.loaded['himalaya.request'] = nil
    package.loaded['himalaya.events'] = nil

    local captured = {}
    package.loaded['himalaya.request'] = {
      json = function(opts)
        captured.opts = opts
        return { kill = function() end }
      end,
    }
    package.loaded['himalaya.domain.email'] = {
      is_busy = function()
        return false
      end,
    }
    package.loaded['himalaya.domain.email.thread_listing'] = {
      is_busy = function()
        return false
      end,
      _set_state = function() end,
      render_page = function() end,
    }
    package.loaded['himalaya.state.account'] = {
      flag = function(acct)
        return '--account ' .. acct
      end,
    }
    package.loaded['himalaya.domain.email.tree'] = {
      build = function(data, _opts)
        local rows = {}
        for _, edge in ipairs(data) do
          rows[#rows + 1] = { env = edge, depth = 0, children = {} }
        end
        return rows
      end,
      build_prefix = function() end,
    }
    package.loaded['himalaya.ui.listing'] = {
      get_email_id_from_line = function(line)
        return line:match('%d+') or ''
      end,
    }

    require('himalaya.config')._reset()
    require('himalaya.events')._reset()
    sync = require('himalaya.sync')
    return captured
  end

  local tracked_bufs = {}
  local function make_thread_buf(ids)
    local bufnr = vim.api.nvim_create_buf(false, true)
    tracked_bufs[#tracked_bufs + 1] = bufnr
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.b[bufnr].himalaya_buffer_type = 'thread-listing'
    vim.b[bufnr].himalaya_account = 'test'
    vim.b[bufnr].himalaya_folder = 'INBOX'
    vim.b[bufnr].himalaya_query = ''
    vim.bo[bufnr].modifiable = true
    local lines = {}
    for _, id in ipairs(ids) do
      lines[#lines + 1] = tostring(id) .. ' │subj│sender│date'
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    return bufnr, winid
  end

  after_each(function()
    if sync then
      sync._reset()
    end
    for _, b in ipairs(tracked_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    tracked_bufs = {}
  end)

  it('skips thread-listing buffers without issuing any CLI request', function()
    local captured = setup_thread_sync()
    make_thread_buf({ 1, 2 })
    sync.poll()
    assert.is_nil(captured.opts)
    assert.is_nil(sync._get_sync_job())
  end)
end)
