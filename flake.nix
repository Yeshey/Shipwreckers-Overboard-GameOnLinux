{
  description = "Overboard! (1997) Wine launcher";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      wine = pkgs.wineWow64Packages.stagingFull;

      # ---------------------------------------------------------------------------
      # Game Data Fetch
      # ---------------------------------------------------------------------------
      # gameData = pkgs.fetchzip {
      #   url = "https://d1.xp.myab.net/t/a7db0d57-3165-458c-b8fa-de72b873913f/Shipwreckers_Win_EN_ISO-Version.zip";
      #   # or https://www.bestoldgames.net/shipwreckers ?
      #   hash = "sha256-wz6AwJZtYPzC3/92Qltk8e0HwNoa2pTc/2jbFOAHg6U=";
      #   stripRoot = false;
      # };

      fetchFromGDrive = pkgs.callPackage ./gdrive-fetch.nix { };

      gameData = pkgs.runCommand "shipwreckers-unpacked" {
        src = fetchFromGDrive {
          name   = "Shipwreckers.zip";
          id     = "1aCCA4yDSDxcLCpyrPRkX0cZa0J0dK3fj";
          sha256 = "sha256-HLpNeOjsLVLcB1e5z8PxTK+JT9umgVEj9ZNGic8M0Vo=";
        };
        nativeBuildInputs = [ pkgs.unzip ];
      } ''
        mkdir -p $out
        unzip -q $src -d $out
      '';

      # ---------------------------------------------------------------------------
      # fake_cdrom.so – LD_PRELOAD shim
      # Intercepts Linux CDROM ioctls on any fd so Wine thinks a disc is present.
      # ---------------------------------------------------------------------------
      fakeCdromC = pkgs.writeText "fake_cdrom.c" ''
        #define _GNU_SOURCE
        #include <dlfcn.h>
        #include <fcntl.h>
        #include <linux/cdrom.h>
        #include <stdarg.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/ioctl.h>
        #include <unistd.h>
        #include <errno.h>

        static int (*real_ioctl)(int, unsigned long, ...) = NULL;

        struct track_info { int control; int lba; };
        static struct track_info tracks[100];
        static int total_tracks = 0;
        static int leadout_lba  = 0;
        static int ccd_loaded   = 0;

        __attribute__((constructor))
        static void shim_init(void) {
            real_ioctl = dlsym(RTLD_NEXT, "ioctl");

            const char *ccd_path = getenv("CCD_PATH");
            if (!ccd_path) return;

            FILE *f = fopen(ccd_path, "r");
            if (!f) {
                fprintf(stderr, "[fake-cdrom] Could not open CCD: %s\n", ccd_path);
                return;
            }

            char line[256];
            int current_point = -1, current_control = -1, current_lba = -1;

            while (fgets(line, sizeof(line), f)) {
                if (strncmp(line, "[Entry ", 7) == 0) {
                    if (current_point >= 1 && current_point <= 99) {
                        tracks[current_point].control = current_control;
                        tracks[current_point].lba     = current_lba;
                        if (current_point > total_tracks) total_tracks = current_point;
                    } else if (current_point == 0xa2) {
                        leadout_lba = current_lba;
                    }
                    current_point = current_control = current_lba = -1;
                }
                int val;
                if (sscanf(line, "Point=0x%x",  &val) == 1 ||
                    sscanf(line, "Point=%d",     &val) == 1) current_point   = val;
                if (sscanf(line, "Control=0x%x",&val) == 1 ||
                    sscanf(line, "Control=%d",   &val) == 1) current_control = val;
                if (sscanf(line, "PLBA=%d",      &val) == 1) current_lba     = val;
            }
            if (current_point >= 1 && current_point <= 99) {
                tracks[current_point].control = current_control;
                tracks[current_point].lba     = current_lba;
                if (current_point > total_tracks) total_tracks = current_point;
            } else if (current_point == 0xa2) {
                leadout_lba = current_lba;
            }
            fclose(f);

            if (total_tracks > 0) {
                ccd_loaded = 1;
                fprintf(stderr, "[fake-cdrom] Loaded %d tracks from CCD. Leadout: %d\n",
                        total_tracks, leadout_lba);
            }
        }

        static void lba_to_msf(int lba, struct cdrom_msf0 *msf) {
            lba += 150;
            msf->frame  = lba % 75; lba /= 75;
            msf->second = lba % 60;
            msf->minute = lba / 60;
        }

        int ioctl(int fd, unsigned long request, ...) {
            va_list ap;
            va_start(ap, request);
            void *arg = va_arg(ap, void *);
            va_end(ap);

            int ret = real_ioctl(fd, request, arg);
            if (ret == 0) return 0;

            switch (request) {
            case CDROMREADTOCHDR: {
                struct cdrom_tochdr *hdr = arg;
                hdr->cdth_trk0 = 1;
                hdr->cdth_trk1 = ccd_loaded ? total_tracks : 30;
                return 0;
            }
            case CDROMREADTOCENTRY: {
                struct cdrom_tocentry *e = arg;
                int track = e->cdte_track;
                int lba = 0, ctrl = 0;
                if (ccd_loaded) {
                    if (track == CDROM_LEADOUT || track == 0xAA) {
                        lba = leadout_lba; ctrl = 0;
                    } else if (track >= 1 && track <= total_tracks) {
                        lba  = tracks[track].lba;
                        ctrl = tracks[track].control;
                    }
                } else {
                    ctrl = (track == 1) ? 4 : 0;
                    lba  = (track == CDROM_LEADOUT || track == 0xAA)
                           ? 30 * 18000 : (track - 1) * 18000;
                }
                e->cdte_ctrl     = ctrl;
                e->cdte_adr      = 1;
                e->cdte_datamode = (ctrl & 4) ? 1 : 0;
                if (e->cdte_format == CDROM_MSF)
                    lba_to_msf(lba, &e->cdte_addr.msf);
                else
                    e->cdte_addr.lba = lba;
                return 0;
            }
            case CDROM_DRIVE_STATUS:  return CDS_DISC_OK;
            case CDROM_DISC_STATUS:   return CDS_MIXED;
            case CDROM_GET_CAPABILITY:
                return CDC_PLAY_AUDIO | CDC_DRIVE_STATUS | CDC_MULTI_SESSION |
                       CDC_MEDIA_CHANGED | CDC_RESET | CDC_SELECT_SPEED;
            case CDROMSUBCHNL: {
                struct cdrom_subchnl *sub = arg;
                sub->cdsc_audiostatus = CDROM_AUDIO_NO_STATUS;
                sub->cdsc_adr  = 0;
                sub->cdsc_ctrl = ccd_loaded ? tracks[1].control : 4;
                sub->cdsc_trk  = 1;
                sub->cdsc_ind  = 0;
                memset(&sub->cdsc_absaddr, 0, sizeof(sub->cdsc_absaddr));
                memset(&sub->cdsc_reladdr, 0, sizeof(sub->cdsc_reladdr));
                return 0;
            }
            case CDROMMULTISESSION: {
                struct cdrom_multisession *ms = arg;
                if (ms->addr_format == CDROM_MSF)
                    lba_to_msf(0, &ms->addr.msf);
                else
                    ms->addr.lba = 0;
                ms->xa_flag = 0;
                return 0;
            }
            default: return ret;
            }
        }
      '';

      fakeCdrom = pkgs.stdenv.mkDerivation {
        name       = "fake-cdrom-ioctl";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.gcc ];
        buildPhase = ''
          mkdir -p $out/lib
          gcc -shared -fPIC -O2 -Wall -Wextra \
              -o $out/lib/fake_cdrom.so \
              ${fakeCdromC} \
              -ldl
        '';
        installPhase = "true";
      };

      # ---------------------------------------------------------------------------
      # Launch script
      # ---------------------------------------------------------------------------
      launchScript = pkgs.writeShellScript "run-overboard" ''
        set -euo pipefail

        # ── Locate game source dir ───────────────────────────────────────
        GAME_FILE=$(find "${gameData}" -type f -iname "OVERBOARD.img" | head -n1)
        if [ -z "$GAME_FILE" ]; then
          echo "ERROR: OVERBOARD.img not found in downloaded game data." >&2
          exit 1
        fi
        GAME_SRC_DIR=$(dirname "$GAME_FILE")

        IMG=$(find "$GAME_SRC_DIR"      -maxdepth 1 -iname "*.img" | head -n1)
        CCD_FILE=$(find "$GAME_SRC_DIR" -maxdepth 1 -iname "*.ccd" | head -n1)
        [ -n "$CCD_FILE" ] && export CCD_PATH="$CCD_FILE"

        WINEPREFIX="''${WINEPREFIX:-$HOME/.wine-overboard}"
        export WINEPREFIX
        WINE="${wine}/bin/wine"
        SHIM="${fakeCdrom}/lib/fake_cdrom.so"
        STATE_DIR="$HOME/.local/share/overboard"
        ISO="$STATE_DIR/overboard.iso"
        # Game lives inside the Wine C: drive so we have a known, stable Windows path.
        GAME_DIR="$WINEPREFIX/drive_c/Psygnosis/Overboard"
        mkdir -p "$STATE_DIR" "$WINEPREFIX"

        # ── 1. Convert ISO (once) ────────────────────────────────────────
        if [ ! -f "$ISO" ]; then
          echo "[1/3] Converting CCD/IMG to ISO..."
          ${pkgs.ccd2iso}/bin/ccd2iso "$IMG" "$ISO" 2>&1 \
            | grep -v "Unrecognized sector" || true
          ISO_SIZE=$(stat -c%s "$ISO" 2>/dev/null || echo 0)
          if [ "$ISO_SIZE" -lt 10485760 ]; then
            echo "ERROR: ISO conversion failed (size: $ISO_SIZE bytes)." >&2
            exit 1
          fi
          echo "ISO: $((ISO_SIZE / 1024 / 1024)) MB"
        fi

        # ── Read the REAL ISO9660 volume label from the binary ───────────
        # Primary Volume Descriptor: sector 16 (offset 16*2048=32768),
        # Volume Identifier field at PVD offset +40, 32 bytes, space-padded.
        ISO_LABEL=$(dd if="$ISO" bs=1 skip=32808 count=32 2>/dev/null \
                    | tr -d '\000' | sed 's/[[:space:]]*$//')
        echo "ISO volume label: '$ISO_LABEL'"

        # ── 2. First-run setup ───────────────────────────────────────────
        if [ ! -f "$GAME_DIR/OB.EXE" ] && [ ! -f "$GAME_DIR/ob.exe" ]; then
          echo "[2/3] Extracting game files to C: (bypassing the 16-bit setup.exe)..."
          mkdir -p "$GAME_DIR"
          ${pkgs.p7zip}/bin/7z x "$ISO" -o"$GAME_DIR" -y -bso0 -bsp1
          chmod -R u+w "$GAME_DIR"

          # ── Initialise Wine prefix ───────────────────────────────────
          # Run wineboot in the background; poll for system.reg up to 7 min.
          echo "Initialising Wine prefix (timeout: 7 min)..."
          WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all \
            "$WINE" wineboot 2>/dev/null &
          WINEBOOT_PID=$!

          TRIES=0
          MAX=420
          until [ -f "$WINEPREFIX/system.reg" ] || [ "$TRIES" -ge "$MAX" ]; do
            sleep 1
            TRIES=$((TRIES + 1))
            # Print a dot every 5s so the terminal doesn't look frozen
            [ $((TRIES % 5)) -eq 0 ] && echo -n "."
          done
          echo ""

          wait "$WINEBOOT_PID" 2>/dev/null || true
          sleep 2  # let wineserver flush to disk

          if [ ! -f "$WINEPREFIX/system.reg" ]; then
            echo "ERROR: Wine prefix not created after ''${MAX}s (system.reg missing)." >&2
            echo "       Try manually: WINEPREFIX=$WINEPREFIX wine wineboot" >&2
            exit 1
          fi
          echo "Wine prefix ready."

          # ── Write registry ─────────────────────────────────────────
          # KEY LESSON: wine regedit fails when given a Unix path because the
          # Z: mapping can be unreliable.  Put the .reg file inside C: drive
          # and pass the Windows path — this is 100% reliable.
          #
          # We write to both the plain path AND WOW6432Node because OB.EXE is
          # 32-bit and under wineWow64, 32-bit apps read from WOW6432Node.
          # We also cover HKCU in case the game checks there.
          #
          # REGEDIT4 string values: each backslash must be doubled.
          echo "Writing registry keys..."
          REG_FILE="$WINEPREFIX/drive_c/overboard_setup.reg"
          cat > "$REG_FILE" << 'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Psygnosis\Studios\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"

[HKEY_LOCAL_MACHINE\Software\Psygnosis\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"

[HKEY_LOCAL_MACHINE\Software\WOW6432Node\Psygnosis\Studios\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"

[HKEY_LOCAL_MACHINE\Software\WOW6432Node\Psygnosis\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"

[HKEY_CURRENT_USER\Software\Psygnosis\Studios\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"

[HKEY_CURRENT_USER\Software\Psygnosis\Overboard!]
"Path"="C:\\Psygnosis\\Overboard\\"
"Exe Path"="C:\\Psygnosis\\Overboard\\"
"Resource Path"="C:\\Psygnosis\\Overboard\\"
"FMV Path"="C:\\Psygnosis\\Overboard\\"
"d:"="cdrom"

EOF
          # Use Windows C:\ path — avoids all Unix→Windows path translation issues
          "$WINE" regedit "C:\\overboard_setup.reg" 2>/dev/null

          # Belt-and-suspenders: also write each key via reg add directly.
          # This hits WOW6432Node natively since we specify the path explicitly.
          for KEY in \
            "HKLM\\Software\\Psygnosis\\Studios\\Overboard!" \
            "HKLM\\Software\\Psygnosis\\Overboard!" \
            "HKLM\\Software\\WOW6432Node\\Psygnosis\\Studios\\Overboard!" \
            "HKLM\\Software\\WOW6432Node\\Psygnosis\\Overboard!" \
            "HKCU\\Software\\Psygnosis\\Studios\\Overboard!" \
            "HKCU\\Software\\Psygnosis\\Overboard!"; do
            for VAL in "Path" "Exe Path" "Resource Path" "FMV Path"; do
              "$WINE" reg add "$KEY" /v "$VAL" /t REG_SZ \
                /d "C:\\Psygnosis\\Overboard\\" /f 2>/dev/null || true
            done
          done

          # ── Verify registry ────────────────────────────────────────
          echo ""
          echo "=== system.reg — Psygnosis / Overboard / WOW6432Node entries ==="
          grep -i "psygnosis\|overboard" \
            "$WINEPREFIX/system.reg" "$WINEPREFIX/user.reg" 2>/dev/null \
            || echo "WARNING: no keys found!"
          echo "================================================================="
          echo ""
        fi

        # ── 3. CD-ROM drive setup (every run) ────────────────────────────
        echo "[3/3] Configuring D: (CD-ROM) drive..."
        mkdir -p "$WINEPREFIX/dosdevices"

        # D: → the extracted game directory.
        # We do NOT create d:: (raw device symlink to the .img file) because
        # when d:: points to a regular file Wine probes it as a device first,
        # which can bypass the registry-based GetDriveType override.
        # Without d::, Wine falls back to HKLM\Software\Wine\Drives, which we
        # control, and returns DRIVE_CDROM reliably.
        ln -sfn "$GAME_DIR" "$WINEPREFIX/dosdevices/d:"
        ln -sfn /dev/null "$WINEPREFIX/dosdevices/d::"   # fake raw device; shim intercepts ioctls on fd

        # Write the volume label that OB.EXE's CD validator checks.
        # We use the real ISO9660 label extracted above — no more guessing.
        printf "%s" "$ISO_LABEL" > "$GAME_DIR/.windows-label"
        printf "12345678"        > "$GAME_DIR/.windows-serial"
        echo "Volume label written: '$ISO_LABEL'"

        # Tell Wine GetDriveType("D:\\") → DRIVE_CDROM
        "$WINE" reg add "HKLM\\Software\\Wine\\Drives" \
          /v "d:" /t REG_SZ /d "cdrom" /f 2>/dev/null \
          && echo "Wine drive type set: d: = cdrom" \
          || echo "WARNING: could not set Wine drive type for D:"

        echo "Flushing registry to disk..."
        "${wine}/bin/wineserver" -k 2>/dev/null || true
        sleep 3
        echo "Flush complete."

        # ── Verify drives entry ──────────────────────────────────────────
        echo ""
        echo "=== system.reg — Wine\\Drives ==="
        grep -i "drives\|\"d:\"" "$WINEPREFIX/system.reg" 2>/dev/null \
          || echo "WARNING: no Wine\\Drives entry in system.reg"
        echo "================================="

        echo ""
        echo "=========================================================="
        echo " Launching Overboard! (1997)"
        echo "=========================================================="
        [ -n "''${CCD_FILE:-}" ] && \
          echo "[Debug] CCD track data from: $(basename "$CCD_FILE")"
        echo "  Game dir   : $GAME_DIR"
        echo "  WINEPREFIX : $WINEPREFIX"
        echo "  Volume label: $ISO_LABEL"
        echo ""

        cd "$GAME_DIR"
        EXE=$(find . -maxdepth 1 -iname "ob.exe" | head -n1)

        export LD_PRELOAD="$SHIM''${LD_PRELOAD:+:$LD_PRELOAD}"
        export GLIBC_TUNABLES=glibc.malloc.tcache_count=0
        exec ${pkgs.gamescope}/bin/gamescope \
          --backend sdl \
          -w 640 -h 480 \
          -W 1920 -H 1080 \
          -f \
          -- "$WINE" explorer /desktop=overboard,640x480 "$EXE"
      '';

    in {
      apps.${system}.default = {
        type    = "app";
        program = "${launchScript}";
      };
      packages.${system} = {
        inherit fakeCdrom;
        default = fakeCdrom;
      };
    };
}