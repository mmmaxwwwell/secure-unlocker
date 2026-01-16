{
  description = "Secure Unlocker NixOS Module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModule = import ./module.nix;

    packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        init-encrypted = pkgs.writeShellScriptBin "init-encrypted" (builtins.readFile ./secure-unlocker-init.sh);
        default = self.packages.${system}.init-encrypted;
      }
    );

    devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        default = pkgs.mkShell {
          buildInputs = [
            pkgs.nodejs_24
            self.packages.${system}.init-encrypted
          ];
        };
      }
    );

    # Integration tests (Linux only - requires VM with root access)
    # Imports from tests.nix to share test definitions with non-flake users
    checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tests = import ./tests.nix {
          inherit pkgs;
          nixosModule = self.nixosModule;
        };
      in {
        inherit (tests) integration-test integration-test-btrfs;
      }
    );
  };
}
