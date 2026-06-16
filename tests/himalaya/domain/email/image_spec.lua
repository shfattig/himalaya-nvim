describe('himalaya.domain.email.image', function()
  local image_mod
  local log_calls
  local last_request_plain_opts
  local last_build_cmd_args
  local last_system_args
  local system_result

  local orig_system
  local orig_executable
  local orig_filereadable
  local orig_tempname
  local orig_mkdir
  local orig_delete
  local orig_hrtime
  local orig_create_autocmd
  local orig_bufwinid

  before_each(function()
    for k in pairs(package.loaded) do
      if k:match('^himalaya') then
        package.loaded[k] = nil
      end
    end

    log_calls = { info = {}, warn = {}, err = {}, debug = {} }
    last_request_plain_opts = nil
    last_build_cmd_args = nil
    last_system_args = nil
    system_result = nil

    -- Save originals
    orig_system = vim.system
    orig_executable = vim.fn.executable
    orig_filereadable = vim.fn.filereadable
    orig_tempname = vim.fn.tempname
    orig_mkdir = vim.fn.mkdir
    orig_delete = vim.fn.delete
    orig_hrtime = vim.uv.hrtime
    orig_create_autocmd = vim.api.nvim_create_autocmd
    orig_bufwinid = vim.fn.bufwinid

    -- Stub vim.system
    vim.system = function(cmd, opts, cb)
      last_system_args = { cmd = cmd, opts = opts }
      local job = {
        kill = function() end,
      }
      if cb and system_result then
        cb(system_result)
      end
      return job
    end

    -- Stub vim.fn helpers
    vim.fn.executable = function(_bin)
      return 1
    end
    vim.fn.filereadable = function(_path)
      return 0
    end
    vim.fn.tempname = function()
      return '/tmp/himalaya-test-tmp'
    end
    vim.fn.mkdir = function() end
    vim.fn.delete = function() end
    vim.fn.bufwinid = function(_bufnr)
      return -1
    end

    -- Stub vim.uv.hrtime
    vim.uv.hrtime = function()
      return 0
    end

    -- Stub nvim_create_autocmd
    vim.api.nvim_create_autocmd = function(_event, _opts)
      return 1
    end

    -- Stub dependencies (stable table so mutations in toggle_mode persist)
    local fake_config = {
      render_html = {
        binary = 'chrome-headless-shell',
        pixels_per_column = 8,
        device_scale_factor = 2,
        max_screenshot_height = 5000,
        image_mode = false,
      },
      mock = false,
    }
    package.loaded['himalaya.config'] = {
      get = function()
        return fake_config
      end,
    }

    package.loaded['himalaya.request'] = {
      json = function() end,
      plain = function(opts)
        last_request_plain_opts = opts
      end,
      _build_cmd = function(fmt, args, mode)
        last_build_cmd_args = { fmt = fmt, args = args, mode = mode }
        return { 'himalaya', 'message', 'export' }
      end,
    }

    package.loaded['himalaya.log'] = {
      info = function(msg)
        table.insert(log_calls.info, msg)
      end,
      warn = function(msg)
        table.insert(log_calls.warn, msg)
      end,
      err = function(msg)
        table.insert(log_calls.err, msg)
      end,
      debug = function(msg)
        table.insert(log_calls.debug, msg)
      end,
    }

    package.loaded['himalaya.state.account'] = {
      flag = function(_account)
        return '-a test'
      end,
    }

    package.loaded['himalaya.state.context'] = {
      resolve = function(_bufnr)
        return 'test', 'INBOX'
      end,
    }

    package.loaded['himalaya.domain.email.chrome'] = {
      get_client = function() end,
    }

    image_mod = require('himalaya.domain.email.image')
  end)

  after_each(function()
    vim.system = orig_system
    vim.fn.executable = orig_executable
    vim.fn.filereadable = orig_filereadable
    vim.fn.tempname = orig_tempname
    vim.fn.mkdir = orig_mkdir
    vim.fn.delete = orig_delete
    vim.fn.bufwinid = orig_bufwinid
    vim.uv.hrtime = orig_hrtime
    vim.api.nvim_create_autocmd = orig_create_autocmd
    vim.wo.winbar = ''
  end)

  describe('prefetch', function()
    it('creates a temp dir and calls _build_cmd and vim.system', function()
      local mkdir_called = false
      vim.fn.mkdir = function(dir, flags)
        mkdir_called = true
        assert.are.equal('/tmp/himalaya-test-tmp', dir)
        assert.are.equal('p', flags)
      end

      system_result = { code = 0 }
      image_mod.prefetch(0, 'test', 'INBOX', '123')

      assert.is_true(mkdir_called)
      assert.is_not_nil(last_build_cmd_args)
      assert.are.equal('plain', last_build_cmd_args.mode)
      assert.is_not_nil(last_system_args)
    end)

    it('kills prior pre-fetch job when called again for the same buffer', function()
      local kill_count = 0
      vim.system = function(cmd, opts, _cb)
        last_system_args = { cmd = cmd, opts = opts }
        local job = {
          kill = function()
            kill_count = kill_count + 1
          end,
        }
        return job
      end

      image_mod.prefetch(0, 'test', 'INBOX', '123')
      assert.are.equal(0, kill_count)

      image_mod.prefetch(0, 'test', 'INBOX', '456')
      assert.are.equal(1, kill_count)
    end)

    it('deletes old tmpdir when re-prefetching', function()
      local deleted_dirs = {}
      vim.fn.delete = function(dir, flags)
        table.insert(deleted_dirs, { dir = dir, flags = flags })
      end

      local call_count = 0
      vim.fn.tempname = function()
        call_count = call_count + 1
        return '/tmp/himalaya-test-tmp-' .. call_count
      end

      image_mod.prefetch(0, 'test', 'INBOX', '123')
      image_mod.prefetch(0, 'test', 'INBOX', '456')

      assert.are.equal(1, #deleted_dirs)
      assert.are.equal('/tmp/himalaya-test-tmp-1', deleted_dirs[1].dir)
      assert.are.equal('rf', deleted_dirs[1].flags)
    end)
  end)

  describe('_show_image', function()
    it('sets buffer lines and marks image as rendered', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'line1', 'line2', 'line3' })
      vim.bo[bufnr].modifiable = false

      local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = 80,
        height = 20,
        row = 0,
        col = 0,
      })

      -- Mock image.utils.term so the term_size branch is exercised.
      package.loaded['image.utils.term'] = {
        get_size = function()
          return { cell_width = 8, cell_height = 16 }
        end,
      }

      local render_called = false
      local fake_image_mod = {
        from_file = function(_path, _opts)
          return {
            render = function()
              render_called = true
            end,
            image_width = 800,
            image_height = 600,
            rendered_geometry = { height = 10 },
          }
        end,
      }

      image_mod._show_image(fake_image_mod, bufnr, winid, '/tmp/test.png', nil)
      package.loaded['image.utils.term'] = nil

      assert.is_true(render_called)
      assert.is_true(vim.b[bufnr].himalaya_image_rendered)
      assert.are.equal('/tmp/test.png', vim.b[bufnr].himalaya_image_png)
      assert.are.same({ 'line1', 'line2', 'line3' }, vim.b[bufnr].himalaya_saved_lines)

      -- Buffer should have filler lines (height - 1 = 9)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(9, #lines)
      for _, line in ipairs(lines) do
        assert.are.equal('', line)
      end

      -- Winbar should have [IMAGE] appended
      assert.truthy(vim.wo[winid].winbar:find('%[IMAGE%]'))

      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns early for invalid buffer', function()
      local fake_image_mod = {
        from_file = function()
          error('should not be called')
        end,
      }
      -- Use a buffer number that doesn't exist
      image_mod._show_image(fake_image_mod, 99999, 0, '/tmp/test.png', nil)
      -- No error means it returned early
    end)

    it('logs error when image.from_file returns nil', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = 80,
        height = 20,
        row = 0,
        col = 0,
      })

      local fake_image_mod = {
        from_file = function()
          return nil
        end,
      }

      image_mod._show_image(fake_image_mod, bufnr, winid, '/tmp/bad.png', nil)

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('image.nvim failed to load'))

      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('uses fallback height when rendered_geometry is nil', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'text' })
      vim.bo[bufnr].modifiable = false

      local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = 80,
        height = 20,
        row = 0,
        col = 0,
      })

      local fake_image_mod = {
        from_file = function()
          return {
            render = function() end,
            image_width = 0,
            image_height = 0,
            rendered_geometry = nil,
          }
        end,
      }

      image_mod._show_image(fake_image_mod, bufnr, winid, '/tmp/test.png', nil)

      -- Fallback height is 500, so 499 filler lines
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(499, #lines)

      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('calls plog when provided', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'text' })

      local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = 80,
        height = 20,
        row = 0,
        col = 0,
      })

      local plog_messages = {}
      local function plog(msg)
        table.insert(plog_messages, msg)
      end

      local fake_image_mod = {
        from_file = function()
          return {
            render = function() end,
            image_width = 800,
            image_height = 600,
            rendered_geometry = { height = 5 },
          }
        end,
      }

      image_mod._show_image(fake_image_mod, bufnr, winid, '/tmp/test.png', plog)

      assert.are.equal(2, #plog_messages)
      assert.truthy(plog_messages[1]:find('image.nvim render:'))
      assert.truthy(plog_messages[2]:find('DONE'))

      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('toggle', function()
    it('calls render when image is not rendered', function()
      vim.b.himalaya_image_rendered = false
      local render_called = false
      image_mod.render = function()
        render_called = true
      end

      image_mod.toggle()
      assert.is_true(render_called)
    end)

    it('calls render when himalaya_image_rendered is nil', function()
      vim.b.himalaya_image_rendered = nil
      local render_called = false
      image_mod.render = function()
        render_called = true
      end

      image_mod.toggle()
      assert.is_true(render_called)
    end)

    it('calls clear when image is rendered', function()
      vim.b.himalaya_image_rendered = true
      local clear_called = false
      image_mod.clear = function()
        clear_called = true
      end

      image_mod.toggle()
      assert.is_true(clear_called)
    end)
  end)

  describe('toggle_mode', function()
    it('enables image_mode and renders when not already rendered', function()
      vim.b.himalaya_current_email_id = '123'
      vim.b.himalaya_image_rendered = false
      local render_called = false
      image_mod.render = function()
        render_called = true
      end

      image_mod.toggle_mode()

      local cfg = require('himalaya.config').get()
      assert.is_true(cfg.render_html.image_mode)
      assert.is_true(render_called)
      assert.are.equal(1, #log_calls.info)
      assert.truthy(log_calls.info[1]:find('Image mode ON'))
    end)

    it('does not re-render when already rendered', function()
      vim.b.himalaya_current_email_id = '123'
      vim.b.himalaya_image_rendered = true
      local render_called = false
      image_mod.render = function()
        render_called = true
      end

      image_mod.toggle_mode()

      local cfg = require('himalaya.config').get()
      assert.is_true(cfg.render_html.image_mode)
      assert.is_false(render_called)
    end)

    it('disables image_mode and clears when rendered', function()
      vim.b.himalaya_current_email_id = '123'
      -- First enable it
      image_mod.toggle_mode()
      log_calls.info = {}

      vim.b.himalaya_image_rendered = true
      local clear_called = false
      image_mod.clear = function()
        clear_called = true
      end

      image_mod.toggle_mode()

      local cfg = require('himalaya.config').get()
      assert.is_false(cfg.render_html.image_mode)
      assert.is_true(clear_called)
      assert.truthy(log_calls.info[1]:find('Image mode OFF'))
    end)

    it('does not clear when not rendered', function()
      vim.b.himalaya_current_email_id = '123'
      -- First enable it
      image_mod.toggle_mode()

      vim.b.himalaya_image_rendered = false
      local clear_called = false
      image_mod.clear = function()
        clear_called = true
      end

      image_mod.toggle_mode()

      assert.is_false(clear_called)
    end)

    it('skips render/clear when no email is open', function()
      vim.b.himalaya_current_email_id = nil
      vim.b.himalaya_image_rendered = false
      local render_called = false
      image_mod.render = function()
        render_called = true
      end

      image_mod.toggle_mode()

      assert.is_true(require('himalaya.config').get().render_html.image_mode)
      assert.is_false(render_called)
      assert.truthy(log_calls.info[1]:find('Image mode ON'))
    end)

    it('initializes render_html if nil', function()
      local bare_config = {}
      package.loaded['himalaya.config'] = {
        get = function()
          return bare_config
        end,
        _reset = function() end,
      }
      package.loaded['himalaya.domain.email.image'] = nil
      image_mod = require('himalaya.domain.email.image')

      vim.b.himalaya_image_rendered = false
      image_mod.render = function() end
      image_mod.toggle_mode()

      assert.is_true(bare_config.render_html.image_mode)
    end)
  end)

  describe('render', function()
    it('logs error when image.nvim is not installed', function()
      -- Force require('image') to fail even if image.nvim is on the rtp
      package.loaded['image'] = nil
      package.preload['image'] = function()
        error('module not found')
      end

      image_mod.render()

      package.preload['image'] = nil

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('image.nvim is not installed'))
    end)

    it('logs error when render_html.binary is not configured', function()
      package.loaded['image'] = { from_file = function() end }
      package.loaded['himalaya.config'] = {
        get = function()
          return { render_html = {} }
        end,
      }
      -- Reload to pick up new config stub
      package.loaded['himalaya.domain.email.image'] = nil
      image_mod = require('himalaya.domain.email.image')

      image_mod.render()

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('render_html.binary is not configured'))
    end)

    it('logs error when binary is not executable', function()
      package.loaded['image'] = { from_file = function() end }
      vim.fn.executable = function(_bin)
        return 0
      end

      image_mod.render()

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('not installed or not in PATH'))
    end)

    it('warns when no email ID is found in buffer', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = nil

      image_mod.render()

      assert.are.equal(1, #log_calls.warn)
      assert.truthy(log_calls.warn[1]:find('No email ID'))
    end)

    it('warns when email ID is empty string', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = ''

      image_mod.render()

      assert.are.equal(1, #log_calls.warn)
      assert.truthy(log_calls.warn[1]:find('No email ID'))
    end)

    it('uses cached PNG fast path when available', function()
      local show_image_called = false
      local orig_show_image = image_mod._show_image
      image_mod._show_image = function(_image, _bufnr, _winid, png_path)
        show_image_called = true
        assert.are.equal('/tmp/cached.png', png_path)
      end

      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      local bufnr = vim.api.nvim_get_current_buf()
      vim.b[bufnr].himalaya_image_png = '/tmp/cached.png'
      vim.fn.filereadable = function(path)
        if path == '/tmp/cached.png' then
          return 1
        end
        return 0
      end

      image_mod.render()

      assert.is_true(show_image_called)
      -- Should not have reached request.plain (fresh export)
      assert.is_nil(last_request_plain_opts)

      image_mod._show_image = orig_show_image
    end)

    it('falls through to fresh export when no pre-fetch exists', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      image_mod.render()

      assert.is_not_nil(last_request_plain_opts)
      assert.truthy(last_request_plain_opts.cmd:find('message export'))
    end)

    it('uses completed pre-fetch when available', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      local bufnr = vim.api.nvim_get_current_buf()

      -- Simulate a completed pre-fetch by calling prefetch and letting callback fire
      local system_callback
      vim.system = function(cmd, opts, cb)
        last_system_args = { cmd = cmd, opts = opts }
        system_callback = cb
        return { kill = function() end }
      end

      image_mod.prefetch(bufnr, 'test', 'INBOX', '123')

      -- Fire the system callback with success (simulating vim.schedule inline)
      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end
      system_callback({ code = 0 })
      vim.schedule = orig_schedule

      -- Now render should use the pre-fetched export (not call request.plain)
      -- We need to stub io.open and vim.fn.glob for do_render
      local autocmd_created = false
      vim.api.nvim_create_autocmd = function(_event, _opts)
        autocmd_created = true
        return 1
      end

      -- The do_render will try to glob for HTML files; stub that
      local orig_glob = vim.fn.glob
      vim.fn.glob = function(_pattern, _nosuf, _list)
        return {}
      end

      image_mod.render()

      -- Since pre-fetch was consumed, request.plain should NOT have been called
      assert.is_nil(last_request_plain_opts)
      -- do_render was entered (autocmd was created), but no HTML found -> warns
      assert.is_true(autocmd_created)

      vim.fn.glob = orig_glob
    end)

    it('waits for in-progress pre-fetch and uses it on success', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      local bufnr = vim.api.nvim_get_current_buf()

      -- Start a pre-fetch that hasn't completed
      local system_callback
      vim.system = function(cmd, opts, cb)
        last_system_args = { cmd = cmd, opts = opts }
        system_callback = cb
        return { kill = function() end }
      end

      image_mod.prefetch(bufnr, 'test', 'INBOX', '123')

      -- Now render: should register a callback on the pending pre-fetch
      local autocmd_created = false
      vim.api.nvim_create_autocmd = function(_event, _opts)
        autocmd_created = true
        return 1
      end

      local orig_glob = vim.fn.glob
      vim.fn.glob = function()
        return {}
      end

      image_mod.render()

      -- At this point, request.plain should NOT have been called yet
      assert.is_nil(last_request_plain_opts)

      -- Complete the pre-fetch
      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end
      system_callback({ code = 0 })
      vim.schedule = orig_schedule

      -- do_render should have been invoked (autocmd was created)
      assert.is_true(autocmd_created)

      vim.fn.glob = orig_glob
    end)

    it('falls back to fresh export when in-progress pre-fetch fails', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      local bufnr = vim.api.nvim_get_current_buf()

      local system_callback
      vim.system = function(cmd, opts, cb)
        last_system_args = { cmd = cmd, opts = opts }
        system_callback = cb
        return { kill = function() end }
      end

      image_mod.prefetch(bufnr, 'test', 'INBOX', '123')

      image_mod.render()

      -- Complete the pre-fetch with failure
      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end
      system_callback({ code = 1 })
      vim.schedule = orig_schedule

      -- Should have fallen back to fresh_export -> request.plain
      assert.is_not_nil(last_request_plain_opts)
    end)
  end)

  -- Helper: set up a completed pre-fetch and all I/O stubs so do_render() runs
  -- when render() is called. Returns a table of captured state.
  local function setup_do_render(opts)
    opts = opts or {}
    package.loaded['image'] = {
      from_file = function(_path, _o)
        return {
          render = function() end,
          rendered_geometry = { height = 10 },
        }
      end,
    }
    vim.b.himalaya_current_email_id = '123'

    local bufnr = vim.api.nvim_get_current_buf()

    -- Complete a pre-fetch so do_render is called directly
    local system_callback
    vim.system = function(_cmd, _opts, cb)
      system_callback = cb
      return { kill = function() end }
    end
    image_mod.prefetch(bufnr, 'test', 'INBOX', '123')

    local orig_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
    system_callback({ code = 0 })
    vim.schedule = orig_schedule

    -- Stub vim.fn.glob to return an HTML file (or empty if opts.no_html)
    local orig_glob = vim.fn.glob
    vim.fn.glob = function(_pattern, _nosuf, _list)
      if opts.no_html then
        return {}
      end
      return { '/tmp/himalaya-test-tmp/email.html' }
    end

    -- Stub vim.fn.fnamemodify for inject path lookup
    local orig_fnamemodify = vim.fn.fnamemodify
    vim.fn.fnamemodify = function(_path, _mod)
      return '/fake/plugin/dir'
    end

    -- Stub io.open to return fake file handles
    local orig_io_open = io.open
    local written_files = {}
    io.open = function(path, mode)
      if path == '/tmp/himalaya-image-perf.log' then
        return orig_io_open(path, mode)
      end
      if mode == 'r' then
        return {
          read = function(_, _fmt)
            if path:match('measure_inject') then
              return '<!-- inject -->'
            end
            return '<html><body>Hello</body></html>'
          end,
          close = function() end,
        }
      elseif mode == 'w' or mode == 'wb' then
        written_files[path] = ''
        return {
          write = function(_, data)
            written_files[path] = (written_files[path] or '') .. data
          end,
          close = function() end,
        }
      end
      return orig_io_open(path, mode)
    end

    -- Track autocmd callbacks for BufWipeout
    local buf_wipeout_cb
    vim.api.nvim_create_autocmd = function(_event, au_opts)
      buf_wipeout_cb = au_opts.callback
      return 1
    end

    -- Configure vim.system for fallback path
    local fallback_system_calls = {}
    local fallback_system_cb
    vim.system = function(cmd, sys_opts, cb)
      table.insert(fallback_system_calls, { cmd = cmd, opts = sys_opts })
      fallback_system_cb = cb
      return { kill = function() end }
    end

    return {
      bufnr = bufnr,
      written_files = written_files,
      fallback_system_calls = fallback_system_calls,
      get_fallback_cb = function()
        return fallback_system_cb
      end,
      get_wipeout_cb = function()
        return buf_wipeout_cb
      end,
      restore = function()
        vim.fn.glob = orig_glob
        vim.fn.fnamemodify = orig_fnamemodify
        io.open = orig_io_open
      end,
    }
  end

  describe('do_render', function()
    it('silently returns when no HTML files found', function()
      local ctx = setup_do_render({ no_html = true })

      image_mod.render()

      assert.are.equal(0, #log_calls.warn)
      assert.are.equal(0, #log_calls.err)
      ctx.restore()
    end)

    it('injects measure snippet into HTML and writes measure.html', function()
      local ctx = setup_do_render()

      image_mod.render()

      -- measure.html should have been written with the injection
      local measure_content
      for path, content in pairs(ctx.written_files) do
        if path:match('measure%.html') then
          measure_content = content
        end
      end
      assert.is_not_nil(measure_content)
      assert.truthy(measure_content:find('inject'))
      ctx.restore()
    end)

    it('calls render_cdp which calls chrome.get_client', function()
      local get_client_called = false
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(_cb)
          get_client_called = true
        end,
      }

      local ctx = setup_do_render()
      image_mod.render()

      assert.is_true(get_client_called)
      ctx.restore()
    end)

    it('falls back to vim.system when CDP client fails', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()

      -- Simulate CDP failure
      cdp_cb('connection failed')

      vim.schedule = orig_schedule

      -- Fallback vim.system should have been called with chrome args
      assert.is_true(#ctx.fallback_system_calls > 0)
      local cmd = ctx.fallback_system_calls[1].cmd
      assert.truthy(vim.tbl_contains(cmd, '--dump-dom'))
      ctx.restore()
    end)

    it('fallback renders image on chrome success with crop', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb('fail')

      -- Now call the fallback system callback with success + content height
      vim.fn.filereadable = function(_path)
        return 1
      end

      local fallback_cb = ctx.get_fallback_cb()
      assert.is_not_nil(fallback_cb)

      -- Simulate chrome returning HTML with data-sh attribute (content < max)
      fallback_cb({ code = 0, stdout = '<div data-sh="500"></div>', stderr = '' })

      -- Should have called magick crop (second vim.system call)
      assert.are.equal(2, #ctx.fallback_system_calls)
      local crop_cmd = ctx.fallback_system_calls[2].cmd
      assert.truthy(vim.tbl_contains(crop_cmd, 'magick'))

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('fallback shows image without crop when height equals max', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local show_image_called = false
      local ctx = setup_do_render()

      -- Override _show_image to track it
      image_mod._show_image = function()
        show_image_called = true
      end

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb('fail')

      vim.fn.filereadable = function(_path)
        return 1
      end

      local fallback_cb = ctx.get_fallback_cb()
      -- No data-sh in stdout, so content_height = max_height (no crop needed)
      fallback_cb({ code = 0, stdout = '', stderr = '' })

      assert.is_true(show_image_called)
      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('fallback logs error on chrome failure', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb('fail')

      local fallback_cb = ctx.get_fallback_cb()
      fallback_cb({ code = 1, stderr = 'Chrome crashed', stdout = '' })

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('Converter failed'))

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('fallback logs error when no output produced', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb('fail')

      vim.fn.filereadable = function(_path)
        return 0
      end

      local fallback_cb = ctx.get_fallback_cb()
      fallback_cb({ code = 0, stdout = '', stderr = '' })

      assert.are.equal(1, #log_calls.err)
      assert.truthy(log_calls.err[1]:find('no output'))

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('fallback crop warns on magick failure but still shows image', function()
      local cdp_cb
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local show_image_called = false
      local ctx = setup_do_render()
      image_mod._show_image = function()
        show_image_called = true
      end

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb('fail')

      vim.fn.filereadable = function(_path)
        return 1
      end

      local fallback_cb = ctx.get_fallback_cb()
      fallback_cb({ code = 0, stdout = '<div data-sh="500"></div>', stderr = '' })

      -- Get the magick crop callback
      local crop_cb = ctx.get_fallback_cb()
      assert.is_not_nil(crop_cb)
      crop_cb({ code = 1 })

      assert.are.equal(1, #log_calls.warn)
      assert.truthy(log_calls.warn[1]:find('magick crop failed'))
      assert.is_true(show_image_called)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP full success path renders image', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local show_image_called = false
      local ctx = setup_do_render()
      image_mod._show_image = function()
        show_image_called = true
      end

      -- Stub vim.base64.decode
      local orig_base64 = vim.base64
      vim.base64 = {
        decode = function(_data)
          return 'PNG_DATA'
        end,
      }

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()

      -- Provide CDP client
      cdp_cb(nil, cdp_client)

      -- sends[1]: setDeviceMetrics
      assert.are.equal('Emulation.setDeviceMetricsOverride', cdp_client.sends[1].method)
      cdp_client.sends[1].cb(nil)

      -- sends[2]: Page.navigate
      assert.are.equal('Page.navigate', cdp_client.sends[2].method)
      cdp_client.sends[2].cb(nil, { frameId = 'F' })

      -- sends[3]: Runtime.evaluate (readyState poll)
      assert.are.equal('Runtime.evaluate', cdp_client.sends[3].method)
      assert.are.equal('document.readyState', cdp_client.sends[3].params.expression)
      cdp_client.sends[3].cb(nil, { result = { value = 'complete' } })

      -- sends[4]: Runtime.evaluate (content height measurement)
      assert.are.equal('Runtime.evaluate', cdp_client.sends[4].method)
      assert.truthy(cdp_client.sends[4].params.expression:find('data%-sh'))
      cdp_client.sends[4].cb(nil, { result = { value = '{"childrenBottom":800,"scrollHeight":800}' } })

      -- sends[5]: viewport resize to content height
      assert.are.equal('Emulation.setDeviceMetricsOverride', cdp_client.sends[5].method)
      assert.are.equal(800, cdp_client.sends[5].params.height)
      cdp_client.sends[5].cb(nil)

      -- sends[6]: captureScreenshot
      assert.are.equal('Page.captureScreenshot', cdp_client.sends[6].method)
      cdp_client.sends[6].cb(nil, { data = 'base64png' })

      assert.is_true(show_image_called)
      assert.truthy(ctx.written_files['/tmp/himalaya-test-tmp/email.png'])

      vim.schedule = orig_schedule
      vim.base64 = orig_base64
      ctx.restore()
    end)

    it('uses term cell_width for viewport with user dpr when image.utils.term available', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      -- Mock image.utils.term so the term_size branch is exercised in do_render.
      package.loaded['image.utils.term'] = {
        get_size = function()
          return { cell_width = 17, cell_height = 34 }
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()

      -- Provide CDP client
      cdp_cb(nil, cdp_client)

      -- sends[1]: setDeviceMetricsOverride
      assert.are.equal('Emulation.setDeviceMetricsOverride', cdp_client.sends[1].method)
      -- viewport = win_width (80) * cell_width (17) / dpr (2) = 680
      assert.are.equal(680, cdp_client.sends[1].params.width)
      -- dpr stays at config value (2)
      assert.are.equal(2, cdp_client.sends[1].params.deviceScaleFactor)

      vim.schedule = orig_schedule
      package.loaded['image.utils.term'] = nil
      ctx.restore()
    end)

    it('CDP stale render is cancelled after get_client', function()
      local cdp_cbs = {}
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          table.insert(cdp_cbs, cb)
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      -- First render
      image_mod.render()
      -- Second render supersedes the first (increments gen)
      image_mod.render()

      -- Complete the first render's CDP client callback — should bail (stale)
      cdp_cbs[1](nil, cdp_client)
      -- No sends should have been made because is_stale() returns true
      assert.are.equal(0, #cdp_client.sends)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP setDeviceMetrics failure falls back', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb(nil, cdp_client)

      -- setDeviceMetrics fails
      cdp_client.sends[1].cb('metrics error')

      -- Should have fallen back to vim.system
      assert.is_true(#ctx.fallback_system_calls > 0)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP evaluate failure falls back', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb(nil, cdp_client)
      cdp_client.sends[1].cb(nil) -- metrics ok
      cdp_client.sends[2].cb(nil, { frameId = 'F' }) -- navigate ok
      -- sends[3]: readyState poll → complete
      cdp_client.sends[3].cb(nil, { result = { value = 'complete' } })
      -- sends[4]: scrollHeight evaluate fails
      cdp_client.sends[4].cb('eval error')

      assert.is_true(#ctx.fallback_system_calls > 0)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP screenshot failure falls back', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb(nil, cdp_client)
      cdp_client.sends[1].cb(nil) -- metrics ok
      cdp_client.sends[2].cb(nil, { frameId = 'F' }) -- navigate ok
      -- sends[3]: readyState poll → complete
      cdp_client.sends[3].cb(nil, { result = { value = 'complete' } })
      -- sends[4]: content height measurement
      cdp_client.sends[4].cb(nil, { result = { value = '{"childrenBottom":800,"scrollHeight":800}' } })
      -- sends[5]: viewport resize
      cdp_client.sends[5].cb(nil)
      -- sends[6]: screenshot fails
      cdp_client.sends[6].cb('screenshot error')

      assert.is_true(#ctx.fallback_system_calls > 0)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP navigate failure falls back', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb(nil, cdp_client)
      cdp_client.sends[1].cb(nil) -- metrics ok
      cdp_client.sends[2].cb('nav error') -- navigate fails

      assert.is_true(#ctx.fallback_system_calls > 0)

      vim.schedule = orig_schedule
      ctx.restore()
    end)

    it('CDP PNG write failure falls back', function()
      local cdp_cb
      local cdp_client = {
        sends = {},
        send = function(self, method, params, cb)
          table.insert(self.sends, { method = method, params = params, cb = cb })
        end,
      }
      package.loaded['himalaya.domain.email.chrome'] = {
        get_client = function(cb)
          cdp_cb = cb
        end,
      }

      local ctx = setup_do_render()

      -- Override io.open to return nil for PNG writes
      local orig_io_open = io.open
      io.open = function(path, mode)
        if mode == 'wb' then
          return nil
        end
        return orig_io_open(path, mode)
      end

      local orig_base64 = vim.base64
      vim.base64 = {
        decode = function(_data)
          return 'PNG_DATA'
        end,
      }

      local orig_schedule = vim.schedule
      vim.schedule = function(fn)
        fn()
      end

      image_mod.render()
      cdp_cb(nil, cdp_client)
      cdp_client.sends[1].cb(nil) -- metrics ok
      cdp_client.sends[2].cb(nil, { frameId = 'F' }) -- navigate ok
      -- sends[3]: readyState poll → complete
      cdp_client.sends[3].cb(nil, { result = { value = 'complete' } })
      -- sends[4]: content height measurement
      cdp_client.sends[4].cb(nil, { result = { value = '{"childrenBottom":800,"scrollHeight":800}' } })
      -- sends[5]: viewport resize
      cdp_client.sends[5].cb(nil)
      -- sends[6]: screenshot ok
      cdp_client.sends[6].cb(nil, { data = 'base64png' })

      assert.is_true(#ctx.fallback_system_calls > 0)

      vim.schedule = orig_schedule
      vim.base64 = orig_base64
      io.open = orig_io_open
      ctx.restore()
    end)

    it('BufWipeout callback clears images and defers tmpdir deletion', function()
      local defer_fn_called = false
      local orig_defer_fn = vim.defer_fn
      vim.defer_fn = function(fn, _ms)
        defer_fn_called = true
        fn()
      end

      local deleted_dirs = {}
      vim.fn.delete = function(dir, flags)
        table.insert(deleted_dirs, { dir = dir, flags = flags })
      end

      local ctx = setup_do_render()

      -- Override autocmd AFTER setup_do_render (which sets its own)
      local wipeout_cb
      vim.api.nvim_create_autocmd = function(_event, au_opts)
        wipeout_cb = au_opts.callback
        return 1
      end

      image_mod.render()

      -- Set image module with get_images AFTER render (so pcall(require, 'image') finds it)
      local images_cleared = 0
      package.loaded['image'] = {
        from_file = function()
          return { render = function() end, rendered_geometry = { height = 10 } }
        end,
        get_images = function(_opts)
          return {
            {
              clear = function()
                images_cleared = images_cleared + 1
              end,
            },
          }
        end,
      }

      -- Get and invoke the BufWipeout callback
      assert.is_not_nil(wipeout_cb)
      wipeout_cb()

      assert.are.equal(1, images_cleared)
      assert.is_true(defer_fn_called)
      assert.is_true(#deleted_dirs > 0)

      vim.defer_fn = orig_defer_fn
      ctx.restore()
    end)

    it('fresh_export on_data callback invokes do_render', function()
      package.loaded['image'] = { from_file = function() end }
      vim.b.himalaya_current_email_id = '123'

      -- No pre-fetch state, so fresh_export will be called
      local plain_opts
      package.loaded['himalaya.request'] = {
        json = function() end,
        plain = function(opts)
          plain_opts = opts
        end,
        _build_cmd = function(_fmt, _args, _mode)
          return { 'himalaya', 'message', 'export' }
        end,
      }
      -- Reload to pick up new request mock
      package.loaded['himalaya.domain.email.image'] = nil
      image_mod = require('himalaya.domain.email.image')

      -- Stub glob and io.open for when do_render runs
      local orig_glob = vim.fn.glob
      vim.fn.glob = function(_pattern, _nosuf, _list)
        return {}
      end

      image_mod.render()

      assert.is_not_nil(plain_opts)
      assert.is_not_nil(plain_opts.on_data)

      -- Call on_data to trigger do_render
      plain_opts.on_data()

      -- do_render ran and found no HTML -> silently returns
      assert.are.equal(0, #log_calls.warn)
      assert.are.equal(0, #log_calls.err)

      vim.fn.glob = orig_glob
    end)
  end)

  describe('clear', function()
    it('restores saved lines and resets state', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '', '', '' })
      vim.bo[bufnr].modifiable = false

      vim.b[bufnr].himalaya_saved_lines = { 'original line 1', 'original line 2' }
      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_image_png = '/tmp/test.png'

      -- Stub image.nvim for clear
      local images_cleared = 0
      package.loaded['image'] = {
        get_images = function(_opts)
          return {
            {
              clear = function()
                images_cleared = images_cleared + 1
              end,
            },
          }
        end,
      }

      image_mod.clear(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.same({ 'original line 1', 'original line 2' }, lines)
      assert.is_false(vim.b[bufnr].himalaya_image_rendered)
      assert.is_nil(vim.b[bufnr].himalaya_saved_lines)
      assert.are.equal(1, images_cleared)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('defaults to current buffer when bufnr is nil', function()
      local bufnr = vim.api.nvim_get_current_buf()
      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_saved_lines = { 'saved' }

      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
      vim.bo[bufnr].modifiable = false

      -- No image.nvim loaded, pcall will fail gracefully
      package.loaded['image'] = nil

      image_mod.clear()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.same({ 'saved' }, lines)
      assert.is_false(vim.b[bufnr].himalaya_image_rendered)
    end)

    it('returns early for invalid buffer', function()
      -- Should not error
      image_mod.clear(99999)
    end)

    it('restores winbar when window is valid', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = 80,
        height = 20,
        row = 0,
        col = 0,
      })

      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_original_winbar = 'my winbar'

      vim.fn.bufwinid = function(_b)
        return winid
      end

      package.loaded['image'] = nil

      image_mod.clear(bufnr)

      assert.are.equal('my winbar', vim.wo[winid].winbar)
      assert.is_nil(vim.b[bufnr].himalaya_original_winbar)

      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('skips winbar restore when window is invalid', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_original_winbar = 'my winbar'

      -- bufwinid returns -1 (no window)
      vim.fn.bufwinid = function(_b)
        return -1
      end

      package.loaded['image'] = nil

      image_mod.clear(bufnr)

      -- original_winbar should still be set (not cleared) since window was invalid
      -- Actually, the code checks winid ~= -1, so it won't clear it
      assert.are.equal('my winbar', vim.b[bufnr].himalaya_original_winbar)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('handles missing saved_lines gracefully', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'current' })
      vim.bo[bufnr].modifiable = false

      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_saved_lines = nil

      package.loaded['image'] = nil

      image_mod.clear(bufnr)

      -- Buffer content should be unchanged since there's nothing to restore
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.same({ 'current' }, lines)
      assert.is_false(vim.b[bufnr].himalaya_image_rendered)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
