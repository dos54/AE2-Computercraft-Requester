local ok, updater = pcall(require, "updater")
if ok and updater and updater.installOrUpdate then
  updater.installOrUpdate(false)
end

shell.run("autocraft/main.lua")
