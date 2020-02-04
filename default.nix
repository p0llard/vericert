with import <nixpkgs> {};

stdenv.mkDerivation {
  name = "CoqUp";
  src = ./.;

  buildInputs = [ coq_8_10 ocamlPackages.menhir dune ];

  buildPhase = "make";
}
