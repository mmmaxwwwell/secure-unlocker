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
    # These tests use the real NixOS module systemd units and Express server
    # Test matrix covers:
    #   - ext4 loop device
    #   - ext4 block device
    #   - btrfs single loop device
    #   - btrfs single block device
    #   - btrfs raid1 multi loop device
    #   - btrfs raid1 multi block device
    checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tests = import ./tests.nix {
          inherit pkgs;
          nixosModule = self.nixosModule;
        };
      in {
        inherit (tests)
          integration-test-ext4-loop
          integration-test-ext4-block
          integration-test-btrfs-loop
          integration-test-btrfs-block
          integration-test-btrfs-raid1-loop
          integration-test-btrfs-raid1-block;
      }
    );
  };
}
