describe('himalaya.domain.email.headers', function()
  local headers = require('himalaya.domain.email.headers')

  describe('parse', function()
    it('extracts known fields and finds the blank-line boundary', function()
      local lines = {
        'Delivered-To: shfattig@gmail.com',
        'From: Progressive <customerservice@e.progressive.com>',
        'To: shfattig@gmail.com',
        'Subject: Policy change',
        'Date: Wed, 12 Aug 2026 19:00:40 -0600',
        '',
        'Hello there.',
      }
      local known, blank_idx = headers.parse(lines)
      assert.equals('Progressive <customerservice@e.progressive.com>', known.From)
      assert.equals('shfattig@gmail.com', known.To)
      assert.equals('Policy change', known.Subject)
      assert.equals('Wed, 12 Aug 2026 19:00:40 -0600', known.Date)
      assert.is_nil(known.Cc)
      assert.equals(6, blank_idx)
    end)

    it('folds continuation lines into the preceding known field', function()
      local lines = {
        'Subject: a very long subject that got',
        '  wrapped onto a second line',
        '',
        'body',
      }
      local known = headers.parse(lines)
      assert.equals('a very long subject that got wrapped onto a second line', known.Subject)
    end)

    it('ignores continuations of unknown headers', function()
      local lines = {
        'ARC-Seal: i=1; a=rsa-sha256;',
        '  d=google.com; s=arc-20260327;',
        'Subject: real subject',
        '',
        'body',
      }
      local known = headers.parse(lines)
      assert.equals('real subject', known.Subject)
      assert.is_nil(known['ARC-Seal'])
    end)

    it('handles no headers at all (blank_idx stays past end)', function()
      local lines = { 'just a body line' }
      local known, blank_idx = headers.parse(lines)
      assert.same({}, known)
      assert.equals(2, blank_idx)
    end)
  end)

  describe('render', function()
    it('prepends a structured summary and returns the fold range for the raw block', function()
      local lines = {
        'Delivered-To: shfattig@gmail.com',
        'From: Alice <alice@example.com>',
        'To: bob@example.com',
        'Subject: Hi',
        'Date: Wed, 12 Aug 2026 19:00:40 -0600',
        '',
        'Hello.',
      }
      local out, fold_start, fold_end = headers.render(lines)

      -- Structured summary lines come first, in fixed order.
      assert.equals('Date:    Wed, 12 Aug 2026 19:00:40 -0600', out[1])
      assert.equals('From:    Alice <alice@example.com>', out[2])
      assert.equals('To:      bob@example.com', out[3])
      assert.equals('Subject: Hi', out[4])

      -- Raw header block follows intact, then the body.
      assert.equals(5, fold_start)
      assert.equals(9, fold_end)
      assert.equals('Delivered-To: shfattig@gmail.com', out[fold_start])
      assert.equals('Date: Wed, 12 Aug 2026 19:00:40 -0600', out[fold_end])
      assert.equals('', out[fold_end + 1])
      assert.equals('Hello.', out[#out])
    end)

    it('omits the summary but still folds raw headers when no known fields are found', function()
      local lines = { 'X-Custom: value', '', 'body' }
      local out, fold_start, fold_end = headers.render(lines)
      assert.equals('X-Custom: value', out[1])
      assert.equals(1, fold_start)
      assert.equals(1, fold_end)
      assert.equals('body', out[#out])
    end)

    it('returns nil fold range when the blank separator is the first line', function()
      local lines = { '', 'just a body' }
      local out, fold_start, fold_end = headers.render(lines)
      assert.same({ '', 'just a body' }, out)
      assert.is_nil(fold_start)
      assert.is_nil(fold_end)
    end)
  end)
end)
