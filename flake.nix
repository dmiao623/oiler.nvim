{
  description = "oiler.nvim development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          pyparsing
          black
          isort
          mypy
        ]);
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            neovim
            luajitPackages.luacheck
            stylua
            pythonEnv
          ];
        };
      }
    );
}
