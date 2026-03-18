local daemonMod = require("daemon")
local ui = require("ui")

parallel.waitForAny(
  daemonMod.daemon,
  ui.run
)
