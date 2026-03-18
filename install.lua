local base = "https://raw.githubusercontent.com/dos54/AE2-Computercraft-Requester/main/"

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

local function downloadFile(path)
  ensureDir(path)

  if fs.exists(path) then
    fs.delete(path)
  end

  print("Downloading " .. path)
  local ok = shell.run("wget", base .. path, path)
  if not ok then
    return false, "Failed to download " .. path
  end

  return true, nil
end

local function install()
  local manifestText, manifestErr = fetch(base .. "manifest.txt")
  if not manifestText then
    error(manifestErr or "Failed to fetch manifest", 0)
  end

  local files = parseManifest(manifestText)

  for _, path in ipairs(files) do
    local ok, err = downloadFile(path)
    if not ok then
      error(err, 0)
    end
  end

  print("Install complete.")
end

install()
