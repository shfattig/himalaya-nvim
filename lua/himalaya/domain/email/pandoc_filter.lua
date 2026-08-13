-- Pandoc Lua filter (not a neovim module - loaded by the external `pandoc`
-- binary via --lua-filter, in its own Lua environment) for html_view.lua's
-- `gh` conversion.
--
-- Marketing/notification emails are almost always one giant HTML <table>
-- used purely for layout, not real tabular data. Left alone, pandoc's
-- table-aware writers (including `plain`) render that as a literal ASCII
-- grid - box-drawing borders plus every cell padded out to the width of
-- the widest line in the whole email, which for a full-width layout table
-- is the entire message. That's the "wall of spaces and pipes" a real
-- table renderer produces; flattening each row's cells into plain
-- paragraphs instead gives normal flowing text.
local function flatten_row(row, out)
  for _, cell in ipairs(row.cells) do
    for _, blk in ipairs(cell.contents) do
      table.insert(out, blk)
    end
  end
end

function Table(tbl)
  local out = {}
  if tbl.head and tbl.head.rows then
    for _, row in ipairs(tbl.head.rows) do
      flatten_row(row, out)
    end
  end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      flatten_row(row, out)
    end
  end
  if tbl.foot and tbl.foot.rows then
    for _, row in ipairs(tbl.foot.rows) do
      flatten_row(row, out)
    end
  end
  return out
end

-- 1x1 tracking-pixel <img>s have no alt text and render as a bare,
-- meaningless "[]" - drop them. Images with real alt text (icon labels
-- etc.) are left alone; alt text is the only thing standing in for them
-- in a plain-text view anyway.
function Image(img)
  if #img.caption == 0 then
    return {}
  end
  return img
end
