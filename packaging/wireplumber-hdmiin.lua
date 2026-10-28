-- Installed by obs-studio-rockchip (obs-jfmpp). The same rule as
-- wireplumber.conf.d/50-obs-jfmpp-hdmiin.conf, for WirePlumber 0.4 (Ubuntu Noble),
-- which only reads Lua configuration: keeps PipeWire away from the RK3588 HDMI-in
-- audio card, which the Rockchip HDMI Input source in OBS records itself.
--
-- To hand the card back to PipeWire, put an empty file of the same name in
-- /etc/wireplumber/main.lua.d/ or ~/.config/wireplumber/main.lua.d/.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "api.alsa.card.name", "equals", "rockchip,hdmiin" },
    },
  },
  apply_properties = {
    ["device.disabled"] = true,
  },
})
