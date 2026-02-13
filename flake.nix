{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ parts, ... }:
    parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, ... }:
        let
          beamPackages = pkgs.beam_minimal.packages.erlang_28;
          elixir = beamPackages.elixir_1_19;
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              elixir
              nodejs

              python3
              pkg-config # required by secp256k1 build
              secp256k1 # secp256k1 C library
              gcc # compiler
              gnumake # correct name for make
              autoreconfHook

              git
              prettier
            ];
            env = {
              MIX_OS_DEPS_COMPILE_PARTITION_COUNT = "16";
              ERL_AFLAGS = "+pc unicode -kernel shell_history enabled";
              ELIXIR_ERL_OPTIONS = "+sssdio 128";
            };

            shellHook = ''
              printf "Setting up virtual environment…\n"
              if [ ! -d ".venv" ]; then
                python3 -m venv .venv
              fi
              source .venv/bin/activate
            '';
          };
        };
    };
}
