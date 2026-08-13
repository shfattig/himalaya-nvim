describe('himalaya.domain.email.html_view', function()
  local html_view

  before_each(function()
    package.loaded['himalaya.domain.email.html_view'] = nil
    html_view = require('himalaya.domain.email.html_view')
  end)

  describe('to_text', function()
    it('strips tags and decodes entities', function()
      local lines = html_view.to_text('<p>Hello &amp; welcome, <b>friend</b>!</p>')
      assert.same({ 'Hello & welcome, **friend**!' }, lines)
    end)

    it('converts headings and paragraphs into separated lines', function()
      local lines = html_view.to_text('<h1>Title</h1><p>Body one.</p><p>Body two.</p>')
      assert.same({ '# Title', '', 'Body one.', '', 'Body two.' }, lines)
    end)

    it('converts links to "text (url)"', function()
      local lines = html_view.to_text('<a href="https://x.com/y">Click here</a>')
      assert.same({ 'Click here (https://x.com/y)' }, lines)
    end)

    it('falls back to the bare url when the link has no text', function()
      local lines = html_view.to_text('<a href="https://x.com/y"></a>')
      assert.same({ 'https://x.com/y' }, lines)
    end)

    it('converts list items to dashed lines', function()
      local lines = html_view.to_text('<ul><li>One</li><li>Two</li></ul>')
      assert.same({ '- One', '- Two' }, lines)
    end)

    it('drops script and style blocks entirely', function()
      local lines = html_view.to_text('<style>.x{color:red}</style><script>alert(1)</script><p>Real content</p>')
      assert.same({ 'Real content' }, lines)
    end)

    it('collapses runs of blank lines to at most one', function()
      local lines = html_view.to_text('<p>A</p><br><br><br><p>B</p>')
      for _, line in ipairs(lines) do
        assert.is_falsy(line == '' and lines[1] == '')
      end
      local blank_run = 0
      for _, line in ipairs(lines) do
        if line == '' then
          blank_run = blank_run + 1
          assert.is_true(blank_run <= 1)
        else
          blank_run = 0
        end
      end
    end)

    it('trims leading and trailing blank lines', function()
      local lines = html_view.to_text('<br><br><p>content</p><br><br>')
      assert.are.equal('content', lines[1])
      assert.are.equal('content', lines[#lines])
    end)
  end)

  describe('fetch_html', function()
    local captured

    before_each(function()
      captured = nil
      package.loaded['himalaya.request'] = {
        json = function(opts)
          captured = opts
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function(acct)
          return acct == '' and {} or { '--account', acct }
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')
    end)

    it('issues a message read --json request for the given id', function()
      html_view.fetch_html('acct', 'INBOX', '42', function() end)
      assert.is_not_nil(captured)
      assert.is_truthy(captured.cmd:find('message read'))
      assert.are.equal('42', captured.args[3])
    end)

    it('resolves the HTML part accounting for the 0-based -> 1-based index shift', function()
      local result
      html_view.fetch_html('acct', 'INBOX', '42', function(html)
        result = html
      end)
      captured.on_data({
        html_body = { 1 },
        parts = {
          { body = { Text = 'plain text part' } },
          { body = { Html = '<p>html part</p>' } },
        },
      })
      assert.are.equal('<p>html part</p>', result)
    end)

    it('calls back with nil when the message has no HTML part', function()
      local result, called = 'unset', false
      html_view.fetch_html('acct', 'INBOX', '42', function(html)
        result = html
        called = true
      end)
      captured.on_data({ html_body = {}, parts = {} })
      assert.is_true(called)
      assert.is_nil(result)
    end)

    it('calls back with nil on fetch error', function()
      local result, called = 'unset', false
      html_view.fetch_html('acct', 'INBOX', '42', function(html)
        result = html
        called = true
      end)
      captured.on_error()
      assert.is_true(called)
      assert.is_nil(result)
    end)
  end)

  describe('convert', function()
    local orig_executable, orig_system

    before_each(function()
      orig_executable = vim.fn.executable
      orig_system = vim.system
    end)

    after_each(function()
      vim.fn.executable = orig_executable
      vim.system = orig_system
    end)

    it('falls back to the bespoke parser when pandoc is not on PATH', function()
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 0 or orig_executable(bin)
      end
      local result
      html_view.convert('<p>Hello <b>there</b></p>', function(lines)
        result = lines
      end)
      assert.same({ 'Hello **there**' }, result)
    end)

    it('uses pandoc output when available', function()
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 1 or orig_executable(bin)
      end
      local captured_cmd, captured_opts
      vim.system = function(cmd, opts, cb)
        captured_cmd, captured_opts = cmd, opts
        cb({ code = 0, stdout = 'Hello there\n', stderr = '' })
        return {}
      end
      local result
      html_view.convert('<p>Hello <b>there</b></p>', function(lines)
        result = lines
      end)
      vim.wait(10, function()
        return result ~= nil
      end)
      assert.are.equal('pandoc', captured_cmd[1])
      assert.are.equal('<p>Hello <b>there</b></p>', captured_opts.stdin)
      assert.same({ 'Hello there' }, result)
    end)

    it('falls back to the bespoke parser when pandoc fails', function()
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 1 or orig_executable(bin)
      end
      vim.system = function(_cmd, _opts, cb)
        cb({ code = 1, stdout = '', stderr = 'pandoc: error' })
        return {}
      end
      local result
      html_view.convert('<p>Hello <b>there</b></p>', function(lines)
        result = lines
      end)
      vim.wait(10, function()
        return result ~= nil
      end)
      assert.same({ 'Hello **there**' }, result)
    end)
  end)

  describe('toggle', function()
    local bufnr, orig_executable

    before_each(function()
      package.loaded['himalaya.log'] = {
        info = function() end,
        err = function() end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')

      -- Force the bespoke fallback path regardless of whether the host
      -- running these tests happens to have pandoc installed, so these
      -- assertions stay deterministic.
      orig_executable = vim.fn.executable
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 0 or orig_executable(bin)
      end

      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'Date:    Wed, 12 Aug 2026 10:00:00 -0600',
        'From:    a@x.com',
        'Delivered-To: a@x.com',
        '',
        'Original plain body',
      })
      vim.b[bufnr].himalaya_header_fold_range = { 3, 3 }
      vim.b[bufnr].himalaya_account = 'acct'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_current_email_id = '42'
    end)

    after_each(function()
      vim.fn.executable = orig_executable
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('is a no-op when required buffer context is missing', function()
      local empty = vim.api.nvim_create_buf(false, true)
      assert.has_no.errors(function()
        html_view.toggle(empty)
      end)
      vim.api.nvim_buf_delete(empty, { force = true })
    end)

    it('replaces the body with converted HTML text, then restores it on second toggle', function()
      package.loaded['himalaya.request'] = {
        json = function(opts)
          opts.on_data({
            html_body = { 0 },
            parts = { { body = { Html = '<p>Rendered <b>HTML</b> body</p>' } } },
          })
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function()
          return {}
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')

      html_view.toggle(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Rendered **HTML** body', lines[#lines])
      assert.is_true(vim.b[bufnr].himalaya_html_view)

      html_view.toggle(bufnr)
      local restored = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Original plain body', restored[#restored])
      assert.is_falsy(vim.b[bufnr].himalaya_html_view)
    end)

    it('leaves the buffer untouched when the message has no HTML part', function()
      package.loaded['himalaya.request'] = {
        json = function(opts)
          opts.on_data({ html_body = {}, parts = {} })
        end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function()
          return {}
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')

      html_view.toggle(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Original plain body', lines[#lines])
      assert.is_falsy(vim.b[bufnr].himalaya_html_view)
    end)
  end)

  describe('prefer_if_available', function()
    local bufnr, orig_executable

    before_each(function()
      package.loaded['himalaya.log'] = {
        info = function() end,
        err = function() end,
      }
      package.loaded['himalaya.state.account'] = {
        flag = function()
          return {}
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil

      orig_executable = vim.fn.executable
      vim.fn.executable = function(bin)
        return bin == 'pandoc' and 0 or orig_executable(bin)
      end

      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'Date:    Wed, 12 Aug 2026 10:00:00 -0600',
        '',
        'Original plain body',
      })
      vim.b[bufnr].himalaya_header_fold_range = { 1, 1 }
      vim.b[bufnr].himalaya_account = 'acct'
      vim.b[bufnr].himalaya_folder = 'INBOX'
      vim.b[bufnr].himalaya_current_email_id = '42'
    end)

    after_each(function()
      vim.fn.executable = orig_executable
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    local function stub_html(html)
      package.loaded['himalaya.request'] = {
        json = function(opts)
          if html then
            opts.on_data({ html_body = { 0 }, parts = { { body = { Html = html } } } })
          else
            opts.on_data({ html_body = {}, parts = {} })
          end
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')
    end

    it('silently applies the HTML view when an HTML part exists', function()
      stub_html('<p>Rendered <b>HTML</b> body</p>')
      html_view.prefer_if_available(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Rendered **HTML** body', lines[#lines])
      assert.is_true(vim.b[bufnr].himalaya_html_view)
    end)

    it('silently no-ops when there is no HTML part (no notification)', function()
      stub_html(nil)
      local notified = false
      package.loaded['himalaya.log'].info = function()
        notified = true
      end
      html_view.prefer_if_available(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Original plain body', lines[#lines])
      assert.is_falsy(vim.b[bufnr].himalaya_html_view)
      assert.is_false(notified)
    end)

    it('no-ops when already toggled to the HTML view', function()
      vim.b[bufnr].himalaya_html_view = true
      local called = false
      package.loaded['himalaya.request'] = {
        json = function()
          called = true
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')
      html_view.prefer_if_available(bufnr)
      assert.is_false(called)
    end)

    it('no-ops when required buffer context is missing', function()
      local empty = vim.api.nvim_create_buf(false, true)
      assert.has_no.errors(function()
        html_view.prefer_if_available(empty)
      end)
      vim.api.nvim_buf_delete(empty, { force = true })
    end)

    it('discards a stale result if the buffer now shows a different email', function()
      package.loaded['himalaya.request'] = {
        json = function(opts)
          -- Simulate the buffer having been reused for a different email
          -- while this "network" call was in flight.
          vim.b[bufnr].himalaya_current_email_id = '99'
          opts.on_data({
            html_body = { 0 },
            parts = { { body = { Html = '<p>Stale content</p>' } } },
          })
        end,
      }
      package.loaded['himalaya.domain.email.html_view'] = nil
      html_view = require('himalaya.domain.email.html_view')

      html_view.prefer_if_available(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('Original plain body', lines[#lines])
      assert.is_falsy(vim.b[bufnr].himalaya_html_view)
    end)
  end)
end)
