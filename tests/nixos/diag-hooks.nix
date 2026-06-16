# NixOS VM test that automates generation of tmux hook diagnostic logs.
#
# Runs 20 tmux interaction scenarios with neovim + diag-hooks.lua loaded,
# capturing hook events to log files for debugging image.nvim focus handling.
#
# A control-mode client (`tmux -C`) is attached to provide CLIENT_FOCUSED,
# which makes tmux deliver real \e[I / \e[O focus sequences to panes when
# the active pane changes (via select-pane, next-window, switch-client, etc.).
{ pkgs }:

let
  diagHooksLua = ../../scripts/diag-hooks/diag-hooks.lua;

  diagFocusLua =
    pkgs.writeText "diag-focus.lua" # lua
      ''
        local f = io.open("/tmp/diag-focus.log", "w")
        if f then f:write("STARTED\n"); f:close() end
        vim.api.nvim_create_augroup("DF", { clear = true })
        vim.api.nvim_create_autocmd("FocusLost", {
          group = "DF",
          callback = function()
            local fh = io.open("/tmp/diag-focus.log", "a")
            if fh then fh:write("FocusLost\n"); fh:close() end
          end,
        })
        vim.api.nvim_create_autocmd("FocusGained", {
          group = "DF",
          callback = function()
            local fh = io.open("/tmp/diag-focus.log", "a")
            if fh then fh:write("FocusGained\n"); fh:close() end
          end,
        })
      '';

  diagScript =
    pkgs.writeScript "diag-focus-test" # sh
      ''
        #!/bin/sh
        set -eu
        tmux kill-server 2>/dev/null || true
        sleep 0.5
        tmux new-session -d -s diag -x 200 -y 50
        tmux set -g focus-events on
        tmux split-window -h -t diag

        LEFT=$(tmux list-panes -t diag -F '#{pane_id}' | head -1)
        RIGHT=$(tmux list-panes -t diag -F '#{pane_id}' | tail -1)

        tmux send-keys -t "$RIGHT" "nvim -u NONE -c 'luafile ${diagFocusLua}'" Enter
        sleep 3

        echo "=== DIAGNOSTICS ==="
        echo "Shell: $(readlink -f /bin/sh)"
        echo "Nvim log exists: $(test -f /tmp/diag-focus.log && echo yes || echo no)"
        cat /tmp/diag-focus.log 2>/dev/null || echo "(no log)"

        # Attach control-mode client
        mkfifo /tmp/diag-fifo
        cat /dev/zero > /tmp/diag-fifo &
        CAT_PID=$!
        tmux -C attach-session -t diag < /tmp/diag-fifo > /tmp/diag-ctrl.log 2>&1 &
        CTRL_PID=$!
        sleep 1

        echo "Clients: $(tmux list-clients)"

        # Test select-pane
        tmux select-pane -t "$LEFT"
        sleep 1
        tmux select-pane -t "$RIGHT"
        sleep 1

        echo "Focus log after select-pane:"
        cat /tmp/diag-focus.log 2>/dev/null || echo "(no log)"

        # Test send-keys -H fallback
        tmux send-keys -H -t "$RIGHT" 1B 5B 4F
        sleep 0.5
        tmux send-keys -H -t "$RIGHT" 1B 5B 49
        sleep 0.5
        echo "Focus log after send-keys -H:"
        cat /tmp/diag-focus.log 2>/dev/null || echo "(no log)"

        kill $CTRL_PID 2>/dev/null || true
        kill $CAT_PID 2>/dev/null || true
        rm -f /tmp/diag-fifo
        tmux kill-server 2>/dev/null || true
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

  setupScript =
    pkgs.writeScript "setup-tmux" # sh
      ''
        #!/bin/sh
        set -eu
        tmux kill-server 2>/dev/null || true
        sleep 0.5

        # Session "main": first window (2 panes), second window (shell)
        tmux new-session -d -s main -x 200 -y 50
        tmux set -g focus-events on
        NVIM_WIN=$(tmux list-windows -t main -F '#{window_index}' | head -1)
        tmux split-window -h -t "main:$NVIM_WIN"
        tmux new-window -t main
        OTHER_WIN=$(tmux list-windows -t main -F '#{window_index}' | tail -1)
        tmux select-window -t "main:$NVIM_WIN"

        # Session "other": two windows (shell)
        tmux new-session -d -s other
        tmux new-window -t other

        # Identify panes in the nvim window
        LEFT_PANE=$(tmux list-panes -t "main:$NVIM_WIN" -F '#{pane_id}' | head -1)
        RIGHT_PANE=$(tmux list-panes -t "main:$NVIM_WIN" -F '#{pane_id}' | tail -1)
        NVIM_PANE="$RIGHT_PANE"

        # Launch nvim in right pane — this is the active pane
        tmux send-keys -t "$NVIM_PANE" 'nvim -c "luafile ${diagHooksLua}"' Enter
        sleep 3

        # Verify nvim started and created the log file
        if [ ! -f /tmp/image-nvim-diag.log ]; then
          echo "  [error] /tmp/image-nvim-diag.log not found"
          tmux capture-pane -t "$NVIM_PANE" -p | tail -10 2>&1 || true
          exit 1
        fi

        # Attach a control-mode client to provide CLIENT_FOCUSED.
        # This makes tmux deliver \e[I / \e[O to panes on focus changes.
        rm -f /tmp/ctrl-fifo
        mkfifo /tmp/ctrl-fifo
        cat /dev/zero > /tmp/ctrl-fifo &
        CAT_PID=$!
        tmux -C attach-session -t main < /tmp/ctrl-fifo > /tmp/tmux-ctrl.log 2>&1 &
        CTRL_PID=$!
        sleep 1

        # Get the control-mode client name for switch-client commands
        CTRL_CLIENT=$(tmux list-clients -F '#{client_name}' | head -1)
      '';

  # Each scenario: { name, cmds }
  # cmds is a list of shell commands (tmux CLI calls) to run sequentially.
  # Special sentinels: DETACH, REATTACH, NOOP, SWITCH_NEXT, SWITCH_PREV,
  # "SWITCH_TO <session>" — handled specially in mkScenarioScript.
  scenarios = [
    {
      name = "focused-zoom-then-unzoom-then-quit";
      cmds = [
        "tmux resize-pane -Z -t $NVIM_PANE"
        "tmux resize-pane -Z -t $NVIM_PANE"
      ];
    }
    {
      name = "focus-left-pane-then-focus-right-pane-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      name = "focused-create-new-pane-to-right-then-close";
      cmds = [
        "tmux split-window -h -t $NVIM_PANE"
        "CLOSE_NEW_PANE"
      ];
    }
    {
      name = "focused-create-new-pane-under-then-close";
      cmds = [
        "tmux split-window -v -t $NVIM_PANE"
        "CLOSE_NEW_PANE"
      ];
    }
    {
      name = "focused-create-new-tab-then-close-and-return-to-nvim-tab-with-nvim-still-focused";
      cmds = [
        "tmux new-window -t main"
        "CLOSE_NEW_WINDOW"
      ];
    }
    {
      name = "focused-detach-and-reattach-then-exit";
      cmds = [
        "DETACH"
        "REATTACH"
      ];
    }
    {
      # choose-tree + Enter on current window = no-op (re-select same window)
      name = "focused-go-to-left-pane-then-open-tree-mode-then-select-same-window-then-focus-nvim-pane-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "tmux select-window -t main:$NVIM_WIN"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      # choose-tree + Enter on current window = no-op
      name = "focused-go-to-tree-mode-then-select-same-window";
      cmds = [
        "tmux select-window -t main:$NVIM_WIN"
      ];
    }
    {
      name = "focused-then-focus-on-left-pane-then-detach-and-reattach-then-focus-nvim-then-exit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "DETACH"
        "REATTACH"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      name = "focused-focus-next-tab-then-focus-prev-and-quit";
      cmds = [
        "tmux next-window -t main"
        "tmux previous-window -t main"
      ];
    }
    {
      name = "focused-focus-left-pane-then-focus-next-tab-then-focus-prev-tab-then-focus-right-pane-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "tmux next-window -t main"
        "tmux previous-window -t main"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      # choose-tree + q = cancel (no window change, just opens and closes tree mode)
      name = "focused-enter-tree-mode-then-q";
      cmds = [
        "NOOP"
      ];
    }
    {
      # choose-tree + q = cancel, then focus nvim pane
      name = "focused-focus-left-pane-then-enter-tree-mode-then-press-q-then-focus-nvim-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "NOOP"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      name = "focused-then-zoom-then-focus-on-nvim-pane-on-left-which-unzooms-and-focuses-left-panel-then-focus-nvim-then-quit";
      cmds = [
        "tmux resize-pane -Z -t $NVIM_PANE"
        "tmux select-pane -t $LEFT_PANE"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      # tree: Down Down Enter -> switch to other session's first window, then back
      name = "focused-enter-tree-mode-then-select-first-tab-of-next-window-then-re-enter-tree-mode-then-select-nvim-tab-and-quit";
      cmds = [
        "SWITCH_TO other"
        "SWITCH_TO main"
      ];
    }
    {
      # tree: Down Enter -> select next window in same session, then back
      name = "focused-enter-tree-mode-then-focus-on-next-tab-in-same-session-then-enter-tree-mode-then-focus-back-on-nvim-tab-and-quit";
      cmds = [
        "tmux select-window -t main:$OTHER_WIN"
        "tmux select-window -t main:$NVIM_WIN"
      ];
    }
    {
      # tree: Down Enter -> next window, then back, with pane focus changes
      name = "focused-focus-left-pane-then-enter-tree-mode-then-focus-on-next-tab-in-same-session-then-enter-tree-mode-then-focus-back-on-previous-tab-then-focus-nvim-pane-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "tmux select-window -t main:$OTHER_WIN"
        "tmux select-window -t main:$NVIM_WIN"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      name = "focused-prefix-right-paren-then-prefix-left-paren-and-quit";
      cmds = [
        "SWITCH_NEXT"
        "SWITCH_PREV"
      ];
    }
    {
      name = "focused-focus-left-pane-then-prefix-right-paren-then-prefix-left-paren-then-focus-nvim-pane-and-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "SWITCH_NEXT"
        "SWITCH_PREV"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
    {
      name = "focused-then-focus-on-left-pane-then-create-new-tab-then-close-then-focus-nvim-then-quit";
      cmds = [
        "tmux select-pane -t $LEFT_PANE"
        "tmux new-window -t main"
        "CLOSE_NEW_WINDOW"
        "tmux select-pane -t $RIGHT_PANE"
      ];
    }
  ];

  # Generate shell commands for one scenario
  mkScenarioScript =
    scenario:
    let
      cmdLines = builtins.concatStringsSep "\n" (
        map (
          cmd:
          if cmd == "REATTACH" then
            ''
              echo "  [reattach]"
              sleep 1
              rm -f /tmp/ctrl-fifo
              mkfifo /tmp/ctrl-fifo
              cat /dev/zero > /tmp/ctrl-fifo &
              CAT_PID=$!
              tmux -C attach-session -t main < /tmp/ctrl-fifo > /tmp/tmux-ctrl.log 2>&1 &
              CTRL_PID=$!
              sleep 1
              CTRL_CLIENT=$(tmux list-clients -F '#{client_name}' | head -1)
              # Inject focus-in to nvim pane (control-mode reattach doesn't
              # naturally deliver \e[I since pane state wasn't cleared)
              tmux send-keys -H -t $NVIM_PANE 1B 5B 49
              sleep 0.5
            ''
          else if cmd == "DETACH" then
            ''
              echo "  [detach]"
              # Inject focus-out to nvim pane before detaching
              tmux send-keys -H -t $NVIM_PANE 1B 5B 4F
              sleep 0.5
              # Kill control-mode client (simulates detach)
              kill $CTRL_PID 2>/dev/null || true
              kill $CAT_PID 2>/dev/null || true
              wait $CTRL_PID 2>/dev/null || true
              wait $CAT_PID 2>/dev/null || true
              rm -f /tmp/ctrl-fifo
              sleep 0.5
            ''
          else if cmd == "NOOP" then
            ''
              echo "  [noop]"
              sleep 0.5
            ''
          else if cmd == "CLOSE_NEW_PANE" then
            ''
              echo "  [close new pane]"
              # The newly split pane is now active; send exit to close it
              tmux send-keys 'exit' Enter
              sleep 0.5
            ''
          else if cmd == "CLOSE_NEW_WINDOW" then
            ''
              echo "  [close new window]"
              # The new window is now active; send exit to close it
              tmux send-keys 'exit' Enter
              sleep 0.5
            ''
          else if builtins.match "SWITCH_TO (.*)" cmd != null then
            let
              target = builtins.head (builtins.match "SWITCH_TO (.*)" cmd);
            in
            ''
              echo "  [switch-client -t ${target}]"
              tmux switch-client -c $CTRL_CLIENT -t ${target}
              sleep 1
            ''
          else if cmd == "SWITCH_NEXT" then
            ''
              echo "  [switch-client -n]"
              tmux switch-client -c $CTRL_CLIENT -n
              sleep 1
            ''
          else if cmd == "SWITCH_PREV" then
            ''
              echo "  [switch-client -p]"
              tmux switch-client -c $CTRL_CLIENT -p
              sleep 1
            ''
          else
            ''
              echo "  [cmd] ${cmd}"
              ${cmd}
              sleep 1
            ''
        ) scenario.cmds
      );
    in
    ''
      echo "=== Scenario: ${scenario.name} ==="
      . ${setupScript}

      ${cmdLines}

      # Wait for events to settle
      sleep 1.5

      # Cleanup control-mode client
      kill $CTRL_PID 2>/dev/null || true
      kill $CAT_PID 2>/dev/null || true
      wait $CTRL_PID 2>/dev/null || true
      wait $CAT_PID 2>/dev/null || true
      rm -f /tmp/ctrl-fifo

      cp /tmp/image-nvim-diag.log "/tmp/diag-logs/nvim-pane-on-right-${scenario.name}.log"
      echo "  -> saved ${scenario.name}"

      # Kill tmux to clean up
      tmux kill-server 2>/dev/null || true
      sleep 0.5
    '';

  scenarioScripts = map (
    scenario:
    pkgs.writeScript "scenario-${scenario.name}" ''
      #!/bin/sh
      set -eu
      mkdir -p /tmp/diag-logs
      ${mkScenarioScript scenario}
    ''
  ) scenarios;

  scenarioNames = map (s: s.name) scenarios;
  scenarioPairs = pkgs.lib.zipListsWith (script: name: { inherit script name; }) scenarioScripts scenarioNames;
in
{
  name = "diag-hooks";

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
    let
      scenarioCommands = builtins.concatStringsSep "\n" (
        pkgs.lib.imap1 (
          i: pair:
          "print(\">>> [${toString i}/${toString (builtins.length scenarios)}] ${pair.name}\")\n"
          + "machine.succeed(\"su - test -c '${pair.script}'\", timeout=60)"
        ) scenarioPairs
      );
    in
    # py
    ''
      machine.wait_for_unit("multi-user.target")

      # Place diag-hook.sh where diag-hooks.lua expects it
      machine.succeed("cp ${diagHookScript} /tmp/diag-hook.sh && chmod +x /tmp/diag-hook.sh")

      # Diagnostic: verify focus events work before running scenarios
      diag = machine.succeed("su - test -c '${diagScript}'", timeout=30)
      print(diag)

      ${scenarioCommands}

      machine.copy_from_vm("/tmp/diag-logs")
    '';
}
