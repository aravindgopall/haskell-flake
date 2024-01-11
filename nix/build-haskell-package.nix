# Like callCabal2nix, but does more:
# - Source filtering (to prevent parent content changes causing rebuilds)
# - Always build from cabal's sdist for release-worthiness
# - Logs what it's doing (based on 'log' option)
#
{ pkgs
, lib
  # 'self' refers to the Haskell package set context.
, self
, log
, ...
}:

let
  fromSdist = self.buildFromCabalSdist or
    (log.traceWarning "Your nixpkgs does not have hs.buildFromCabalSdist" (pkg: pkg));

  mkNewStorePath = name: src:
    # Since 'src' may be a subdirectory of a store path
    # (in string form, which means that it isn't automatically
    # copied), the purpose of cleanSourceWith here is to create a
    # new (smaller) store path that is a copy of 'src' but
    # does not contain the unrelated parent source contents.
    lib.cleanSourceWith {
      name = "${name}";
      inherit src;
    };

  callPackageKeepDeriver = src: args:
    pkgs.haskell.lib.compose.overrideCabal
      (orig: {
        passthru = orig.passthru or { } // {
          # When using callCabal2nix or callHackage, it is often useful
          # to debug a failure by inspecting the Nix expression
          # generated by cabal2nix. This can be accessed via this
          # cabal2nixDeriver field.
          cabal2nixDeriver = src;
        };
      })
      (self.callPackage src args);

  callCabal2nixWithOptions = name: src: expr: args:
    pkgs.haskell.lib.compose.overrideCabal
      (orig: {
        inherit src;
      })
      (callPackageKeepDeriver expr args);
in

name: root: expr:
lib.pipe root
  [
    # Avoid rebuilding because of changes in parent directories
    (mkNewStorePath "source-${name}")
    (x: log.traceDebug "${name}.mkNewStorePath ${x.outPath}" x)

    (root: callCabal2nixWithOptions name root expr { })
    # (x: log.traceDebug "${name}.cabal2nixDeriver ${x.cabal2nixDeriver.outPath}" x)

    # Make sure all files we use are included in the sdist, as a check
    # for release-worthiness.
    fromSdist
    (x: log.traceDebug "${name}.fromSdist ${x.outPath}" x)
  ]
