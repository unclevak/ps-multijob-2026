local QBCore = exports['qb-core']:GetCoreObject()

-- Qbox runs qb-core bridge, so QBCore is available.
-- Prefer ox_lib callback API when available.
local function GetJobsPayload()
    if lib and lib.callback and lib.callback.await then
        return lib.callback.await('ps-multijob:getJobs', false) or {}
    end

    local p = promise.new()
    QBCore.Functions.TriggerCallback('ps-multijob:getJobs', function(result)
        p:resolve(result or {})
    end)
    return Citizen.Await(p) or {}
end

local function GetPlayerJob()
    local pd = QBCore.Functions.GetPlayerData() or {}
    return pd.job or {}
end

local function Notify(msg, nType)
    nType = nType or 'inform'
    if lib and lib.notify then
        lib.notify({ description = msg, type = nType })
        return
    end
    TriggerEvent('QBCore:Notify', msg, nType)
end

local function GetSharedJobs()
    if GetResourceState('qbx_core') == 'started' and exports.qbx_core and exports.qbx_core.GetJobs then
        return exports.qbx_core:GetJobs() or {}
    end
    return (QBCore.Shared and QBCore.Shared.Jobs) or {}
end

local function OpenUI()
    local job = GetPlayerJob()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'sendjobs',
        activeJob = job.name,
        onDuty = job.onduty,
        jobs = GetJobsPayload(),
        side = Config.Side,
    })
end

RegisterNUICallback('selectjob', function(data, cb)
    TriggerServerEvent('ps-multijob:changeJob', data.name, data.grade)

    -- Determine default duty state for the selected job (if the job defines it)
    local jobs = GetSharedJobs()
    local j = jobs and jobs[data.name]
    local onDuty = false
    if j and j.defaultDuty ~= nil then
        onDuty = j.defaultDuty
    end

    cb({ onDuty = onDuty })
end)

RegisterNUICallback('closemenu', function(_, cb)
    cb({})
    SetNuiFocus(false, false)
end)

RegisterNUICallback('removejob', function(data, cb)
    TriggerServerEvent('ps-multijob:removeJob', data.name)
    local jobs = GetJobsPayload()
    -- server will persist; UI can refresh from callback response
    cb(jobs)
end)

RegisterNUICallback('toggleduty', function(_, cb)
    cb({})

    local jobData = GetPlayerJob()
    local jobName = jobData.name

    if jobName and Config.DenyDuty[jobName] then
        Notify('Not allowed to use this station for clock-in.', 'error')
        return
    end

    -- Prefer CodeM MDT duty handler if present
    if GetResourceState('codem-mdt') == 'started' then
        TriggerEvent('codem-mdt:client:ToggleDuty')
        return
    end

    -- Fallback to qb-core duty toggle event (works on QBX via bridge)
    TriggerServerEvent('QBCore:ToggleDuty')
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    SendNUIMessage({
        action = 'updatejob',
        name = JobInfo.name,
        label = JobInfo.label,
        onDuty = JobInfo.onduty,
        gradeLabel = (JobInfo.grade and JobInfo.grade.name) or '',
        grade = (JobInfo.grade and JobInfo.grade.level) or JobInfo.grade or 0,
        salary = JobInfo.payment or 0,
        isWhitelist = Config.WhitelistJobs[JobInfo.name] or false,
        description = Config.Descriptions[JobInfo.name] or '',
        icon = Config.FontAwesomeIcons[JobInfo.name] or '',
    })
end)

RegisterCommand('jobmenu', OpenUI, false)
RegisterKeyMapping('jobmenu', 'Show Job Management', 'keyboard', 'J')
TriggerEvent('chat:removeSuggestion', '/jobmenu')
