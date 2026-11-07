-- ============================================================
-- 小草 / Rage Quit 运行时全量捕获脚本（Potassium 手机端单文件）
-- 原理：先 hook 全局 loadstring 和 game 的 HttpGet，再走官方
-- QuantumOnyx 真实加载链 + 你的高级卡密。Luarmor VM 解密出的
-- 每个明文模块、每次远程拉取的脚本，都会原样写进本地目录。
-- hook 不改动任何返回值，官方功能照常运行。
-- ============================================================

local sessionDir = "rq_dump_" .. tostring(os.time and os.time() or "0")
local loadCount, httpCount = 0, 0
local manifest = {}

local function ensureDir()
	pcall(function()
		if not isfolder(sessionDir) then makefolder(sessionDir) end
	end)
end

local function writeManifest()
	pcall(function()
		writefile(sessionDir .. "/manifest.txt", table.concat(manifest, "\n"))
	end)
end

local function dumpSource(prefix, n, src, extra)
	if type(src) ~= "string" then return end
	local path = sessionDir .. "/" .. prefix .. "_" .. string.format("%03d", n) .. ".lua"
	pcall(function() writefile(path, src) end)
	manifest[#manifest + 1] = prefix .. " #" .. n .. " len=" .. #src .. (extra and (" " .. extra) or "")
	writeManifest()
end

local function makeClosure(fn)
	if newcclosure then
		local ok, c = pcall(newcclosure, fn)
		if ok then return c end
	end
	return fn
end

-- 1) hook loadstring（含 load），捕获 VM 解密出的明文模块
-- 用 hookfunction 的返回值作为原始函数，避免自递归
local function installLoadHook()
	if not hookfunction then return false end
	local anyOk = false
	local function hookOne(target, tag)
		if type(target) ~= "function" then return end
		local real
		local ok = pcall(function()
			real = hookfunction(target, makeClosure(function(src, ...)
				if type(src) == "string" then
					loadCount = loadCount + 1
					dumpSource("load", loadCount, src, tag)
				end
				return real(src, ...)
			end))
		end)
		if ok and real then anyOk = true end
	end
	hookOne(loadstring, "loadstring")
	if load and load ~= loadstring then hookOne(load, "load") end
	return anyOk
end

-- 2) hook game __namecall，捕获所有 HttpGet / HttpGetAsync
local function installHttpHook()
	if not hookmetamethod then return false end
	local old
	local function handler(...)
		local method = getnamecallmethod and getnamecallmethod() or ""
		local m = tostring(method)
		if m == "HttpGet" or m == "HttpGetAsync" or m:find("HttpGet", 1, true) then
			local url = select(2, ...)
			local result = old(...)
			if type(result) == "string" then
				httpCount = httpCount + 1
				dumpSource("http", httpCount, result, "url=" .. tostring(url))
			end
			return result
		end
		return old(...)
	end
	local ok = pcall(function()
		old = hookmetamethod(game, "__namecall", makeClosure(handler))
	end)
	return ok
end

ensureDir()
pcall(function()
	writefile(sessionDir .. "/readme.txt",
		"capture dir: " .. sessionDir .. "\n" ..
		"load_###.lua = plaintext modules the Luarmor VM loads via loadstring\n" ..
		"http_###.lua = scripts fetched via HttpGet (see url in manifest.txt)\n" ..
		"manifest.txt = ordered capture log\n")
end)

local lsOk = installLoadHook()
local httpOk = installHttpHook()

print("================ 小草捕获 ================")
print("loadstring hook = " .. tostring(lsOk))
print("http hook       = " .. tostring(httpOk))
print("capture folder  = " .. sessionDir)
print("==========================================")

-- 3) 走官方真实入口（卡密在弹出的官方窗口里你本人输入）
local ENTRY_URL = "https://raw.githubusercontent.com/flazhy/QuantumOnyx/refs/heads/main/QuantumOnyx.lua"
local started = pcall(function()
	local entry = game:HttpGet(ENTRY_URL)
	local f, err = loadstring(entry)
	if not f then error(tostring(err)) end
	f()
end)

print("官方链启动 = " .. tostring(started))
print("不用点任何功能：主菜单加载出来、等约10秒，把 " .. sessionDir .. " 整个目录发我即可。")
