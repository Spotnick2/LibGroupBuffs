------------------------------------------------------------
-- config_scan.lua - the source scan behind the one-write-path rule.
--
-- A behavioural test cannot catch a new direct write to a saved table: it
-- works perfectly well. So a consuming addon reads every file its TOC loads
-- and fails on any assignment into its SavedVariables outside a
-- `config-owner` region - the code that creates the tables, seeds defaults,
-- runs migrations and keeps caches. Everything else goes through
-- Settings:Set / SetIn.
--
-- Not shipped (tests/ is in .pkgmeta's ignore list). A consumer loads it from
-- its library checkout, the one its own tests already load the library from:
--
--     local CS = dofile(libraryRoot .. "/tests/config_scan.lua")
--     local bad, regions = CS.Scan(path, src, { "PriestlyDB", "PriestlySVCheck" })
--
-- `bad` lists each violation as "path:line  code"; `regions` is how many owner
-- regions the file declares, which the consumer pins so that adding one has to
-- be done on purpose. The consumer reads its own files and fails on one it
-- cannot read.
--
-- A lexical guard, not a proof: a write through an alias
-- (`local db = PriestlyDB; db.x = 1`) is invisible to it. Owner code that
-- writes through an alias reports the change itself with Settings:Changed.
--
-- A small hand-written scanner rather than one pattern, because a pattern kept
-- missing shapes: a key with a space, a call, `..` or arithmetic in it,
-- multiple assignment, a value on the next line - all found in review.
------------------------------------------------------------

local CS = {}

CS.BEGIN = "^%s*%-%- config%-owner: begin%s*$"
CS.END = "^%s*%-%- config%-owner: end%s*$"

-- String contents blanked, so `=` and `--` inside them are ignored; then the
-- comment cut off.
local function CodeOf(line)
    local code = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    return (code:gsub("%-%-.*$", ""))
end

-- Is this piece of an assignment's left side an lvalue in one of the saved
-- tables? Bracket and paren contents are dropped first, so any key expression
-- counts: `[ name ]`, `[self:GetName()]`, `[key .. "x"]`, `[i+1]`.
local function IsTarget(piece, names)
    local flat, depth = {}, 0
    for ch in piece:gmatch(".") do
        if ch == "[" or ch == "(" then
            depth = depth + 1
            if depth == 1 then flat[#flat + 1] = ch end
        elseif ch == "]" or ch == ")" then
            if depth == 1 then flat[#flat + 1] = ch end
            depth = depth - 1
        elseif depth == 0 then
            flat[#flat + 1] = ch
        end
    end
    local tail = table.concat(flat):match("([%w_%.%:%[%]%(%)]+)%s*$") or ""
    for _, name in ipairs(names) do
        if tail == name then return true end
        local rest = tail:sub(#name + 1, #name + 1)
        if tail:sub(1, #name) == name and (rest == "." or rest == "[") then return true end
    end
    return false
end

-- Every assignment target on one line of code. An `=` counts if it is at
-- bracket depth 0 and is not part of `==` `~=` `<=` `>=`. It may end the line,
-- with the value on the next one. The left side is cut back to the last
-- statement boundary, split on top-level commas for multiple assignment, and a
-- `local` declaration is skipped.
local function WritesIn(code, names)
    local hits, depth, from, i = 0, 0, 1, 1
    while i <= #code do
        local c = code:sub(i, i)
        if c == "(" or c == "[" or c == "{" then
            depth = depth + 1
        elseif c == ")" or c == "]" or c == "}" then
            depth = depth - 1
        elseif c == "=" and depth == 0 then
            local prev, nxt = code:sub(i - 1, i - 1), code:sub(i + 1, i + 1)
            if nxt == "=" then
                i = i + 1
            elseif prev ~= "~" and prev ~= "<" and prev ~= ">" and prev ~= "=" then
                local left = code:sub(from, i - 1)
                left = left:gsub("%f[%w_]function%f[^%w_][^(]*%b()", "\1")
                for _, kw in ipairs({ "then", "do", "else", "end", "return", "repeat" }) do
                    left = left:gsub("%f[%w_]" .. kw .. "%f[^%w_]", "\1")
                end
                left = left:gsub(";", "\1")
                local stmt = left:match("([^\1]*)$")
                if not stmt:find("^%s*local%s") then
                    local pieceDepth, piece = 0, ""
                    for ch in (stmt .. ","):gmatch(".") do
                        if ch == "(" or ch == "[" or ch == "{" then pieceDepth = pieceDepth + 1 end
                        if ch == ")" or ch == "]" or ch == "}" then pieceDepth = pieceDepth - 1 end
                        if ch == "," and pieceDepth == 0 then
                            if IsTarget(piece, names) then hits = hits + 1 end
                            piece = ""
                        else
                            piece = piece .. ch
                        end
                    end
                end
                from = i + 1
            end
        end
        i = i + 1
    end
    return hits
end

-- Violations in one file's source, and the number of owner regions it
-- declares. Region markers are recognised only as whole comment lines, so
-- prose that mentions them opens nothing, and they must balance.
function CS.Scan(path, src, names)
    assert(type(src) == "string", "config_scan: no source for " .. tostring(path))
    assert(type(names) == "table" and #names > 0, "config_scan: name the saved tables")
    local bad, owned, regions, n = {}, false, 0, 0
    src = src:gsub("\r\n", "\n")
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        if line:find(CS.BEGIN) then
            if owned then bad[#bad + 1] = path .. ":" .. n .. "  nested owner region" end
            owned, regions = true, regions + 1
        elseif line:find(CS.END) then
            if not owned then bad[#bad + 1] = path .. ":" .. n .. "  owner end with no begin" end
            owned = false
        elseif not owned and WritesIn(CodeOf(line), names) > 0 then
            bad[#bad + 1] = path .. ":" .. n .. "  " .. line
        end
    end
    if owned then bad[#bad + 1] = path .. "  owner region never closed" end
    return bad, regions
end

return CS
