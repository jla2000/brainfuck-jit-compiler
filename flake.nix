{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [ pkgs.zig ];
      };

      packages.${system}.default = pkgs.stdenv.mkDerivation {
        name = "brainfuck-jit-compiler";
        src = self;
        nativeBuildInputs = [ pkgs.zig.hook ];
      };
    };
}
