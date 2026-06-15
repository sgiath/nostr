{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [ git prettier ];

  languages = {
    elixir = {
      enable = true;
      package = pkgs.beamMinimal29Packages.elixir_1_20;
    };

    javascript = {
      enable = true;
      package = pkgs.nodejs-slim;
      pnpm.enable = true;
    };

    python = {
      enable = true;
      venv.enable = true;
      uv.enable = true;
    };
  };

  env = {
    MIX_OS_DEPS_COMPILE_PARTITION_COUNT = "16";
    ERL_AFLAGS = "+pc unicode -kernel shell_history enabled";
    ELIXIR_ERL_OPTIONS = "+sssdio 128";
  };
  dotenv.disableHint = true;
}
