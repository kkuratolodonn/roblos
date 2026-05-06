-- ============================================
-- AUTO LOOP: PICKUP → EQUIP → WAIT GONE → REPEAT
-- ============================================

local Players = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- ============================================
-- CONFIG
-- ============================================
local CAMERA_LOOK_DELAY = 0.3 -- Berapa lama kamera "menatap" batu sebelum trigger
local PICKUP_WAIT_DELAY = 0.1 -- Tunggu setelah trigger E sebelum cek backpack
local BACKPACK_WAIT_TIMEOUT = 1.5 -- Maksimum tunggu batu muncul di backpack (detik)
local LOOP_DELAY = 0.3 -- Jeda antar cycle setelah batu hilang
local RESTORE_CAMERA = true -- Balikin kamera setelah pickup
local SELL_POSITION = Vector3.new(-498, 64, -1497) -- Lokasi jual yang udah disave
local TP_ON_START = true -- Teleport sekali di awal

-- ============================================
-- LOGGER
-- ============================================
local function log(...)
	print("[Auto]", string.format("[%.2fs]", os.clock()), ...)
end

local function warnLog(...)
	warn("[Auto]", ...)
end

-- ============================================
-- HELPER: Snapshot nama tool di backpack
-- ============================================
local function getBackpackToolNames()
	local names = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return names
	end

	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") then
			table.insert(names, item.Name)
		end
	end
	return names
end

-- ============================================
-- HELPER: Cari tool baru (yang nggak ada di snapshot)
-- ============================================
local function findNewTool(beforeNames, backpack)
	local beforeSet = {}
	for _, name in ipairs(beforeNames) do
		beforeSet[name] = (beforeSet[name] or 0) + 1
	end

	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") then
			if not beforeSet[item.Name] or beforeSet[item.Name] == 0 then
				return item
			else
				beforeSet[item.Name] = beforeSet[item.Name] - 1
			end
		end
	end
	return nil
end

-- ============================================
-- HELPER: Tool yang lagi ke-equip
-- ============================================
local function getEquippedTool()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Tool") or nil
end

-- ============================================
-- HELPER: Cari posisi batu (parent dari prompt)
-- ============================================
local function getRockPosition(rockPrompt)
	local parent = rockPrompt.Parent

	if parent:IsA("BasePart") then
		return parent.Position
	end

	if parent:IsA("Model") then
		if parent.PrimaryPart then
			return parent.PrimaryPart.Position
		end
		for _, child in ipairs(parent:GetDescendants()) do
			if child:IsA("BasePart") then
				return child.Position
			end
		end
	end

	local current = parent
	while current and current ~= Workspace do
		if current:IsA("BasePart") then
			return current.Position
		end
		current = current.Parent
	end

	return nil
end

-- ============================================
-- FUNCTION: PICKUP ROCK (returns tool object kalau berhasil, nil kalau gagal)
-- ============================================
local function pickupRock()
	log("--- PICKUP ---")

	-- Cari prompt (re-find tiap cycle, prompt mungkin di-respawn)
	local promptFolder = Workspace:FindFirstChild("Prompt")
	if not promptFolder then
		warnLog("workspace.Prompt tidak ada.")
		return nil
	end

	local rockPrompt = promptFolder:FindFirstChild("ProximityPrompt")
	if not rockPrompt then
		warnLog("ProximityPrompt belum muncul.")
		return nil
	end

	local rockPosition = getRockPosition(rockPrompt)
	if not rockPosition then
		warnLog("Posisi batu tidak ketemu.")
		return nil
	end

	-- Setup prompt
	rockPrompt.HoldDuration = 0
	rockPrompt.MaxActivationDistance = math.huge
	rockPrompt.RequiresLineOfSight = false
	rockPrompt.Enabled = true

	-- Snapshot backpack sebelum pickup
	local backpackBefore = getBackpackToolNames()
	local equippedBefore = getEquippedTool()
	local equippedBeforeName = equippedBefore and equippedBefore.Name or nil

	-- Save & arahkan kamera
	local originalCameraCFrame = camera.CFrame
	local originalCameraType = camera.CameraType

	camera.CFrame = CFrame.new(camera.CFrame.Position, rockPosition)
	task.wait(CAMERA_LOOK_DELAY)

	-- Trigger E
	VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
	task.wait(0.15)
	VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)

	task.wait(PICKUP_WAIT_DELAY)

	-- Restore kamera
	if RESTORE_CAMERA then
		camera.CFrame = originalCameraCFrame
		camera.CameraType = originalCameraType
	end

	-- Tunggu batu muncul (di backpack atau di tangan)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		warnLog("Backpack hilang.")
		return nil
	end

	local elapsed = 0
	local checkInterval = 0.1

	while elapsed < BACKPACK_WAIT_TIMEOUT do
		-- Cek tool baru di backpack
		local newTool = findNewTool(backpackBefore, backpack)
		if newTool then
			log("Batu masuk backpack:", newTool.Name)
			return newTool
		end

		-- Cek juga kalau langsung ke tangan
		local equipped = getEquippedTool()
		if equipped and equipped.Name ~= equippedBeforeName then
			log("Batu langsung ke tangan:", equipped.Name)
			return equipped
		end

		task.wait(checkInterval)
		elapsed = elapsed + checkInterval
	end

	warnLog("Timeout. Batu tidak muncul.")
	return nil
end

-- ============================================
-- FUNCTION: EQUIP TOOL
-- ============================================
local function equipTool(tool)
	local char = player.Character
	if not char then
		return false
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end

	-- Skip kalau udah ke-equip
	if getEquippedTool() == tool then
		log("Tool udah ter-equip:", tool.Name)
		return true
	end

	humanoid:EquipTool(tool)
	log("Equipped:", tool.Name)
	return true
end

-- ============================================
-- FUNCTION: TUNGGU SAMPAI TOOL HILANG (event-based, instant)
-- ============================================
local function waitUntilToolGone(tool)
	log("Nunggu batu hilang...")

	if not tool or not tool.Parent then
		log("Batu udah hilang.")
		return
	end

	-- Pakai event biar instant detect
	local gone = false
	local connections = {}

	-- Event 1: Tool di-destroy
	table.insert(
		connections,
		tool.Destroying:Connect(function()
			gone = true
		end)
	)

	-- Event 2: Tool dipindahin parent-nya (misal ke nil atau ke tempat lain)
	table.insert(
		connections,
		tool.AncestryChanged:Connect(function(_, newParent)
			local char = player.Character
			local backpack = player:FindFirstChildOfClass("Backpack")

			-- Kalau parent baru bukan character & bukan backpack, anggap hilang
			if newParent ~= char and newParent ~= backpack then
				gone = true
			end
		end)
	)

	-- Tunggu salah satu event fire
	while not gone do
		task.wait(0.05) -- polling super cepat sebagai backup

		-- Backup check (jaga-jaga kalau event nggak fire)
		if not tool or not tool.Parent then
			gone = true
			break
		end

		local parent = tool.Parent
		local char = player.Character
		local backpack = player:FindFirstChildOfClass("Backpack")
		if parent ~= char and parent ~= backpack then
			gone = true
			break
		end
	end

	-- Cleanup connections
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end

	log("Batu hilang. Lanjut.")
end

-- ============================================
-- TELEPORT KE LOKASI JUAL (sekali di awal)
-- ============================================
if TP_ON_START then
	log("=== TELEPORT KE LOKASI JUAL ===")

	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart")

	log("Posisi awal:", hrp.Position)
	hrp.CFrame = CFrame.new(SELL_POSITION)
	task.wait(0.5)
	log("Posisi sekarang:", hrp.Position)
end

-- ============================================
-- MAIN LOOP
-- ============================================
log("=== AUTO LOOP MULAI ===")

while true do
	local success, err = pcall(function()
		-- Step 1: Pickup
		local rock = pickupRock()
		if not rock then
			log("Pickup gagal, retry next cycle.")
			return
		end

		-- Step 2: Equip (kalau belum ke-equip)
		equipTool(rock)

		-- Step 3: Tunggu batu hilang
		waitUntilToolGone(rock)

		log("Cycle selesai. Restart...\n")
	end)

	if not success then
		warnLog("Error di cycle:", err)
	end

	task.wait(LOOP_DELAY)
end
