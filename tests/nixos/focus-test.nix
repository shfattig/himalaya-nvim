# Minimal VM test: binary search for what in diag-hooks.lua breaks focus events.
{ pkgs }:

let
  diagHooksLua = ../../scripts/diag-hooks/diag-hooks.lua;

  simpleFocus = # lua
    ''
      local LOG = "/tmp/focus.log"
      local f = io.open(LOG, "w")
      if f then f:write("STARTED\n"); f:close() end
      vim.api.nvim_create_augroup("SF", { clear = true })
      vim.api.nvim_create_autocmd("FocusLost", {
        group = "SF",
        callback = function()
          local fh = io.open(LOG, "a")
          if fh then fh:write("FocusLost\n"); fh:close() end
        end,
      })
      vim.api.nvim_create_autocmd("FocusGained", {
        group = "SF",
        callback = function()
          local fh = io.open(LOG, "a")
          if fh then fh:write("FocusGained\n"); fh:close() end
        end,
      })
    '';

  hooksDef = # lua
    ''
      local HOOKS = {
        { "-g", "session-window-changed" },
        { "-g", "after-select-window" },
        { "-g", "after-select-pane" },
        { "-g", "client-session-changed" },
        { "-g", "client-focus-in" },
        { "-g", "client-focus-out" },
        { "-g", "after-resize-pane" },
        { "-gw", "pane-mode-changed" },
        { "-gw", "window-layout-changed" },
        { "-gw", "window-pane-changed" },
        { "-gw", "pane-focus-in" },
        { "-gw", "pane-focus-out" },
      }
      local function tmux(args)
        local cmd = { "tmux" }
        for _, a in ipairs(args) do cmd[#cmd + 1] = a end
        return vim.system(cmd, { text = true }):wait()
      end
    '';

  # Test 5: unregister hooks at [0] + simple focus
  test5Lua =
    pkgs.writeText "test5.lua" # lua
      ''
        ${hooksDef}
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, "-u", name .. "[0]" })
        end
        ${simpleFocus}
      '';

  # Test 6: register hooks + unregister [0] + simple focus
  test6Lua =
    pkgs.writeText "test6.lua" # lua
      ''
        ${hooksDef}
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, "-u", name .. "[0]" })
        end
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, name .. "[99]", "run-shell \"/tmp/diag-hook.sh " .. name .. "\"" })
        end
        ${simpleFocus}
      '';

  # Test 7: register + unregister + verify + simple focus (everything except vim.system in callback)
  test7Lua =
    pkgs.writeText "test7.lua" # lua
      ''
        ${hooksDef}
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, "-u", name .. "[0]" })
        end
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, name .. "[99]", "run-shell \"/tmp/diag-hook.sh " .. name .. "\"" })
        end
        tmux({ "show-hooks", "-g" })
        tmux({ "show-hooks", "-gw" })
        ${simpleFocus}
      '';

  # Test 8: hooks + vim.system() in callback (both features combined)
  test8Lua =
    pkgs.writeText "test8.lua" # lua
      ''
        ${hooksDef}
        for _, entry in ipairs(HOOKS) do
          local scope, name = entry[1], entry[2]
          tmux({ "set-hook", scope, name .. "[99]", "run-shell \"/tmp/diag-hook.sh " .. name .. "\"" })
        end
        local LOG = "/tmp/focus.log"
        local f = io.open(LOG, "w")
        if f then f:write("STARTED\n"); f:close() end
        vim.api.nvim_create_augroup("SF", { clear = true })
        vim.api.nvim_create_autocmd("FocusLost", {
          group = "SF",
          callback = function()
            vim.system({ "tmux", "display-message", "-p", "x" }, { text = true }):wait()
            local fh = io.open(LOG, "a")
            if fh then fh:write("FocusLost\n"); fh:close() end
          end,
        })
        vim.api.nvim_create_autocmd("FocusGained", {
          group = "SF",
          callback = function()
            vim.system({ "tmux", "display-message", "-p", "x" }, { text = true }):wait()
            local fh = io.open(LOG, "a")
            if fh then fh:write("FocusGained\n"); fh:close() end
          end,
        })
      '';

  diagHookScript =
    pkgs.writeScript "diag-hook.sh" # sh
      ''
        #!/bin/sh
        HOOK="$1"
        LOG="/tmp/image-nvim-diag.log"
        STATE=$(tmux display-message -p "win=#{window_id} pane=#{pane_id} win_active=#{window_active} pane_active=#{pane_active} sess_att=#{session_attached} mode='#{pane_mode}' sess=#{session_id} zoomed=#{window_zoomed_flag} client_sess=#{client_session}")
        printf "%s HOOK:%-30s %s\n" "$(date +%H:%M:%S.%3N)" "$HOOK" "$STATE" >> "$LOG"
      '';

  testScript =
    pkgs.writeScript "focus-test" # sh
      ''
        #!/bin/sh
        set -eu

        run_test() {
          local name="$1"
          local nvim_cmd="$2"

          echo -n "  $name: "
          tmux kill-server 2>/dev/null || true
          sleep 0.3

          tmux new-session -d -s t -x 200 -y 50
          tmux set -g focus-events on
          tmux split-window -h -t t

          LEFT=$(tmux list-panes -t t -F '#{pane_id}' | head -1)
          RIGHT=$(tmux list-panes -t t -F '#{pane_id}' | tail -1)

          tmux send-keys -t "$RIGHT" "$nvim_cmd" Enter
          sleep 3

          rm -f /tmp/ctrl-fifo
          mkfifo /tmp/ctrl-fifo
          cat /dev/zero > /tmp/ctrl-fifo &
          CAT_PID=$!
          tmux -C attach-session -t t < /tmp/ctrl-fifo > /dev/null 2>&1 &
          CTRL_PID=$!
          sleep 1

          tmux select-pane -t "$LEFT"
          sleep 1
          tmux select-pane -t "$RIGHT"
          sleep 1

          count=$(grep -cE 'Focus' /tmp/focus.log 2>/dev/null || echo 0)
          if [ "$count" -ge 2 ]; then
            echo "PASS ($count focus events)"
          else
            echo "FAIL ($count focus events)"
            cat /tmp/focus.log 2>/dev/null | head -5 | sed 's/^/    /'
          fi

          kill $CTRL_PID $CAT_PID 2>/dev/null || true
          wait $CTRL_PID $CAT_PID 2>/dev/null || true
          rm -f /tmp/ctrl-fifo /tmp/focus.log
          tmux kill-server 2>/dev/null || true
          sleep 0.3
        }

        echo "=== Focus event isolation tests ==="
        run_test "5-unregister-hooks-only" "nvim -u NONE -c 'luafile ${test5Lua}'"
        run_test "6-unregister+register" "nvim -u NONE -c 'luafile ${test6Lua}'"
        run_test "7-unregister+register+verify" "nvim -u NONE -c 'luafile ${test7Lua}'"
        run_test "8-hooks+syscall-callback" "nvim -u NONE -c 'luafile ${test8Lua}'"

        # Test 9: diag-hooks.lua + simple logger (both loaded)
        # This tells us: does nvim RECEIVE \e[I/\e[O when diag-hooks.lua is loaded?
        run_test "9-diag-hooks+simple-logger" \
          "nvim -u NONE -c 'luafile ${diagHooksLua}' -c 'luafile ${
            pkgs.writeText "also-simple.lua" # lua
              ''
                local LOG = "/tmp/focus.log"
                local f = io.open(LOG, "w")
                if f then f:write("STARTED\n"); f:close() end
                vim.api.nvim_create_augroup("AS", { clear = true })
                vim.api.nvim_create_autocmd("FocusLost", {
                  group = "AS",
                  callback = function()
                    local fh = io.open(LOG, "a")
                    if fh then fh:write("FocusLost\n"); fh:close() end
                  end,
                })
                vim.api.nvim_create_autocmd("FocusGained", {
                  group = "AS",
                  callback = function()
                    local fh = io.open(LOG, "a")
                    if fh then fh:write("FocusGained\n"); fh:close() end
                  end,
                })
              ''
          }'"

        # Test 10: diag-hooks.lua with send-keys -H for focus injection
        echo -n "  10-diag-hooks+sendkeys-H: "
        tmux kill-server 2>/dev/null || true
        sleep 0.3
        tmux new-session -d -s t -x 200 -y 50
        tmux set -g focus-events on
        tmux split-window -h -t t
        LEFT=$(tmux list-panes -t t -F '#{pane_id}' | head -1)
        RIGHT=$(tmux list-panes -t t -F '#{pane_id}' | tail -1)
        tmux send-keys -t "$RIGHT" "nvim -u NONE -c 'luafile ${diagHooksLua}'" Enter
        sleep 3
        rm -f /tmp/ctrl-fifo
        mkfifo /tmp/ctrl-fifo
        cat /dev/zero > /tmp/ctrl-fifo &
        CAT_PID=$!
        tmux -C attach-session -t t < /tmp/ctrl-fifo > /dev/null 2>&1 &
        CTRL_PID=$!
        sleep 1
        # Use send-keys -H instead of select-pane
        tmux send-keys -H -t "$RIGHT" 1B 5B 4F
        sleep 1
        tmux send-keys -H -t "$RIGHT" 1B 5B 49
        sleep 1
        count=$(grep -cE 'NVIM:' /tmp/image-nvim-diag.log 2>/dev/null || echo 0)
        if [ "$count" -ge 2 ]; then
          echo "PASS ($count NVIM events)"
        else
          echo "FAIL ($count NVIM events)"
          cat /tmp/image-nvim-diag.log 2>/dev/null | head -10 | sed 's/^/    /'
        fi
        kill $CTRL_PID $CAT_PID 2>/dev/null || true
        wait $CTRL_PID $CAT_PID 2>/dev/null || true
        rm -f /tmp/ctrl-fifo
        tmux kill-server 2>/dev/null || true

        # Test 11: diag-hooks.lua with LONG wait (10s for init to finish)
        echo -n "  11-diag-hooks+long-wait: "
        tmux kill-server 2>/dev/null || true
        sleep 0.3
        tmux new-session -d -s t -x 200 -y 50
        tmux set -g focus-events on
        tmux split-window -h -t t
        LEFT=$(tmux list-panes -t t -F '#{pane_id}' | head -1)
        RIGHT=$(tmux list-panes -t t -F '#{pane_id}' | tail -1)
        tmux send-keys -t "$RIGHT" "nvim -u NONE -c 'luafile ${diagHooksLua}'" Enter
        sleep 10
        rm -f /tmp/ctrl-fifo
        mkfifo /tmp/ctrl-fifo
        cat /dev/zero > /tmp/ctrl-fifo &
        CAT_PID=$!
        tmux -C attach-session -t t < /tmp/ctrl-fifo > /dev/null 2>&1 &
        CTRL_PID=$!
        sleep 1
        tmux send-keys -H -t "$RIGHT" 1B 5B 4F
        sleep 1
        tmux send-keys -H -t "$RIGHT" 1B 5B 49
        sleep 1
        tmux select-pane -t "$LEFT"
        sleep 1
        tmux select-pane -t "$RIGHT"
        sleep 1
        count=$(grep -cE 'NVIM:' /tmp/image-nvim-diag.log 2>/dev/null || echo 0)
        if [ "$count" -ge 2 ]; then
          echo "PASS ($count NVIM events)"
        else
          echo "FAIL ($count NVIM events)"
          cat /tmp/image-nvim-diag.log 2>/dev/null | head -15 | sed 's/^/    /'
        fi
        kill $CTRL_PID $CAT_PID 2>/dev/null || true
        wait $CTRL_PID $CAT_PID 2>/dev/null || true
        rm -f /tmp/ctrl-fifo
        tmux kill-server 2>/dev/null || true

        # Test 12: 26 vim.system tmux calls + simple logger (same call COUNT as diag-hooks)
        echo -n "  12-26-syscalls+simple: "
        tmux kill-server 2>/dev/null || true
        sleep 0.3
        tmux new-session -d -s t -x 200 -y 50
        tmux set -g focus-events on
        tmux split-window -h -t t
        LEFT=$(tmux list-panes -t t -F '#{pane_id}' | head -1)
        RIGHT=$(tmux list-panes -t t -F '#{pane_id}' | tail -1)
        tmux send-keys -t "$RIGHT" "nvim -u NONE -c 'luafile ${
          pkgs.writeText "many-syscalls.lua" # lua
            ''
              -- Do 26 vim.system() calls (same number as diag-hooks.lua)
              for i = 1, 26 do
                vim.system({ "tmux", "display-message", "-p", "call " .. i }, { text = true }):wait()
              end
              local LOG = "/tmp/focus.log"
              local f = io.open(LOG, "w")
              if f then f:write("STARTED\n"); f:close() end
              vim.api.nvim_create_augroup("SF", { clear = true })
              vim.api.nvim_create_autocmd("FocusLost", {
                group = "SF",
                callback = function()
                  local fh = io.open(LOG, "a")
                  if fh then fh:write("FocusLost\n"); fh:close() end
                end,
              })
              vim.api.nvim_create_autocmd("FocusGained", {
                group = "SF",
                callback = function()
                  local fh = io.open(LOG, "a")
                  if fh then fh:write("FocusGained\n"); fh:close() end
                end,
              })
            ''
        }'" Enter
        sleep 3
        rm -f /tmp/ctrl-fifo
        mkfifo /tmp/ctrl-fifo
        cat /dev/zero > /tmp/ctrl-fifo &
        CAT_PID=$!
        tmux -C attach-session -t t < /tmp/ctrl-fifo > /dev/null 2>&1 &
        CTRL_PID=$!
        sleep 1
        tmux select-pane -t "$LEFT"
        sleep 1
        tmux select-pane -t "$RIGHT"
        sleep 1
        count=$(grep -cE 'Focus' /tmp/focus.log 2>/dev/null || echo 0)
        if [ "$count" -ge 2 ]; then
          echo "PASS ($count focus events)"
        else
          echo "FAIL ($count focus events)"
          cat /tmp/focus.log 2>/dev/null | head -5 | sed 's/^/    /'
        fi
        kill $CTRL_PID $CAT_PID 2>/dev/null || true
        wait $CTRL_PID $CAT_PID 2>/dev/null || true
        rm -f /tmp/ctrl-fifo
        tmux kill-server 2>/dev/null || true
      '';
in
{
  name = "focus-test";

  nodes.machine =
    { ... }:
    {
      users.users.test = {
        isNormalUser = true;
        password = "test";
        uid = 1000;
      };
      environment.systemPackages = [
        pkgs.tmux
        pkgs.neovim
      ];
    };

  testScript =
    # py
    ''
      machine.wait_for_unit("multi-user.target")
      machine.succeed("cp ${diagHookScript} /tmp/diag-hook.sh && chmod +x /tmp/diag-hook.sh")
      output = machine.succeed("su - test -c '${testScript}'", timeout=120)
      print(output)
    '';
}
