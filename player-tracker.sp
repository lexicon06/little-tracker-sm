#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "3.3"
#define DATABASE_NAME "l4dstats"
#define UPDATE_INTERVAL 30.0

// Debug logging - set to true for testing
#define DEBUG_MODE false

Database g_Database = null;
bool g_bDatabaseConnected = false;

// ============================================
// PLAYER DATA STRUCTURES
// ============================================

enum struct PlayerData
{
    char steamid[32];
    int joinTime;
    int sessionPlaytime;
    
    // Medic stats
    int heals;
    int revives;
    int defibs;
    int pills;
    int assists;
    
    // Player stats
    int kills;
    int headshots;
    int totalShots;
    
    // Points tracking
    int pointsStartDaily;
    int pointsStartWeekly;
    int currentPoints;
    
    bool loaded;
    bool authorized;
    bool pendingSave;
    
    void Reset()
    {
        this.steamid[0] = '\0';
        this.joinTime = 0;
        this.sessionPlaytime = 0;
        this.heals = 0;
        this.revives = 0;
        this.defibs = 0;
        this.pills = 0;
        this.assists = 0;
        this.kills = 0;
        this.headshots = 0;
        this.totalShots = 0;
        this.pointsStartDaily = 0;
        this.pointsStartWeekly = 0;
        this.currentPoints = 0;
        this.loaded = false;
        this.authorized = false;
        this.pendingSave = false;
    }
}

PlayerData g_PlayerData[MAXPLAYERS + 1];

// Timer handles
Handle g_hPlaytimeTimer = null;
Handle g_hStatsTimer = null;
Handle g_hPointsTimer = null;

// Batch update queue
ArrayList g_hUpdateQueue = null;

// Retry queue for players without SteamID
ArrayList g_hRetryQueue = null;

// ============================================
// PLUGIN INFO
// ============================================

public Plugin myinfo = 
{
    name = "L4D2 Stats Tracker",
    author = "PabloSan",
    description = "Tracks playtime, medic stats, and player performance",
    version = PLUGIN_VERSION,
    url = "fox4dead.com"
};

// ============================================
// MAIN PLUGIN FUNCTIONS
// ============================================

public void OnPluginStart()
{
    // Initialize data structures
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_PlayerData[i].Reset();
    }
    
    // Initialize queues
    g_hUpdateQueue = new ArrayList(1024);
    g_hRetryQueue = new ArrayList();
    
    // Connect to database
    ConnectToDatabase();
    
    // Create timers
    g_hPlaytimeTimer = CreateTimer(UPDATE_INTERVAL, Timer_UpdatePlaytime, _, TIMER_REPEAT);
    g_hStatsTimer = CreateTimer(60.0, Timer_UpdateStats, _, TIMER_REPEAT);
    g_hPointsTimer = CreateTimer(30.0, Timer_CheckPoints, _, TIMER_REPEAT);
    
    // Create retry timer
    CreateTimer(5.0, Timer_RetryPlayers, _, TIMER_REPEAT);
    
    // Hook player events
    HookEvent("player_spawn", Event_PlayerSpawn);
    
    // Hook medic events
    HookEvent("heal_success", Event_HealSuccess);
    HookEvent("revive_success", Event_ReviveSuccess);
    HookEvent("defibrillator_used", Event_DefibUsed);
    HookEvent("pills_used", Event_PillsUsed);
    HookEvent("adrenaline_used", Event_AdrenalineUsed);
    HookEvent("player_incapacitated_start", Event_PlayerIncap);
    
    // Hook player stats events
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("weapon_fire", Event_WeaponFire);
    HookEvent("map_transition", Event_MapTransition);
    
    // Late load support
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && IsClientAuthorized(client))
        {
            char auth[32];
            if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
            {
                OnClientAuthorized(client, auth);
            }
        }
    }
    
    PrintToServer("[Stats Tracker] Plugin loaded successfully!");
}

public void OnPluginEnd()
{
    // Save all valid player data on plugin unload
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && IsValidSteamID(g_PlayerData[i].steamid))
        {
            SaveAllPlayerData(i, true);
        }
    }
    
    // Process remaining queued updates
    ProcessUpdateQueue();
    
    // Clean up timers
    if (g_hPlaytimeTimer != null)
    {
        KillTimer(g_hPlaytimeTimer);
        g_hPlaytimeTimer = null;
    }
    
    if (g_hStatsTimer != null)
    {
        KillTimer(g_hStatsTimer);
        g_hStatsTimer = null;
    }
    
    if (g_hPointsTimer != null)
    {
        KillTimer(g_hPointsTimer);
        g_hPointsTimer = null;
    }
    
    // Clean up arrays
    if (g_hUpdateQueue != null)
    {
        delete g_hUpdateQueue;
        g_hUpdateQueue = null;
    }
    
    if (g_hRetryQueue != null)
    {
        delete g_hRetryQueue;
        g_hRetryQueue = null;
    }
    
    // Close database connection
    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }
}

// ============================================
// STEAMID VALIDATION FUNCTIONS
// ============================================

bool IsValidSteamID(const char[] steamid)
{
    if (steamid[0] == '\0')
        return false;
    
    // Check for common invalid SteamIDs
    if (StrEqual(steamid, "STEAM_ID_STOP_IGNORING_RETVALS") ||
        StrEqual(steamid, "STEAM_ID_PENDING") ||
        StrEqual(steamid, "STEAM_ID_INVALID") ||
        StrEqual(steamid, "BOT"))
    {
        return false;
    }
    
    // Check if it starts with STEAM_ and has valid format
    return (StrContains(steamid, "STEAM_") == 0 && strlen(steamid) > 10);
}

bool GetValidSteamID(int client, char[] steamid, int maxlen)
{
    // First check if we already have a valid SteamID stored
    if (IsValidSteamID(g_PlayerData[client].steamid))
    {
        strcopy(steamid, maxlen, g_PlayerData[client].steamid);
        return true;
    }
    
    // Try to get SteamID from client
    if (GetClientAuthId(client, AuthId_Steam2, steamid, maxlen))
    {
        if (IsValidSteamID(steamid))
        {
            // Store it for future use
            strcopy(g_PlayerData[client].steamid, sizeof(PlayerData::steamid), steamid);
            return true;
        }
    }
    
    return false;
}

// ============================================
// CLIENT CONNECTION/DISCONNECTION
// ============================================

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client))
        return;
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] OnClientAuthorized: %d - %s", client, auth);
    
    // Validate SteamID before storing
    if (IsValidSteamID(auth))
    {
        strcopy(g_PlayerData[client].steamid, sizeof(PlayerData::steamid), auth);
        g_PlayerData[client].authorized = true;
        
        if (DEBUG_MODE) PrintToServer("[DEBUG] Valid SteamID stored: %s", auth);
        
        // Queue player for initialization
        AddToRetryQueue(client);
    }
    else
    {
        if (DEBUG_MODE) PrintToServer("[DEBUG] Invalid SteamID: %s", auth);
    }
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
        return;
    
    char steamid[32];
    if (GetValidSteamID(client, steamid, sizeof(steamid)))
    {
        if (g_PlayerData[client].loaded)
        {
            if (DEBUG_MODE) PrintToServer("[DEBUG] Saving data for %s on disconnect", steamid);
            SaveAllPlayerData(client, true);
        }
        else
        {
            if (DEBUG_MODE) PrintToServer("[DEBUG] Player %s never loaded, no data to save", steamid);
        }
    }
    else
    {
        if (DEBUG_MODE) PrintToServer("[DEBUG] Client %d disconnected without valid SteamID", client);
    }
    
    // Always reset data on disconnect
    g_PlayerData[client].Reset();
    
    // Remove from retry queue
    RemoveFromRetryQueue(client);
}

void InitializePlayerData(int client)
{
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
    {
        if (DEBUG_MODE) PrintToServer("[DEBUG] Cannot initialize player %d - no valid SteamID", client);
        return;
    }
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] Initializing player %s", steamid);
    
    g_PlayerData[client].joinTime = GetTime();
    g_PlayerData[client].sessionPlaytime = 0;
    
    g_PlayerData[client].heals = 0;
    g_PlayerData[client].revives = 0;
    g_PlayerData[client].defibs = 0;
    g_PlayerData[client].pills = 0;
    g_PlayerData[client].assists = 0;
    
    g_PlayerData[client].kills = 0;
    g_PlayerData[client].headshots = 0;
    g_PlayerData[client].totalShots = 0;
    
    g_PlayerData[client].pointsStartDaily = 0;
    g_PlayerData[client].pointsStartWeekly = 0;
    g_PlayerData[client].currentPoints = 0;
    
    g_PlayerData[client].loaded = false;
    g_PlayerData[client].pendingSave = false;
    
    LoadPlayerData(client);
}

// ============================================
// RETRY QUEUE SYSTEM
// ============================================

void AddToRetryQueue(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;
    
    // Check if already in queue
    for (int i = 0; i < g_hRetryQueue.Length; i++)
    {
        if (g_hRetryQueue.Get(i) == client)
            return;
    }
    
    g_hRetryQueue.Push(client);
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] Added client %d to retry queue", client);
}

void RemoveFromRetryQueue(int client)
{
    int index = g_hRetryQueue.FindValue(client);
    if (index != -1)
    {
        g_hRetryQueue.Erase(index);
        if (DEBUG_MODE) PrintToServer("[DEBUG] Removed client %d from retry queue", client);
    }
}

public Action Timer_RetryPlayers(Handle timer)
{
    if (g_hRetryQueue.Length == 0)
        return Plugin_Continue;
    
    for (int i = 0; i < g_hRetryQueue.Length; i++)
    {
        int client = g_hRetryQueue.Get(i);
        
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            g_hRetryQueue.Erase(i);
            i--;
            continue;
        }
        
        char steamid[32];
        if (GetValidSteamID(client, steamid, sizeof(steamid)))
        {
            if (!g_PlayerData[client].loaded)
            {
                if (DEBUG_MODE) PrintToServer("[DEBUG] Retry loading player %s", steamid);
                InitializePlayerData(client);
            }
            
            // Remove from queue once loaded
            if (g_PlayerData[client].loaded)
            {
                g_hRetryQueue.Erase(i);
                i--;
            }
        }
    }
    
    return Plugin_Continue;
}

// ============================================
// DATABASE FUNCTIONS
// ============================================

void ConnectToDatabase()
{
    if (SQL_CheckConfig(DATABASE_NAME))
    {
        PrintToServer("[Stats Tracker] Connecting to database '%s'...", DATABASE_NAME);
        Database.Connect(SQL_ConnectCallback, DATABASE_NAME);
    }
    else
    {
        LogError("Database configuration '%s' not found in databases.cfg!", DATABASE_NAME);
        
        // Try to connect with default credentials as fallback
        char error[255];
        g_Database = SQL_Connect("default", true, error, sizeof(error));
        if (g_Database == null)
        {
            LogError("Could not connect to database: %s", error);
            g_bDatabaseConnected = false;
        }
        else
        {
            PrintToServer("[Stats Tracker] Connected to default database");
            g_bDatabaseConnected = true;
            if (!g_Database.SetCharset("utf8mb4"))
            {
                PrintToServer("[Stats Tracker] Warning: Could not set charset to utf8mb4");
            }
        }
    }
}

public void SQL_ConnectCallback(Database db, const char[] error, any data)
{
    if (db == null)
    {
        g_bDatabaseConnected = false;
        LogError("Failed to connect to database: %s", error);
        
        // Try again in 30 seconds
        CreateTimer(30.0, Timer_Reconnect);
        return;
    }
    
    g_Database = db;
    g_bDatabaseConnected = true;
    
    // Set charset to avoid encoding issues
    if (!g_Database.SetCharset("utf8mb4"))
    {
        PrintToServer("[Stats Tracker] Warning: Could not set charset to utf8mb4");
    }
    
    PrintToServer("[Stats Tracker] Successfully connected to database!");
}

public Action Timer_Reconnect(Handle timer)
{
    PrintToServer("[Stats Tracker] Attempting to reconnect to database...");
    ConnectToDatabase();
    return Plugin_Stop;
}

// ============================================
// DATA LOADING & SAVING
// ============================================

void LoadPlayerData(int client)
{
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
    {
        LogError("Cannot load player data - no valid SteamID for client %d", client);
        return;
    }
    
    if (g_Database == null || !g_bDatabaseConnected)
    {
        LogError("Cannot load player data - database not connected");
        return;
    }
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] Loading data for %s", steamid);
    
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT steamid FROM player_playtime WHERE steamid = '%s' LIMIT 1",
        steamid);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.Reset();
    
    g_Database.Query(SQL_CheckPlayerExists, query, pack);
}

public void SQL_CheckPlayerExists(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_CheckPlayerExists error: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        // Player exists, load full data
        LoadPlayerResetDates(client, steamid);
    }
    else
    {
        // New player, insert into all tables
        InsertNewPlayer(client, steamid);
    }
}

void LoadPlayerResetDates(int client, const char[] steamid)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char query[1024];
    g_Database.Format(query, sizeof(query),
        "SELECT \
            (SELECT DATE(last_daily_reset) FROM player_playtime WHERE steamid = '%s'), \
            (SELECT DATE(last_weekly_reset) FROM player_playtime WHERE steamid = '%s'), \
            (SELECT DATE(last_daily_reset) FROM medic_stats WHERE steamid = '%s'), \
            (SELECT DATE(last_weekly_reset) FROM medic_stats WHERE steamid = '%s'), \
            (SELECT DATE(last_daily_reset) FROM player_stats WHERE steamid = '%s'), \
            (SELECT DATE(last_weekly_reset) FROM player_stats WHERE steamid = '%s')",
        steamid, steamid, steamid, steamid, steamid, steamid);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.Reset();
    
    g_Database.Query(SQL_LoadResetDatesCallback, query, pack);
}

void InsertNewPlayer(int client, const char[] steamid)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char currentDate[20];
    FormatTime(currentDate, sizeof(currentDate), "%Y-%m-%d");
    
    // Insert into all three tables
    Transaction txn = new Transaction();
    
    char query[512];
    
    // Playtime table
    g_Database.Format(query, sizeof(query),
        "INSERT INTO player_playtime (steamid, player_name, last_join, last_daily_reset, last_weekly_reset) \
         VALUES ('%s', '%s', NOW(), '%s', '%s')",
        steamid, escapedName, currentDate, currentDate);
    txn.AddQuery(query);
    
    // Medic stats table
    g_Database.Format(query, sizeof(query),
        "INSERT INTO medic_stats (steamid, player_name, last_daily_reset, last_weekly_reset) \
         VALUES ('%s', '%s', '%s', '%s')",
        steamid, escapedName, currentDate, currentDate);
    txn.AddQuery(query);
    
    // Player stats table
    g_Database.Format(query, sizeof(query),
        "INSERT INTO player_stats (steamid, player_name, last_daily_reset, last_weekly_reset, \
                                   daily_points_start, daily_points_current, \
                                   weekly_points_start, weekly_points_current) \
         VALUES ('%s', '%s', '%s', '%s', 0, 0, 0, 0)",
        steamid, escapedName, currentDate, currentDate);
    txn.AddQuery(query);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.Reset();
    
    g_Database.Execute(txn, SQL_InsertAllSuccess, SQL_InsertAllFailure, pack);
}

void SaveAllPlayerData(int client, bool disconnect = false)
{
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
    {
        if (DEBUG_MODE) PrintToServer("[DEBUG] Cannot save data for client %d - no valid SteamID", client);
        return;
    }
    
    if (!g_PlayerData[client].loaded)
    {
        if (DEBUG_MODE) PrintToServer("[DEBUG] Player %s not loaded, skipping save", steamid);
        return;
    }
    
    // Update session playtime before saving
    UpdateSessionPlaytime(client);
    
    // Save all data types
    SavePlayerPlaytime(client, disconnect);
    SavePlayerStats(client, disconnect);
    SaveMedicStats(client, disconnect);
    SavePlayerPoints(client, disconnect);
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] All data saved for %s", steamid);
}

void UpdateSessionPlaytime(int client)
{
    if (g_PlayerData[client].joinTime == 0)
        return;
    
    int currentTime = GetTime();
    int sessionTime = currentTime - g_PlayerData[client].joinTime;
    
    if (sessionTime > 0)
    {
        g_PlayerData[client].sessionPlaytime += sessionTime;
        g_PlayerData[client].joinTime = currentTime;
    }
}

void SavePlayerPlaytime(int client, bool disconnect = false)
{
    if (!g_PlayerData[client].loaded || g_PlayerData[client].sessionPlaytime <= 0 || !g_bDatabaseConnected)
        return;
    
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char query[512];
    if (disconnect)
    {
        g_Database.Format(query, sizeof(query),
            "UPDATE player_playtime SET \
                playtime = playtime + %d, \
                daily_playtime = daily_playtime + %d, \
                weekly_playtime = weekly_playtime + %d, \
                player_name = '%s', \
                last_join = NOW() \
             WHERE steamid = '%s'",
            g_PlayerData[client].sessionPlaytime,
            g_PlayerData[client].sessionPlaytime,
            g_PlayerData[client].sessionPlaytime,
            escapedName,
            steamid);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
            "UPDATE player_playtime SET \
                playtime = playtime + %d, \
                daily_playtime = daily_playtime + %d, \
                weekly_playtime = weekly_playtime + %d, \
                player_name = '%s' \
             WHERE steamid = '%s'",
            g_PlayerData[client].sessionPlaytime,
            g_PlayerData[client].sessionPlaytime,
            g_PlayerData[client].sessionPlaytime,
            escapedName,
            steamid);
    }
    
    QueueUpdate(query);
    
    // Reset session time
    g_PlayerData[client].sessionPlaytime = 0;
}

void SaveMedicStats(int client, bool disconnect = false)
{
    if (!g_PlayerData[client].loaded || g_Database == null || !g_bDatabaseConnected)
        return;
    
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
        return;
    
    // Only save if there's something to save
    if (g_PlayerData[client].heals == 0 && g_PlayerData[client].revives == 0 && 
        g_PlayerData[client].defibs == 0 && g_PlayerData[client].pills == 0 && 
        g_PlayerData[client].assists == 0)
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char query[1024];
    g_Database.Format(query, sizeof(query),
        "UPDATE medic_stats SET \
            total_heals = total_heals + %d, \
            total_revives = total_revives + %d, \
            total_defibs = total_defibs + %d, \
            total_pills = total_pills + %d, \
            total_assists = total_assists + %d, \
            daily_heals = daily_heals + %d, \
            daily_revives = daily_revives + %d, \
            daily_defibs = daily_defibs + %d, \
            daily_pills = daily_pills + %d, \
            daily_assists = daily_assists + %d, \
            weekly_heals = weekly_heals + %d, \
            weekly_revives = weekly_revives + %d, \
            weekly_defibs = weekly_defibs + %d, \
            weekly_pills = weekly_pills + %d, \
            weekly_assists = weekly_assists + %d, \
            player_name = '%s' \
         WHERE steamid = '%s'",
        g_PlayerData[client].heals, g_PlayerData[client].revives, g_PlayerData[client].defibs, 
        g_PlayerData[client].pills, g_PlayerData[client].assists,
        g_PlayerData[client].heals, g_PlayerData[client].revives, g_PlayerData[client].defibs, 
        g_PlayerData[client].pills, g_PlayerData[client].assists,
        g_PlayerData[client].heals, g_PlayerData[client].revives, g_PlayerData[client].defibs, 
        g_PlayerData[client].pills, g_PlayerData[client].assists,
        escapedName, steamid);
    
    QueueUpdate(query);
    
    // Reset session stats
    g_PlayerData[client].heals = 0;
    g_PlayerData[client].revives = 0;
    g_PlayerData[client].defibs = 0;
    g_PlayerData[client].pills = 0;
    g_PlayerData[client].assists = 0;
}

void SavePlayerStats(int client, bool disconnect = false)
{
    if (!g_PlayerData[client].loaded || g_Database == null || !g_bDatabaseConnected)
        return;
    
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
        return;
    
    // Only save if there's something to save
    if (g_PlayerData[client].kills == 0 && g_PlayerData[client].headshots == 0 && 
        g_PlayerData[client].totalShots == 0)
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char query[1024];
    g_Database.Format(query, sizeof(query),
        "UPDATE player_stats SET \
            total_kills = total_kills + %d, \
            total_headshots = total_headshots + %d, \
            total_shots = total_shots + %d, \
            daily_kills = daily_kills + %d, \
            daily_headshots = daily_headshots + %d, \
            daily_shots = daily_shots + %d, \
            weekly_kills = weekly_kills + %d, \
            weekly_headshots = weekly_headshots + %d, \
            weekly_shots = weekly_shots + %d, \
            player_name = '%s' \
         WHERE steamid = '%s'",
        g_PlayerData[client].kills, g_PlayerData[client].headshots, g_PlayerData[client].totalShots,
        g_PlayerData[client].kills, g_PlayerData[client].headshots, g_PlayerData[client].totalShots,
        g_PlayerData[client].kills, g_PlayerData[client].headshots, g_PlayerData[client].totalShots,
        escapedName, steamid);
    
    QueueUpdate(query);
    
    // Reset session stats
    g_PlayerData[client].kills = 0;
    g_PlayerData[client].headshots = 0;
    g_PlayerData[client].totalShots = 0;
}

void SavePlayerPoints(int client, bool disconnect = false)
{
    if (!g_PlayerData[client].loaded || g_Database == null || !g_bDatabaseConnected)
        return;
    
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char query[512];
    g_Database.Format(query, sizeof(query),
        "UPDATE player_stats SET \
            daily_points_current = %d, \
            weekly_points_current = %d, \
            player_name = '%s' \
         WHERE steamid = '%s'",
        g_PlayerData[client].currentPoints,
        g_PlayerData[client].currentPoints,
        escapedName,
        steamid);
    
    QueueUpdate(query);
}

// ============================================
// QUEUE MANAGEMENT
// ============================================

void QueueUpdate(const char[] query)
{
    if (g_hUpdateQueue == null)
        return;
    
    char queuedQuery[1024];
    strcopy(queuedQuery, sizeof(queuedQuery), query);
    g_hUpdateQueue.PushString(queuedQuery);
}

void ProcessUpdateQueue()
{
    if (g_hUpdateQueue.Length == 0 || g_Database == null || !g_bDatabaseConnected)
        return;
    
    // Start transaction for batch update
    Transaction txn = new Transaction();
    
    char query[1024];
    for (int i = 0; i < g_hUpdateQueue.Length; i++)
    {
        g_hUpdateQueue.GetString(i, query, sizeof(query));
        txn.AddQuery(query);
    }
    
    g_Database.Execute(txn, SQL_TransactionSuccess, SQL_TransactionFailure);
    
    // Clear the queue
    g_hUpdateQueue.Clear();
}

// ============================================
// TIMERS
// ============================================

public Action Timer_UpdatePlaytime(Handle timer)
{
    // Update session times for all online players with valid SteamID
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_PlayerData[i].loaded)
        {
            UpdateSessionPlaytime(i);
            
            // Auto-save if session is long enough
            if (g_PlayerData[i].sessionPlaytime >= 60) // Save if at least 1 minute accumulated
            {
                SavePlayerPlaytime(i, false);
            }
        }
    }
    
    // Process queued updates
    ProcessUpdateQueue();
    
    return Plugin_Continue;
}

public Action Timer_UpdateStats(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_PlayerData[i].loaded)
        {
            // Save medic and player stats every minute
            SaveMedicStats(i, false);
            SavePlayerStats(i, false);
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_CheckPoints(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_PlayerData[i].loaded)
        {
            CheckPlayerPoints(i);
        }
    }
    
    return Plugin_Continue;
}

// ============================================
// EVENT HANDLERS
// ============================================

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(client) && !IsFakeClient(client) && !g_PlayerData[client].loaded)
    {
        AddToRetryQueue(client);
    }
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    // Save stats for all valid players on map transition
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_PlayerData[i].loaded)
        {
            SaveAllPlayerData(i, false);
        }
    }
    
    // Process queue
    ProcessUpdateQueue();
}

// Medic events
public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int healer = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(healer) && !IsFakeClient(healer) && g_PlayerData[healer].loaded)
    {
        g_PlayerData[healer].heals++;
    }
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int reviver = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(reviver) && !IsFakeClient(reviver) && g_PlayerData[reviver].loaded)
    {
        g_PlayerData[reviver].revives++;
    }
}

public void Event_DefibUsed(Event event, const char[] name, bool dontBroadcast)
{
    int user = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(user) && !IsFakeClient(user) && g_PlayerData[user].loaded)
    {
        g_PlayerData[user].defibs++;
    }
}

public void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    int user = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(user) && !IsFakeClient(user) && g_PlayerData[user].loaded)
    {
        g_PlayerData[user].pills++;
    }
}

public void Event_AdrenalineUsed(Event event, const char[] name, bool dontBroadcast)
{
    int user = GetClientOfUserId(event.GetInt("userid"));
    
    if (IsValidClient(user) && !IsFakeClient(user) && g_PlayerData[user].loaded)
    {
        g_PlayerData[user].pills++; // Count adrenaline as pills
    }
}

public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    
    // Track assists for incapping special infected
    if (IsValidClient(attacker) && !IsFakeClient(attacker) && g_PlayerData[attacker].loaded)
    {
        int victim = GetClientOfUserId(event.GetInt("userid"));
        if (IsValidClient(victim) && GetClientTeam(victim) == 3) // Team 3 = Infected
        {
            g_PlayerData[attacker].assists++;
        }
    }
}

// Player stats events
public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    
    if (!IsValidClient(attacker) || IsFakeClient(attacker) || !g_PlayerData[attacker].loaded)
        return;
    
    bool headshot = event.GetBool("headshot");
    
    g_PlayerData[attacker].kills++;
    if (headshot)
        g_PlayerData[attacker].headshots++;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    
    if (!IsValidClient(attacker) || IsFakeClient(attacker) || !g_PlayerData[attacker].loaded)
        return;
    
    // Only count infected team kills
    if (IsValidClient(victim) && GetClientTeam(victim) == 3)
    {
        bool headshot = event.GetBool("headshot");
        
        g_PlayerData[attacker].kills++;
        if (headshot)
            g_PlayerData[attacker].headshots++;
    }
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    
    if (!IsValidClient(client) || IsFakeClient(client) || !g_PlayerData[client].loaded)
        return;
    
    // Only count actual firearms, not melee weapons
    char weapon[64];
    GetClientWeapon(client, weapon, sizeof(weapon));
    
    // Exclude melee weapons and chainsaw from shot count
    if (!StrContains(weapon, "weapon_melee") && !StrEqual(weapon, "weapon_chainsaw"))
    {
        g_PlayerData[client].totalShots++;
    }
}

// ============================================
// SQL CALLBACKS
// ============================================

public void SQL_LoadResetDatesCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_LoadResetDatesCallback error: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        // Load current points
        LoadCurrentPoints(client, steamid);
    }
}

void LoadCurrentPoints(int client, const char[] steamid)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT points FROM players WHERE steamid = '%s' LIMIT 1",
        steamid);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.Reset();
    
    g_Database.Query(SQL_LoadCurrentPointsCallback, query, pack);
}

public void SQL_LoadCurrentPointsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_LoadCurrentPointsCallback error: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        int currentPoints = results.FetchInt(0);
        g_PlayerData[client].currentPoints = currentPoints;
        g_PlayerData[client].pointsStartDaily = currentPoints;
        g_PlayerData[client].pointsStartWeekly = currentPoints;
    }
    
    // Mark player as loaded
    g_PlayerData[client].loaded = true;
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] Player %s fully loaded", steamid);
}

public void SQL_InsertAllSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    // Set current points to 0 for new player
    g_PlayerData[client].currentPoints = 0;
    g_PlayerData[client].pointsStartDaily = 0;
    g_PlayerData[client].pointsStartWeekly = 0;
    
    // Mark player as loaded
    g_PlayerData[client].loaded = true;
    
    if (DEBUG_MODE) PrintToServer("[DEBUG] New player %s inserted and loaded", steamid);
}

public void SQL_InsertAllFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    LogError("Failed to insert new player %s: %s (query %d)", steamid, error, failIndex);
}

public void SQL_TransactionSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    // Transaction successful
}

public void SQL_TransactionFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("Transaction failed at query %d: %s", failIndex, error);
}

// ============================================
// HELPER FUNCTIONS
// ============================================

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}

void CheckPlayerPoints(int client)
{
    if (!g_PlayerData[client].loaded || g_Database == null || !g_bDatabaseConnected)
        return;
    
    char steamid[32];
    if (!GetValidSteamID(client, steamid, sizeof(steamid)))
        return;
    
    // Query current points from players table
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT points FROM players WHERE steamid = '%s' LIMIT 1",
        steamid);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.Reset();
    
    g_Database.Query(SQL_CheckPointsCallback, query, pack);
}

public void SQL_CheckPointsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_CheckPointsCallback error: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        int newPoints = results.FetchInt(0);
        int oldPoints = g_PlayerData[client].currentPoints;
        
        if (newPoints != oldPoints)
        {
            // Update player's current points
            g_PlayerData[client].currentPoints = newPoints;
        }
    }
}
