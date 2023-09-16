{
  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        inherit (builtins) fetchurl head substring stringLength replaceStrings foldl' filter compareVersions;
        inherit (pkgs) lib;

        trace = arg: builtins.trace arg arg;
        traceSeq = arg: lib.debug.traceSeq arg arg;
        traceType = arg: builtins.trace (builtins.typeOf arg) arg;

        checksumKinds = [
          ({ prefix = "SHA-256:"; kind = "sha256"; })
          ({ prefix = "MD5:"; kind = "md5"; })
        ];

        mkChecksum = checksumString:
          let
            matchingChecksum = lib.lists.findFirst
              (checksumKind: lib.strings.hasPrefix checksumKind.prefix checksumString)
              (throw "Unknown checksum prefix in ${checksumString}")
              checksumKinds
            ;
          in {
            kind = matchingChecksum.kind;
            value = lib.strings.removePrefix matchingChecksum.prefix checksumString;
          }
        ;

        latestVersion = lhs: rhs: if (compareVersions lhs.version rhs.version) == 1 then lhs else rhs;

        dummyPlatformVersion = {
          version = "0.0.0";
        };

        mkIndexPackages = indexAttrs:
          let
            attrs = indexAttrs;

            packageNames = lib.lists.forEach indexAttrs.packages (package: package.name);

            mkPackage = packageName:
              let
                packageAttrs =
                  lib.lists.findFirst
                    (package: package.name == packageName)
                    (throw "Unreachable")
                    indexAttrs.packages
                ;

                packagePlatformArches =
                  lib.lists.unique (
                    lib.lists.forEach
                      packageAttrs.platforms
                      (plat: plat.architecture)
                  )
                ;

                # Get the latest platform for each architecture.
                latestPlatformsAttrs =
                  lib.lists.forEach
                    packagePlatformArches
                    (arch:
                      foldl'
                        latestVersion
                        dummyPlatformVersion
                        (filter (plat: plat.architecture == arch) packageAttrs.platforms)
                    )
                ;

                mkPlatform = { platformName, version, url, checksum, architecture }:
                  let
                    outPath = "${packageName}/hardware/${architecture}/${version}";
                    # FIXME: comment
                    builtChecksum = mkChecksum checksum;
                  in
                    pkgs.stdenv.mkDerivation {
                      pname = platformName;
                      inherit version;

                      src = fetchurl {
                        inherit url;
                        "${builtChecksum.kind}" = builtChecksum.value;
                      };

                      dontConfigure = true;
                      dontBuild = true;

                      installPhase = ''
                        mkdir -p "$out/${outPath}"
                        cp -r ./* "$out/${outPath}/";
                      '';
                    }
                ;

              in {
                name = packageName;
                platforms = lib.lists.forEach
                  latestPlatformsAttrs
                  (platformAttrs: mkPlatform {
                    platformName = platformAttrs.name;
                    inherit (platformAttrs) version url checksum architecture;
                  })
                ;
              }
            ; # mkPackage

          in
            lib.attrsets.genAttrs packageNames mkPackage
        ; # mkIndexPackages

        fetchArduinoIndex = { url, sha256 }:
          let
            inherit (builtins) match fetchurl foldl' compareVersions filter;

            indexRawStem = match ''^.+/([A-Za-z0-9_\-]+)\.json$'' url;
            # FIXME: assert match doesn't fail.
            indexName = replaceStrings [ "_" ] [ "-" ] (head indexRawStem);

            drv = pkgs.stdenv.mkDerivation {
              # There isn't any meaningful version we can assign here.
              name = "arduino-${indexName}";

              src = fetchurl {
                inherit url sha256;
              };

              dontUnpack = true;
              dontConfigure = true;
              dontBuild = true;

              installPhase = ''
                mkdir -p $out
                cp $src $out/${indexName}
                ln -sr $out/${indexName} $out/index.json
              '';
            };

            attrs = builtins.fromJSON ((builtins.readFile "${drv}/index.json"));

          in {
            inherit drv attrs;
            packages = mkIndexPackages attrs;
          }
        ; # fetchFromArduinoIndex


        adafruit = fetchArduinoIndex {
          url = "https://adafruit.github.io/arduino-board-index/package_adafruit_index.json";
          sha256 = "0dsxql1lw6c6yhdsmdynvqs342vxlc0h553xbcdc4zjhknv7p5jh";
        };

        adafruitPlatforms = pkgs.symlinkJoin {
          name = "adafruit";
          paths = adafruit.packages.adafruit.platforms;
        };

      in {
        packages.default = adafruitPlatforms;
        platforms = adafruit;
      }
    )
  ;
}
