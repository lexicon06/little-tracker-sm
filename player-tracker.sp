#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "3.2"
#define DATABASE_NAME "l4dstats"
#define UPDATE_INTERVAL 30.0

Database g_Database = null;
bool g_bDatabaseConnected = false;

// ============================================
// PLAYER DATA STRUCTURES
// ============================================

// Playtime tracking
int g_iClientJoinTime[MAXPLAYERS + 1];
int g_iSessionPlaytime[MAXPLAYERS + 1];

// Medic stats
int g_iHeals[MAXPLAYERS + 1];
int g_iRevives[MAXPLAYERS + 1];
int g_iDefibs[MAXPLAYERS + 1];
int g_iPills[MAXPLAYERS + 1];
int g_iAssists[MAXPLAYERS + 1];

// Player stats
int g_iKills[MAXPLAYERS + 1];
int g_iHeadshots[MAXPLAYERS + 1];
int g_iTotalShots[MAXPLAYERS + 1];

// Points tracking
int g_iPointsStartDaily[MAXPLAYERS + 1];    // Points when daily reset happened
int g_iPointsStartWeekly[MAXPLAYERS + 1];   // Points when weekly reset happened
int g_iCurrentPoints[MAXPLAYERS + 1];       // Current points from players table

// Shared
char g_sClientSteamID[MAXPLAYERS + 1][32];
bool g_bPlayerLoaded[MAXPLAYERS + 1];

// Timer handles
Handle g_hPlaytimeTimer = null;
Handle g_hStatsTimer = null;
Handle g_hPointsTimer = null;

// Batch update queue
ArrayList g_hUpdateQueue = null;

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
    // Initialize update queue
    g_hUpdateQueue = new ArrayList(1024);
    
    // Connect to database
    ConnectToDatabase();
    
    // Create timers
    g_hPlaytimeTimer = CreateTimer(UPDATE_INTERVAL, Timer_UpdatePlaytime, _, TIMER_REPEAT);
    g_hStatsTimer = CreateTimer(60.0, Timer_UpdateStats, _, TIMER_REPEAT);
    g_hPointsTimer = CreateTimer(30.0, Timer_CheckPoints, _, TIMER_REPEAT);
    
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
    
    PrintToServer("[Stats Tracker] Plugin loaded successfully!");
}

public void OnPluginEnd()
{
    // Save all player data on plugin unload
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bPlayerLoaded[i])
        {
            UpdateSessionPlaytime(i);
            SavePlayerPlaytime(i, true);
            SavePlayerStats(i, true);
            SaveMedicStats(i, true);
            SavePlayerPoints(i, true);
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
    
    // Clean up array
    if (g_hUpdateQueue != null)
    {
        delete g_hUpdateQueue;
        g_hUpdateQueue = null;
    }
    
    // Close database connection
    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    // Just save stats on map transition
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bPlayerLoaded[i])
        {
            UpdateSessionPlaytime(i);
            SavePlayerPlaytime(i, false);
            SavePlayerStats(i, false);
            SaveMedicStats(i, false);
            SavePlayerPoints(i, false);
        }
    }
    
    // Process queue
    ProcessUpdateQueue();
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
// PLAYER CONNECTION/DISCONNECTION
// ============================================

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client))
        return;
    
    // Get SteamID
    if (!GetClientAuthId(client, AuthId_Steam2, g_sClientSteamID[client], sizeof(g_sClientSteamID[])))
    {
        LogError("Failed to get SteamID for client %d", client);
        return;
    }
    
    // Initialize all stats
    g_iClientJoinTime[client] = GetTime();
    g_iSessionPlaytime[client] = 0;
    
    g_iHeals[client] = 0;
    g_iRevives[client] = 0;
    g_iDefibs[client] = 0;
    g_iPills[client] = 0;
    g_iAssists[client] = 0;
    
    g_iKills[client] = 0;
    g_iHeadshots[client] = 0;
    g_iTotalShots[client] = 0;
    
    // Points tracking
    g_iPointsStartDaily[client] = 0;
    g_iPointsStartWeekly[client] = 0;
    g_iCurrentPoints[client] = 0;
    
    g_bPlayerLoaded[client] = false;
    
    // Load player data from all tables
    LoadPlayerData(client);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client) || !g_bPlayerLoaded[client])
        return;
    
    // Update and save all stats
    UpdateSessionPlaytime(client);
    SavePlayerPlaytime(client, true);
    SavePlayerStats(client, true);
    SaveMedicStats(client, true);
    SavePlayerPoints(client, true);
    
    // Reset all data
    ResetPlayerData(client);
}

void ResetPlayerData(int client)
{
    g_iClientJoinTime[client] = 0;
    g_iSessionPlaytime[client] = 0;
    
    g_iHeals[client] = 0;
    g_iRevives[client] = 0;
    g_iDefibs[client] = 0;
    g_iPills[client] = 0;
    g_iAssists[client] = 0;
    
    g_iKills[client] = 0;
    g_iHeadshots[client] = 0;
    g_iTotalShots[client] = 0;
    
    // Points tracking
    g_iPointsStartDaily[client] = 0;
    g_iPointsStartWeekly[client] = 0;
    g_iCurrentPoints[client] = 0;
    
    g_sClientSteamID[client][0] = '\0';
    g_bPlayerLoaded[client] = false;
}

// ============================================
// DATA LOADING & MANAGEMENT
// ============================================

void LoadPlayerData(int client)
{
    if (g_Database == null || !g_bDatabaseConnected)
    {
        LogError("Cannot load player data - database not connected");
        return;
    }
    
    // Check if player exists in playtime table
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT steamid FROM player_playtime WHERE steamid = '%s' LIMIT 1",
        g_sClientSteamID[client]);
    
    g_Database.Query(SQL_CheckPlayerExists, query, GetClientUserId(client));
}

public void SQL_CheckPlayerExists(Database db, DBResultSet results, const char[] error, any userid)
{
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
        // Player exists, load data including points
        LoadPlayerResetDates(client);
    }
    else
    {
        // New player, insert into all tables
        InsertNewPlayer(client);
    }
}

void LoadPlayerResetDates(int client)
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
        g_sClientSteamID[client], g_sClientSteamID[client], g_sClientSteamID[client],
        g_sClientSteamID[client], g_sClientSteamID[client], g_sClientSteamID[client]);
    
    g_Database.Query(SQL_LoadResetDatesCallback, query, GetClientUserId(client));
}

public void SQL_LoadResetDatesCallback(Database db, DBResultSet results, const char[] error, any userid)
{
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
        char playtimeDaily[20], playtimeWeekly[20];
        char medicDaily[20], medicWeekly[20];
        char playerDaily[20], playerWeekly[20];
        
        results.FetchString(0, playtimeDaily, sizeof(playtimeDaily));
        results.FetchString(1, playtimeWeekly, sizeof(playtimeWeekly));
        results.FetchString(2, medicDaily, sizeof(medicDaily));
        results.FetchString(3, medicWeekly, sizeof(medicWeekly));
        results.FetchString(4, playerDaily, sizeof(playerDaily));
        results.FetchString(5, playerWeekly, sizeof(playerWeekly));
        
        // Load current points from players table
        LoadCurrentPoints(client, playtimeDaily, playtimeWeekly, 
                        medicDaily, medicWeekly,
                        playerDaily, playerWeekly);
    }
}

void LoadCurrentPoints(int client, const char[] playtimeDaily, const char[] playtimeWeekly,
                      const char[] medicDaily, const char[] medicWeekly,
                      const char[] playerDaily, const char[] playerWeekly)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT points FROM players WHERE steamid = '%s' LIMIT 1",
        g_sClientSteamID[client]);
    
    // Create a data pack to pass multiple strings
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(playtimeDaily);
    pack.WriteString(playtimeWeekly);
    pack.WriteString(medicDaily);
    pack.WriteString(medicWeekly);
    pack.WriteString(playerDaily);
    pack.WriteString(playerWeekly);
    pack.Reset();
    
    g_Database.Query(SQL_LoadCurrentPointsCallback, query, pack);
}

public void SQL_LoadCurrentPointsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    
    char playtimeDaily[20], playtimeWeekly[20];
    char medicDaily[20], medicWeekly[20];
    char playerDaily[20], playerWeekly[20];
    
    pack.ReadString(playtimeDaily, sizeof(playtimeDaily));
    pack.ReadString(playtimeWeekly, sizeof(playtimeWeekly));
    pack.ReadString(medicDaily, sizeof(medicDaily));
    pack.ReadString(medicWeekly, sizeof(medicWeekly));
    pack.ReadString(playerDaily, sizeof(playerDaily));
    pack.ReadString(playerWeekly, sizeof(playerWeekly));
    
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
        g_iCurrentPoints[client] = currentPoints;
        
        // For existing players, load their start points from player_stats
        LoadStartingPoints(client, playtimeDaily, playtimeWeekly, 
                          medicDaily, medicWeekly,
                          playerDaily, playerWeekly);
    }
    else
    {
        // Player doesn't exist in players table, set to 0
        g_iCurrentPoints[client] = 0;
        g_iPointsStartDaily[client] = 0;
        g_iPointsStartWeekly[client] = 0;
        
        // Now check and reset counters for all tables
        CheckResetCounters(client, playtimeDaily, playtimeWeekly, 
                          medicDaily, medicWeekly,
                          playerDaily, playerWeekly);
        
        g_bPlayerLoaded[client] = true;
    }
}

void LoadStartingPoints(int client, const char[] playtimeDaily, const char[] playtimeWeekly,
                       const char[] medicDaily, const char[] medicWeekly,
                       const char[] playerDaily, const char[] playerWeekly)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT daily_points_start, weekly_points_start FROM player_stats WHERE steamid = '%s' LIMIT 1",
        g_sClientSteamID[client]);
    
    // Create a data pack to pass multiple strings
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(playtimeDaily);
    pack.WriteString(playtimeWeekly);
    pack.WriteString(medicDaily);
    pack.WriteString(medicWeekly);
    pack.WriteString(playerDaily);
    pack.WriteString(playerWeekly);
    pack.Reset();
    
    g_Database.Query(SQL_LoadStartingPointsCallback, query, pack);
}

public void SQL_LoadStartingPointsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    
    char playtimeDaily[20], playtimeWeekly[20];
    char medicDaily[20], medicWeekly[20];
    char playerDaily[20], playerWeekly[20];
    
    pack.ReadString(playtimeDaily, sizeof(playtimeDaily));
    pack.ReadString(playtimeWeekly, sizeof(playtimeWeekly));
    pack.ReadString(medicDaily, sizeof(medicDaily));
    pack.ReadString(medicWeekly, sizeof(medicWeekly));
    pack.ReadString(playerDaily, sizeof(playerDaily));
    pack.ReadString(playerWeekly, sizeof(playerWeekly));
    
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_LoadStartingPointsCallback error: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        g_iPointsStartDaily[client] = results.FetchInt(0);
        g_iPointsStartWeekly[client] = results.FetchInt(1);
    }
    else
    {
        // No start points found, use current points
        g_iPointsStartDaily[client] = g_iCurrentPoints[client];
        g_iPointsStartWeekly[client] = g_iCurrentPoints[client];
    }
    
    // Now check and reset counters for all tables
    CheckResetCounters(client, playtimeDaily, playtimeWeekly, 
                      medicDaily, medicWeekly,
                      playerDaily, playerWeekly);
    
    g_bPlayerLoaded[client] = true;
}

void InsertNewPlayer(int client)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    char currentDate[20];
    FormatTime(currentDate, sizeof(currentDate), "%Y-%m-%d");
    
    // Get current points from players table for new player
    char pointsQuery[256];
    g_Database.Format(pointsQuery, sizeof(pointsQuery),
        "SELECT points FROM players WHERE steamid = '%s' LIMIT 1",
        g_sClientSteamID[client]);
    
    // Create a data pack to pass strings
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(escapedName);
    pack.WriteString(currentDate);
    pack.Reset();
    
    g_Database.Query(SQL_GetNewPlayerPoints, pointsQuery, pack);
}

public void SQL_GetNewPlayerPoints(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int userid = pack.ReadCell();
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    char currentDate[20];
    
    pack.ReadString(escapedName, sizeof(escapedName));
    pack.ReadString(currentDate, sizeof(currentDate));
    
    delete pack;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    if (db == null || results == null)
    {
        LogError("SQL_GetNewPlayerPoints error: %s", error);
        return;
    }
    
    int currentPoints = 0;
    if (results.FetchRow())
    {
        currentPoints = results.FetchInt(0);
    }
    
    g_iCurrentPoints[client] = currentPoints;
    g_iPointsStartDaily[client] = currentPoints;
    g_iPointsStartWeekly[client] = currentPoints;
    
    // Insert into all three tables
    Transaction txn = new Transaction();
    
    char query[512];
    
    // Playtime table
    g_Database.Format(query, sizeof(query),
        "INSERT INTO player_playtime (steamid, player_name, last_join, last_daily_reset, last_weekly_reset) \
         VALUES ('%s', '%s', NOW(), '%s', '%s') \
         ON DUPLICATE KEY UPDATE player_name = VALUES(player_name), last_join = VALUES(last_join)",
        g_sClientSteamID[client], escapedName, currentDate, currentDate);
    txn.AddQuery(query);
    
    // Medic stats table
    g_Database.Format(query, sizeof(query),
        "INSERT INTO medic_stats (steamid, player_name, last_daily_reset, last_weekly_reset) \
         VALUES ('%s', '%s', '%s', '%s') \
         ON DUPLICATE KEY UPDATE player_name = VALUES(player_name)",
        g_sClientSteamID[client], escapedName, currentDate, currentDate);
    txn.AddQuery(query);
    
    // Player stats table - include points tracking
    g_Database.Format(query, sizeof(query),
        "INSERT INTO player_stats (steamid, player_name, last_daily_reset, last_weekly_reset, \
                                   daily_points_start, daily_points_current, \
                                   weekly_points_start, weekly_points_current) \
         VALUES ('%s', '%s', '%s', '%s', %d, %d, %d, %d) \
         ON DUPLICATE KEY UPDATE player_name = VALUES(player_name)",
        g_sClientSteamID[client], escapedName, currentDate, currentDate, 
        currentPoints, currentPoints, currentPoints, currentPoints);
    txn.AddQuery(query);
    
    g_Database.Execute(txn, SQL_InsertAllSuccess, SQL_InsertAllFailure, GetClientUserId(client));
}

public void SQL_InsertAllSuccess(Database db, any userid, int numQueries, DBResultSet[] results, any[] queryData)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    g_bPlayerLoaded[client] = true;
}

public void SQL_InsertAllFailure(Database db, any userid, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("Failed to insert new player: %s (query %d)", error, failIndex);
}

// ============================================
// RESET COUNTERS
// ============================================

void CheckResetCounters(int client, const char[] playtimeDaily, const char[] playtimeWeekly,
                       const char[] medicDaily, const char[] medicWeekly,
                       const char[] playerDaily, const char[] playerWeekly)
{
    if (g_Database == null || !g_bDatabaseConnected)
        return;
    
    char currentDate[20];
    FormatTime(currentDate, sizeof(currentDate), "%Y-%m-%d");
    
    char weekStart[20];
    GetWeekStartDate(weekStart, sizeof(weekStart));
    
    Transaction txn = new Transaction();
    bool hasQueries = false;
    
    // Playtime table reset
    if (!StrEqual(playtimeDaily, currentDate))
    {
        char query[256];
        g_Database.Format(query, sizeof(query),
            "UPDATE player_playtime SET daily_playtime = 0, last_daily_reset = '%s' WHERE steamid = '%s'",
            currentDate, g_sClientSteamID[client]);
        txn.AddQuery(query);
        hasQueries = true;
    }
    
    if (!StrEqual(playtimeWeekly, weekStart))
    {
        char query[256];
        g_Database.Format(query, sizeof(query),
            "UPDATE player_playtime SET weekly_playtime = 0, last_weekly_reset = '%s' WHERE steamid = '%s'",
            weekStart, g_sClientSteamID[client]);  
        txn.AddQuery(query);  
        hasQueries = true;  
    }  
      
    // Medic stats table reset  
    if (!StrEqual(medicDaily, currentDate))  
    {  
        char query[512];  
        g_Database.Format(query, sizeof(query),  
        "UPDATE medic_stats SET \  
                daily_heals = 0, daily_revives = 0, daily_defibs = 0, \  
                daily_pills = 0, daily_assists = 0, last_daily_reset = '%s' \  
             WHERE steamid = '%s'",  
            currentDate, g_sClientSteamID[client]);  
        txn.AddQuery(query);  
        hasQueries = true;  
    }  
      
    if (!StrEqual(medicWeekly, weekStart))  
    {  
        char query[512];  
        g_Database.Format(query, sizeof(query),  
            "UPDATE medic_stats SET \  
                weekly_heals = 0, weekly_revives = 0, weekly_defibs = 0, \  
                weekly_pills = 0, weekly_assists = 0, last_weekly_reset = '%s' \  
             WHERE steamid = '%s'",  
            weekStart, g_sClientSteamID[client]);  
        txn.AddQuery(query);  
        hasQueries = true;  
    }  
      
    // Player stats table reset - FIXED FOR YOUR SCHEMA
    if (!StrEqual(playerDaily, currentDate))  
    {  
        char query[512];  
        g_Database.Format(query, sizeof(query),  
            "UPDATE player_stats SET \  
                daily_kills = 0, daily_headshots = 0, daily_shots = 0, \  
                daily_points_start = daily_points_current, \
                last_daily_reset = '%s' \  
             WHERE steamid = '%s'",  
            currentDate, g_sClientSteamID[client]);  
        txn.AddQuery(query);  
        hasQueries = true;  
        
        // Reset daily points starting point
        g_iPointsStartDaily[client] = g_iCurrentPoints[client];
    }  
      
    if (!StrEqual(playerWeekly, weekStart))  
    {  
        char query[512];  
        g_Database.Format(query, sizeof(query),  
            "UPDATE player_stats SET \  
                weekly_kills = 0, weekly_headshots = 0, weekly_shots = 0, \  
                weekly_points_start = weekly_points_current, \
                last_weekly_reset = '%s' \  
             WHERE steamid = '%s'",  
            weekStart, g_sClientSteamID[client]);  
        txn.AddQuery(query);  
        hasQueries = true;  
        
        // Reset weekly points starting point
        g_iPointsStartWeekly[client] = g_iCurrentPoints[client];
    }  
      
    if (hasQueries)  
    {  
        g_Database.Execute(txn, SQL_ResetSuccess, SQL_ResetFailure, GetClientUserId(client));  
    }  
    else  
    {  
        delete txn;  
    }  
}  
  
public void SQL_ResetSuccess(Database db, any userid, int numQueries, DBResultSet[] results, any[] queryData)  
{  
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return;
    
    // Update local start points after reset
    g_iPointsStartDaily[client] = g_iCurrentPoints[client];
    g_iPointsStartWeekly[client] = g_iCurrentPoints[client];
}  
  
public void SQL_ResetFailure(Database db, any userid, int numQueries, const char[] error, int failIndex, any[] queryData)  
{  
    LogError("Failed to reset counters: %s (query %d)", error, failIndex);  
}  
  
void GetWeekStartDate(char[] buffer, int size)  
{  
    int time = GetTime();  
    int dayOfWeek = GetTimeDayOfWeek(time);  
    int daysToSubtract = (dayOfWeek == 0) ? 6 : (dayOfWeek - 1);  
    time -= (daysToSubtract * 86400);  
    FormatTime(buffer, size, "%Y-%m-%d", time);  
}  
  
int GetTimeDayOfWeek(int timestamp)  
{  
    int days = timestamp / 86400;  
    return (days + 4) % 7;  
}  
  
// ============================================  
// POINTS TRACKING FUNCTIONS  
// ============================================  

void CheckPlayerPoints(int client)
{
    if (!g_bPlayerLoaded[client] || g_Database == null || !g_bDatabaseConnected)
        return;
    
    // Query current points from players table
    char query[256];
    g_Database.Format(query, sizeof(query),
        "SELECT points FROM players WHERE steamid = '%s' LIMIT 1",
        g_sClientSteamID[client]);
    
    g_Database.Query(SQL_CheckPointsCallback, query, GetClientUserId(client));
}

public void SQL_CheckPointsCallback(Database db, DBResultSet results, const char[] error, any userid)
{
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
        int oldPoints = g_iCurrentPoints[client];
        
        if (newPoints != oldPoints)
        {
            // Update player's current points
            g_iCurrentPoints[client] = newPoints;
            
            // Save points to database
            SavePlayerPoints(client, false);
        }
    }
}

void SavePlayerPoints(int client, bool disconnect = false)
{
    if (!g_bPlayerLoaded[client] || g_Database == null || !g_bDatabaseConnected)
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char escapedName[MAX_NAME_LENGTH * 2 + 1];
    g_Database.Escape(name, escapedName, sizeof(escapedName));
    
    // Update current points in player_stats
    char query[512];
    g_Database.Format(query, sizeof(query),
        "UPDATE player_stats SET \
            daily_points_current = %d, \
            weekly_points_current = %d, \
            player_name = '%s' \
         WHERE steamid = '%s'",
        g_iCurrentPoints[client],  // Store in daily_current
        g_iCurrentPoints[client],  // Store in weekly_current  
        escapedName,
        g_sClientSteamID[client]);
    
    // Queue for batch update
    char queuedQuery[512];
    strcopy(queuedQuery, sizeof(queuedQuery), query);
    g_hUpdateQueue.PushString(queuedQuery);
}

// ============================================  
// PLAYTIME FUNCTIONS  
// ============================================  
  
void UpdateSessionPlaytime(int client)  
{  
    if (g_iClientJoinTime[client] == 0)  
        return;  
      
    int currentTime = GetTime();  
    int sessionTime = currentTime - g_iClientJoinTime[client];  
      
    if (sessionTime > 0)  
    {  
        g_iSessionPlaytime[client] += sessionTime;  
        g_iClientJoinTime[client] = currentTime;  
    }  
}  
  
void SavePlayerPlaytime(int client, bool disconnect = false)  
{  
    if (!g_bPlayerLoaded[client] || g_iSessionPlaytime[client] <= 0 || !g_bDatabaseConnected)  
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
            g_iSessionPlaytime[client],  
            g_iSessionPlaytime[client],  
            g_iSessionPlaytime[client],  
            escapedName,  
            g_sClientSteamID[client]);  
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
            g_iSessionPlaytime[client],  
            g_iSessionPlaytime[client],  
            g_iSessionPlaytime[client],  
            escapedName,  
            g_sClientSteamID[client]);  
    }  
      
    // Queue for batch update  
    char queuedQuery[512];  
    strcopy(queuedQuery, sizeof(queuedQuery), query);  
    g_hUpdateQueue.PushString(queuedQuery);  
      
    // Reset session time  
    g_iSessionPlaytime[client] = 0;  
}  
  
// ============================================  
// MEDIC STATS FUNCTIONS  
// ============================================  
  
void SaveMedicStats(int client, bool disconnect = false)  
{  
    if (!g_bPlayerLoaded[client] || g_Database == null || !g_bDatabaseConnected)  
        return;  
      
    // Only save if there's something to save  
    if (g_iHeals[client] == 0 && g_iRevives[client] == 0 && g_iDefibs[client] == 0 &&   
        g_iPills[client] == 0 && g_iAssists[client] == 0)  
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
        g_iHeals[client], g_iRevives[client], g_iDefibs[client], g_iPills[client], g_iAssists[client],  
        g_iHeals[client], g_iRevives[client], g_iDefibs[client], g_iPills[client], g_iAssists[client],  
        g_iHeals[client], g_iRevives[client], g_iDefibs[client], g_iPills[client], g_iAssists[client],  
        escapedName, g_sClientSteamID[client]);  
      
    // Queue for batch update  
    char queuedQuery[1024];  
    strcopy(queuedQuery, sizeof(queuedQuery), query);  
    g_hUpdateQueue.PushString(queuedQuery);  
      
    // Reset session stats  
    g_iHeals[client] = 0;  
    g_iRevives[client] = 0;  
    g_iDefibs[client] = 0;  
    g_iPills[client] = 0;  
    g_iAssists[client] = 0;  
}  
  
// ============================================  
// PLAYER STATS FUNCTIONS  
// ============================================  
  
void SavePlayerStats(int client, bool disconnect = false)  
{  
    if (!g_bPlayerLoaded[client] || g_Database == null || !g_bDatabaseConnected)  
        return;  
      
    // Only save if there's something to save  
    if (g_iKills[client] == 0 && g_iHeadshots[client] == 0 && g_iTotalShots[client] == 0)  
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
        g_iKills[client], g_iHeadshots[client], g_iTotalShots[client],  
        g_iKills[client], g_iHeadshots[client], g_iTotalShots[client],  
        g_iKills[client], g_iHeadshots[client], g_iTotalShots[client],  
        escapedName, g_sClientSteamID[client]);  
      
    // Queue for batch update  
    char queuedQuery[1024];  
    strcopy(queuedQuery, sizeof(queuedQuery), query);  
    g_hUpdateQueue.PushString(queuedQuery);  
      
    // Reset session stats  
    g_iKills[client] = 0;  
    g_iHeadshots[client] = 0;  
    g_iTotalShots[client] = 0;  
}  
  
// ============================================  
// TIMERS  
// ============================================  
  
public Action Timer_UpdatePlaytime(Handle timer)  
{  
    // Update session times for all online players  
    for (int i = 1; i <= MaxClients; i++)  
    {  
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bPlayerLoaded[i])  
        {  
            UpdateSessionPlaytime(i);  
              
            // Auto-save if session is long enough  
            if (g_iSessionPlaytime[i] >= 60) // Save if at least 1 minute accumulated  
            {  
                SavePlayerPlaytime(i);  
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
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bPlayerLoaded[i])  
        {  
            // Save medic and player stats every minute  
            SaveMedicStats(i, false);  
            SavePlayerStats(i, false);  
        }  
    }  
      
    return Plugin_Continue;  
}

// Timer to check points
public Action Timer_CheckPoints(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bPlayerLoaded[i])
        {
            CheckPlayerPoints(i);
        }
    }
    
    return Plugin_Continue;
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
  
public void SQL_TransactionSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)  
{  
    // Transaction successful
}  
  
public void SQL_TransactionFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)  
{  
    LogError("Transaction failed at query %d: %s", failIndex, error);  
}  
  
public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("SQL_GenericCallback error: %s", error);
    }
}
  
// ============================================  
// EVENT HANDLERS  
// ============================================  
  
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)  
{  
    int client = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(client) && !IsFakeClient(client) && !g_bPlayerLoaded[client])  
    {  
        LoadPlayerData(client);  
    }  
}  
  
// Medic events  
public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)  
{  
    int healer = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(healer) && !IsFakeClient(healer) && g_bPlayerLoaded[healer])  
    {  
        g_iHeals[healer]++;  
    }  
}  
  
public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)  
{  
    int reviver = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(reviver) && !IsFakeClient(reviver) && g_bPlayerLoaded[reviver])  
    {  
        g_iRevives[reviver]++;  
    }  
}  
  
public void Event_DefibUsed(Event event, const char[] name, bool dontBroadcast)  
{  
    int user = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(user) && !IsFakeClient(user) && g_bPlayerLoaded[user])  
    {  
        g_iDefibs[user]++;  
    }  
}  
  
public void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)  
{  
    int user = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(user) && !IsFakeClient(user) && g_bPlayerLoaded[user])  
    {  
        g_iPills[user]++;  
    }  
}  
  
public void Event_AdrenalineUsed(Event event, const char[] name, bool dontBroadcast)  
{  
    int user = GetClientOfUserId(event.GetInt("userid"));  
      
    if (IsValidClient(user) && !IsFakeClient(user) && g_bPlayerLoaded[user])  
    {  
        g_iPills[user]++; // Count adrenaline as pills  
    }  
}  
  
public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)  
{  
    int attacker = GetClientOfUserId(event.GetInt("attacker"));  
      
    // Track assists for incapping special infected  
    if (IsValidClient(attacker) && !IsFakeClient(attacker) && g_bPlayerLoaded[attacker])  
    {  
        int victim = GetClientOfUserId(event.GetInt("userid"));  
        if (IsValidClient(victim) && GetClientTeam(victim) == 3) // Team 3 = Infected  
        {  
            g_iAssists[attacker]++;  
        }  
    }  
}  
  
// Player stats events  
public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)  
{  
    int attacker = GetClientOfUserId(event.GetInt("attacker"));  
      
    if (!IsValidClient(attacker) || IsFakeClient(attacker) || !g_bPlayerLoaded[attacker])  
        return;  
      
    bool headshot = event.GetBool("headshot");  
      
    g_iKills[attacker]++;  
    if (headshot)  
        g_iHeadshots[attacker]++;  
}  
  
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)  
{  
    int attacker = GetClientOfUserId(event.GetInt("attacker"));  
    int victim = GetClientOfUserId(event.GetInt("userid"));  
      
    if (!IsValidClient(attacker) || IsFakeClient(attacker) || !g_bPlayerLoaded[attacker])  
        return;  
      
    // Only count infected team kills  
    if (IsValidClient(victim) && GetClientTeam(victim) == 3)  
    {  
        bool headshot = event.GetBool("headshot");  
          
        g_iKills[attacker]++;  
        if (headshot)  
            g_iHeadshots[attacker]++;  
    }  
}  
  
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)  
{  
    int client = GetClientOfUserId(event.GetInt("userid"));  
      
    if (!IsValidClient(client) || IsFakeClient(client) || !g_bPlayerLoaded[client])  
        return;  
      
    // Only count actual firearms, not melee weapons  
    char weapon[64];  
    GetClientWeapon(client, weapon, sizeof(weapon));  
      
    // Exclude melee weapons and chainsaw from shot count  
    if (!StrContains(weapon, "weapon_melee") && !StrEqual(weapon, "weapon_chainsaw"))  
    {  
        g_iTotalShots[client]++;  
    }  
}  
  
// ============================================  
// HELPER FUNCTIONS  
// ============================================  
  
bool IsValidClient(int client)  
{  
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));  
}
