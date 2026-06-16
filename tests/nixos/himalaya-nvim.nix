{
  pkgs,
  himalaya-cli,
  himalaya-nvim,
}:

let
  lib = import ./lib.nix { inherit pkgs himalaya-cli; };

  testHimalayaCli =
    pkgs.writeScriptBin "test-himalaya-cli" # sh
      ''
        #!${pkgs.runtimeShell}
        set -euo pipefail
        output=$(su - ${lib.user} -c '${lib.himalayaBin} --config ${lib.himalayaConfig} --output json envelope list --page-size 50 --page 1')
        echo "$output"
        echo "$output" | ${pkgs.lib.getExe pkgs.jq} -e '.[].subject' > /dev/null
        for subject in ${pkgs.lib.concatMapStringsSep " " (s: ''"${s}"'') lib.inboxSubjects}; do
          echo "$output" | ${pkgs.lib.getExe pkgs.jq} -e ".[] | select(.subject == \"$subject\")" > /dev/null \
            || { echo "FAIL: subject '$subject' not found"; exit 1; }
        done
        echo "CLI test passed"
      '';

  nvimTestScript =
    pkgs.writeText "nvim-test.lua" # lua
      ''
        vim.opt.rtp:prepend('${himalaya-nvim}')
        vim.cmd('runtime! plugin/**/*.lua')

        require('himalaya').setup({
          executable = '${lib.himalayaBin}',
          config_path = '${lib.himalayaConfig}',
        })

        vim.cmd('Himalaya')

        vim.defer_fn(function()
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local f = io.open('/tmp/nvim-output.txt', 'w')
          if f then
            f:write(table.concat(lines, '\n'))
            f:close()
          end
          vim.cmd('qa!')
        end, 8000)
      '';

  testHimalayaNvim =
    pkgs.writeScriptBin "test-himalaya-nvim" # sh
      ''
        #!${pkgs.runtimeShell}
        set -euo pipefail
        su - ${lib.user} -c '${pkgs.lib.getExe pkgs.neovim} --headless -u NONE -c "luafile ${nvimTestScript}"'
      '';
in
{
  name = "himalaya-nvim";

  nodes.machine =
    { ... }:
    lib.machineConfig
    // {
      environment.systemPackages = [
        himalaya-cli
        pkgs.neovim
        pkgs.jq
        pkgs.dovecot
        lib.injectCorpus
        lib.recordCliResponses
        testHimalayaCli
        testHimalayaNvim
      ];
    };

  testScript =
    let
      nvimAssertions = pkgs.lib.concatMapStringsSep "\n" (
        s:
        let
          words = pkgs.lib.splitString " " s;
          word = builtins.elemAt words (builtins.length words - 1);
        in
        # py
        ''assert "${word}" in output, f"Expected '${word}' in buffer output: {output}"''
      ) lib.inboxSubjects;
    in
    # py
    ''
      ${lib.testPreamble}

      machine.succeed("su - alice -c 'record-cli-responses'")
      machine.copy_from_vm("/tmp/fixtures")

      # himalaya CLI can list envelopes directly
      machine.succeed("test-himalaya-cli")

      # neovim plugin renders the listing buffer
      machine.succeed("test-himalaya-nvim")
      output = machine.succeed("cat /tmp/nvim-output.txt")
      print(f"nvim buffer output:\n{output}")
      ${nvimAssertions}

      machine.copy_from_vm("/tmp/nvim-output.txt")
    '';
}
