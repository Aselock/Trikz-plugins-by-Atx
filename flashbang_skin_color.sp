/**
 * sm_flashbang_skin_color.sp
 * Counter-Strike: Source (OrangeBox) — SourceMod plugin
 *
 * Функции:
 *  - Меню: 1) Выбрать скин (Fullbright / Shadow / Wireframe), 2) Выбрать цвет
 *  - Меняет модель и скин flashbang_projectile на кастомную
 *  - Красит гранату в выбранный цвет
 *  - Сохраняет выбор игрока (через clientprefs cookies)
 *  - Применяет изменения только с начала раунда (не с начала карты)
 *
 * Требуется: SourceMod 1.10+; extensions: sdkhooks, sdktools, clientprefs
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <adt_array>
#include <entity_prop_stocks>

#pragma semicolon 1

public Plugin myinfo =
{
    name        = "Flashbang Model & Color (CS:S)",
    author      = "ChatGPT",
    description = "Смена модели/скина и цвета flashbang_projectile, меню + сохранение",
    version     = "1.0.0",
    url         = ""
};

// === ПУТИ К ФАЙЛАМ (из архива) ===
static const char MODEL_FLASHBANG_PROJECTILE[] = "models/expert_zone/flashbang/flashbang.mdl"; // модель летящей гранаты
static const char MODEL_FLASHBANG_WORLD[]      = "models/trueexpert/w_flashbang/w_flashbang.mdl"; // worldmodel в руках/на земле
static const char MODEL_FLASHBANG_VIEW[]       = "models/trueexpert/v_flashbang4/v_flashbang.mdl"; // viewmodel от первого лица

static const char DOWNLOADS[][] =
{
    // Модель
    "models/expert_zone/flashbang/flashbang.mdl",
    "models/expert_zone/flashbang/flashbang.vvd",
    "models/expert_zone/flashbang/flashbang.dx80.vtx",
    "models/expert_zone/flashbang/flashbang.dx90.vtx",
    "models/expert_zone/flashbang/flashbang.sw.vtx",
    "models/expert_zone/flashbang/flashbang.phy",

    "models/trueexpert/w_flashbang/w_flashbang.mdl",
    "models/trueexpert/w_flashbang/w_flashbang.vvd",
    "models/trueexpert/w_flashbang/w_flashbang.dx80.vtx",
    "models/trueexpert/w_flashbang/w_flashbang.dx90.vtx",
    "models/trueexpert/w_flashbang/w_flashbang.sw.vtx",
    "models/trueexpert/w_flashbang/w_flashbang.phy",

    "models/trueexpert/v_flashbang4/v_flashbang.mdl",
    "models/trueexpert/v_flashbang4/v_flashbang.vvd",
    "models/trueexpert/v_flashbang4/v_flashbang.dx80.vtx",
    "models/trueexpert/v_flashbang4/v_flashbang.dx90.vtx",
    "models/trueexpert/v_flashbang4/v_flashbang.sw.vtx",

    // Материалы (варианты скинов)
    "materials/expert_zone/flashbang/default.vmt",
    "materials/expert_zone/flashbang/noshadows.vmt",
    "materials/expert_zone/flashbang/shadows.vmt",
    "materials/expert_zone/flashbang/wireframe.vmt",

    "materials/trueexpert/w_flashbang/default.vmt",
    "materials/trueexpert/w_flashbang/noshadow.vmt",
    "materials/trueexpert/w_flashbang/shadow.vmt",
    "materials/trueexpert/w_flashbang/wireframe.vmt",
    "materials/trueexpert/v_flashbang4/default.vmt",
    "materials/trueexpert/v_flashbang4/noshadow.vmt",
    "materials/trueexpert/v_flashbang4/shadow.vmt",
    "materials/trueexpert/v_flashbang4/wireframe.vmt"
};

// === СКИНЫ ===
// Предполагается, что модель скомпилирована с 4 skin-family под эти VMT:
// 0: default, 1: noshadows (Fullbright), 2: shadows (Shadow), 3: wireframe (Wireframe)
// Если в вашей сборке порядок иной, поправьте индексы ниже.
enum SkinStyle
{
    SKIN_DEFAULT   = 0,
    SKIN_FULLBRIGHT= 1, // UnlitGeneric — яркий без освещения
    SKIN_SHADOW    = 2, // VertexLitGeneric — с тенями
    SKIN_WIREFRAME = 3  // Wireframe
};

// === КУКИ ДЛЯ СОХРАНЕНИЯ ===
Handle g_hCookieSkin;   // int
Handle g_hCookieColor;  // string "r,g,b"

// === ПЕРЕМЕННЫЕ ИГРОКОВ ===
int g_iSkin[MAXPLAYERS+1];         // выбранный скин (SkinStyle)
int g_iColor[MAXPLAYERS+1][3];     // RGB 0..255

bool g_bRoundActive = false;       // применяем только во время раунда
bool g_bProjectileModelReady = false; // модель гранаты в полете предкешена
bool g_bWorldModelReady = false;      // модель weapon_flashbang загружена
bool g_bViewModelReady = false;       // viewmodel загружен
int g_iProjectileModelIndex = -1;
int g_iWorldModelIndex = -1;
int g_iViewModelIndex = -1;

Handle g_hRefreshTimer = INVALID_HANDLE;
Handle g_hTrackedProjectiles = INVALID_HANDLE;
Handle g_hTrackedViewmodels = INVALID_HANDLE;


bool IsClientActive(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}


// === КОМАНДЫ ===
public void OnPluginStart()
{
    RegConsoleCmd("sm_flash",    CmdOpenMenu,   "Открыть меню кастомизации флешки");
    RegConsoleCmd("sm_flashrgb", CmdSetRGB,     "Установить цвет вручную: sm_flashrgb R G B");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end",   Event_RoundEnd,   EventHookMode_PostNoCopy);

    // Куки
    g_hCookieSkin  = RegClientCookie("flash_skin",  "Flash skin index", CookieAccess_Public);
    g_hCookieColor = RegClientCookie("flash_color", "Flash color RGB",  CookieAccess_Public);

    if (g_hTrackedProjectiles == INVALID_HANDLE)
    {
        g_hTrackedProjectiles = CreateArray();
    }

    if (g_hTrackedViewmodels == INVALID_HANDLE)
    {
        g_hTrackedViewmodels = CreateArray();
    }

    if (g_hRefreshTimer == INVALID_HANDLE)
    {
        g_hRefreshTimer = CreateTimer(0.1, Timer_RefreshFlashEntities, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }

    ResetTrackedFlashEntities();

    // Подхватить игроков при поздней загрузке плагина
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);

            ResetClientSettings(i);

            if (AreClientCookiesCached(i))
            {
                LoadClientSettings(i);
            }

            UpdateActiveFlashViewmodel(i);
        }
    }
}

public void OnPluginEnd()
{
    if (g_hRefreshTimer != INVALID_HANDLE)
    {
        CloseHandle(g_hRefreshTimer);
        g_hRefreshTimer = INVALID_HANDLE;
    }

    if (g_hTrackedProjectiles != INVALID_HANDLE)
    {
        CloseHandle(g_hTrackedProjectiles);
        g_hTrackedProjectiles = INVALID_HANDLE;
    }

    if (g_hTrackedViewmodels != INVALID_HANDLE)
    {
        CloseHandle(g_hTrackedViewmodels);
        g_hTrackedViewmodels = INVALID_HANDLE;
    }
}
public void OnMapStart()
{
    ResetTrackedFlashEntities();

    // Добавляем файлы в таблицу закачек
    for (int i = 0; i < sizeof(DOWNLOADS); i++)
    {
        AddFileToDownloadsTable(DOWNLOADS[i]);
    }

    // Безопасный предкеш модели (НЕ preload!)
    g_iProjectileModelIndex = PrecacheFlashModel(MODEL_FLASHBANG_PROJECTILE, "projectile");
    g_bProjectileModelReady = (g_iProjectileModelIndex > 0);

    g_iWorldModelIndex = PrecacheFlashModel(MODEL_FLASHBANG_WORLD, "world");
    g_bWorldModelReady = (g_iWorldModelIndex > 0);

    g_iViewModelIndex = PrecacheFlashModel(MODEL_FLASHBANG_VIEW, "view");
    g_bViewModelReady = (g_iViewModelIndex > 0);
}

public void OnMapEnd()
{
    ResetTrackedFlashEntities();
}

int PrecacheFlashModel(const char[] path, const char[] tag)
{
    if (!FileExists(path, true))
    {
        LogError("[Flash] Model not found (%s): %s", tag, path);
        return -1;
    }

    int idx = PrecacheModel(path, false);
    if (idx <= 0)
    {
        LogError("[Flash] PrecacheModel returned 0 (%s): %s", tag, path);
        return -1;
    }

    return idx;
}

void ResetClientSettings(int client)
{
    g_iSkin[client] = SKIN_WIREFRAME; // дефолт — Wireframe
    g_iColor[client][0] = 255;
    g_iColor[client][1] = 255;
    g_iColor[client][2] = 255;
}

void LoadClientSettings(int client)
{
    // Восстановить скин
    char buff[16];
    GetClientCookie(client, g_hCookieSkin, buff, sizeof(buff));
    if (buff[0] != '\0')
    {
        int v = StringToInt(buff);
        if (v < SKIN_DEFAULT) v = SKIN_DEFAULT;
        if (v > SKIN_WIREFRAME) v = SKIN_WIREFRAME;
        g_iSkin[client] = v;
    }

    // Восстановить цвет
    char col[32];
    GetClientCookie(client, g_hCookieColor, col, sizeof(col));
    if (col[0] != '\0')
    {
        int r, g, b;
        if (ParseRGB(col, r, g, b))
        {
            g_iColor[client][0] = r;
            g_iColor[client][1] = g;
            g_iColor[client][2] = b;
        }
    }
}


public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);

    ResetClientSettings(client);

    if (AreClientCookiesCached(client))
    {
        LoadClientSettings(client);
    }

    UpdateActiveFlashViewmodel(client);
}

public void OnClientDisconnect_Post(int client)
{
    SDKUnhook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);

    ResetClientSettings(client);
}

public void OnClientCookiesCached(int client)
{
    LoadClientSettings(client);
}

void ApplyFlashSettings(int entity, int owner)
{
    if (!IsClientActive(owner))
    {
        return;
    }

    if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
    {
        SetEntityModel(entity, MODEL_FLASHBANG_PROJECTILE);
        SetEntProp(entity, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
        SetEntProp(entity, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
    }

    int skin = g_iSkin[owner];
    SetEntProp(entity, Prop_Send, "m_nSkin", skin);
    SetEntProp(entity, Prop_Data, "m_nSkin", skin);

    SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
    int r = g_iColor[owner][0];
    int g = g_iColor[owner][1];
    int b = g_iColor[owner][2];
    SetEntityRenderColor(entity, r, g, b, 255);
}

public Action Timer_RefreshFlashEntities(Handle timer)
{
    CleanupTrackedArray(g_hTrackedProjectiles);
    CleanupTrackedArray(g_hTrackedViewmodels);

    if (!g_bRoundActive)
    {
        return Plugin_Continue;
    }

    ProcessFlashProjectiles();
    ProcessPredictedViewmodels();

    return Plugin_Continue;
}

void ProcessFlashProjectiles()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "flashbang_projectile")) != -1)
    {
        if (!IsValidEntSafe(entity))
        {
            continue;
        }

        TrackEntityReference(g_hTrackedProjectiles, entity);

        int owner = ResolveFlashOwner(entity);
        if (owner == 0)
        {
            continue;
        }

        ApplyFlashSettings(entity, owner);
    }
}

void ProcessPredictedViewmodels()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "predicted_viewmodel")) != -1)
    {
        if (!IsValidEntSafe(entity))
        {
            continue;
        }

        TrackEntityReference(g_hTrackedViewmodels, entity);

        ApplyPredictedViewmodel(entity);
    }
}

void ApplyPredictedViewmodel(int entity)
{
    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwner");
    if (!IsClientActive(owner))
    {
        return;
    }

    int weapon = GetEntPropEnt(owner, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEdict(weapon))
    {
        return;
    }

    char classname[32];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (!StrEqual(classname, "weapon_flashbang", false))
    {
        return;
    }

    ApplyFlashWeaponViewmodel(owner, weapon);
}

void CleanupTrackedArray(Handle array)
{
    if (array == INVALID_HANDLE)
    {
        return;
    }

    int length = GetArraySize(array);
    for (int i = length - 1; i >= 0; i--)
    {
        int ref = GetArrayCell(array, i);
        int entity = EntRefToEntIndex(ref);
        if (entity == INVALID_ENT_REFERENCE || entity <= MaxClients || !IsValidEdict(entity))
        {
            RemoveFromArray(array, i);
        }
    }
}

void TrackEntityReference(Handle array, int entity)
{
    if (array == INVALID_HANDLE)
    {
        return;
    }

    int ref = EntIndexToEntRef(entity);
    if (ref == INVALID_ENT_REFERENCE)
    {
        return;
    }

    if (FindValueInArray(array, ref) == -1)
    {
        PushArrayCell(array, ref);
    }
}

void ResetTrackedFlashEntities()
{
    if (g_hTrackedProjectiles != INVALID_HANDLE)
    {
        ClearArray(g_hTrackedProjectiles);
    }

    if (g_hTrackedViewmodels != INVALID_HANDLE)
    {
        ClearArray(g_hTrackedViewmodels);
    }
}

void ApplyFlashWeaponViewmodel(int client, int weapon)
{
    if (!IsClientActive(client) || !IsValidEntSafe(weapon))
    {
        return;
    }

    int skin = g_iSkin[client];
    int r = g_iColor[client][0];
    int g = g_iColor[client][1];
    int b = g_iColor[client][2];

    if (g_bWorldModelReady && g_iWorldModelIndex != -1)
    {
        SetEntityModel(weapon, MODEL_FLASHBANG_WORLD);
        SetEntProp(weapon, Prop_Send, "m_nModelIndex", g_iWorldModelIndex);
        SetEntProp(weapon, Prop_Data, "m_nModelIndex", g_iWorldModelIndex);
        SetEntProp(weapon, Prop_Send, "m_iWorldModelIndex", g_iWorldModelIndex);
    }
    else if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
    {
        SetEntityModel(weapon, MODEL_FLASHBANG_PROJECTILE);
        SetEntProp(weapon, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
        SetEntProp(weapon, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
        SetEntProp(weapon, Prop_Send, "m_iWorldModelIndex", g_iProjectileModelIndex);
    }

    SetEntProp(weapon, Prop_Send, "m_nSkin", skin);
    SetEntProp(weapon, Prop_Data, "m_nSkin", skin);

    SetEntityRenderMode(weapon, RENDER_TRANSCOLOR);
    SetEntityRenderColor(weapon, r, g, b, 255);

    int worldModel = GetEntPropEnt(weapon, Prop_Send, "m_hWeaponWorldModel");
    if (worldModel > MaxClients && IsValidEdict(worldModel))
    {
        if (g_bWorldModelReady && g_iWorldModelIndex != -1)
        {
            SetEntityModel(worldModel, MODEL_FLASHBANG_WORLD);
            SetEntProp(worldModel, Prop_Send, "m_nModelIndex", g_iWorldModelIndex);
            SetEntProp(worldModel, Prop_Data, "m_nModelIndex", g_iWorldModelIndex);
        }
        else if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
        {
            SetEntityModel(worldModel, MODEL_FLASHBANG_PROJECTILE);
            SetEntProp(worldModel, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
            SetEntProp(worldModel, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
        }

        SetEntProp(worldModel, Prop_Send, "m_nSkin", skin);
        SetEntProp(worldModel, Prop_Data, "m_nSkin", skin);
        SetEntityRenderMode(worldModel, RENDER_TRANSCOLOR);
        SetEntityRenderColor(worldModel, r, g, b, 255);
    }

    ApplyFlashPlayerViewmodels(client, skin, r, g, b);
}

void UpdateActiveFlashViewmodel(int client)
{
    if (!IsClientActive(client))
    {
        return;
    }

    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (active <= MaxClients || !IsValidEdict(active))
    {
        return;
    }

    char classname[32];
    GetEntityClassname(active, classname, sizeof(classname));
    if (StrEqual(classname, "weapon_flashbang", false))
    {
        ApplyFlashWeaponViewmodel(client, active);
    }
}

void ApplyFlashPlayerViewmodels(int client, int skin, int r, int g, int b)
{
    if (!IsClientActive(client))
    {
        return;
    }

    // Обновляем viewmodel, который возвращает prop m_hViewModel
    for (int slot = 0; slot < 2; slot++)
    {
        int viewmodel = GetEntPropEnt(client, Prop_Send, "m_hViewModel", slot);
        if (viewmodel > MaxClients && IsValidEdict(viewmodel))
        {
            ApplyFlashSkinToEntity(viewmodel, skin, r, g, b, true);
        }
    }

    // А также predicated_viewmodel (как делает weaponmodels.sp)
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "predicted_viewmodel")) != -1)
    {
        if (GetEntPropEnt(entity, Prop_Send, "m_hOwner") != client)
        {
            continue;
        }

        ApplyFlashSkinToEntity(entity, skin, r, g, b, true);
    }
}

void ApplyFlashSkinToEntity(int entity, int skin, int r, int g, int b, bool isViewModel)
{
    if (isViewModel)
    {
        if (g_bViewModelReady && g_iViewModelIndex != -1)
        {
            SetEntityModel(entity, MODEL_FLASHBANG_VIEW);
            SetEntProp(entity, Prop_Send, "m_nModelIndex", g_iViewModelIndex);
            SetEntProp(entity, Prop_Data, "m_nModelIndex", g_iViewModelIndex);
        }
        else if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
        {
            SetEntityModel(entity, MODEL_FLASHBANG_PROJECTILE);
            SetEntProp(entity, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
            SetEntProp(entity, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
        }
    }
    else if (g_bWorldModelReady && g_iWorldModelIndex != -1)
    {
        SetEntityModel(entity, MODEL_FLASHBANG_WORLD);
        SetEntProp(entity, Prop_Send, "m_nModelIndex", g_iWorldModelIndex);
        SetEntProp(entity, Prop_Data, "m_nModelIndex", g_iWorldModelIndex);
    }
    else if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
    {
        SetEntityModel(entity, MODEL_FLASHBANG_PROJECTILE);
        SetEntProp(entity, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
        SetEntProp(entity, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
    }

    SetEntProp(entity, Prop_Send, "m_nSkin", skin);
    SetEntProp(entity, Prop_Data, "m_nSkin", skin);
    SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
    SetEntityRenderColor(entity, r, g, b, 255);
}

public void OnWeaponSwitchPost(int client, int weapon)
{
    if (!IsClientActive(client))
    {
        return;
    }

    if (!IsValidEntSafe(weapon))
    {
        return;
    }

    char classname[32];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (StrEqual(classname, "weapon_flashbang", false))
    {
        ApplyFlashWeaponViewmodel(client, weapon);
    }
}

int ResolveFlashOwner(int entity)
{
   
    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    int weapon = owner;
    if (!IsClientActive(owner))
    {
        owner = GetEntPropEnt(entity, Prop_Data, "m_hThrower");
    }

    if (!IsClientActive(owner))
    {
        owner = GetEntPropEnt(entity, Prop_Data, "m_hOriginalThrower");
    }
    
    if (!IsClientActive(owner))
    {
        if (weapon <= MaxClients)
        {
            weapon = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
        }
        if (weapon > MaxClients && weapon != -1)
        {
            int weaponOwner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
            if (!IsClientActive(weaponOwner))
            {
                weaponOwner = GetEntPropEnt(weapon, Prop_Data, "m_hOwnerEntity");
            }
            if (IsClientActive(weaponOwner))
            {
                owner = weaponOwner;
            }
        }
    }

    if (!IsClientActive(owner))
    {
        return 0;
    }

    return owner;
}

// === СОБЫТИЯ РАУНДА ===
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = true;

    ResetTrackedFlashEntities();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = false;

    ResetTrackedFlashEntities();
}

// === МЕНЮ ===
public Action CmdOpenMenu(int client, int args)
{
    if (!IsClientInGame(client)) return Plugin_Handled;

    Menu m = new Menu(MenuHandler_Main);
    m.SetTitle("Настройки флешки");
    m.AddItem("skin",  "1. Выбрать скин");
    m.AddItem("color", "2. Выбрать цвет");
    m.ExitButton = true;
    m.Display(client, 20);
    return Plugin_Handled;
}

public int MenuHandler_Main(Menu m, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete m;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        m.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "skin"))
        {
            OpenSkinMenu(client);
        }
        else if (StrEqual(info, "color"))
        {
            OpenColorMenu(client);
        }
    }
    return 0;
}

void OpenSkinMenu(int client)
{
    Menu s = new Menu(MenuHandler_Skin);
    s.SetTitle("Выбрать скин");
    s.AddItem("1", "Скин 1");   // SKIN_FULLBRIGHT (1)
    s.AddItem("2", "Скин 2");       // SKIN_SHADOW (2)
    s.AddItem("3", "Скин 3");    // SKIN_WIREFRAME (3)
    s.ExitBackButton = true;
    s.Display(client, 20);
}

public int MenuHandler_Skin(Menu s, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete s;
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        CmdOpenMenu(client, 0);
    }
    else if (action == MenuAction_Select)
    {
        char info[8];
        s.GetItem(item, info, sizeof(info));
        int choice = StringToInt(info);
        int skin = SKIN_FULLBRIGHT;
        if (choice == 1) skin = SKIN_FULLBRIGHT;
        else if (choice == 2) skin = SKIN_SHADOW;
        else if (choice == 3) skin = SKIN_WIREFRAME;

        g_iSkin[client] = skin;

        // Сохранить
        char buff[16];
        IntToString(skin, buff, sizeof(buff));
        SetClientCookie(client, g_hCookieSkin, buff);

        UpdateActiveFlashViewmodel(client);

        PrintToChat(client, "\x04[Flash]\x01 Скин установлен: \x03%s", (skin==SKIN_FULLBRIGHT)?"Fullbright":(skin==SKIN_SHADOW)?"Shadow":"Wireframe");
        OpenSkinMenu(client);
    }
    return 0;
}

void OpenColorMenu(int client)
{
    Menu c = new Menu(MenuHandler_Color);
    c.SetTitle("Выбрать цвет");
    c.AddItem("255,255,255", "Белый");
    c.AddItem("255,0,0",     "Красный");
    c.AddItem("0,255,0",     "Зелёный");
    c.AddItem("0,0,255",     "Синий");
    c.AddItem("255,255,0",   "Жёлтый");
    c.AddItem("0,255,255",   "Голубой");
    c.AddItem("255,0,255",   "Пурпурный");
    c.AddItem("255,128,0",   "Оранжевый");
    c.AddItem("128,0,255",   "Фиолетовый");
    c.AddItem("custom",      "Свой RGB (пример !flashrgb 128 0 128) ");
    c.ExitBackButton = true;
    c.Display(client, 20);
}

public int MenuHandler_Color(Menu c, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete c;
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        CmdOpenMenu(client, 0);
    }
    else if (action == MenuAction_Select)
    {
        char info[32];
        c.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "custom"))
        {
            PrintToChat(client, "\x04[Flash]\x01 Введите: \x03sm_flashrgb R G B\x01 (0-255)");
            OpenColorMenu(client);
        }
        else
        {
            int r, g, b;
            if (ParseRGB(info, r, g, b))
            {
                g_iColor[client][0] = r;
                g_iColor[client][1] = g;
                g_iColor[client][2] = b;

                // Сохранить
                SetClientCookie(client, g_hCookieColor, info);

                UpdateActiveFlashViewmodel(client);
                PrintToChat(client, "\x04[Flash]\x01 Цвет установлен: \x03%d %d %d", r, g, b);
                OpenColorMenu(client);
            }
        }
    }
    return 0;
}

public Action CmdSetRGB(int client, int args)
{
    if (args < 3)
    {
        ReplyToCommand(client, "Использование: sm_flashrgb <R> <G> <B>");
        return Plugin_Handled;
    }

    int r = GetCmdArgInt(1);
    int g = GetCmdArgInt(2);
    int b = GetCmdArgInt(3);

    ClampColor(r); ClampColor(g); ClampColor(b);

    g_iColor[client][0] = r;
    g_iColor[client][1] = g;
    g_iColor[client][2] = b;

    char buff[32];
    Format(buff, sizeof(buff), "%d,%d,%d", r, g, b);
    SetClientCookie(client, g_hCookieColor, buff);

    UpdateActiveFlashViewmodel(client);

    ReplyToCommand(client, "Цвет сохранён: %d %d %d", r, g, b);
    return Plugin_Handled;
}

// === ВСПОМОГАТЕЛЬНЫЕ ===
bool ParseRGB(const char[] s, int &r, int &g, int &b)
{
    char parts[3][8];
    int n = ExplodeString(s, ",", parts, 3, sizeof(parts[]));
    if (n != 3)
        return false;

    r = StringToInt(parts[0]);
    g = StringToInt(parts[1]);
    b = StringToInt(parts[2]);

    ClampColor(r); ClampColor(g); ClampColor(b);
    return true;
}

void ClampColor(int &v)
{
    if (v < 0) v = 0;
    if (v > 255) v = 255;
}

// Безопасная обёртка, т.к. Entity может умереть очень быстро
bool IsValidEntSafe(int entity)
{
    return (entity > MaxClients && entity <= GetMaxEntities() && IsValidEdict(entity));
}
