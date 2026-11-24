# butternut audio routing policy (WirePlumber 0.5). Node names are
# hardware-specific, hence host-local.
#
# Priorities decide the *fallback* default sink (when no stored/user choice is
# present): Bluetooth > C-Media USB speakers > Intel HDA (HDMI-only, unused).
# The user's explicit choice (pactl/wpctl/mixer) still wins over priorities,
# so the hook below also makes a newly connected Bluetooth or USB headset the
# configured default — it becomes the top of WirePlumber's stored stack and is
# dropped back to the previous choice when it disconnects.
#
# One-time after the first switch: delete ~/.local/state/wireplumber/default-nodes
# (stale stack that still prefers HDMI) and switch the Intel HDA card profile
# off "Pro Audio" in the mixer.
{
  flake.nixosModules.hostButternut = {
    # No microphone on butternut except a Bluetooth headset's: the C-Media
    # input is the empty headphone jack and recorded near-silence that looked
    # like a working mic. So no DeepFilter source either (it would wrap that
    # input, or nothing, and pass for a mic too).
    preferences.audio.denoise.enable = false;

    services.pipewire.wireplumber = {
      extraConfig = {
        "60-butternut-sink-priorities" = {
          "monitor.alsa.rules" = [
            {
              # Intel HDA only carries display audio (HDMI/DP); no monitor here
              # has speakers, only an occasional TV. Use the normal HDMI profile
              # (one "HDMI" output) instead of Pro Audio's four raw outputs.
              matches = [{"device.name" = "alsa_card.pci-0000_00_1f.3";}];
              actions.update-props = {
                "device.profile" = "output:hdmi-stereo";
                "api.acp.auto-profile" = false;
              };
            }
            {
              matches = [{"node.name" = "~alsa_output.pci-0000_00_1f.3.*";}];
              actions.update-props."priority.session" = 500;
            }
            {
              matches = [{"node.name" = "~alsa_output.usb-ASUSTeK_COMPUTER_INC._C-Media.*";}];
              actions.update-props."priority.session" = 1500;
            }
            {
              # Built-in audio is a USB chip. Output only: its input is the
              # headphone jack's mic pin, with nothing plugged in, so without
              # a Bluetooth headset there is no mic at all and dictation says
              # so instead of recording silence. (A wired headset mic would
              # need "output:analog-stereo+input:analog-stereo" back.)
              matches = [{"device.name" = "alsa_card.usb-ASUSTeK_COMPUTER_INC._C-Media_R__Audio-00";}];
              actions.update-props = {
                "device.profile" = "output:analog-stereo";
                "api.acp.auto-profile" = false;
              };
            }
          ];
          "monitor.bluez.rules" = [
            {
              matches = [{"node.name" = "~bluez_output.*";}];
              actions.update-props."priority.session" = 2500;
            }
            {
              # A connected headset's mic becomes the default microphone
              # (3000: WirePlumber gives the C-Media mic ~2109, so 2000 lost to it);
              # recording from it makes
              # WirePlumber switch the headset to HSP/HFP and back afterwards.
              matches = [{"node.name" = "~bluez_input.*";}];
              actions.update-props."priority.session" = 3000;
            }
          ];
        };

        "60-butternut-settings" = {
          "wireplumber.settings" = {
            # Streams without an explicit target move along with the default sink.
            "linking.follow-default-target" = true;
            # Don't pin apps to the sink they last used (would ignore BT/default).
            "node.stream.restore-target" = false;
            # Desktop-style: when an app records from the headset mic, switch to
            # HSP/HFP for the duration, then back to A2DP. Safe now that the
            # always-on DeepFilter chain is pinned to the laptop mic.
            "bluetooth.autoswitch-to-headset-profile" = true;
          };
        };

        "61-butternut-headset-default" = {
          "wireplumber.components" = [
            {
              name = "butternut/headset-default.lua";
              type = "script/lua";
              provides = "custom.butternut.headset-default";
              # No `requires`: WirePlumber keeps the JSON quotes on generated
              # requires entries ('"metadata.default"'), fails dependency
              # resolution and refuses to start. The hook only touches the
              # default metadata on node-added, long after startup.
            }
          ];
          "wireplumber.profiles".main."custom.butternut.headset-default" = "required";
        };
      };

      extraScripts."butternut/headset-default.lua" = ''
        -- Make a newly added Bluetooth sink, or a USB headset (any USB sink
        -- except the built-in C-Media speakers), the configured default sink.
        cutils = require ("common-utils")
        log = Log.open_topic ("s-butternut-headset")

        SimpleEventHook {
          name = "butternut/headset-default",
          interests = {
            EventInterest {
              Constraint { "event.type", "=", "node-added" },
              Constraint { "media.class", "=", "Audio/Sink" },
              Constraint { "node.name", "#", "bluez_output.*" },
            },
            EventInterest {
              Constraint { "event.type", "=", "node-added" },
              Constraint { "media.class", "=", "Audio/Sink" },
              Constraint { "node.name", "#", "alsa_output.usb-*" },
            },
            -- The headset mic (A2DP exposes it as a virtual source; recording
            -- from it triggers the HSP/HFP autoswitch). The built-in C-Media
            -- input is switched off (output-only profile above).
            EventInterest {
              Constraint { "event.type", "=", "node-added" },
              Constraint { "media.class", "=", "Audio/Source" },
              Constraint { "node.name", "#", "bluez_input.*" },
            },
          },
          execute = function (event)
            local name = event:get_properties () ["node.name"]
            local metadata = cutils.get_default_metadata_object ()
            if name == nil or metadata == nil then
              return
            end
            -- Lua constraints have no "not matches" verb; skip the speakers here.
            if name:find ("alsa_output.usb-ASUSTeK_COMPUTER_INC._C-Media", 1, true) then
              return
            end
            local isSource = name:find ("bluez_input", 1, true) ~= nil
            local key = isSource and "default.configured.audio.source"
                or "default.configured.audio.sink"
            log:info ("headset node added, making it default: " .. name)
            metadata:set (0, key, "Spa:String:JSON",
                Json.Object { ["name"] = name }:to_string ())
          end
        }:register ()
      '';
    };
  };
}
