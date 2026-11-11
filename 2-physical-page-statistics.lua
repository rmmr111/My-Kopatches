--[[
Physical Page Statistics - PageMap normalized progress, compatible with KOReader 2026.07.2
Fix v3 (2026-10-27)

Requires the unchanged 2-physical-page-count.lua patch.
The book's pagemap_physical_pages setting is the authority for normalization.
Only normalized books are intercepted. No new tables/files or history rewrites.

New reading samples are saved as PageMap page / normalized total. Existing
samples remain untouched; the standard KOReader page_stat view already knows
how to re-scale samples saved under different page counts.

The original Statistics plugin remains responsible for durations, timestamps,
reading-time estimates, metadata, and reading session handling.
Back up statistics.sqlite3 and the old patch before installing.
--]]

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local userpatch = require("userpatch")

local DB_LOCATION = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local TAG = "PhysicalPageStats PageMap-v3"

local function positiveInt(v)
    v = tonumber(v)
    if not v or v ~= v or v < 1 then return nil end
    return math.floor(v + 0.5)
end

local function normalizedTotal(self)
    local settings = self and self.ui and self.ui.doc_settings
    if not settings or type(settings.readSetting) ~= "function" then return nil end
    return positiveInt(settings:readSetting("pagemap_physical_pages"))
end

local function closeToChosenTotal(count, total)
    return count and total and math.abs(count - total) <= math.max(4, math.floor(total * 0.02))
end

-- A PageMap is indexed in stable-page units, but each entry's .page is a
-- rendered-page coordinate. Do NOT confuse this with the footer screen page.
local function readPageMap(self, total)
    local doc = self and (self.document or (self.ui and self.ui.document))
    if not doc or type(doc.getPageMap) ~= "function" then return nil end
    local ok, entries = pcall(doc.getPageMap, doc)
    if not ok or type(entries) ~= "table" or not closeToChosenTotal(#entries, total) then
        return nil
    end
    local previous, mapped = 0, {}
    for i = 1, #entries do
        local page = positiveInt(entries[i] and entries[i].page)
        if not page or page < previous then return nil end
        mapped[i] = page
        previous = page
    end
    return mapped
end

local function mappedPage(entries, rendered, total)
    rendered = positiveInt(rendered)
    if not rendered or not entries then return nil end
    local lo, hi, index = 1, #entries, 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if entries[mid] <= rendered then
            index = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return math.min(index, total)
end

local function currentStablePage(self, total, entries)
    local pagemap = self and self.ui and self.ui.pagemap
    if pagemap and type(pagemap.getCurrentPageLabel) == "function" then
        local ok, _, index, count = pcall(pagemap.getCurrentPageLabel, pagemap, true)
        index, count = positiveInt(index), positiveInt(count)
        if ok and index and count and index <= count and closeToChosenTotal(count, total) then
            return math.min(index, total)
        end
    end
    -- Only use a rendered-page fallback when a validated PageMap is available.
    return mappedPage(entries, self and self.curr_page, total)
end

-- No table/schema creation here. Reuse the existing lock table only if present.
local function updateCurrentBook(self, total, current)
    local id = positiveInt(self and self.id_curr_book)
    if not id then return end
    local ok, err = pcall(function()
        local conn = SQ3.open(DB_LOCATION)
        local stmt
        if current then
            stmt = conn:prepare("UPDATE book SET pages = ?, total_read_pages = ? WHERE id = ?;")
            stmt:reset():bind(total, current, id):step()
        else
            stmt = conn:prepare("UPDATE book SET pages = ? WHERE id = ?;")
            stmt:reset():bind(total, id):step()
        end
        stmt:close()
        -- Keep the previous lock record in sync; do not recreate removed locks.
        local lock_ok = pcall(function()
            stmt = conn:prepare([[UPDATE physical_page_total_lock
                SET total_pages = ?, last_seen_at = ? WHERE id_book = ?;]])
            stmt:reset():bind(total, os.time(), id):step()
            stmt:close()
        end)
        conn:close()
        if not lock_ok then
            -- Older/fresh databases may not have the optional legacy lock table.
            logger.dbg(TAG .. ": legacy lock table unavailable")
        end
    end)
    if not ok then logger.warn(TAG .. ": book sync failed:", err) end
end

-- Build a temporary normalized version of the still-unsaved reading samples.
-- Preserve ALL positive durations, including multiple rendered pages mapping
-- to one stable page. Never rewrite any existing SQLite reading records.
local function normalizedSamples(samples, entries, total)
    if type(samples) ~= "table" then return nil end
    local converted = {}
    for rendered, spans in pairs(samples) do
        local page = mappedPage(entries, rendered, total)
        if not page or type(spans) ~= "table" then return nil end
        local target = converted[page]
        if not target then target = {}; converted[page] = target end
        for _, span in ipairs(spans) do
            if type(span) ~= "table" then return nil end
            -- Keep timestamps and durations. Combine same-second collisions
            -- so INSERT OR IGNORE cannot silently drop time on a merged page.
            local ts, duration = tonumber(span[1]), tonumber(span[2])
            if not ts or not duration then return nil end
            local found
            for _, existing in ipairs(target) do
                if existing[1] == ts then found = existing; break end
            end
            if found then found[2] = found[2] + duration
            else target[#target + 1] = {ts, duration} end
        end
    end
    return converted
end

local function patchStatistics(ReaderStatistics)
    if not ReaderStatistics or ReaderStatistics._physical_page_v3 then return end
    local original_initData = ReaderStatistics.initData
    local original_insertDB = ReaderStatistics.insertDB
    if type(original_initData) ~= "function" or type(original_insertDB) ~= "function" then
        logger.warn(TAG .. ": unsupported initData/insertDB methods",
            "initData:", type(original_initData), "insertDB:", type(original_insertDB))
        return
    end
    -- onPageUpdate may be unavailable in some patched instances. v2 required
    -- it and then disabled itself entirely. We do not override or require it.
    ReaderStatistics._physical_page_v3 = true

    ReaderStatistics.initData = function(self, ...)
        local result = original_initData(self, ...)
        local total = normalizedTotal(self)
        if total then
            local entries = readPageMap(self, total)
            local current = currentStablePage(self, total, entries)
            updateCurrentBook(self, total, current)
            logger.info(TAG .. ": book opened:",
                (current or "?") .. "/" .. total,
                "book:", self.data and self.data.title or "?")
        end
        return result
    end

    ReaderStatistics.insertDB = function(self, updated_pagecount)
        local total = normalizedTotal(self)
        if not total then
            return original_insertDB(self, updated_pagecount)
        end
        -- Respect KOReader's freeze/disabled conditions and don't discard its
        -- volatile reading samples when the native method would early-return.
        if not (self.id_curr_book and self.is_doc_not_frozen) then
            local result = original_insertDB(self, updated_pagecount)
            updateCurrentBook(self, total, currentStablePage(self, total, readPageMap(self, total)))
            return result
        end

        local original_rendered_total = self.data and self.data.pages
        local original_rendered_page = self.curr_page
        local original_samples = self.page_stat
        local entries = readPageMap(self, total)
        local current = currentStablePage(self, total, entries)

        -- On rerender, pending samples still belong to the PREVIOUS layout.
        -- Do not convert them against the NEW map. Native KOReader will save
        -- them correctly, with the old page count, and rescale them in its view.
        local rerender = updated_pagecount and original_rendered_total
            and updated_pagecount ~= original_rendered_total
        local converted = not rerender and entries
            and normalizedSamples(original_samples, entries, total)
        local mapped_current = converted
            and mappedPage(entries, original_rendered_page, total)
        local result
        if converted and mapped_current and self.data then
            local saved_start_ts
            local spans = original_samples and original_samples[original_rendered_page]
            local last = spans and spans[#spans]
            if last and last[2] == 0 then saved_start_ts = last[1] end

            -- Stage consistent normalized page/total ONLY during the stock DB
            -- write. Then restore KOReader's native screen-page runtime state.
            self.page_stat = converted
            self.curr_page = mapped_current
            self.data.pages = total
            local ok, value = pcall(original_insertDB, self, total)
            self.curr_page = original_rendered_page
            self.data.pages = original_rendered_total
            if ok then
                -- Stock insertDB resets volatile samples to a zero-duration
                -- placeholder. Restore its *rendered* page key and start time.
                local placeholder = self.page_stat and self.page_stat[mapped_current]
                local tail = placeholder and placeholder[#placeholder]
                local next_start_ts = tail and tail[1] or saved_start_ts or os.time()
                self.page_stat = { [original_rendered_page] = {{next_start_ts, 0}} }
            else
                -- Avoid losing pending samples if the native insertion failed.
                self.page_stat = original_samples
                error(value)
            end
            result = value
            logger.info(TAG .. ": saved normalized samples:",
                (current or mapped_current) .. "/" .. total)
        else
            -- Never guess a conversion: stock statistics keep exact time data.
            result = original_insertDB(self, updated_pagecount)
            logger.info(TAG .. ": PageMap unavailable; native samples preserved",
                "book:", self.data and self.data.title or "?")
        end

        -- This is the authoritative exposed total for KoScope. Write AFTER
        -- stock insertDB, which otherwise sets book.pages to rendered count.
        updateCurrentBook(self, total, current)
        return result
    end

    logger.info(TAG .. ": installed for KOReader 2026.07.2")
end

userpatch.registerPatchPluginFunc("statistics", patchStatistics)
logger.info(TAG .. ": registered")
