--[[
usbmtp_drive: the "USB drive" mode's files.

The drive is a disk image in KOReader's folder (never in documents/, and never
inside the plugin, which updates replace). The computer sees it as a plain USB
stick called TO KINDLE, which every OS can write to with no extra app; the
Kindle's own storage stays mounted here the whole time, so KOReader keeps
running. After the computer ejects it, import() copies what's on it into
documents/ and wipe() empties it for next time.

  Drive.create(path)        -> true | nil, err   (SIZE_MB, formatted; takes a while)
  Drive.pending(path)       -> number of files on the drive not yet added (or nil, err)
  Drive.import(path, opts)  -> result | nil, err [, "dirty"]
        result = { added = {us paths}, same = n, empty = n, skipped = n, owned = n,
                   failed = { {name=, err=} } }
        owned: .lua files and .sdr folders, which are never copied (KOReader runs/reads them)
        "dirty": the computer didn't eject it, so nothing was touched; the books
        wait on the drive until it's ejected properly
        opts.before_replace(us_path)  called before an existing file is overwritten
        opts.free_space(dir)          bytes available (default: util.diskUsage)
  Drive.wipe(path), Drive.erase(path)
]]

local Fat = require("usbmtp_fat")
local lfs = require("libs/libkoreader-lfs")

local Drive = {
    IMAGE = "/mnt/base-us/koreader/usbmtp-drive.img", -- base-us: the kernel must not go through Amazon's FUSE layer
    BOOKS = "/mnt/base-us/documents",
    MB = 1024 * 1024,
    SIZE_MB = 256,
}

-- KOReader knows files by their /mnt/us path.
function Drive.usPath(p)
    return (p:gsub("^/mnt/base%-us/", "/mnt/us/"))
end

local function mkdirs(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local path = ""
    for part in dir:gmatch("[^/]+") do
        path = path .. "/" .. part
        if lfs.attributes(path, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(path)
            if not ok and lfs.attributes(path, "mode") ~= "directory" then return nil, err end
        end
    end
    return true
end

local function defaultFreeSpace(dir)
    local ok, util = pcall(require, "util")
    if not ok or not util.diskUsage then return nil end
    local u = util.diskUsage(dir)
    return u and u.available
end

function Drive.size(path)
    return lfs.attributes(path, "size")
end

-- Zeros first (vfat on this kernel can't make a large file any other way), then
-- the filesystem; renamed into place only when complete.
function Drive.create(path, free_space)
    local mb = Drive.SIZE_MB
    local dir = path:match("^(.*)/[^/]+$")
    local ok, err = mkdirs(dir)
    if not ok then return nil, err end
    local avail = (free_space or defaultFreeSpace)(dir)
    if avail and avail < (mb + 32) * Drive.MB then
        return nil, string.format("not enough space on the Kindle (%d MB needed, %d MB free)",
                                  mb + 32, math.floor(avail / Drive.MB))
    end
    local tmp = path .. ".part"
    local f
    f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local zero = string.rep("\0", Drive.MB)
    for _ = 1, mb do
        if not f:write(zero) then f:close(); os.remove(tmp); return nil, "write failed (Kindle full?)" end
    end
    ok = f:close()
    if ok then ok, err = Fat.format(tmp) end
    if ok then ok, err = os.rename(tmp, path) end
    if not ok then os.remove(tmp); return nil, err or "write failed (Kindle full?)" end
    return true
end


local function sameContent(a, b, size)
    local fa, fb = io.open(a, "rb"), io.open(b, "rb")
    local same = fa and fb and true or false
    while same and size > 0 do
        local n = math.min(size, Drive.MB)
        local x, y = fa:read(n), fb:read(n)
        same = x ~= nil and x == y
        size = size - n
    end
    if fa then fa:close() end
    if fb then fb:close() end
    return same
end

-- vfat drops trailing dots and spaces from names it stores ("x.lua." is saved
-- as "x.lua"), so names are judged, and written, the way they'll end up.
local function vfatName(name)
    return (name:gsub("[%. ]+$", ""))
end

-- KOReader's own files: it runs the Lua in settings and in each book's .sdr
-- folder, and an old .sdr would replace a book's reading progress and
-- highlights. A drive, whoever wrote it, never supplies these.
local function koreaderOwned(rel)
    for part in rel:gmatch("[^/]+") do
        local l = part:lower()
        if l:match("%.sdr$") or l:match("%.lua$") then return true end
    end
    return false
end

-- What an import that stopped part-way already added (path + size), so the
-- next one doesn't put back a book that was since changed or deleted on the
-- Kindle. Kept next to the image until the drive is emptied.
local function importedListPath(path) return path .. ".imported" end

local function readImported(path)
    local done = {}
    local f = io.open(importedListPath(path), "r")
    if f then
        for line in f:lines() do
            local size, rel = line:match("^(%d+)\t(.+)$")
            if rel then done[rel .. "\0" .. size] = true end
        end
        f:close()
    end
    return done
end

-- Files on the drive not yet added to the Kindle (an import that stopped
-- part-way may have added some).
function Drive.pending(path)
    local vol, err = Fat.open(path)
    if not vol then return nil, err end
    local list
    list, err = vol:list()
    vol:close()
    if not list then return nil, err end
    local done, n = readImported(path), 0
    for _, file in ipairs(list) do
        if not done[file.path .. "\0" .. file.size] then n = n + 1 end
    end
    return n
end

function Drive.import(path, opts)
    opts = opts or {}
    local vol, err = Fat.open(path)
    if not vol then return nil, err end
    -- Not ejected: the computer may not have written everything yet (a file can
    -- have its final size and no data). Leave it all for a proper eject.
    if vol:dirty() then
        vol:close()
        return nil, "the drive wasn't ejected on the computer", "dirty"
    end
    local list, skipped = vol:list()
    if not list then vol:close(); return nil, skipped end

    -- People coming from the stock USB mode may well drop a "documents" folder on
    -- it. That can make two files land on the same name (vfat ignores case), so the
    -- later one gets " (2)".
    local plan, taken, need, owned = {}, {}, 0, 0
    local done = readImported(path)
    for i, file in ipairs(list) do
        local parts = {}
        for part in file.path:gmatch("[^/]+") do parts[#parts + 1] = vfatName(part) end
        local rel = table.concat(parts, "/"):gsub("^[Dd][Oo][Cc][Uu][Mm][Ee][Nn][Tt][Ss]/", "")
        if koreaderOwned(rel) or rel == "" or rel:find("//", 1, true) then
            owned = owned + 1
            goto continue
        end
        local dest = Drive.BOOKS .. "/" .. rel
        local n = 1
        while taken[dest:lower()] do
            n = n + 1
            local stem, ext = rel:match("^(.*)(%.[^./]+)$")
            dest = Drive.BOOKS .. "/" .. (stem and (stem .. " (" .. n .. ")" .. ext) or (rel .. " (" .. n .. ")"))
        end
        taken[dest:lower()] = true
        plan[#plan + 1] = { file = file, dest = dest, index = i, key = file.path .. "\0" .. file.size }
        local existing = lfs.attributes(dest)
        if not (existing and existing.size == file.size) and not done[plan[#plan].key] then
            need = need + file.size
        end
        ::continue::
    end
    local avail = (opts.free_space or defaultFreeSpace)(Drive.BOOKS)
    if avail and need > 0 and avail < need + 8 * Drive.MB then
        vol:close()
        return nil, string.format("not enough space on the Kindle for the %d MB on the drive (%d MB free)",
                                  math.ceil(need / Drive.MB), math.floor(avail / Drive.MB))
    end

    -- One file: "added", "same" (already there, identical), "empty", or nil, err.
    local function importOne(p)
        if p.file.size == 0 then return "empty" end -- e.g. what an interrupted copy leaves
        local dir = p.dest:match("^(.*)/[^/]+$")
        local ok, e = mkdirs(dir)
        if not ok then return nil, e end
        local existing = lfs.attributes(p.dest)
        if existing and existing.mode ~= "file" then return nil, "a folder of that name is in the way" end
        -- Hidden temp name in the same folder (short: long names must still fit), then
        -- rename: never a half-written book.
        local tmp = dir .. "/.usbmtp-part-" .. p.index
        ok, e = vol:extract(p.file, tmp)
        if not ok then return nil, e end
        if existing and existing.size == p.file.size and sameContent(tmp, p.dest, p.file.size) then
            os.remove(tmp) -- e.g. imported before, by a run that stopped part-way
            return "same"
        end
        if existing and opts.before_replace then opts.before_replace(Drive.usPath(p.dest)) end
        ok, e = os.rename(tmp, p.dest)
        if not ok then os.remove(tmp); return nil, e end
        return "added"
    end

    local result = { added = {}, same = 0, empty = 0, skipped = skipped or 0, owned = owned, failed = {} }
    local log = io.open(importedListPath(path), "a")
    for _, p in ipairs(plan) do
        local status, e
        if done[p.key] then
            status = "same" -- added by an earlier import; may have been changed or deleted since
        else
            status, e = importOne(p)
            if (status == "added" or status == "same") and log then
                log:write(p.file.size, "\t", p.file.path, "\n")
                log:flush()
            end
        end
        if status == "added" then
            result.added[#result.added + 1] = Drive.usPath(p.dest)
        elseif status == "same" then
            result.same = result.same + 1
        elseif status == "empty" then
            result.empty = result.empty + 1
        else
            result.failed[#result.failed + 1] = { name = p.file.path, err = tostring(e) }
        end
    end
    vol:close()
    if log then log:close() end
    table.sort(result.added)
    return result
end

-- Remove the drive (and a half-created one).
function Drive.erase(path)
    os.remove(path .. ".part")
    os.remove(importedListPath(path))
    return os.remove(path)
end

function Drive.wipe(path)
    local ok, err = Fat.format(path)
    if ok then os.remove(importedListPath(path)) end
    return ok, err
end

return Drive
