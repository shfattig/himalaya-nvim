# Reproduces https://github.com/xav-ie/himalaya-nvim/issues/1
# Tests that the plugin works when loaded via lazy.nvim,
# mirroring the reporter's exact setup pattern:
#
#   require("lazy.minit").repro({
#     spec = {
#       { "xav-ie/himalaya-nvim", cmd = "Himalaya", lazy = false,
#         config = function() require("himalaya").setup({}) end },
#     },
#   })
#
# Adaptations for VM (no network, no default config):
#   - Use lazy.minit.setup() instead of repro() to skip update()
#   - Set LAZY_OFFLINE=1 as fallback safety net
#   - Pass executable + config_path (VM has no default himalaya config)
# Everything else is faithful: cmd, lazy=false, config function pattern.
#
# Parameterized: pass a different himalaya-cli to test upstream vs patched.
{
  pkgs,
  himalaya-cli,
  himalaya-nvim,
  name ? "himalaya-nvim-lazy",
}:

let
  lib = import ./lib.nix { inherit pkgs himalaya-cli; };

  lazyNvim = pkgs.vimPlugins.lazy-nvim;

  lazyTestScript =
    pkgs.writeText "lazy-test.lua" # lua
      ''
        vim.env.LAZY_STDPATH = '/tmp/lazy-repro'
        vim.env.LAZY_OFFLINE = '1'

        local lazypath = '${lazyNvim}'
        vim.opt.rtp:prepend(lazypath)

        require('lazy.minit').setup({
          spec = {
            {
              dir = '${himalaya-nvim}',
              cmd = 'Himalaya',
              lazy = false,
              config = function()
                require('himalaya').setup({
                  executable = '${lib.himalayaBin}',
                  config_path = '${lib.himalayaConfig}',
                })
              end,
            },
          },
        })

        vim.cmd('Himalaya')

        vim.defer_fn(function()
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local f = io.open('/tmp/lazy-nvim-output.txt', 'w')
          if f then
            f:write(table.concat(lines, '\n'))
            f:close()
          end
          vim.cmd('qa!')
        end, 8000)
      '';

  testLazyNvim =
    pkgs.writeScriptBin "test-lazy-nvim" # sh
      ''
        #!${pkgs.runtimeShell}
        set -euo pipefail
        su - ${lib.user} -c 'HOME=/tmp/lazy-home ${pkgs.lib.getExe pkgs.neovim} --headless -u NONE -c "luafile ${lazyTestScript}"'
      '';
in
{
  inherit name;

  nodes.machine =
    { ... }:
    lib.machineConfig
    // {
      environment.systemPackages = [
        himalaya-cli
        pkgs.neovim
        lib.injectCorpus
        testLazyNvim
      ];
    };

  testScript =
    let
      # Use short, early words that survive column truncation (~)
      assertWords = [
        "Alpha"
        "Code review"
        "lunch"
      ];
      assertions = pkgs.lib.concatMapStringsSep "\n" (
        word: ''assert "${word}" in output, f"Expected '${word}' in buffer output: {output}"''
      ) assertWords;
    in
    # py
    ''
      ${lib.testPreamble}

      # Create HOME for lazy.nvim state directories
      machine.succeed("mkdir -p /tmp/lazy-home && chown alice:users /tmp/lazy-home")

      machine.succeed("test-lazy-nvim")
      output = machine.succeed("cat /tmp/lazy-nvim-output.txt")
      print(f"lazy.nvim buffer output:\n{output}")
      ${assertions}

      machine.copy_from_vm("/tmp/lazy-nvim-output.txt")
    '';
}
