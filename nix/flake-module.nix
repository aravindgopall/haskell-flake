# A flake-parts module for Haskell cabal projects.
{ self, config, lib, flake-parts-lib, withSystem, ... }:

let
  inherit (flake-parts-lib)
    mkPerSystemOption
    mkSubmoduleOptions;
  inherit (lib)
    mkOption
    types;
  inherit (types)
    functionTo
    raw;
in
{
  options = {
    perSystem = mkPerSystemOption
      ({ config, self', inputs', pkgs, system, ... }:
        let
          hlsCheckSubmodule = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                description = ''
                  Whether to enable a flake check to verify that HLS works.
                  
                  This is equivalent to `nix develop -i -c haskell-language-server`.

                  Note that, HLS will try to access the network through Cabal (see 
                  <https://github.com/haskell/haskell-language-server/issues/3128>),
                  therefore sandboxing must be disabled when evaluating this
                  check.
                '';
                default = false;
              };

            };
          };
          packageSubmodule = with types; submodule {
            options = {
              root = mkOption {
                type = path;
                description = "Path to Haskell package where the `.cabal` file lives";
              };
            };
          };
          devShellSubmodule = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                description = ''
                  Whether to enable a development shell for the project.
                '';
                default = true;
              };
              tools = mkOption {
                type = functionTo (types.attrsOf (types.nullOr types.package));
                description = ''
                  Build tools for developing the Haskell project.
                '';
                default = hp: { };
                defaultText = ''
                  Build tools useful for Haskell development are included by default.
                '';
              };
              hlsCheck = mkOption {
                default = { };
                type = hlsCheckSubmodule;
                description = ''
                  A [check](flake-parts.html#opt-perSystem.checks) to make sure that your IDE will work.
                '';
              };
              mkShellArgs = mkOption {
                type = types.attrsOf types.raw;
                description = ''
                  Extra arguments to pass to `pkgs.mkShell`.
                '';
                default = { };
                example = ''
                  {
                    shellHook = \'\'
                      # Re-generate .cabal files so HLS will work (per hie.yaml)
                      ''${pkgs.findutils}/bin/find -name package.yaml -exec hpack {} \;
                    \'\';
                  };
                '';
              };
            };
          };
          outputsSubmodule = types.submodule {
            options = {
              finalOverlay = mkOption {
                type = types.raw;
                readOnly = true;
                internal = true;
              };
              finalPackages = mkOption {
                # This must be raw because the Haskell package set also contains functions.
                type = types.attrsOf types.raw;
                readOnly = true;
                description = ''
                  The final Haskell package set including local packages and any
                  overrides, on top of `basePackages`.
                '';
              };
              localPackages = mkOption {
                type = types.attrsOf types.package;
                readOnly = true;
                description = ''
                  The local Haskell packages in the project.

                  This is a subset of `finalPackages` containing only local
                  packages excluding everything else.
                '';
              };
              devShell = mkOption {
                type = types.package;
                readOnly = true;
                description = ''
                  The development shell derivation generated for this project.
                '';
              };
              hlsCheck = mkOption {
                type = types.package;
                readOnly = true;
                description = ''
                  The `hlsCheck` derivation generated for this project.
                '';
              };
            };
          };
          projectSubmodule = types.submoduleWith {
            specialArgs = { inherit pkgs self; };
            modules = [
              ./haskell-project.nix
              {
                options = {
                  basePackages = mkOption {
                    type = types.attrsOf raw;
                    description = ''
                      Which Haskell package set / compiler to use.

                      You can effectively select the GHC version here. 
                  
                      To get the appropriate value, run:

                          nix-env -f "<nixpkgs>" -qaP -A haskell.compiler

                      And then, use that in `pkgs.haskell.packages.ghc<version>`
                    '';
                    example = "pkgs.haskell.packages.ghc924";
                    default = pkgs.haskellPackages;
                    defaultText = lib.literalExpression "pkgs.haskellPackages";
                  };
                  source-overrides = mkOption {
                    type = types.attrsOf (types.oneOf [ types.path types.str ]);
                    description = ''
                      Source overrides for Haskell packages

                      You can either assign a path to the source, or Hackage
                      version string.
                    '';
                    default = { };
                  };
                  overrides = mkOption {
                    type = import ./haskell-overlay-type.nix { inherit lib; };
                    description = ''
                      Cabal package overrides for this Haskell project
                
                      For handy functions, see 
                      <https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/haskell-modules/lib/compose.nix>

                      **WARNING**: When using `imports`, multiple overlays
                      will be merged using `lib.composeManyExtensions`.
                      However the order the overlays are applied can be
                      arbitrary (albeit deterministic, based on module system
                      implementation).  Thus, the use of `overrides` via
                      `imports` is not officiallly supported. If you'd like
                      to see proper support, add your thumbs up to
                      <https://github.com/NixOS/nixpkgs/issues/215486>.
                    '';
                    default = self: super: { };
                    defaultText = lib.literalExpression "self: super: { }";
                  };
                  packages = mkOption {
                    type = types.lazyAttrsOf packageSubmodule;
                    description = ''
                      Attrset of local packages in the project repository.

                      Autodiscovered by default by looking for `.cabal` files in
                      top-level or sub-directories.
                    '';
                    default =
                      let find-cabal-paths = import ./find-cabal-paths.nix { inherit lib; };
                      in
                      lib.mapAttrs
                        (_: value: { root = value; })
                        (find-cabal-paths self);
                    defaultText = lib.literalMD "autodiscovered by reading `self` files.";
                  };
                  devShell = mkOption {
                    type = devShellSubmodule;
                    description = ''
                      Development shell configuration
                    '';
                    default = { };
                  };
                  outputs = mkOption {
                    type = outputsSubmodule;
                    description = ''
                      The flake outputs generated for this project.

                      This is an internal option, not meant to be set by the user.
                    '';
                  };


                };
              }
            ];
          };
        in
        {
          options = {
            haskellProjects = mkOption {
              description = "Haskell projects";
              type = types.attrsOf projectSubmodule;
            };

          };

          config =
            let
              # Like mapAttrs, but merges the values (also attrsets) of the resulting attrset.
              mergeMapAttrs = f: attrs: lib.mkMerge (lib.mapAttrsToList f attrs);
            in
            {
              packages =
                mergeMapAttrs
                  (name: project:
                    let
                      mapKeys = f: attrs: lib.mapAttrs' (n: v: { name = f n; value = v; }) attrs;
                      # Prefix package names with the project name (unless
                      # project is named `default`)
                      dropDefaultPrefix = packageName:
                        if name == "default"
                        then packageName
                        else "${name}-${packageName}";
                    in
                    mapKeys dropDefaultPrefix project.outputs.localPackages)
                  config.haskellProjects;
              devShells =
                mergeMapAttrs
                  (name: project:
                    lib.optionalAttrs project.devShell.enable {
                      "${name}" = project.outputs.devShell;
                    })
                  config.haskellProjects;
              checks =
                mergeMapAttrs
                  (name: project:
                    lib.optionalAttrs (project.devShell.enable && project.devShell.hlsCheck.enable) {
                      "${name}-hls" = project.outputs.hlsCheck;
                    })
                  config.haskellProjects;
            };
        });

    flake = mkSubmoduleOptions {
      haskellFlakeProjectModules = mkOption {
        type = types.lazyAttrsOf types.deferredModule;
        description = ''
          An attrset of `haskellProjects.<name>` modules that can be imported in
          other flakes.
        '';
        defaultText = ''
          Package and dependency information for this project exposed for reuse
          in another flake, when using this project as a Haskell dependency.

          Typically the consumer of this flake will want to use one of the
          following modules:

            - output: provides both local package and dependency overrides.
            - local: provides only local package overrides (ignores dependency
              overrides in this flake)
        '';
        default = rec {
          # The 'output' module provides both local package and dependency
          # overrides.
          output = {
            imports = [ input local ];
          };
          # The 'local' module provides only local package overrides.
          local = { pkgs, lib, ... }: withSystem pkgs.system ({ config, ... }: {
            source-overrides =
              lib.mapAttrs (_: v: v.root)
                config.haskellProjects.default.packages;
          });
          # The 'input' module contains only dependency overrides.
          input = { pkgs, ... }: withSystem pkgs.system ({ config, ... }: {
            inherit (config.haskellProjects.default)
              source-overrides overrides;
          });
        };
      };
    };
  };
}
