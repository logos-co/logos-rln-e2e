# librlnconsumer — the RlnConsumer Nim library, built the way logos-delivery
# builds liblogosdelivery (nix/default.nix there), minus everything this lib
# doesn't need: no zerokit, no postgres, no nat_traversal. The nim-ffi C
# bindings header is generated during the build and installed to include/.
{ pkgs, src }:

let
  deps = import ./deps.nix { inherit pkgs; };

  # Some packages keep sources under src/; pass both layouts.
  pathArgs = builtins.concatStringsSep " " (builtins.concatMap
    (p: [ "--path:${p}" "--path:${p}/src" ])
    (builtins.attrValues deps));

  libExt = if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so";

  nim = pkgs.nim-2_2 or pkgs.nim;

  nimFlags = builtins.concatStringsSep " " [
    "--noNimblePath"
    pathArgs
    "--define:disable_libbacktrace"
    "--threads:on"
    "--mm:refc"
    "--hints:off"
    "--nimcache:$NIMCACHE"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "librlnconsumer";
  version = "dev";

  inherit src;

  nativeBuildInputs = [ nim pkgs.git ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.cctools ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMCACHE=$TMPDIR/nimcache
    mkdir -p build $NIMCACHE

    echo "== Generating C bindings =="
    nim c ${nimFlags} \
      --compileOnly \
      -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=$TMPDIR/c_abi_bindings -d:ffiSrcPath=src/rlnconsumer.nim \
      src/rlnconsumer.nim

    echo "== Building librlnconsumer (dynamic) =="
    nim c ${nimFlags} \
      --app:lib \
      --opt:size \
      --noMain \
      --header \
      --nimMainPrefix:librlnconsumer \
      --out:build/librlnconsumer.${libExt} \
      src/rlnconsumer.nim
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    cp build/librlnconsumer.${libExt} $out/lib/
    cp $TMPDIR/c_abi_bindings/rlnconsumer.h $out/include/
    cp include/rlnconsumer_rln.h $out/include/
    runHook postInstall
  '';

  # Same install-name discipline as liblogosdelivery so the .lgx bundle's
  # plugin finds the lib via @loader_path / $ORIGIN.
  postInstall =
    pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      chmod +w $out/lib/librlnconsumer.dylib
      install_name_tool -id @rpath/librlnconsumer.dylib $out/lib/librlnconsumer.dylib
      install_name_tool -add_rpath @loader_path $out/lib/librlnconsumer.dylib
    ''
    + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      patchelf --add-rpath '$ORIGIN' $out/lib/librlnconsumer.so
    '';

  meta.description = "RlnConsumer — Nim mock of logos-delivery's RLN integration";
}
