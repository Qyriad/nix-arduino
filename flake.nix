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

        checksumKinds = [
          ({ prefix = "SHA-256:"; kind = "sha256"; })
          ({ prefix = "MD5:"; kind = "md5"; })
        ];

        # HACK: some things are still specified with MD5, so this set here will indicate what
        # MD5 hashes to replace, which will need to be manually updated.
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

                mkPlatform = { platformName, version, url, checksum, architecture }:
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

                      dontConfigure = true;
                      dontBuild = true;

                      installPhase = ''
                        mkdir -p "$out/${outPath}"
                        cp -r ./* "$out/${outPath}/"
                      '';
                    }
                ;

                mkTool = { toolName, version, url, checksum, host }:
                  let outPath = "${packageName}/tools/${toolName}/${version}";
                in
                  pkgs.stdenv.mkDerivation {
                    pname = "arduino-${packageName}-${toolName}";
                    inherit version;

                    src = fetchurl {
                      inherit url;
                      hash = mkHash checksum;
                    };

                    # HACK: fetchurl doesn't know how to unpack zip files, but
                    # fetchzip hashes *after* unpack. So if we have a zip file, then unpack that
                    # manually.
                    unpackCmd = if lib.hasSuffix ".zip" url then "${pkgs.unzip}/bin/unzip $src" else null;
                    dontConfigure = true;
                    dontBuild = true;

                    installPhase = ''
                      mkdir -p "$out/${outPath}"
                      cp -r ./* "$out/${outPath}/"
                    '';
                  }
                ;

              in {
                name = packageName;
                platforms = lib.attrsets.mapAttrs
                  (name: value: mkPlatform {
                    platformName = name;
                    inherit (value) version url checksum architecture;
                  })
                  platformsByArch
                ;

                tools = lib.attrsets.mapAttrs
                  (name: value: mkTool {
                    toolName = name;
                    inherit (value) version url checksum host;
                  })
                  toolsByName
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
          paths = (lib.attrsets.mapAttrsToList (name: value: value) adafruit.packages.adafruit.platforms) ++ (lib.attrsets.mapAttrsToList (name: value: value) adafruit.packages.adafruit.tools);
        };

      in {
        packages.default = adafruitPlatforms;
        platforms = adafruit;
      }
    )
  ;
}
