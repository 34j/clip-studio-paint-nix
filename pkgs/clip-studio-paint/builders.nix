{
  lib,
  symlinkJoin,
  stdenvNoCC,
  runCommand,
  writeShellApplication,
  copyDesktopItems,
  wineWowPackages,
  winetricks,
  fetchurl,
  ...
}:
rec {
  writeWineScript =
    {
      winePackage,
      wineprefix,
      use32Bit,
      text,
      derivationArgs ? { },
      runtimeInputs ? [ ],
      ...
    }@args:
    let
      WINEPREFIX = wineprefix;
      WINEARCH = if use32Bit then "win32" else "win64";
    in
    writeShellApplication (
      {
        derivationArgs = {
          allowSubstitutes = false;
          preferLocalBuild = true;
        }
        // derivationArgs;

        runtimeInputs = [ winePackage ] ++ runtimeInputs;

        runtimeEnv = {
          inherit WINEARCH;
        };

        # We need to do it this way because runtimeEnv uses single quotes
        text = ''
          export WINEPREFIX="${WINEPREFIX}"
        ''
        + text;
      }
      // (builtins.removeAttrs args [
        "winePackage"
        "wineprefix"
        "use32Bit"
        "text"
        "derivationArgs"
        "runtimeInputs"
      ])
    );

  buildInstallShield =
    {
      name,
      winePackage,
      installerExecutable, # setup.exe file
      installerResponse, # .iss file
      programFiles,
    }:
    runCommand "${name}" { nativeBuildInputs = [ winePackage ]; } ''
      export WINEPREFIX="$TEMPDIR/wineprefix"
      wineboot -u

      cp "${installerResponse}" "$WINEPREFIX/drive_c/response.iss"
      wine "${installerExecutable}" /s /f1"C:\response.iss"

      mv "$WINEPREFIX/drive_c/${programFiles}" $out
    '';

  buildWineApplication =
    {
      pname,
      version,

      executable,
      extraExecutables ? { },

      desktopItems ? [ ],

      winePackage ? wineWowPackages.waylandFull,
      winetricksPackage ? winetricks,

      withCjk ? false,
      extraTricks ? [ ],

      use32Bit ? false,
      windowsVersion ? "win7",
      wineprefix ? "$HOME/.nix-wine/${pname}-${version}",

      meta,
      derivationArgs ? { },
    }:
    let
      mkRunner =
        let
          # https://github.com/Winetricks/winetricks/issues/2226
          edgeInstallerExecutable = fetchurl {
            url = "https://web.archive.org/web/20241127085924/https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/c234a7e5-8ebb-49dc-b21c-880622eb365b/MicrosoftEdgeWebView2RuntimeInstallerX86.exe";
            hash = "sha256-fMCXmuXRQ4f789HS0krNtmGOcSZR2mqojOjlOPjKE3Q=";
          };
          buildScript =
            let
              tricks = [ ] ++ lib.optional withCjk "cjkfonts" ++ extraTricks;
              tricksString = lib.lists.foldl (elm: acc: acc + toString (elm)) "" tricks;
            in
            ''
              mkdir -p "$WINEPREFIX"
              wineboot -u

              winecfg /v win10
              wine "${edgeInstallerExecutable}" || true
              wineserver -k

              winecfg /v ${windowsVersion}
            ''
            + lib.optionalString (tricks != [ ]) ''
              winetricks --unattended ${tricksString}
            '';
        in
        { name, command }:
        writeWineScript {
          inherit
            name
            winePackage
            wineprefix
            use32Bit
            ;

          text = ''
            for var in WINEPREFIX WINEARCH; do
              printf '\e[1;35m%s: \e[0m%s\n' "$var" "''${!var:-""}"
            done

            COMMAND="''${1:-${command}}"

            build() {
            ${buildScript}
            }

            case "$COMMAND" in
              boot|build|rebuild)
                build
                ;;
              *)
                if [ ! -d "$WINEPREFIX" ]; then
                  build
                fi
                eval "$COMMAND"
                ;;
            esac

            wineserver -k
          '';
        };

      desktopEntries = stdenvNoCC.mkDerivation {
        pname = "${pname}-desktop-entries";
        inherit version desktopItems;

        allowSubstitutes = false;
        preferLocalBuild = true;

        nativeBuildInputs = [ copyDesktopItems ];

        buildCommand = ''
          mkdir $out
          runHook postInstall
        '';
      };

      runners =
        lib.attrsets.mapAttrsToList
          (
            name: value:
            mkRunner {
              inherit name;
              command = "wine '${value}'";
            }
          )
          (
            {
              "${pname}" = executable;
            }
            // extraExecutables
          );
    in
    symlinkJoin {
      name = "${pname}-${version}";

      paths = runners ++ lib.optional (desktopItems != [ ]) desktopEntries;

      meta = {
        mainProgram = pname;
      }
      // meta;
    }
    // derivationArgs;
}
