{
  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        inherit (builtins) head substring stringLength replaceStrings foldl' filter compareVersions listToAttrs hasAttr;
        inherit (pkgs) lib fetchurl fetchzip;

        trace = arg: builtins.trace arg arg;
        traceSeq = arg: lib.debug.traceSeq arg arg;
        traceType = arg: builtins.trace (builtins.typeOf arg) arg;

        attrsToList = attrs: lib.attrsets.mapAttrsToList (name: value: value) attrs;

        systemDoubleFromString = string:
          let
            inherit (pkgs.lib.systems.parse) mkSystemFromString doubleFromSystem;
            result =
              assert (builtins.typeOf string == "string");
              builtins.tryEval
                (doubleFromSystem (mkSystemFromString string))
            ;
          in
            if result.success then result.value else null
        ;

        # HACK: fetchurl doesn't accept MD5s, but it does accept SRIs from MD5s.
        # And make things easier, we'll just use SRIs for other hashes too.
        # But as far as I can tell, nixpkgs doesn't have a library function to calculate
        # SRIs. The Nix command does, though, so let's create a derivation that runs the Nix
        # command to calculate the SRI hash.
        mkHash = checksumString:
          let
            newString = lib.strings.replaceStrings
              [ "SHA-256:" "MD5:" ]
              [ "sha256:" "md5:" ]
              checksumString
            ;

            sri = pkgs.runCommand "sri-hash-${newString}" { } ''
              mkdir $out
              ${pkgs.nix}/bin/nix-hash --to-sri "${newString}" > $out/hash
            '';
          in
            (builtins.readFile "${sri}/hash")
        ;

        # Create a version of atool that can unpack most things.
        aunpack = pkgs.symlinkJoin {
          name = "advancedUnpacker";
          paths = with pkgs; [
            atool
            unzip
            gnutar
            xz
            gzip
            bzip2
            bzip3
          ];
        };

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

                # And index by architecture.
                platformsByArch = listToAttrs (
                  lib.lists.forEach
                    latestPlatformsAttrs
                    (plat: lib.attrsets.nameValuePair plat.architecture plat)
                );

                # Takes a tool a returns a list of tool systems.
                mkToolSet = tool:
                  lib.lists.forEach
                    tool.systems
                    # Add the base tool name and version to the "system" attributes.
                    (toolSystem: toolSystem // { name = tool.name; version = tool.version; })
                ;

                toolsForHost =
                  filter
                    (tool: (systemDoubleFromString tool.host) == system)
                    (lib.lists.flatten (lib.lists.forEach packageAttrs.tools mkToolSet))
                ;

                toolsByName = listToAttrs (
                  lib.lists.forEach
                    toolsForHost
                    (tool: lib.attrsets.nameValuePair tool.name tool)
                );

                mkTool = { toolName, version, url, checksum, host }:
                  let
                    outPath = "${packageName}/tools/${toolName}/${version}";
                  in
                    pkgs.stdenv.mkDerivation {
                      pname = "arduino-${packageName}-${toolName}";
                      inherit version;

                      src = fetchurl {
                        inherit url;
                        hash = mkHash checksum;
                      };

                      # HACK: fetchurl doesn't know how to unpack zip files, but
                      # fetchzip hashes *after* unpack. Also, some of these archives have
                      # a root folder and some don't. Let's just use aunpack to normalize it all.
                      unpackCmd = ''
                        export PATH="$PATH:${aunpack}/bin"
                        aunpack $src
                      '';
                      dontConfigure = true;
                      dontBuild = true;

                      installPhase = ''
                        mkdir -p "$out/${outPath}"
                        cp -r ./* "$out/${outPath}/"
                      '';
                    }
                ; # mkTool

                tools = lib.attrsets.mapAttrs
                  (name: value: mkTool {
                    toolName = name;
                    inherit (value) version url checksum host;
                  })
                  toolsByName
                ;

                # TODO: toolDependencies not yet implemented.
                mkPlatform = { platformName, version, url, checksum, architecture, platformAttrs ? {} }:
                  let
                    outPath = "${packageName}/hardware/${architecture}/${version}";
                    # FIXME: comment
                  in
                    pkgs.stdenv.mkDerivation {
                      pname = "arduino-${packageName}-${platformName}";
                      inherit version;

                      src = fetchurl {
                        inherit url;
                        hash = mkHash checksum;
                      };

                      # HACK: fetchurl doesn't know how to unpack zip files, but
                      # fetchzip hashes *after* unpack. Also, some of these archives have
                      # a root folder and some don't. Let's just use aunpack to normalize it all.
                      unpackCmd = ''
                        export PATH="$PATH:${aunpack}/bin"
                        aunpack $src
                      '';

                      dontConfigure = true;
                      dontBuild = true;

                      installPhase = ''
                        mkdir -p "$out/${outPath}"
                        cp -r ./* "$out/${outPath}/"
                      '';

                      passthru.platformAttrs = platformAttrs;
                    }
                ;

              in {
                name = packageName;
                platforms = lib.attrsets.mapAttrs
                  (name: value: mkPlatform {
                    platformName = name;
                    inherit (value) version url checksum architecture;
                    platformAttrs = value;
                  })
                  platformsByArch
                ;

                inherit tools;
              }
            ; # mkPackage

          in
            lib.attrsets.genAttrs packageNames mkPackage
        ; # mkIndexPackages

        # Creates a derivation to fetch an Arduino index JSON file from the specified URL,
        # and populates an attrset with the results of the JSON file. This function returns an attrset
        # with the derivation in `.drv`, the JSON result attributes in `.attrs`, and attrsets representing the
        # packages described in this index as `.packages`.
        # The derivation has two outputs. `out`, as a directory containing only the index JSON file as it
        # was originally named (suitable for merging/symlinking with other Arduino packages to create an Arduino
        # data directory environment), and `index`, the JSON file as a single-file output.
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

              outputs = [ "out" "index" ];

              dontUnpack = true;
              dontConfigure = true;
              dontBuild = true;

              installPhase = ''
                mkdir -p $out
                cp $src $out/${indexName}
                cp $src $index
              '';
            };

            attrs = builtins.fromJSON (builtins.readFile drv.index);

            packages = mkIndexPackages attrs;

          in {
            inherit drv attrs packages;

            allPlatforms =
              lib.lists.flatten (
                lib.lists.forEach
                  (attrsToList packages)
                  (package: attrsToList package.platforms)
              )
            ;

            allTools =
              lib.lists.flatten (
                lib.lists.forEach
                  (attrsToList packages)
                  (package: attrsToList package.tools)
              )
            ;
          }

        ; # fetchFromArduinoIndex


        arduinoIndex = fetchArduinoIndex {
          url = "https://downloads.arduino.cc/packages/package_index.json";
          sha256 = "2793dbf068ec2d3b86c060e42a8f5a2faa6a61c799481bb1b9ff20989cbd938e";
        };

        adafruitIndex = fetchArduinoIndex {
          url = "https://adafruit.github.io/arduino-board-index/package_adafruit_index.json";
          sha256 = "0dsxql1lw6c6yhdsmdynvqs342vxlc0h553xbcdc4zjhknv7p5jh";
        };

        adafruitSamdPkgs = pkgs.symlinkJoin {
          name = "adafruitSamdPkgs";
          paths =
            let
              inherit (adafruitIndex.packages) adafruit;
              inherit (arduinoIndex.packages) arduino;
            in [
              adafruit.platforms.samd
              # Dependencies for adafruit.packages.adafruit.platforms.samd.
              adafruit.tools.arm-none-eabi-gcc
              adafruit.tools.bossac
              arduino.tools.bossac
              arduino.tools.openocd
              adafruit.tools."CMSIS"
              adafruit.tools."CMSIS-Atmel"
              arduino.tools."arduinoOTA"
            ];
        };

      in {
        packages.default = adafruitSamdPkgs;
        indexes = {
          inherit adafruitIndex;
          inherit arduinoIndex;
        };
      }
    ) # eachDefaultSystem
  ;
}
