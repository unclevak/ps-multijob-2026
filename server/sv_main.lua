local QBCore = exports['qb-core']:GetCoreObject()

-- Qbox notes:
-- - qbx_core provides a qb-core bridge, so QBCore.Functions.* works on QBX.
-- - In Qbox, job grades are numeric (not strings). Handle both to stay compatible.

local function gradeKey(grades, grade)
    if not grades then return nil end
    if grades[grade] ~= nil then return grade end
    local s = tostring(grade)
    if grades[s] ~= nil then return s end
    return nil
end

local function getGradeData(jobData, grade)
    if not jobData or not jobData.grades then return nil end
    local key = gradeKey(jobData.grades, grade)
    return key and jobData.grades[key] or nil
end

local function GetJobsTable()
    -- Prefer QBX shared export if present; fallback to qb-core bridge shared table
    if GetResourceState('qbx_core') == 'started' and exports.qbx_core and exports.qbx_core.GetJobs then
        return exports.qbx_core:GetJobs()
    end
    return (QBCore.Shared and QBCore.Shared.Jobs) or {}
end

local function GetPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

local function GetPlayerByCitizenId(citizenid)
    if QBCore.Functions.GetPlayerByCitizenId then
        return QBCore.Functions.GetPlayerByCitizenId(citizenid)
    end
    return nil
end

local function GetOfflinePlayerByCitizenId(citizenid)
    if QBCore.Functions.GetOfflinePlayerByCitizenId then
        return QBCore.Functions.GetOfflinePlayerByCitizenId(citizenid)
    end
    return nil
end

local function GetPlayersData()
    -- Prefer QBX export for performance if present
    if GetResourceState('qbx_core') == 'started' and exports.qbx_core and exports.qbx_core.GetPlayersData then
        return exports.qbx_core:GetPlayersData() or {}
    end

    local out = {}
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = GetPlayer(src)
        if p and p.PlayerData then
            out[#out+1] = p.PlayerData
        end
    end
    return out
end

local function HasAdminPerm(source)
    if QBCore and QBCore.Functions and QBCore.Functions.HasPermission then
        return QBCore.Functions.HasPermission(source, 'admin')
    end
    return IsPlayerAceAllowed(source, 'admin')
end

local function GetJobs(citizenid)
    local p = promise.new()
    MySQL.Async.fetchAll("SELECT jobdata FROM multijobs WHERE citizenid = @citizenid",{
        ["@citizenid"] = citizenid
    }, function(rows)
        local jobs
        if rows and rows[1] and rows[1].jobdata and rows[1].jobdata ~= "[]" then
            jobs = json.decode(rows[1].jobdata) or {}
        else
            local Player = GetOfflinePlayerByCitizenId(citizenid)
            local temp = {}
            if Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name then
                if not Config.IgnoredJobs[Player.PlayerData.job.name] then
                    local g = Player.PlayerData.job.grade
                    local grade = tonumber((type(g) == "table" and (g.level or g.grade)) or g) or 0
                    temp[Player.PlayerData.job.name] = grade

                    MySQL.insert('INSERT INTO multijobs (citizenid, jobdata) VALUES (:citizenid, :jobdata) ON DUPLICATE KEY UPDATE jobdata = :jobdata', {
                        citizenid = citizenid,
                        jobdata = json.encode(temp),
                    })
                end
            end
            jobs = temp
        end
        p:resolve(jobs)
    end)
    return Citizen.Await(p)
end
exports("GetJobs", GetJobs)

local function AddJob(citizenid, job, grade)
    grade = tonumber(grade) or 0
    local jobs = GetJobs(citizenid)

    -- Remove ignored jobs if they exist in the saved list
    for ignored in pairs(Config.IgnoredJobs) do
        if jobs[ignored] then
            jobs[ignored] = nil
        end
    end

    jobs[job] = grade
    MySQL.insert('INSERT INTO multijobs (citizenid, jobdata) VALUES (:citizenid, :jobdata) ON DUPLICATE KEY UPDATE jobdata = :jobdata', {
        citizenid = citizenid,
        jobdata = json.encode(jobs),
    })
end
exports("AddJob", AddJob)

local function UpdatePlayerJob(Player, job, grade)
    grade = tonumber(grade) or 0

    if Player and Player.PlayerData and Player.PlayerData.source ~= nil then
        -- online
        Player.Functions.SetJob(job, grade)
        return
    end

    -- offline update
    local sharedJobData = GetJobsTable()[job]
    if sharedJobData == nil then return end

    local sharedGradeData = getGradeData(sharedJobData, grade)
    if sharedGradeData == nil then return end

    local isBoss = sharedGradeData.isboss and true or false

    MySQL.update.await("UPDATE players SET job = @jobData WHERE citizenid = @citizenid", {
        jobData = json.encode({
            label = sharedJobData.label,
            name = job,
            isboss = isBoss,
            onduty = sharedJobData.defaultDuty,
            payment = sharedGradeData.payment or 0,
            grade = {
                name = sharedGradeData.name,
                level = grade,
            },
        }),
        citizenid = Player.PlayerData.citizenid
    })
end

local function UpdateJobRank(citizenid, job, grade)
    grade = tonumber(grade) or 0
    local Player = GetOfflinePlayerByCitizenId(citizenid)
    if Player == nil then return end

    local jobs = GetJobs(citizenid)
    if jobs[job] == nil then return end

    jobs[job] = grade

    MySQL.update.await("UPDATE multijobs SET jobdata = :jobdata WHERE citizenid = :citizenid", {
        citizenid = citizenid,
        jobdata = json.encode(jobs),
    })

    -- if the current job matches, then update
    if Player.PlayerData.job and Player.PlayerData.job.name == job then
        UpdatePlayerJob(Player, job, grade)
    end
end
exports("UpdateJobRank", UpdateJobRank)

local function RemoveJob(citizenid, job)
    local Player = GetPlayerByCitizenId(citizenid)
    if Player == nil then
        Player = GetOfflinePlayerByCitizenId(citizenid)
    end
    if Player == nil then return end

    local jobs = GetJobs(citizenid)
    jobs[job] = nil

    -- Since we removed a job, put player in a new job
    local foundNewJob = false
    if Player.PlayerData.job and Player.PlayerData.job.name == job then
        for k, v in pairs(jobs) do
            UpdatePlayerJob(Player, k, v)
            foundNewJob = true
            break
        end
    end

    if not foundNewJob then
        UpdatePlayerJob(Player, "unemployed", 0)
    end

    MySQL.insert('INSERT INTO multijobs (citizenid, jobdata) VALUES (:citizenid, :jobdata) ON DUPLICATE KEY UPDATE jobdata = :jobdata', {
        citizenid = citizenid,
        jobdata = json.encode(jobs),
    })
end
exports("RemoveJob", RemoveJob)

-- Admin commands (bridge-compatible)
QBCore.Commands.Add('removejob', 'Remove Multi Job (Admin Only)', { { name = 'id', help = 'ID of player' }, { name = 'job', help = 'Job Name' } }, false, function(source, args)
    if source == 0 then return end
    local target = tonumber(args[1] or '')
    local job = args[2]
    if not target or not job then
        TriggerClientEvent("QBCore:Notify", source, "Wrong usage!", "error")
        return
    end

    local Player = GetPlayer(target)
    if not Player then
        TriggerClientEvent("QBCore:Notify", source, "Player not found!", "error")
        return
    end

    RemoveJob(Player.PlayerData.citizenid, job)
end, 'admin')

QBCore.Commands.Add('addjob', 'Add Multi Job (Admin Only)', { { name = 'id', help = 'ID of player' }, { name = 'job', help = 'Job Name' }, { name = 'grade', help = 'Job Grade' } }, false, function(source, args)
    if source == 0 then return end
    local target = tonumber(args[1] or '')
    local job = args[2]
    local grade = tonumber(args[3] or '')
    if not target or not job or grade == nil then
        TriggerClientEvent("QBCore:Notify", source, "Wrong usage!", "error")
        return
    end

    local Player = GetPlayer(target)
    if not Player then
        TriggerClientEvent("QBCore:Notify", source, "Player not found!", "error")
        return
    end

    AddJob(Player.PlayerData.citizenid, job, grade)
end, 'admin')

local function BuildJobsPayload(source)
    local Player = GetPlayer(source)
    if not Player or not Player.PlayerData then
        return { whitelist = {}, civilian = {} }
    end

    local jobs = GetJobs(Player.PlayerData.citizenid)
    local whitelistedjobs, civjobs = {}, {}
    local active = {}
    local players = GetPlayersData()
    local jobsTable = GetJobsTable()

    -- count on-duty per job
    for i = 1, #players do
        local pd = players[i]
        if pd and pd.job and pd.job.name then
            local name = pd.job.name
            active[name] = active[name] or 0
            if pd.job.onduty then
                active[name] = active[name] + 1
            end
        end
    end

    for job, grade in pairs(jobs) do
        local jobData = jobsTable[job]
        if jobData == nil then
            print(("ps-multijob: job '%s' is missing from qbx/qb jobs. Remove it from multijobs DB or add it back to jobs.lua."):format(job))
        else
            grade = tonumber(grade) or 0
            local gradeData = getGradeData(jobData, grade) or { name = tostring(grade), payment = 0 }

            local payload = {
                name = job,
                grade = grade,
                description = Config.Descriptions[job] or '',
                icon = Config.FontAwesomeIcons[job] or '',
                label = jobData.label or job,
                gradeLabel = gradeData.name or '',
                salary = gradeData.payment or 0,
                active = active[job] or 0,
            }

            if Config.WhitelistJobs[job] then
                whitelistedjobs[#whitelistedjobs + 1] = payload
            else
                civjobs[#civjobs + 1] = payload
            end
        end
    end

    return { whitelist = whitelistedjobs, civilian = civjobs }
end

-- ox_lib callback (Qbox-native) + qb-core callback (legacy)
if lib and lib.callback and lib.callback.register then
    lib.callback.register('ps-multijob:getJobs', function(source)
        return BuildJobsPayload(source)
    end)
end

QBCore.Functions.CreateCallback("ps-multijob:getJobs", function(source, cb)
    cb(BuildJobsPayload(source))
end)

RegisterNetEvent("ps-multijob:changeJob", function(cjob, cgrade)
    local source = source
    local Player = GetPlayer(source)
    if not Player or not Player.PlayerData then return end

    cgrade = tonumber(cgrade) or 0

    if cjob == "unemployed" and cgrade == 0 then
        Player.Functions.SetJob(cjob, cgrade)
        return
    end

    local jobs = GetJobs(Player.PlayerData.citizenid)
    for job, grade in pairs(jobs) do
        if cjob == job and cgrade == tonumber(grade) then
            Player.Functions.SetJob(job, cgrade)
            break
        end
    end
end)

RegisterNetEvent("ps-multijob:removeJob", function(job)
    local source = source
    local Player = GetPlayer(source)
    if not Player or not Player.PlayerData then return end
    RemoveJob(Player.PlayerData.citizenid, job)
end)

-- When a player's job is updated by other scripts, persist it into multijobs
RegisterNetEvent('QBCore:Server:OnJobUpdate', function(source, newJob)
    local src = source
    local Player = GetPlayer(src)
    if not Player or not Player.PlayerData then return end
    if not newJob or not newJob.name then return end

    local jobs = GetJobs(Player.PlayerData.citizenid)

    local amount = 0
    for _ in pairs(jobs) do amount = amount + 1 end

    local maxJobs = Config.MaxJobs
    if HasAdminPerm(src) then
        maxJobs = math.huge
    end

    local grade = newJob.grade
    local lvl = tonumber((type(grade) == "table" and (grade.level or grade.grade)) or grade) or 0

    if amount < maxJobs and not Config.IgnoredJobs[newJob.name] then
        local existing = jobs[newJob.name]
        if existing == nil or tonumber(existing) ~= lvl then
            AddJob(Player.PlayerData.citizenid, newJob.name, lvl)
        end
    end
end)

-- Utility event: wipe a citizen's multijobs row
RegisterNetEvent('ps-multijob:server:removeJob', function(targetCitizenId)
    MySQL.Async.execute('DELETE FROM multijobs WHERE citizenid = ?', { targetCitizenId }, function(affectedRows)
        if affectedRows > 0 then
            print('ps-multijob: removed multijobs for ' .. targetCitizenId)
        else
            print('ps-multijob: no multijobs found for ' .. targetCitizenId)
        end
    end)
end)
