local M = {}

local base = "https://raw.githubusercontent.com/dos54/AE2-Computercraft-Requester/main/"

local LOG_FILE = "updater.log"

local function log(msg)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = "[" .. ts .. "] " .. tostring(msg)

  print(line)

  local f = fs.open(LOG_FILE, "a")
  if f then
    f.writeLine(line)
    f.close()
  end
end

local function fetch(url)
  local res = http.get(url)
  if not res then
    return nil, "HTTP request failed: " .. url
  end

  local body = res.readAll()
  res.close()
  return body, nil
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function readLocalFile(path)
  if not fs.exists(path) then
    return nil
  end

  local f = fs.open(path, "r")
  if not f then
    return nil
  end

  local text = f.readAll()
  f.close()
  return text
end

local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function parseManifest(text)
  local files = {}

  for line in text:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      files[#files + 1] = line
    end
  end

  return files
end

local function readLocalVersion()
  local v = readLocalFile("version.txt")
  if not v then
    return nil
  end

  return trim(v)
end

local function fetchRemoteVersion()
  local v, err = fetch(base .. "version.txt")
  if not v then
    return nil, err
  end

  return trim(v), nil
end

local function fetchManifest()
  local text, err = fetch(base .. "manifest.txt")
  if not text then
    return nil, err
  end

  return parseManifest(text), nil
end

local function downloadFile(path)
  ensureDir(path)

  if fs.exists(path) then
    fs.delete(path)
  end

  log("Downloading " .. path)
  local ok = shell.run("wget", base .. path, path)
  if not ok then
    return false, "Failed to download " .. path
  end

  return true, nil
end

local function removeFilesNotInManifest(manifestFiles)
  local keep = {}
  for _, path in ipairs(manifestFiles) do
    keep[path] = true
  end

  local localVersion = "version.txt"
  if fs.exists(localVersion) and not keep[localVersion] then
    fs.delete(localVersion)
  end
end

function M.installOrUpdate(force)
  local localVersion = readLocalVersion()
  local remoteVersion, versionErr = fetchRemoteVersion()

  if not remoteVersion then
    log(versionErr or "Failed to fetch remote version")
    return false
  end

  if not force and localVersion and localVersion == remoteVersion then
    return true
  end

  log("Local version:  " .. tostring(localVersion or "<none>"))
  log("Remote version: " .. remoteVersion)

  local files, manifestErr = fetchManifest()
  if not files then
    log(manifestErr or "Failed to fetch manifest")
    return false
  end

  for _, path in ipairs(files) do
    local ok, err = downloadFile(path)
    if not ok then
      log(err or "Download failed")
      return false
    end
  end

  removeFilesNotInManifest(files)

  log("Update complete.")
  return true
end

return M
