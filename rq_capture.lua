-- ============================================================
-- 小草 / Rage Quit 运行时全量捕获（Potassium 电脑端）
-- 设计：hook 只做"入队"（极薄、不写盘、不 pcall），独立后台
-- 协程负责写盘，避免在 Luarmor 深调用栈上做重操作导致 C stack
-- overflow。先自检，确认 hook 安全透传后，再自动启动官方链。
-- 修复：读写各用独立单调指针（qtail/qhead），杜绝队列清空后
-- 新写入回到低索引被丢弃；并维护独立的总调用计数交叉验证。
-- ============================================================

local sessionDir = "rq_dump_" .. tostring(os.time and os.time() or "0")
local ENTRY_URL = "https://raw.githubusercontent.com/flazhy/QuantumOnyx/refs/heads/main/QuantumOnyx.lua"

-- 捕获队列：qtail=写指针（hook 用），qhead=读指针（协程用），均单调递增
local queue = {}
local qhead, qtail = 1, 1
local loadN, httpN = 0, 0
local loadCalls, httpCalls = 0, 0   -- 独立于落盘文件数的 hook 总调用计数
local manifestLines = {}

local function fmt3(n) return string.format("%03d", n) end

local function ensureDir()
	pcall(function()
		if not isfolder(sessionDir) then makefolder(sessionDir) end
	end)
end

-- 后台写盘协程：与 hook 调用栈解耦
task.spawn(function()
	while true do
		if qhead < qtail then
			local item = queue[qhead]
			queue[qhead] = nil
			qhead = qhead + 1
			if item then
				if item.kind == "load" then
					loadN = loadN + 1
					pcall(writefile, sessionDir .. "/load_" .. fmt3(loadN) .. ".lua", item.src)
					manifestLines[#manifestLines + 1] = "load #" .. loadN .. " len=" .. #item.src .. " " .. tostring(item.extra)
				elseif item.kind == "http" then
					httpN = httpN + 1
					pcall(writefile, sessionDir .. "/http_" .. fmt3(httpN) .. ".lua", item.src)
					manifestLines[#manifestLines + 1] = "http #" .. httpN .. " len=" .. #item.src .. " " .. tostring(item.extra)
				end
				pcall(writefile, sessionDir .. "/manifest.txt", table.concat(manifestLines, "\n"))
			end
		else
			task.wait(0.05)
		end
	end
end)

-- 定期把"hook 总调用计数"独立落盘，便于和实际文件数交叉核对
task.spawn(function()
	while true do
		task.wait(1)
		pcall(writefile, sessionDir .. "/counters.txt",
			"loadstring hook total calls = " .. tostring(loadCalls) ..
			"\nhttp hook total calls     = " .. tostring(httpCalls) ..
			"\nload files written        = " .. tostring(loadN) ..
			"\nhttp files written        = " .. tostring(httpN) ..
			"\nqtail (write pointer)     = " .. tostring(qtail) ..
			"\nqhead (read pointer)      = " .. tostring(qhead))
	end
end)

local function wrap(fn)
	if newcclosure then
		local ok, c = pcall(newcclosure, fn)
		if ok then return c end
	end
	return fn
end

-- 1) hook loadstring（极薄，只入队；独立写指针，不依赖 #queue）
local loadHookOk = false
local realLoad
if hookfunction and loadstring then
	local ok = pcall(function()
		realLoad = hookfunction(loadstring, wrap(function(src, ...)
			loadCalls = loadCalls + 1
			if type(src) == "string" then
				queue[qtail] = { kind = "load", src = src, extra = "loadstring" }
				qtail = qtail + 1
			end
			return realLoad(src, ...)
		end))
	end)
	loadHookOk = ok and realLoad ~= nil
end

-- 同时 hook 全局 load（若存在且与 loadstring 不同），避免漏掉编译入口
local realLoad2
if hookfunction and load and load ~= loadstring then
	pcall(function()
		realLoad2 = hookfunction(load, wrap(function(src, ...)
			loadCalls = loadCalls + 1
			if type(src) == "string" then
				queue[qtail] = { kind = "load", src = src, extra = "load" }
				qtail = qtail + 1
			end
			return realLoad2(src, ...)
		end))
	end)
end

-- 2) hook game __namecall，捕获 HttpGet / HttpGetAsync（极薄，只入队）
local httpHookOk = false
if hookmetamethod then
	local old
	local ok = pcall(function()
		old = hookmetamethod(game, "__namecall", wrap(function(...)
			local method = getnamecallmethod and getnamecallmethod() or ""
			local m = tostring(method)
			if m == "HttpGet" or m == "HttpGetAsync" or string.find(m, "HttpGet", 1, true) then
				local url = select(2, ...)
				local result = old(...)
				httpCalls = httpCalls + 1
				if type(result) == "string" then
					queue[qtail] = { kind = "http", src = result, extra = "url=" .. tostring(url) }
					qtail = qtail + 1
				end
				return result
			end
			return old(...)
		end))
	end)
	httpHookOk = ok and old ~= nil
end

ensureDir()
pcall(writefile, sessionDir .. "/readme.txt",
	"capture dir: " .. sessionDir .. "\n" ..
	"load_###.lua = plaintext modules the Luarmor VM loads via loadstring/load\n" ..
	"http_###.lua = scripts fetched via HttpGet (see url in manifest.txt)\n" ..
	"counters.txt = independent hook call totals for cross-checking\n" ..
	"manifest.txt = ordered capture log\n")

print("================ 小草捕获 ================")
print("loadstring hook = " .. tostring(loadHookOk))
print("http hook       = " .. tostring(httpHookOk))
print("capture folder  = " .. sessionDir)
print("==========================================")

-- 自检：先证明 hook 能安全透传、不递归，再启动官方链
local selfTestOk = true

local t1ok, t1err = pcall(function()
	local f = loadstring("return 123")
	if not f then error("loadstring returned nil") end
	if f() ~= 123 then error("loadstring result mismatch") end
end)
if not t1ok then selfTestOk = false; print("[自检] loadstring 失败: " .. tostring(t1err)) end

-- 自检 http，同时拿到官方入口源码（不重复请求）
local entrySrc
local t2ok, t2err = pcall(function()
	entrySrc = game:HttpGet(ENTRY_URL)
	if type(entrySrc) == "string" and #entrySrc >= 100 then return end
	error("bad entry source")
end)
if not t2ok then selfTestOk = false; print("[自检] http 失败: " .. tostring(t2err)) end

print("自检结果 = " .. tostring(selfTestOk))

if selfTestOk then
	-- 3) 自动启动官方真实链（卡密在弹出的官方窗口里你本人输入）
	local started = pcall(function()
		local f, err = loadstring(entrySrc)
		if not f then error(tostring(err)) end
		f()
	end)
	print("官方链启动 = " .. tostring(started))
else
	print("自检未通过，已停止、不启动官方链。把上面诊断截图发我。")
end

print("不用点任何功能：主菜单出来后等约15秒让后台写盘完成，把 " .. sessionDir .. " 整个目录发我。")
