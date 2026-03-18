local M = {}

local base = "https://raw.githubusercontent.com/dos54/AE2-Computercraft-Requester/main/"
local LOG_FILE = "updater.log"
local VERSION_FILE = "version.txt"
local MANIFEST_FILE = "manifest.txt"

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

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fetch(url)
  local res, err = http.get(url, nil, true)
  if not res then
    return nil, "HTTP request failed: " .. tostring(err or url)
  end

  local code = res.getResponseCode and res.getResponseCode() or nil
  if code and code ~= 200 then
    local body = res.readAll()
    res.close()
    return nil, "HTTP " .. tostring(code) .. " for " .. url .. ": " .. tostring(body)
  end

  local body = res.readAll()
  res.close()

  if type(body) ~= "string" or body == "" then
    return nil, "Empty response for " .. url
  end

  return body, nil
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

local function writeFileAtomic(path, contents)
  local tmp = path .. ".tmp"
  local dir = fs.getDir(path)

  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end

  local f = fs.open(tmp, "w")
  if not f then
    return false, "Failed to open temp file for " .. path
  end

  f.write(contents)
  f.close()

  if fs.exists(path) then
    fs.delete(path)
  end

  fs.move(tmp, path)
  return true, nil
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
  local v = readLocalFile(VERSION_FILE)
  if not v then
    return nil
  end

  return trim(v)
end

local function fetchRemoteVersion()
  local v, err = fetch(base .. VERSION_FILE .. "?_=" .. tostring(os.epoch("utc")))
  if not v then
    return nil, err
  end

  return trim(v), nil
end

local function fetchManifest()
  local text, err = fetch(base .. MANIFEST_FILE .. "?_=" .. tostring(os.epoch("utc")))
  if not text then
    return nil, err
  end

  return parseManifest(text), nil
end

local function ensureManagedFiles(files)
  local seen = {}

  for _, path in ipairs(files) do
    seen[path] = true
  end

  if not seen[VERSION_FILE] then
    files[#files + 1] = VERSION_FILE
  end

  if not seen[MANIFEST_FILE] then
    files[#files + 1] = MANIFEST_FILE
  end
end

local function downloadFile(path)
  local url = base .. path .. "?_=" .. tostring(os.epoch("utc"))
  log("Downloading " .. path)

  local body, err = fetch(url)
  if not body then
    return false, err or ("Failed to download " .. path)
  end

  local ok, writeErr = writeFileAtomic(path, body)
  if not ok then
    return false, writeErr
  end

  return true, nil
end

function M.installOrUpdate(force)
  log("Updater started")

  local localVersion = readLocalVersion()
  local remoteVersion, versionErr = fetchRemoteVersion()

  if not remoteVersion then
    log(versionErr or "Failed to fetch remote version")
    return false
  end

  log("Local version:  " .. tostring(localVersion or "<none>"))
  log("Remote version: " .. tostring(remoteVersion))

  if not force and localVersion and localVersion == remoteVersion then
    log("Already up to date")
    return true
  end

  local files, manifestErr = fetchManifest()
  if not files then
    log(manifestErr or "Failed to fetch manifest")
    return false
  end

  ensureManagedFiles(files)

  for _, path in ipairs(files) do
    local ok, err = downloadFile(path)
    if not ok then
      log(err or ("Download failed for " .. path))
      return false
    end
  end

  local writtenVersion = readLocalVersion()
  if trim(writtenVersion) ~= remoteVersion then
    log("Version mismatch after update. Expected " .. remoteVersion .. ", got " .. tostring(writtenVersion))
    return false
  end

  log("Update complete")
  return true
end

return M
