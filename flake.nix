{
  description = "Bit Torrent in Nim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "bt-in-nim";
          version = "0.0.1";
          src = ./.;

          buildInputs = with pkgs; [ nim-2_0 ];

          buildPhase = ''
            mkdir -p $out/bin
            export HOME=$(pwd)
            ${pkgs.nim-2_0}/bin/nim c -d:release -o:$out/bin/bt bt.nim
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ nim-2_0 ];
          shellHook = ''
            echo "Nimrod: $(${pkgs.nim-2_0}/bin/nim -v)"
            echo "Run './result/bin/bt'."
          '';
        };
      });
}
