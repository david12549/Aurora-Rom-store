scriptTitle = "ROM Store"
scriptAuthor = "david12549"
scriptVersion = 4.0
scriptDescription = "Download ROMs from multiple sources"
scriptIcon = "icon.png"
scriptPermissions = { "http", "filesystem" }

require("MenuSystem")

local DOWNLOAD_FOLDER = "Downloads"
local ROM_BASE = "Emulators\\RetroArch\\roms"

local storageDevice = "Hdd1:\\"
local confPath = ""
local absoluteDownloadsPath = ""
local currentSystem = nil
local repos = {}  -- Will hold all loaded repos

-- Globals for progress tracking
gAbortedOperation = false
gDownloadStartTime = 0
gLastProgressUpdate = 0

local function log(msg) print("> " .. tostring(msg)) end

local function getTime()
    local t = Aurora.GetTime()
    if t then
        return (t.Hour or 0) * 3600 + (t.Minute or 0) * 60 + (t.Second or 0)
    end
    return 0
end

local function formatSize(bytes)
    if bytes >= 1073741824 then
        return string.format("%.2f GB", bytes / 1073741824)
    elseif bytes >= 1048576 then
        return string.format("%.2f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.2f KB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

local function formatSpeed(bytesPerSec)
    if bytesPerSec >= 1048576 then
        return string.format("%.2f MB/s", bytesPerSec / 1048576)
    elseif bytesPerSec >= 1024 then
        return string.format("%.2f KB/s", bytesPerSec / 1024)
    else
        return string.format("%d B/s", bytesPerSec)
    end
end

function HttpProgressRoutine(dwTotalFileSize, dwTotalBytesTransferred, dwReason)
    if Script.IsCanceled() then
        gAbortedOperation = true
        Script.SetStatus("Cancelling...")
        return 1
    end
    
    Script.SetProgress(dwTotalBytesTransferred, dwTotalFileSize)
    
    local now = getTime()
    if now > gLastProgressUpdate then
        local elapsed = now - gDownloadStartTime
        if elapsed < 1 then elapsed = 1 end
        if elapsed < 0 then elapsed = elapsed + 86400 end
        
        local speed = dwTotalBytesTransferred / elapsed
        local percent = 0
        if dwTotalFileSize > 0 then
            percent = math.floor((dwTotalBytesTransferred / dwTotalFileSize) * 100)
        end
        
        local eta = ""
        if speed > 0 and dwTotalFileSize > 0 then
            local remaining = (dwTotalFileSize - dwTotalBytesTransferred) / speed
            local mins = math.floor(remaining / 60)
            local secs = math.floor(remaining % 60)
            eta = string.format(" | %dm %ds", mins, secs)
        end
        
        local status = string.format("%d%% | %s / %s | %s%s",
            percent,
            formatSize(dwTotalBytesTransferred),
            formatSize(dwTotalFileSize),
            formatSpeed(speed),
            eta)
        
        Script.SetStatus(status)
        gLastProgressUpdate = now
    end
    
    return 0
end

local function basenameOnly(p)
    p = tostring(p or ""):gsub("\\", "/")
    return p:match("([^/]+)$") or p
end

local function sanitizeName(s)
    s = s:gsub("%%20", " ")
    s = s:gsub("%%28", "(")
    s = s:gsub("%%29", ")")
    s = s:gsub("%%2C", ",")
    s = s:gsub("%%27", "'")
    s = s:gsub("%%26", "&")
    s = s:gsub("%%2B", "+")
    s = s:gsub("%%21", "!")
    s = s:gsub("%%5B", "[")
    s = s:gsub("%%5D", "]")
    s = s:gsub(",", "_")
    s = s:gsub("!", "_")
    s = s:gsub("&", "_")
    s = s:gsub("'", "_")
    s = s:gsub("%%+", "_")
    s = s:gsub("%%", "_")
    s = s:gsub("[/\\]", "_")
    return s
end

local function decodeUrl(s)
    s = s:gsub("%%20", " ")
    s = s:gsub("%%28", "(")
    s = s:gsub("%%29", ")")
    s = s:gsub("%%2C", ",")
    s = s:gsub("%%27", "'")
    s = s:gsub("%%26", "&")
    s = s:gsub("%%2B", "+")
    s = s:gsub("%%21", "!")
    s = s:gsub("%%5B", "[")
    s = s:gsub("%%5D", "]")
    return s
end

local function isWantedFile(name)
    if not currentSystem or not currentSystem.exts then return false end
    name = tostring(name or ""):lower()
    for ext in currentSystem.exts:gmatch("([^,]+)") do
        ext = ext:gsub("%s", "")
        if name:match("%." .. ext .. "$") then
            return true
        end
    end
    return false
end

-- Extract base URL (scheme + host) from a full URL
local function getBaseUrl(url)
    -- https://example.com/path/to/thing -> https://example.com
    local base = url:match("^(https?://[^/]+)")
    return base or url
end

-- Convert myrient URL to direct CDN URL (skip redirect)
local function toCdnUrl(url)
    local cdnUrl = url:gsub("myrient%.erista%.me", "f5.erista.me")
    if cdnUrl ~= url then
        log("CDN URL: " .. cdnUrl)
    end
    return cdnUrl
end

-- Build full download URL from href and current browse URL
local function buildDownloadUrl(href, currentUrl)
    -- If href starts with http, it's already a full URL
    if href:match("^https?://") then
        return href
    end
    
    -- If href starts with /, it's absolute from the domain root
    if href:sub(1,1) == "/" then
        local base = getBaseUrl(currentUrl)
        return base .. href
    end
    
    -- Otherwise it's relative to current URL
    return currentUrl:gsub("/?$", "/") .. href
end

-- ============================================
-- DEFLATE DECOMPRESSION (Pure Lua)
-- ============================================

local lenBase = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local lenExtra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local distBase = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local distExtra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
local clOrder = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

local function getBits(bs, n)
    while bs.n < n do
        if bs.p > #bs.d then return 0 end
        bs.b = bs.b + bit32.lshift(string.byte(bs.d, bs.p), bs.n)
        bs.p = bs.p + 1
        bs.n = bs.n + 8
    end
    local v = bit32.band(bs.b, bit32.lshift(1, n) - 1)
    bs.b = bit32.rshift(bs.b, n)
    bs.n = bs.n - n
    return v
end

local function buildTree(lens, count)
    local bl_count = {}
    local next_code = {}
    local tree = {}
    for i = 0, 15 do bl_count[i] = 0 end
    for i = 0, count - 1 do
        local l = lens[i] or 0
        bl_count[l] = bl_count[l] + 1
    end
    local code = 0
    for bits = 1, 15 do
        code = bit32.lshift(code + bl_count[bits - 1], 1)
        next_code[bits] = code
    end
    for i = 0, count - 1 do
        local l = lens[i] or 0
        if l > 0 then
            local c = next_code[l]
            next_code[l] = c + 1
            local rev = 0
            for j = 1, l do
                rev = bit32.lshift(rev, 1) + bit32.band(c, 1)
                c = bit32.rshift(c, 1)
            end
            tree[rev * 16 + l] = i
        end
    end
    return tree
end

local function decode(bs, tree)
    local code = 0
    for l = 1, 15 do
        code = code + bit32.lshift(getBits(bs, 1), l - 1)
        local sym = tree[code * 16 + l]
        if sym then return sym end
    end
    return 0
end

local function inflateToFile(data, outFile)
    local bs = {d = data, p = 1, b = 0, n = 0}
    local WINDOW_SIZE = 32768
    local window = {}
    for i = 0, WINDOW_SIZE - 1 do window[i] = 0 end
    local wp = 0
    local totalWritten = 0
    
    local MAX_OUT_BYTES = 512 * 1024 * 1024
    local checkCancelEvery = 65536
    local bytesSinceCheck = 0
    
    local buffer = {}
    local bufLen = 0
    local BUFFER_SIZE = 32768
    
    local function flushBuffer()
        if bufLen > 0 then
            outFile:write(table.concat(buffer))
            buffer = {}
            bufLen = 0
        end
    end
    
    local function outputByte(b)
        bytesSinceCheck = bytesSinceCheck + 1
        if bytesSinceCheck >= checkCancelEvery then
            bytesSinceCheck = 0
            if Script.IsCanceled() then
                flushBuffer()
                return false
            end
        end
        
        if totalWritten >= MAX_OUT_BYTES then
            flushBuffer()
            return false
        end
        
        window[wp] = b
        wp = (wp + 1) % WINDOW_SIZE
        buffer[bufLen + 1] = string.char(b)
        bufLen = bufLen + 1
        totalWritten = totalWritten + 1
        if bufLen >= BUFFER_SIZE then
            flushBuffer()
        end
        return true
    end
    
    repeat
        local fin = getBits(bs, 1)
        local typ = getBits(bs, 2)
        if typ == 0 then
            bs.b = 0
            bs.n = 0
            local len = getBits(bs, 16)
            getBits(bs, 16)
            for i = 1, len do
                if bs.p > #bs.d then flushBuffer(); return nil end
                if not outputByte(string.byte(bs.d, bs.p)) then return nil end
                bs.p = bs.p + 1
            end
        elseif typ == 1 or typ == 2 then
            local litTree, distTree
            if typ == 1 then
                local ll = {}
                for i = 0, 143 do ll[i] = 8 end
                for i = 144, 255 do ll[i] = 9 end
                for i = 256, 279 do ll[i] = 7 end
                for i = 280, 287 do ll[i] = 8 end
                litTree = buildTree(ll, 288)
                local dl = {}
                for i = 0, 31 do dl[i] = 5 end
                distTree = buildTree(dl, 32)
            else
                local hlit = getBits(bs, 5) + 257
                local hdist = getBits(bs, 5) + 1
                local hclen = getBits(bs, 4) + 4
                local cl = {}
                for i = 1, hclen do
                    cl[clOrder[i]] = getBits(bs, 3)
                end
                local clTree = buildTree(cl, 19)
                local lens = {}
                local i = 0
                while i < hlit + hdist do
                    local sym = decode(bs, clTree)
                    if sym < 16 then
                        lens[i] = sym
                        i = i + 1
                    elseif sym == 16 then
                        local rep = getBits(bs, 2) + 3
                        local val = lens[i - 1] or 0
                        for j = 1, rep do lens[i] = val; i = i + 1 end
                    elseif sym == 17 then
                        local rep = getBits(bs, 3) + 3
                        for j = 1, rep do lens[i] = 0; i = i + 1 end
                    elseif sym == 18 then
                        local rep = getBits(bs, 7) + 11
                        for j = 1, rep do lens[i] = 0; i = i + 1 end
                    end
                end
                local ll = {}
                for j = 0, hlit - 1 do ll[j] = lens[j] end
                litTree = buildTree(ll, hlit)
                local dl = {}
                for j = 0, hdist - 1 do dl[j] = lens[hlit + j] end
                distTree = buildTree(dl, hdist)
            end
            while true do
                local sym = decode(bs, litTree)
                if sym < 256 then
                    if not outputByte(sym) then return nil end
                elseif sym == 256 then
                    break
                else
                    local li = sym - 257 + 1
                    local len = lenBase[li] + getBits(bs, lenExtra[li])
                    local di = decode(bs, distTree) + 1
                    local dist = distBase[di] + getBits(bs, distExtra[di])
                    for j = 1, len do
                        local pos = (wp - dist) % WINDOW_SIZE
                        local b = window[pos]
                        if b == nil then
                            flushBuffer()
                            return nil
                        end
                        if not outputByte(b) then return nil end
                    end
                end
            end
        else
            flushBuffer()
            return nil
        end
    until fin == 1
    
    flushBuffer()
    return totalWritten
end

local function readU16(d, p)
    local b1 = string.byte(d, p) or 0
    local b2 = string.byte(d, p + 1) or 0
    return b1 + b2 * 256
end

local function readU32(d, p)
    local b1 = string.byte(d, p) or 0
    local b2 = string.byte(d, p + 1) or 0
    local b3 = string.byte(d, p + 2) or 0
    local b4 = string.byte(d, p + 3) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function findEOCD(data)
    local len = #data
    for p = len - 21, math.max(1, len - 65556), -1 do
        if data:sub(p, p + 3) == "PK\5\6" then
            return p
        end
    end
    return nil
end

local function extractZip(zipPath, destFolder)
    local f = io.open(zipPath, "rb")
    if not f then return nil, "Cannot open" end
    
    local MAX_ZIP_BYTES = 80 * 1024 * 1024
    local sz = FileSystem.GetFileSize(zipPath)
    if sz and sz > MAX_ZIP_BYTES then
        f:close()
        return nil, "ZIP too large: " .. formatSize(sz) .. " (limit " .. formatSize(MAX_ZIP_BYTES) .. ")"
    end
    
    local data = f:read("*all")
    f:close()
    
    local eocd = findEOCD(data)
    if not eocd then return nil, "EOCD not found" end
    
    local totalEntries = readU16(data, eocd + 10)
    local cdOffset = readU32(data, eocd + 16)
    
    if totalEntries < 1 then return nil, "ZIP contains no files" end
    
    local p = cdOffset + 1
    
    if p < 1 or p > #data - 46 then return nil, "Bad CD offset" end
    
    local chosen = nil
    
    for entry = 1, totalEntries do
        local sig1 = string.byte(data, p)
        local sig2 = string.byte(data, p + 1)
        local sig3 = string.byte(data, p + 2)
        local sig4 = string.byte(data, p + 3)
        
        if sig1 ~= 0x50 or sig2 ~= 0x4B or sig3 ~= 0x01 or sig4 ~= 0x02 then
            return nil, "Bad CD signature"
        end
        
        local method = readU16(data, p + 10)
        local compSz = readU32(data, p + 20)
        local uncompSz = readU32(data, p + 24)
        local nameLen = readU16(data, p + 28)
        local extraLen = readU16(data, p + 30)
        local commLen = readU16(data, p + 32)
        local lho = readU32(data, p + 42)
        local fileName = data:sub(p + 46, p + 45 + nameLen)
        
        p = p + 46 + nameLen + extraLen + commLen
        
        -- For EdgeEmu: the ZIP contains the ROM directly
        -- Accept any file that's not a directory
        if fileName:sub(-1) ~= "/" then
            -- Check if it matches wanted extensions OR just take first file
            if isWantedFile(fileName) or chosen == nil then
                chosen = {
                    method = method, compSz = compSz, uncompSz = uncompSz,
                    lho = lho, fileName = fileName
                }
                if isWantedFile(fileName) then
                    break  -- Found exact match, stop
                end
            end
        end
    end
    
    if not chosen then
        return nil, "No file found in archive"
    end
    
    local method = chosen.method
    local compSz = chosen.compSz
    local uncompSz = chosen.uncompSz
    local lho = chosen.lho
    local fileName = chosen.fileName
    
    local lp = lho + 1
    
    local lsig1 = string.byte(data, lp)
    local lsig2 = string.byte(data, lp + 1)
    local lsig3 = string.byte(data, lp + 2)
    local lsig4 = string.byte(data, lp + 3)
    
    if lsig1 ~= 0x50 or lsig2 ~= 0x4B or lsig3 ~= 0x03 or lsig4 ~= 0x04 then
        return nil, "Bad local header"
    end
    
    local lNameLen = readU16(data, lp + 26)
    local lExtraLen = readU16(data, lp + 28)
    local dataStart = lp + 30 + lNameLen + lExtraLen
    
    if dataStart < 1 or (dataStart + compSz - 1) > #data then
        return nil, "Data out of bounds"
    end
    
    local compData = data:sub(dataStart, dataStart + compSz - 1)
    
    local outName = sanitizeName(basenameOnly(fileName))
    
    if #outName > 42 then
        local ext = fileName:match("%.[^%.]+$") or ".bin"
        outName = outName:sub(1, 38) .. ext
    end
    
    log("Extracting: " .. fileName .. " -> " .. outName)
    
    local outPath = destFolder .. "\\" .. outName
    local outF = io.open(outPath, "wb")
    if not outF then return nil, "Cannot write" end
    
    local bytesWritten
    if method == 0 then
        outF:write(compData)
        bytesWritten = #compData
    elseif method == 8 then
        bytesWritten = inflateToFile(compData, outF)
    else
        outF:close()
        return nil, "Unsupported method: " .. method
    end
    
    outF:close()
    
    if not bytesWritten then
        FileSystem.DeleteFile(outPath)
        return nil, "Decompression failed"
    end
    
    return outName, bytesWritten
end

-- ============================================
-- HTTP AND BROWSING
-- ============================================

local function httpGet(url)
    local r = Http.Get(url)
    if r and r.Success and r.OutputData then
        return r.OutputData
    end
    return nil
end

local function parseLinks(html)
    local items = {}
    for href in html:gmatch('href="([^"]+)"') do
        local name = decodeUrl(href)
        name = name:gsub("/$", ""):match("([^/]+)$") or href
        local isDir = href:sub(-1) == "/"
        if href ~= "../" then
            local isZip = href:lower():match("%.zip$")
            local isWanted = isWantedFile(href)
            if isDir or isZip or isWanted then
                items[#items + 1] = {href = href, name = name, isDir = isDir}
            end
        end
    end
    return items
end

local function browse(rootUrl)
    local url = rootUrl
    while true do
        Script.SetStatus("Fetching directory...")
        local html = httpGet(url)
        if not html then
            Script.ShowMessageBox("Error", "Failed to load directory", "OK")
            return nil
        end
        
        local items = parseLinks(html)
        local list = {}
        local canGoUp = (url ~= rootUrl)
        
        if canGoUp then
            table.insert(items, 1, {href = "__UP__", name = ".. (Back)", isDir = true})
        end
        
        for i, item in ipairs(items) do
            list[i] = item.isDir and "[DIR] " .. item.name or item.name
        end
        
        if #list == 0 then
            Script.ShowMessageBox("Error", "Empty directory", "OK")
            return nil
        end
        
        local r = Script.ShowPopupList("ROM Store", "Select ROM or folder", list)
        if not r or r.Canceled then return nil end
        
        local sel = items[r.Selected.Key]
        
        if sel.href == "__UP__" then
            url = url:gsub("/+$", ""):gsub("/[^/]+$", "") .. "/"
        elseif sel.isDir then
            url = url:gsub("/?$", "/") .. sel.href
        else
            -- Build the full download URL
            local downloadUrl = buildDownloadUrl(sel.href, url)
            log("Download URL: " .. downloadUrl)
            return {name = sel.name, href = sel.href, url = downloadUrl}
        end
    end
end

-- ============================================
-- MAIN
-- ============================================

function main()
    log("=== ROM Store v4.0 ===")
    
    if Aurora.HasInternetConnection() ~= true then
        Script.ShowMessageBox("No Internet", "This script requires an internet connection.", "OK")
        return
    end
    
    local basePath = Script.GetBasePath()
    confPath = basePath .. "romstore.conf"
    absoluteDownloadsPath = basePath .. DOWNLOAD_FOLDER .. "\\"
    
    FileSystem.DeleteDirectory(absoluteDownloadsPath)
    FileSystem.CreateDirectory(absoluteDownloadsPath)
    
    local saved = FileSystem.ReadFile(confPath)
    if saved and saved ~= "" then
        storageDevice = saved
    end
    
    -- Load all repo INI files
    repos = {}
    local repoFiles = FileSystem.GetFiles(basePath .. "Repos\\*.ini")
    if repoFiles == nil or #repoFiles == 0 then
        Script.ShowMessageBox("Error", "No .ini files found in Repos folder", "OK")
        return
    end
    
    for _, repoFile in ipairs(repoFiles) do
        local ini = IniFile.LoadFile("Repos\\" .. repoFile.Name)
        if ini then
            local repoName = repoFile.Name:gsub("%.ini$", "")
            local systems = {}
            local sections = ini:GetAllSections()
            
            for _, sec in ipairs(sections) do
                if sec ~= "update" then
                    local name = ini:ReadValue(sec, "name", "")
                    local browseurl = ini:ReadValue(sec, "browseurl", "")
                    local folder = ini:ReadValue(sec, "folder", "")
                    local exts = ini:ReadValue(sec, "exts", "")
                    
                    if name ~= "" and browseurl ~= "" and folder ~= "" then
                        systems[#systems + 1] = {
                            name = name,
                            url = browseurl,
                            folder = folder,
                            exts = exts
                        }
                    end
                end
            end
            
            if #systems > 0 then
                repos[#repos + 1] = {
                    name = repoName,
                    systems = systems
                }
            end
        end
    end
    
    if #repos == 0 then
        Script.ShowMessageBox("Error", "No valid repos found", "OK")
        return
    end
    
    -- Main menu loop
    while true do
        Menu.ResetMenu()
        Menu.SetTitle(scriptTitle .. " (" .. storageDevice:gsub("\\", "") .. ")")
        Menu.SetGoBackText("")
        
        -- Add each repo as a menu item
        for _, repo in ipairs(repos) do
            local label = repo.name .. " (" .. #repo.systems .. " systems)"
            Menu.AddMainMenuItem(Menu.MakeMenuItem(label, {action = "REPO", repo = repo}))
        end
        
        -- Add storage device option at the end
        Menu.AddMainMenuItem(Menu.MakeMenuItem("[ Change Storage Device ]", {action = "CHANGE_STORAGE"}))
        
        local ret, menu, canceled = Menu.ShowMainMenu()
        if canceled or not ret then break end
        
        if ret.action == "CHANGE_STORAGE" then
            local devices = {"Hdd1:\\", "Usb0:\\", "Usb1:\\"}
            local devNames = {"Internal HDD", "USB 0", "USB 1"}
            local choice = Script.ShowPopupList("Storage", "Select destination", devNames)
            if choice and not choice.Canceled then
                storageDevice = devices[choice.Selected.Key]
                FileSystem.WriteFile(confPath, storageDevice)
                Script.ShowNotification("Storage: " .. storageDevice:gsub("\\", ""))
            end
            
        elseif ret.action == "REPO" then
            -- Show systems for this repo
            local repo = ret.repo
            local keepBrowsingRepo = true
            
            while keepBrowsingRepo do
                local systemList = {}
                for i, sys in ipairs(repo.systems) do
                    systemList[i] = sys.name
                end
                
                local r = Script.ShowPopupList(repo.name, "Select system (" .. #repo.systems .. ")", systemList)
                if not r or r.Canceled then
                    keepBrowsingRepo = false
                else
                    local sys = repo.systems[r.Selected.Key]
                    currentSystem = {folder = sys.folder, exts = sys.exts}
                    local romFolder = storageDevice .. ROM_BASE .. "\\" .. sys.folder
                    FileSystem.CreateDirectory(romFolder)
                    
                    local file = browse(sys.url)
                    if file then
                        local displayName = decodeUrl(file.name)
                        local confirm = Script.ShowMessageBox("Download", "Download " .. displayName .. "?", "Yes", "No")
                        
                        if confirm.Button == 1 then
                            gAbortedOperation = false
                            gDownloadStartTime = getTime()
                            gLastProgressUpdate = 0
                            
                            -- Convert to CDN URL if myrient (skip redirect)
                            local downloadUrl = toCdnUrl(file.url)
                            
                            Script.SetStatus("Downloading...")
                            Script.SetProgress(0)
                            
                            local dlPath = DOWNLOAD_FOLDER .. "\\temp.zip"
                            local result = Http.GetEx(downloadUrl, HttpProgressRoutine, dlPath)
                            
                            if gAbortedOperation then
                                Script.ShowNotification("Cancelled")
                                FileSystem.DeleteFile(absoluteDownloadsPath .. "temp.zip")
                            elseif not result or not result.Success then
                                Script.ShowNotification("Download failed")
                            else
                                local endTime = getTime()
                                local elapsed = endTime - gDownloadStartTime
                                if elapsed < 0 then elapsed = elapsed + 86400 end
                                if elapsed < 1 then elapsed = 1 end
                                
                                local fileSize = FileSystem.GetFileSize(absoluteDownloadsPath .. "temp.zip")
                                if fileSize then
                                    local speed = fileSize / elapsed
                                    log(string.format("Downloaded: %s in %ds (%s)", 
                                        formatSize(fileSize), elapsed, formatSpeed(speed)))
                                end
                                
                                Script.SetStatus("Extracting...")
                                local extracted, err = extractZip(absoluteDownloadsPath .. "temp.zip", romFolder)
                                FileSystem.DeleteFile(absoluteDownloadsPath .. "temp.zip")
                                
                                if extracted then
                                    Script.ShowNotification("Installed: " .. extracted)
                                    log("Extracted: " .. extracted)
                                else
                                    Script.ShowNotification("Extract failed: " .. tostring(err))
                                    log("Extract error: " .. tostring(err))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    FileSystem.DeleteDirectory(absoluteDownloadsPath)
    log("=== ROM Store ended ===")
end
