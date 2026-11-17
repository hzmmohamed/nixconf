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
    services.pipewire.wireplumber = {
      extraConfig = {
        "60-butternut-sink-priorities" = {
          "monitor.alsa.rules" = [
            {
              matches = [{"node.name" = "~alsa_output.pci-0000_00_1f.3.*";}];
              actions.update-props."priority.session" = 500;
            }
            {
              matches = [{"node.name" = "~alsa_output.usb-ASUSTeK_COMPUTER_INC._C-Media.*";}];
              actions.update-props."priority.session" = 1500;
            }
          ];
          "monitor.bluez.rules" = [
            {
              matches = [{"node.name" = "~bluez_output.*";}];
              actions.update-props."priority.session" = 2500;
            }
            {
              # Keep the default microphone off Bluetooth: a BT mic only exists
              # in HSP/HFP, so anything recording the default source (e.g. the
              # always-on DeepFilter chain) would pin headsets to call quality.
              # Pick the headset mic manually for calls.
              matches = [{"node.name" = "~bluez_input.*";}];
              actions.update-props."priority.session" = 100;
            }
          ];
        };

        "60-butternut-settings" = {
          "wireplumber.settings" = {
            # Streams without an explicit target move along with the default sink.
            "linking.follow-default-target" = true;
            # Don't pin apps to the sink they last used (would ignore BT/default).
            "node.stream.restore-target" = false;
            # Keep A2DP quality. Trade-off: using the BT headset mic needs a
            # manual profile switch (HSP/HFP) in the mixer.
            "bluetooth.autoswitch-to-headset-profile" = false;
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
            log:info ("headset sink added, making it default: " .. name)
            metadata:set (0, "default.configured.audio.sink", "Spa:String:JSON",
                Json.Object { ["name"] = name }:to_string ())
          end
        }:register ()
      '';
    };
  };
}
