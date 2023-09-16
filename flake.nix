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
        hashReplacements = {
          #"fe0029de4f4ec43cf7008944e34ff8cc" = "0yhp3ps4zv433qkjb6vskiy3mvxjj1wgds9qjqklkgym77w41n5w";
          #
          ## gcc-arm-none-eabi-5_2-2015q4-20151219-linux.tar.bz2
          #"f88caac80b4444a17344f57ccb760b90" = "12mbwl9iwbw7h6gwwkvyvfmrsz7vgjz27jh2cz9z006ihzigi50y";
          #
          ## gcc-5_2-2015q4/nrfjprog-9.4.0-linux64.tar.bz2
          #"da3c7b348e0c22766f175a4a9cca0d19" = "0sg7sibdl1qdbikskn38sya6jv4yq0ma0dvnsxbcvzsar7i71129";
          #
          ## wiced_dfu-1.0.0-linux64.tar.gz
          #"ae36e3e3a35ac507955a3ee4f18e4bb7" = "02g9ck29c2bkqf70nhlmmpxgw4qz7m37li2zg7m7b8pgdzd7psmb";
        };

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

        mkChecksum = checksumString:
          let
            inherit (builtins) hasAttr;
            matchingChecksum = lib.lists.findFirst
              (checksumKind: lib.strings.hasPrefix checksumKind.prefix checksumString)
              (throw "Unknown checksum prefix in ${checksumString}")
              checksumKinds
            ;

            #value = lib.strings.removePrefix matchingChecksum.prefix checksumString;
            value = lib.strings.replaceStrings
              [ "SHA-256:" "MD5:" ]
              [ "sha256-" "md5-" ]
              checksumString
            ;

            replacement = if matchingChecksum.kind == "md5" && (hasAttr value hashReplacements) then
                hashReplacements.${value}
              else
                null
            ;
          in {
            kind = if replacement != null then "sha256" else matchingChecksum.kind;
            value = trace (if replacement != null then replacement else value);
          }
        ;

        mkHash = checksumString:
          let
            newString = lib.strings.replaceStrings
              [ "SHA-256:" "MD5:" ]
              [ "sha256:" "md5:" ]
              checksumString
            ;

            sriDrv = pkgs.runCommand "sri-hash-${newString}" { } ''
              mkdir $out
              ${pkgs.nix}/bin/nix --experimental-features nix-command --offline hash to-sri "${newString}" > $out/hash
            '';
          in
            (builtins.readFile "${sriDrv}/hash")
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

                #mkSystemTool = toolAttrs:
                #  lib.lists.forEach
                #    toolAttrs.systems
                #    (tool: (lib.attrsets.nameValuePair (systemDoubleFromString tool.host tool)) // { inherit (toolAttrs) name version; } )
                #;
                #
                #toolsBySystem =
                #  lib.lists.forEach
                #    packageAttrs.tools
                #    (tool: mkSystemTool tool)
                #;
                #
                #toolsForHost =
                #  filter
                #    (tool: hasAttr system (trace tool)
                #    toolsBySystem
                #;
                #
                #toolsForHostByName =
                #  lib.lists.forEach
                #    (tool: lib.attrsets.nameValuePair (tool.name tool))
                #    toolsForHost
                #;

                #toolsByNameAndSystem =
                #  lib.lists.forEach
                #    packageAttrs.tools
                #    (toolAttrs: lib.attrsets.nameValuePair toolAttrs.name (mkSystemTool toolAttrs))
                #;

                mkPlatform = { platformName, version, url, checksum, architecture }:
                  let
                    outPath = "${packageName}/hardware/${architecture}/${version}";
                    # FIXME: comment
                    builtChecksum = mkChecksum checksum;
                  in
                    pkgs.stdenv.mkDerivation {
                      pname = "arduino-${packageName}-${platformName}";
                      inherit version;

                      #src = fetchurl {
                      #  inherit url;
                      #  "${builtChecksum.kind}" = builtChecksum.value;
                      #};

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
                  # FIXME: comment
                  builtChecksum = mkChecksum checksum;
                  #builtChecksum = if _builtChecksum.kind == "md5"
                  #  then
                  #    throw "${url} uses MD5 hash; add sha256 hash to hashReplacements attrset for ${_builtChecksum.value} at the top of this file"
                  #  else
                  #    _builtChecksum
                  #;

                  fetcher = if lib.hasSuffix ".zip" url then pkgs.fetchzip else builtins.fetchurl;
                in
                  pkgs.stdenv.mkDerivation {
                    pname = "arduino-${packageName}-${toolName}";
                    inherit version;

                    #src = fetcher {
                    #  inherit url;
                    #  #"${builtChecksum.kind}" = builtins.trace "${toolName}-${version}" builtChecksum.value;
                    #  hash = builtChecksum.value;
                    #};

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
