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

        mkPname = prettyName: "arduino-" + (replaceStrings
          [ " " ]
          [ "-" ]
          (lib.strings.toLower prettyName)
        );

        # Returns a set containing the Arduino index derivation as `.drv`, and the resulting attrs as `.attrs`.
        fetchArduinoIndex = { url, sha256 }:
          let
            inherit (builtins) match fetchurl foldl' compareVersions filter;

            indexRawStem = match ''^.+/([A-Za-z0-9_\-]+)\.json$'' url;
            # FIXME: assert match doesn't fail.
            indexName = replaceStrings [ "_" ] [ "-" ] (head indexRawStem);

            #mkPackages = indexAttrs:
            #  lib.lists.forEach
            #    indexAttrs.packages
            #    (packagesAttrs: {
            #      name = packagesAttrs.name;
            #    })
            #;


          in
            pkgs.stdenv.mkDerivation {
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
            }
        ; # fetchFromArduinoIndex

        mkIndexPackages = index:
          let
            attrs = builtins.fromJSON (builtins.readFile "${index}/index.json");

            packageNames = traceSeq (lib.lists.forEach attrs.packages (package: package.name));

            mkPackage = packageName:
              let
                packageAttrs =
                  lib.lists.findFirst
                    (package: package.name == packageName)
                    (throw "Unreachable")
                    attrs.packages
                ;

                packagePlatformArches =
                  lib.lists.unique (
                    lib.lists.forEach
                      (traceType packageAttrs.platforms)
                      (plat: trace plat.architecture)
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

          in {
            packages = lib.attrsets.genAttrs packageNames mkPackage;
          }
        ;





            #  attrs = builtins.fromJSON (builtins.readFile "${drv}/index.json");
            #
            #  packages =
            #    let
            #      packageNames = lib.lists.forEach attrs.packages (package: package.name);
            #
            #      mkPackage = packageName:
            #        let
            #          packageAttrs = lib.lists.findFirst (package: package.name == packageName);
            #
            #          packagePlatformArches =
            #            lib.lists.unique (lib.lists.forEach packageAttrs.platforms) (plat: plat.architecture)
            #          ;
            #
            #          # Get the latest platform for each architecture.
            #          latestPlatformsAttrs =
            #            lib.lists.forEach
            #              packagePlatformArches
            #              (arch:
            #                foldl'
            #                  latestVersion
            #                  dummyPlatformVersion
            #                  (filter (plat: plat.architecture == arch) packageAttrs.platforms)
            #              )
            #          ;
            #
            #          mkPlatform = { platformName, version, url, checksum, architecture }:
            #            let
            #              outPath = "${packageName}/hardware/${architecture}/${version}";
            #              # FIXME: comment
            #              builtChecksum = mkChecksum checksum;
            #            in
            #              pkgs.stdenv.mkDerivation {
            #                pname = platformName;
            #                inherit version;
            #
            #                src = fetchurl {
            #                  inherit url;
            #                  "${builtChecksum.kind}" = builtChecksum.value;
            #                };
            #
            #                dontConfigure = true;
            #                dontBuild = true;
            #
            #                installPhase = ''
            #                  mkdir -p "$out/${outPath}"
            #                  cp -r ./* "$out/${outPath}/";
            #                '';
            #              }
            #          ;
            #        in {
            #          name = packageName;
            #          platforms = lib.lists.forEach
            #            latestPlatformsAttrs
            #            (platformAttrs: mkPlatform {
            #              platformName = platformAttrs.name;
            #              inherit (platformAttrs) version url checksum architecture;
            #            })
            #          ;
            #        }
            #      ; # mkPackage
            #    in
            #      lib.attrsets.genAttrs
            #        packageNames
            #        mkPackage
            #  ; # packages
            #}
            #
        #; # fetchFromArduinoIndex

        #buildArduinoPlatform = { pname, version, vendor, url, checksum, architecture }:
        #  let
        #    outPath = "${vendor}/hardware/${architecture}/${version}";
        #    builtChecksum = mkChecksum (lib.traceSeq [ url checksum ] checksum);
        #  in
        #    pkgs.stdenv.mkDerivation {
        #      inherit pname version;
        #
        #      src = fetchurl {
        #        inherit url;
        #        "${builtChecksum.kind}" = (builtins.trace builtChecksum.kind) builtChecksum.value;
        #      };
        #
        #      dontConfigure = true;
        #      dontBuild = true;
        #
        #      installPhase = ''
        #        echo "Installing ${pname}!"
        #        mkdir -p "$out/${outPath}"
        #        cp -r ./* "$out/${outPath}/"
        #      '';
        #  }
        #;
        #
        #adafruit_index = pkgs.stdenv.mkDerivation {
        #  name = "arduino-adafruit-index";
        #
        #  src = fetchurl {
        #    url = "https://adafruit.github.io/arduino-board-index/package_adafruit_index.json";
        #    sha256 = "0dsxql1lw6c6yhdsmdynvqs342vxlc0h553xbcdc4zjhknv7p5jh";
        #  };
        #
        #  dontUnpack = true;
        #  dontBuild = true;
        #
        #  installPhase = ''
        #    mkdir -p $out
        #    cp $src $out/package_adafruit_index.json
        #  '';
        #};
        #
        #adafruitIndex = builtins.fromJSON (builtins.readFile "${adafruit_index}/package_adafruit_index.json");
        #
        #adafruitPackages = lib.lists.findSingle
        #  (package: package.name == "adafruit")
        #  (throw "Adafruit package not found")
        #  (throw "Multiple Adafruit packages found")
        #  adafruitIndex.packages
        #;
        #
        #architectures =
        #  lib.lists.unique
        #    # unique: list to operate on
        #    (lib.lists.forEach
        #      # forEach: list to operate on
        #      (traceType adafruitPackages.platforms)
        #      # forEach: operation
        #      (platform: platform.architecture)
        #  )
        #;
        #
        ## Get the latest version for each architecture.
        #latestPlatformsInfo =
        #  lib.lists.forEach
        #    # forEach: list to operator on
        #    architectures
        #    # forEach: operation
        #    (arch:
        #      foldl'
        #        # foldl': op
        #        (lhs: rhs: if (compareVersions lhs.version rhs.version) == 1 then lhs else rhs)
        #        # foldl': first arg
        #        ({ version = "0.0.0"; })
        #        # foldl': list to operate on
        #        (filter (plat: plat.architecture == arch) adafruitPackages.platforms)
        #    )
        #;
        #
        #eachPlatform = lib.lists.forEach
        #  latestPlatformsInfo
        #  (plat: buildArduinoPlatform {
        #    inherit (plat) checksum architecture url version;
        #    pname = plat.name;
        #    vendor = "adafruit";
        #  })
        #;
        #
        #allPlatforms = pkgs.symlinkJoin {
        #  name = "arduino-adafruit-platforms";
        #  paths = eachPlatform;
        #};
        #
        index = fetchArduinoIndex {
          url = "https://adafruit.github.io/arduino-board-index/package_adafruit_index.json";
          sha256 = "0dsxql1lw6c6yhdsmdynvqs342vxlc0h553xbcdc4zjhknv7p5jh";
        };

        adindex = mkIndexPackages index;

        adafruit = pkgs.symlinkJoin {
          name = "adafruit";
          paths = adindex.packages.adafruit.platforms;
        };

        #adafruit = mkIndexPackages index;

      in {
        packages.default = adafruit;
      }
    )
  ;
}
