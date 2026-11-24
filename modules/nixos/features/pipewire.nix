{...}: {
  flake.nixosModules.pipewire = {
    config,
    lib,
    pkgs,
    ...
  }: let
    denoise = config.preferences.audio.denoise;
  in {
    options.preferences.audio.denoise = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "The DeepFilter noise-cancelling virtual source. Off on a host without a usable mic: the virtual source would otherwise look like a mic that records silence.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source node the DeepFilter chain records from (null = default source). Pin it to a built-in mic so it never grabs a Bluetooth headset mic.";
      };
      priority = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "priority.session of the denoised virtual source (vs. hardware mics).";
      };
    };

    config = {
      # pwvucontrol (libadwaita) follows dark mode; pavucontrol (plain GTK4) does not.
      environment.systemPackages = [pkgs.pwvucontrol];
      preferences.keymap = {
        "SUPER + v".exec = ''${pkgs.alsa-utils}/bin/amixer sset Capture toggle'';
        "SUPER + d"."s".package = pkgs.pwvucontrol;
      };

      persistance.cache.directories = [
        ".local/state/wireplumber"
      ];

      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;

        extraConfig = {
          # No X11 bell on a Wayland desktop: libpipewire-module-x11-bell
          # segfaulted PipeWire whenever the Xwayland display went away
          # ("X11 display (:0) has encountered a fatal I/O error").
          pipewire."10-no-x11-bell"."context.properties"."module.x11.bell" = false;

          # cooler denoising
          pipewire."99-input-denoising" = lib.mkIf denoise.enable {
            "context.modules" = [
              {
                "name" = "libpipewire-module-filter-chain";
                "args" = {
                  "node.description" = "DeepFilter Noise Cancelling Source";
                  "media.name" = "DeepFilter Noise Cancelling Source";
                  "filter.graph" = {
                    "nodes" = [
                      {
                        "type" = "ladspa";
                        "name" = "DeepFilter Mono";
                        "plugin" = "${pkgs.deepfilternet}/lib/ladspa/libdeep_filter_ladspa.so";
                        "label" = "deep_filter_mono";
                        # "control" = {
                        #   "Attenuation Limit (dB)" = cfg.source.attenuation;
                        # };
                      }
                    ];
                  };
                  "audio.rate" = 48000;
                  "capture.props" =
                    {
                      "node.name" = "deep_filter_mono_input";
                      "node.passive" = true;
                    }
                    // lib.optionalAttrs (denoise.source != null) {
                      "target.object" = denoise.source;
                      # Wait for the mic instead of falling back to another
                      # source. NOT node.dont-reconnect: the filter chain
                      # loads with PipeWire, before WirePlumber creates the
                      # ALSA node, and dont-reconnect then errors the stream
                      # and unloads the whole chain (DeepFilter missing after
                      # every boot).
                      "node.dont-fallback" = true;
                    };
                  "playback.props" = {
                    "node.name" = "deep_filter_mono_output";
                    "media.class" = "Audio/Source";
                    "priority.session" = denoise.priority;
                  };
                };
              }
            ];
          };

          # https://discourse.nixos.org/t/pipewire-rnnoise-module-wont-work/58975/12
          # pipewire."99-input-denoising" = {
          #   "context.modules" = [
          #     {
          #       name = "libpipewire-module-filter-chain";
          #       args = {
          #         "node.description" = "Noise Canceling source";
          #         "media.name" = "Noise Canceling source";
          #         "filter.graph" = {
          #           nodes = [
          #             {
          #               type = "ladspa";
          #               name = "rnnoise";
          #               plugin = "${pkgs.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa.so";
          #               label = "noise_suppressor_mono";
          #               control = {
          #                 "VAD Threshold (%)" = 50.0;
          #                 "VAD Grace Period (ms)" = 200;
          #                 "Retroactive VAD Grace (ms)" = 0;
          #               };
          #             }
          #           ];
          #         };
          #         "capture.props" = {
          #           "node.name" = "capture.rnnoise_source";
          #           "node.passive" = true;
          #           "audio.rate" = 48000;
          #         };
          #         "playback.props" = {
          #           "node.name" = "rnnoise_source";
          #           "media.class" = "Audio/Source";
          #           "audio.rate" = 48000;
          #         };
          #       };
          #     }
          #   ];
          # };
        };
      };
    };
  };
}
