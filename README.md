<div align="center">
  <img src="./logo.svg" alt="Logo" width="128" height="128" />
  <h1>Himalaya Nvim</h1>
  <p>Neovim front-end for the email client <a href="https://github.com/xav-ie/himalaya">Himalaya CLI</a></p>
  <p><em>🌱 A heavily modified fork of <a href="https://github.com/pimalaya/himalaya-vim">pimalaya/himalaya-vim</a></em></p>
  <p>
    <a href="https://github.com/xav-ie/himalaya/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/xav-ie/himalaya?color=success"/></a>
    <a href="https://github.com/xav-ie/himalaya-nvim/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/xav-ie/himalaya-nvim/actions/workflows/ci.yml/badge.svg"/></a>
  </p>
</div>

<!-- GEN:media src="himalaya" alt="Himalaya demo" -->
<img src="https://himalaya-nvim.xav.ie/himalaya.svg?v=1" width="100%" alt="Himalaya demo">
<p align="center"><a href="https://himalaya-nvim.xav.ie/himalaya.mp4?v=1">▶ Watch as video</a></p>
<!-- /GEN:media -->

## Features

- **Flat envelope listing** — adaptive column layout, pagination, flag indicators, unread highlighting
- **Threaded view** — Unicode tree connectors, reverse toggle, per-thread grouping
- **Structured search** — popup with per-field input, field negation, date presets, live query preview
- **Sort toggle** — sort by date, from, subject, or to in ascending/descending order
- **Email reading** — split view with quoted-text folding and `]]`/`[[` navigation between emails
- **Inline HTML rendering** — render an email as an image (kitty/ghostty) with smooth full-width scrolling and dark mode, plus a hybrid layer to hover/copy/open/search its links and text
- **Composing** — write, reply, reply-all, forward with auto-save drafts and contact completion
- **Flag management** — mark seen/unseen, add/remove arbitrary flags, visual-mode bulk operations
- **Folder operations** — switch folders, copy/move emails between folders
- **Per-account signatures** — global or per-account email signatures
- **Background sync** — periodic re-fetch while idle
- **Events system** — hook into `EmailsListed`, `EmailRead`, `ComposeOpened`, and more
- **Picker integration** — native, fzf, fzf-lua, or Telescope for account/folder selection
- **Mock mode** — try the plugin without a real email account or CLI binary

## Requirements

- Neovim >= 0.10
- [Himalaya CLI](https://pimalaya.org/himalaya/cli/latest/installation/) (not needed in mock mode)

**Optional picker integrations** (auto-detected if installed):
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)
- [fzf.vim](https://github.com/junegunn/fzf.vim)

Falls back to a built-in native picker if none are present.

**Optional inline HTML image rendering** (render emails as images, see
[HTML image rendering](#html-image-rendering)):
- the **[xav-ie fork of image.nvim](https://github.com/xav-ie/image.nvim)** — **required**, *not* upstream image.nvim, which lacks the unicode-placeholder, preload, and batched-write support this feature relies on; on a kitty/ghostty graphics terminal
- `chrome-headless-shell` (or a compatible headless browser)
- ImageMagick (`magick`)

## Installation

Install and configure the [Himalaya CLI](https://github.com/xav-ie/himalaya), then add
the plugin with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'xav-ie/himalaya-nvim',
  cmd = 'Himalaya',
  config = function()
    require('himalaya').setup({})
  end,
}
```

> **Note:** `require('himalaya').setup()` is required. It validates the CLI binary and applies configuration.

> **Try it without an account:** pass `mock = true` to explore the full UI with built-in sample data — no CLI binary or email account needed. See [mock mode](#mock-mode) in CONTRIBUTING.md.

## Configuration

All options with their defaults:

<!-- GEN:config -->
```lua
require('himalaya').setup({
  -- Path to the himalaya CLI binary
  executable = 'himalaya',

  -- Path to a custom himalaya config file (nil = CLI default)
  config_path = nil,

  -- Folder/account picker: 'native', 'fzf', 'fzf-lua', or 'telescope'
  -- nil = auto-detect (telescope > fzf-lua > fzf > native)
  folder_picker = nil,

  -- Show preview in Telescope picker
  telescope_preview = false,

  -- Shell command for contact completion (omnifunc); %s = query
  complete_contact_cmd = nil,

  -- Additional flags for flag completion
  custom_flags = {},

  -- Prompt before destructive actions (delete, move)
  always_confirm = true,

  -- Mailbox delete() moves messages to (himalaya's `message delete` no
  -- longer exists - deleting is moving to trash, same as most webmail).
  -- Resolved through the account's [mailbox.alias] map, so this only needs
  -- changing if an account's config doesn't alias 'trash' to something.
  trash_mailbox = 'trash',

  -- Flag display characters in the listing
  flags = {
    header = 'FLGS',
    flagged = '!',
    unseen = '*',
    answered = 'R',
    attachment = '@',
  },

  -- Compact flags into the subject column instead of a separate column.
  -- nil/false: never (5-column layout), true: when narrow, "always": always.
  compact_flags = true,

  -- Compact IDs: remove the ID column and reclaim its width for the subject.
  -- nil/false: never, true: when narrow, "always": always.
  compact_ids = nil,

  -- Show vertical separators between columns
  gutters = true,

  -- Date format (strftime)
  date_format = '%Y-%m-%d %H:%M',

  -- Compact date format used when the listing is too narrow for the full FROM column.
  compact_date_format = '%m/%d',

  -- Start in thread view instead of flat listing
  thread_view = false,

  -- Show newest messages at top in thread view
  thread_reverse = false,

  -- Named search presets for quick access via g?
  search_presets = {},

  -- Override default keybinds (key = plug-name, value = key or false)
  keymaps = {},

  -- Periodically re-fetch envelopes in the background
  background_sync = false,

  -- Background sync interval in seconds
  sync_interval = 60,

  -- Per-account email signatures: string or { account_name = string }
  signature = nil,

  -- This account's own email address(es), used by reply_all() to exclude
  -- yourself from the Cc list it computes. himalaya has no way to expose
  -- an OAuth-backed account's address (e.g. Gmail's `user-id = "me"`), so
  -- it can't be inferred automatically. string, string[], or
  -- { account_name = string|string[] }. nil = skip self-filtering (your
  -- own address may then show up in the computed Cc list).
  own_email = nil,

  -- Reading pane split configuration.
  -- threshold: listing width at which 'over' vs 'under' is chosen.
  -- size: 0.0–1.0 = fraction of space; >1 = absolute cols/rows (shared default)
  -- over/under: direction string ('left'|'right'|'above'|'below')
  --   or table { side = direction, size = number } to override size per branch.
  reading_split = {
    threshold = 115,
    size = 0.6,
    over = 'right',
    under = 'below',
  },

  -- HTML image rendering. REQUIRES the xav-ie fork of image.nvim
  -- (https://github.com/xav-ie/image.nvim) — upstream image.nvim lacks the
  -- unicode-placeholder, preload, and batched-write support this relies on —
  -- plus chrome-headless-shell and ImageMagick (magick).
  -- binary: path to chrome-headless-shell (or compatible headless browser).
  -- pixels_per_column: scale factor to convert buffer columns to viewport
  --   pixels (default 8). Increase for sharper text on HiDPI displays.
  render_html = {
    binary = 'chrome-headless-shell',
    pixels_per_column = 8,
    device_scale_factor = 2,
    max_screenshot_height = 5000,
    -- Content zoom, as a percentage. The on-screen display area is fixed; zoom
    -- controls the CSS width the email is laid out at, hence how large the
    -- content appears. 100 = lay out at the true display width (content 1:1).
    -- >100 magnifies (narrower layout, bigger text/images); <100 shrinks
    -- (wider layout, more fits, smaller content). Independent of
    -- device_scale_factor, which only affects capture sharpness, not size.
    zoom = 100,
    -- When true, emails are rendered as images by default (gI toggles this).
    image_mode = false,
    -- Progressive (two-pass) rendering. When true, paint a first image as soon
    -- as the DOM is interactive (fast), then re-render once the page reaches
    -- 'complete' (all images settled) for a refined result. Off by default:
    -- single capture once the page is complete (or the load cap is hit).
    progressive = false,
    -- Device scale factor for the progressive FIRST (interactive) pass. Lower
    -- than device_scale_factor means the preview is captured at reduced
    -- resolution (blurry, but far fewer PNG bytes to transmit and a faster
    -- capture); the final pass still renders at device_scale_factor (sharp).
    -- The CSS layout width is held fixed across passes so the layout doesn't
    -- shift. Clamped to [1, device_scale_factor]. Only used when progressive.
    preview_scale_factor = 1,
    -- Smooth-scroll plugins (e.g. vim-smoothie) animate Ctrl-d/u/f/b as many
    -- rapid scroll frames. Inline images are positioned at absolute screen
    -- coords and reposition one tick behind neovim's text-grid scroll; with the
    -- image split into stacked tiles that one-frame lag is visible as flicker at
    -- the tile seams during the animation (a single discrete jump doesn't show
    -- it). When false (default), Ctrl-d/u/f/b are mapped buffer-local to the
    -- builtin discrete scroll while an email image is displayed, so there's no
    -- flicker; set true to keep smooth scrolling over the image (with flicker).
    smooth_image_scroll = false,
    -- Unicode-placeholder rendering (kitty/ghostty). When true, the email image
    -- is transmitted once as a virtual placement and laid out as placeholder
    -- cells in the buffer, so it scrolls in lockstep with the text grid — no
    -- seam flicker, fully smooth scrolling. Trade-off vs. chunked: the whole
    -- image is transmitted up front. Requires termguicolors. Takes precedence
    -- over `chunked`; falls back to it (or single image) when unavailable or the
    -- image is too tall for the placeholder grid.
    placeholders = false,
    -- Dark-mode rendering. When true, the headless browser is told to emulate
    -- `prefers-color-scheme: dark`, so emails render their OWN dark theme
    -- instead of blinding white. Emails that don't support a dark theme still
    -- render as authored. Off by default.
    dark = false,
    -- Hybrid text/image layer (experimental, placeholder mode only). When true,
    -- the headless render also extracts the email's links/text with their
    -- bounding boxes and maps them onto the placeholder cells, giving the image
    -- a clickable/copyable/searchable layer. Over a link: hover shows its URL,
    -- gx/<CR> opens it, gy copies it. g/ searches the email's text+links, marks
    -- matches on the image, and n/N cycle the cursor through them.
    -- (:HimalayaHybridDots overlays link alignment markers, :HimalayaHybridDump
    -- lists entities.) Off by default.
    hybrid = false,
    -- Chunked rendering. When true, the tall email PNG is sliced into
    -- viewport-height tiles, each placed as its own image.nvim image stacked in
    -- the buffer. image.nvim only transmits the chunks intersecting the visible
    -- window (off-screen tiles early-return before transmit), so a long email
    -- ships ~1 screen of pixels up front and streams the rest on scroll. Slices
    -- are produced in parallel. Off by default: one image for the whole email.
    chunked = false,
  },

  -- Enable mock mode (no CLI binary or email account needed)
  mock = false,
})
```
<!-- /GEN:config -->

## Usage

Open the email listing:

```vim
:Himalaya
```

<!-- GEN:media src="listing" alt="Listing demo" -->
<img src="https://himalaya-nvim.xav.ie/listing.svg?v=1" width="100%" alt="Listing demo">
<p align="center"><a href="https://himalaya-nvim.xav.ie/listing.mp4?v=1">▶ Watch as video</a></p>
<!-- /GEN:media -->

### Flat listing

| Key         | Action                       |
| ----------- | ---------------------------- |
| `Enter`     | Read email under cursor      |
| `]]`        | Next page                    |
| `[[`        | Previous page                |
| `gt`        | Switch to thread view        |
| `g/`        | Open search popup            |
| `g?`        | Apply search preset          |
| `go`        | Toggle sort field/direction  |
| `]u` / `[u` | Jump to next/previous unread |
| `]r` / `[r` | Jump to next/previous read   |
| `?`         | Show keybind help            |

### Thread view

| Key         | Action                               |
| ----------- | ------------------------------------ |
| `Enter`     | Read email under cursor              |
| `]]`        | Next page                            |
| `[[`        | Previous page                        |
| `gt`        | Switch to flat listing               |
| `gT`        | Toggle reverse order (newest on top) |
| `g/`        | Open search popup                    |
| `g?`        | Apply search preset                  |
| `go`        | Toggle sort field/direction          |
| `]u` / `[u` | Jump to next/previous unread         |
| `?`         | Show keybind help                    |

<!-- GEN:media src="reply" alt="Reply demo" -->
<img src="https://himalaya-nvim.xav.ie/reply.svg?v=1" width="100%" alt="Reply demo">
<p align="center"><a href="https://himalaya-nvim.xav.ie/reply.mp4?v=1">▶ Watch as video</a></p>
<!-- /GEN:media -->

### Reading

| Key  | Action               |
| ---- | -------------------- |
| `]]` | Next email           |
| `[[` | Previous email       |
| `gr` | Reply                |
| `gR` | Reply all            |
| `gf` | Forward              |
| `gA` | Download attachments |
| `gC` | Copy to folder       |
| `gM` | Move to folder       |
| `gD` | Delete               |
| `gb` | Open in browser      |
| `gI` | Toggle HTML image rendering |
| `?`  | Show keybind help    |

### HTML image rendering

HTML emails can be rendered to an image and shown inline (on a kitty/ghostty
graphics terminal), instead of the plain-text conversion. Toggle it per-email
with `gI`, or set `render_html.image_mode = true` to make it the default.

**Requires** the **[xav-ie fork of image.nvim](https://github.com/xav-ie/image.nvim)**
— *not* upstream image.nvim, which lacks the unicode-placeholder, preload, and
batched-write support this relies on — plus a headless browser
(`chrome-headless-shell`) and ImageMagick (`magick`). See the `render_html`
options in [Configuration](#configuration); briefly:

- `placeholders` — render via kitty unicode placeholders so the image scrolls in
  lockstep with the text (smooth, full-width, no seam flicker). Recommended.
- `progressive` — paint a fast low-res preview, then refine.
- `zoom` — content size (CSS layout width); independent of `device_scale_factor`
  (sharpness).
- `dark` — emulate `prefers-color-scheme: dark` so emails render their own dark
  theme instead of white.
- `chunked` — fallback tiling when placeholders are unavailable.

#### Hybrid text/link layer

With `render_html.hybrid = true` (placeholder mode), the render also extracts the
email's links and text and maps them onto the image, so it stays
clickable/copyable/searchable:

| Key      | Action                                             |
| -------- | -------------------------------------------------- |
| `f`      | Hint-jump — label every visible node, type to jump |
| `h`/`j`/`k`/`l` | Jump between text/link nodes                |
| `gx` / `<CR>` | Open the link under the cursor                |
| `gy`     | Copy the link/text under the cursor                |
| `K`      | Focus the hover popup (scroll long content)        |
| `g/`     | Search the email's text + links                    |
| `n` / `N` | Cycle search matches                              |
| `<Esc>`  | Clear the search                                   |

Commands: `:HimalayaHybridMode` (toggle `hjkl` node-navigation),
`:HimalayaHybridDots` (overlay alignment markers), `:HimalayaHybridDump` (list
extracted entities).

<!-- GEN:media src="search" alt="Search demo" -->
<img src="https://himalaya-nvim.xav.ie/search.svg?v=1" width="100%" alt="Search demo">
<p align="center"><a href="https://himalaya-nvim.xav.ie/search.mp4?v=1">▶ Watch as video</a></p>
<!-- /GEN:media -->

### Search

The search popup (`g/`) provides structured per-field input:

| Field   | Description                                           |
| ------- | ----------------------------------------------------- |
| folder  | Target folder (Tab to complete)                       |
| subject | Subject text pattern                                  |
| body    | Body text pattern (linked to subject by default)      |
| from    | Sender pattern                                        |
| to      | Recipient pattern                                     |
| when    | Date filter (Tab for presets: today, past week, etc.) |
| flag    | Flag filter (Tab to complete: Seen, Flagged, etc.)    |
| query   | Live-updated composite query                          |

- **Tab** / **Shift-Tab** — navigate between fields (or complete on completable fields)
- **Ctrl-x** — toggle field negation
- **Enter** — submit search
- **Esc** — cancel

<!-- GEN:media src="compose" alt="Compose demo" -->
<img src="https://himalaya-nvim.xav.ie/compose.svg?v=1" width="100%" alt="Compose demo">
<p align="center"><a href="https://himalaya-nvim.xav.ie/compose.mp4?v=1">▶ Watch as video</a></p>
<!-- /GEN:media -->

### Composing

| Key  | Action                      |
| ---- | --------------------------- |
| `gw` | Write new email             |
| `gr` | Reply to email under cursor |
| `gR` | Reply all                   |
| `gf` | Forward email               |

In the compose buffer:

- `:w` sends the email
- Leaving the buffer auto-saves as draft
- Contact completion: `Ctrl-x Ctrl-u` (requires `complete_contact_cmd`)

### Common bindings (listing and thread view)

| Key   | Action               |
| ----- | -------------------- |
| `ga`  | Switch account       |
| `gm`  | Switch folder        |
| `gw`  | Write new email      |
| `dd`  | Delete email         |
| `gs`  | Mark as seen         |
| `gS`  | Mark as unseen       |
| `gFa` | Add flag             |
| `gFr` | Remove flag          |
| `gC`  | Copy to folder       |
| `gM`  | Move to folder       |
| `gA`  | Download attachments |
| `gb`  | Open in browser      |

Visual mode: `d`, `gs`, `gS`, `gFa`, `gFr`, `gC`, `gM` work on selected range.

## Customization

### Keymap overrides

Remap any binding by its plug name, or set to `false` to disable:

```lua
require('himalaya').setup({
  keymaps = {
    ['email-read'] = 'o',           -- open email with 'o' instead of Enter
    ['email-delete'] = false,       -- disable dd delete
    ['email-toggle-sort'] = 'gO',   -- remap sort toggle
  },
})
```

### Events

Subscribe to plugin events for custom behavior:

```lua
local events = require('himalaya.events')

events.on('EmailsListed', function(data) ... end)
events.on('EmailRead', function(data) ... end)
events.on('ComposeOpened', function(data) ... end)
```

See [CONTRIBUTING.md](./CONTRIBUTING.md#all-events) for the full list of events and their payloads.

### Signatures

Set a global signature or per-account signatures:

```lua
require('himalaya').setup({
  -- Global signature
  signature = '\n--\nSent with himalaya',

  -- Or per-account
  signature = {
    personal = '\n--\nJohn Doe',
    work = '\n--\nJohn Doe\nSoftware Engineer\nAcme Corp',
  },
})
```

### Search presets

Define named search presets for quick access via `g?`:

```lua
require('himalaya').setup({
  search_presets = {
    { name = 'Unread', query = 'not flag Seen' },
    { name = 'Flagged', query = 'flag Flagged' },
    { name = 'This week', query = 'after ' .. os.date('%Y-%m-%d', os.time() - 7 * 86400) },
  },
})
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup, testing, the
full events reference, and a guide to writing plugins that extend himalaya-nvim.
