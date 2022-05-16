{
  inputs = {
    flake-utils.url = github:numtide/flake-utils;

    plutus.url = github:input-output-hk/plutus;

    nixpkgs.follows = "plutus/nixpkgs";
    # nixpkgs.follows = "plutip/nixpkgs";

    # haskell-nix.follows = "plutus/haskell-nix"; # to old for this template
    haskell-nix.url = github:input-output-hk/haskell.nix;
    plutus.inputs.haskell-nix.follows = "haskell-nix";

    cardano-base = {
      url = github:input-output-hk/cardano-base;
      flake = false;
    };
    cardano-crypto = {
      url = github:input-output-hk/cardano-crypto;
      flake = false;
    };
    cardano-prelude = {
      url = github:input-output-hk/cardano-prelude;
      flake = false;
    };

    plutip.url = github:mlabs-haskell/plutip?rev=88d069d68c41bfd31b2057446a9d4e584a4d2f32;

    plutarch.url = github:Plutonomicon/plutarch;
    plutarch.inputs.plutus.follows = "plutus";
    plutarch.inputs.haskell-nix.follows = "haskell-nix";
    plutarch.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs@{ flake-utils, nixpkgs, haskell-nix, ... }:
    flake-utils.lib.eachSystem (with nixpkgs.lib.systems.supported; tier1 ++ tier2 ++ tier3) (system:
      let
        compiler-nix-name = "ghc810420210212";
        # index-state = "2022-05-04T00:00:00Z";

        pkgs = import nixpkgs { inherit system overlays; inherit (haskell-nix) config; };

        overlay = final: prev: rec {

          mkPackageSpec = src: with pkgs.lib;
            let
              cabalFiles = concatLists (mapAttrsToList
                (name: type: if type == "regular" && hasSuffix ".cabal" name then [ name ] else [ ])
                (builtins.readDir src));

              cabalPath =
                if length cabalFiles == 1
                then src + "/${head cabalFiles}"
                else builtins.abort "Could not find unique file with .cabal suffix in source: ${src}";
              cabalFile = builtins.readFile cabalPath;
              parse = field:
                let
                  lines = filter (s: if builtins.match "^${field} *:.*$" (toLower s) != null then true else false) (splitString "\n" cabalFile);
                  line =
                    if lines != [ ]
                    then head lines
                    else builtins.abort "Could not find line with prefix ''${field}:' in ${cabalPath}";
                in
                replaceStrings [ " " ] [ "" ] (head (tail (splitString ":" line)));
              pname = parse "name";
              version = parse "version";
            in
            { inherit src pname version; };

          mkPackageTarball = { pname, version, src }: pkgs.runCommand "${pname}-${version}.tar.gz" { } ''
            cd ${src}/..
            tar --sort=name --owner=Hackage:0 --group=Hackage:0 --mtime='UTC 2009-01-01' -czvf $out $(basename ${src})
          '';

          mkHackageDir = { pname, version, src }@args: pkgs.runCommand "${pname}-${version}-hackage"
            {
              tarball = mkPackageTarball args;
            } ''
            set -e
            mkdir -p $out/${pname}/${version}
            md5=$(md5sum "$tarball"  | cut -f 1 -d ' ')
            sha256=$(sha256sum "$tarball" | cut -f 1 -d ' ')
            length=$(stat -c%s "$tarball")
            cat <<EOF > $out/"${pname}"/"${version}"/package.json
            {
              "signatures" : [],
              "signed" : {
                  "_type" : "Targets",
                  "expires" : null,
                  "targets" : {
                    "<repo>/package/${pname}-${version}.tar.gz" : {
                        "hashes" : {
                          "md5" : "$md5",
                          "sha256" : "$sha256"
                        },
                        "length" : $length
                    }
                  },
                  "version" : 0
              }
            }
            EOF
            cp ${src}/*.cabal $out/"${pname}"/"${version}"/
          '';

          mkHackageTarballFromDirs = hackageDirs: pkgs.runCommand "01-index.tar.gz" { } ''
            mkdir hackage
            ${pkgs.lib.concatStrings (map (dir: ''
              echo ${dir}
              ln -s ${dir}/* hackage/
            '') hackageDirs)}
            cd hackage
            tar --sort=name --owner=root:0 --group=root:0 --mtime='UTC 2009-01-01' -hczvf $out */*/*
          '';

          mkHackageTarball = pkg-defs: mkHackageTarballFromDirs (map mkHackageDir pkg-defs);

          mkHackageNix = hackageTarball: pkgs.runCommand "hackage-nix" { } ''
            set -e
            cp ${hackageTarball} 01-index.tar.gz
            ${pkgs.gzip}/bin/gunzip 01-index.tar.gz
            ${pkgs.haskell-nix.nix-tools.${compiler-nix-name}}/bin/hackage-to-nix $out 01-index.tar "https://not-there/"
          '';

          mkHackageFromSpec = extraHackagePackages: rec {
            tarballs = pkgs.lib.listToAttrs (map (def: { name = def.pname; value = mkPackageTarball def; }) extraHackagePackages);
            hackageTarball = mkHackageTarball extraHackagePackages;
            hackageNix = mkHackageNix hackageTarball;
            # Prevent nix-build from trying to download the package
            module = { packages = (pkgs.lib.mapAttrs (pname: tarball: { src = tarball; }) tarballs); };
          };

          mkHackage = srcs: mkHackageFromSpec (map mkPackageSpec srcs);

          # Usage:
          myhackage = mkHackage [ "${inputs.plutus}/plutus-core"
                                  "${inputs.plutus}/plutus-ledger-api"
                                  "${inputs.plutus}/plutus-tx"
                                  "${inputs.plutus}/prettyprinter-configurable"
                                  "${inputs.plutus}/word-array"
                                  "${inputs.cardano-base}/cardano-crypto-class"
                                  "${inputs.cardano-base}/binary"
                                  inputs.cardano-crypto
                                  "${inputs.cardano-prelude}/cardano-prelude"
                                  inputs.plutip
                                  inputs.plutarch ];
          plutus-tests = final.haskell-nix.project {
            src = ./.;
            inherit compiler-nix-name; # index-state;

            extra-hackages = [ (import myhackage.hackageNix) ];
            extra-hackage-tarballs = { myhackage = myhackage.hackageTarball; };
            modules = [ myhackage.module ];
          };
        };
        overlays = [ haskell-nix.overlay overlay ];
      in
      {
        packages = (pkgs.plutus-tests.flake { }).packages // {
          default = (pkgs.plutus-tests.flake { }).packages."plutus-tests:test:plutus-tests";
        };

        # export
        inherit (pkgs) mkPackageSpec mkPackageTarball mkHackageDir mkHackageTarballFromDirs mkHackageTarball mkHackageNix mkHackageFromSpec mkHackage;

        # for debugging
        inherit (pkgs) plutus-tests haskell-nix myhackage;

        checks = (pkgs.plutus-tests.flake { }).checks;
        herculesCI.ciSystems = [ "x86_64-linux" ];
      }
    );
}
