describe('himalaya.domain.email.flags', function()
  local flags
  local config

  before_each(function()
    package.loaded['himalaya.domain.email.flags'] = nil
    package.loaded['himalaya.config'] = nil
    config = require('himalaya.config')
    config._reset()
    flags = require('himalaya.domain.email.flags')
  end)

  it('returns default flags', function()
    -- Lowercase, matching himalaya v2's `--flag <FLAG>` values - 'deleted'
    -- isn't one of them, so it's not in the list.
    local result = flags.complete_list()
    assert.is_truthy(vim.tbl_contains(result, 'seen'))
    assert.is_truthy(vim.tbl_contains(result, 'answered'))
    assert.is_truthy(vim.tbl_contains(result, 'flagged'))
    assert.is_truthy(vim.tbl_contains(result, 'draft'))
    assert.is_falsy(vim.tbl_contains(result, 'deleted'))
  end)

  it('includes custom flags from config', function()
    config.setup({ custom_flags = { 'Important', 'Urgent' } })
    local result = flags.complete_list()
    assert.is_truthy(vim.tbl_contains(result, 'Important'))
    assert.is_truthy(vim.tbl_contains(result, 'Urgent'))
    assert.is_truthy(vim.tbl_contains(result, 'seen'))
  end)

  describe('is_unseen', function()
    it('returns false when flags is nil (unknown state)', function()
      assert.is_false(flags.is_unseen({}))
    end)

    it('returns true when Seen flag is absent', function()
      assert.is_true(flags.is_unseen({ flags = { 'Answered' } }))
    end)

    it('returns false when Seen flag is present', function()
      assert.is_false(flags.is_unseen({ flags = { 'Seen' } }))
    end)

    it('returns false when Seen is among multiple flags', function()
      assert.is_false(flags.is_unseen({ flags = { 'Answered', 'Seen', 'Flagged' } }))
    end)

    -- himalaya v2 returns each flags-array entry as {raw = "\\Seen", iana =
    -- "seen"}, not a bare string - confirmed against a real Gmail account.
    -- A bare-string comparison here would silently treat every message as
    -- unseen forever, which is exactly what shipped before this test.
    it('returns false when Seen is present as a real v2 {raw, iana} table', function()
      assert.is_false(flags.is_unseen({ flags = { { raw = '\\Seen', iana = 'seen' } } }))
    end)

    it('returns true when only non-Seen v2 {raw, iana} tables are present', function()
      assert.is_true(flags.is_unseen({ flags = { { raw = '\\Answered', iana = 'answered' } } }))
    end)
  end)

  describe('flag_name', function()
    it('passes bare strings through lowercased', function()
      assert.are.equal('seen', flags.flag_name('Seen'))
    end)

    it('extracts and lowercases the iana name from a v2 {raw, iana} table', function()
      assert.are.equal('seen', flags.flag_name({ raw = '\\Seen', iana = 'seen' }))
    end)

    it('falls back to a stripped, lowercased raw name when iana is absent', function()
      assert.are.equal('seen', flags.flag_name({ raw = '\\Seen' }))
    end)
  end)

  describe('has', function()
    it('finds a flag among mixed bare-string and v2 table entries', function()
      local mixed = { 'Answered', { raw = '\\Seen', iana = 'seen' } }
      assert.is_true(flags.has(mixed, 'seen'))
      assert.is_true(flags.has(mixed, 'ANSWERED'))
      assert.is_false(flags.has(mixed, 'flagged'))
    end)

    it('returns false for nil or empty flags', function()
      assert.is_false(flags.has(nil, 'seen'))
      assert.is_false(flags.has({}, 'seen'))
    end)
  end)

  describe('is_seen', function()
    it('returns true when flags is nil (unknown treated as not-unseen)', function()
      assert.is_true(flags.is_seen({}))
    end)

    it('returns true when Seen flag is present', function()
      assert.is_true(flags.is_seen({ flags = { 'Seen' } }))
    end)
  end)

  describe('count_unseen', function()
    it('counts envelopes without Seen flag', function()
      local envelopes = {
        { flags = { 'Seen' } },
        { flags = { 'Answered' } },
        {},
        { flags = { 'Seen', 'Flagged' } },
      }
      assert.equals(1, flags.count_unseen(envelopes))
    end)

    it('returns 0 for empty list', function()
      assert.equals(0, flags.count_unseen({}))
    end)
  end)

  describe('debug_flags', function()
    after_each(function()
      vim.g.himalaya_debug = nil
    end)

    it('is a no-op when himalaya_debug is unset', function()
      flags.debug_flags('test', { { flags = { 'Seen' } } })
    end)

    it('logs seen, unseen, and unknown counts', function()
      vim.g.himalaya_debug = true
      local orig_echo = vim.api.nvim_echo
      vim.api.nvim_echo = function() end
      flags.debug_flags('test', {
        { flags = { 'Seen' } },
        { flags = { 'Answered' } },
        {},
      })
      vim.api.nvim_echo = orig_echo
    end)
  end)

  describe('debug_flags_rows', function()
    after_each(function()
      vim.g.himalaya_debug = nil
    end)

    it('is a no-op when himalaya_debug is unset', function()
      flags.debug_flags_rows('test', { { env = { flags = { 'Seen' } } } })
    end)

    it('extracts envs from rows and logs', function()
      vim.g.himalaya_debug = true
      local orig_echo = vim.api.nvim_echo
      vim.api.nvim_echo = function() end
      flags.debug_flags_rows('test', {
        { env = { flags = { 'Seen' } } },
        { env = {} },
      })
      vim.api.nvim_echo = orig_echo
    end)
  end)

  describe('count_unseen_rows', function()
    it('counts rows whose .env lacks Seen flag', function()
      local rows = {
        { env = { flags = { 'Seen' } } },
        { env = { flags = { 'Answered' } } },
        { env = {} },
        { env = { flags = { 'Seen', 'Flagged' } } },
      }
      assert.equals(1, flags.count_unseen_rows(rows))
    end)

    it('returns 0 for empty list', function()
      assert.equals(0, flags.count_unseen_rows({}))
    end)
  end)
end)
