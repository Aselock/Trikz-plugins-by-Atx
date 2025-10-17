/**
 * sm_flashbang_skin_color.sp
 * Counter-Strike: Source (OrangeBox) — SourceMod plugin
 *
 * Функции:
 *  - Меню: 1) Выбрать стиль (Fullbright / NoShadows / Wireframe), 2) Выбрать цвет
 *  - Меняет модель flashbang_projectile и viewmodel на кастомную
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

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "Flashbang Viewmodel Styler (CS:S)",
    author      = "ChatGPT",
    description = "Позволяет выбрать стиль first person флешки (Fullbright/NoShadows/Wireframe) и её цвет",
    version     = "1.1.0",
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
// 0: default, 1: fullbright (unlit), 2: noshadows (lit без теней), 3: wireframe
// Если в вашей сборке порядок иной, поправьте индексы ниже.
enum SkinStyle
{
    SKIN_DEFAULT    = 0,
    SKIN_FULLBRIGHT = 1,
    SKIN_NOSHADOWS  = 2,
    SKIN_WIREFRAME  = 3
};

static const char g_sSkinLabels[][] =
{
    "Default",
    "Fullbright",
    "NoShadows",
    "Wireframe"
};

int GetSkinIndex(SkinStyle style)
{
    switch (style)
    {
        case SKIN_FULLBRIGHT: return 1;
        case SKIN_NOSHADOWS:  return 2;
        case SKIN_WIREFRAME:  return 3;
    }
    return 0;
}

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
public void OnMapStart()
{
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
    g_iSkin[client] = view_as<int>(SKIN_FULLBRIGHT);
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
    UpdateActiveFlashViewmodel(client);
}


 
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_bRoundActive) return;
    if (classname[0] == '\0') return;

    if (StrEqual(classname, "flashbang_projectile", false))
    {
        // Отложим применение на момент после спавна, чтобы владелец уже был назначен
        SDKHook(entity, SDKHook_SpawnPost, OnFlashbangSpawned);
    }
}

public void OnFlashbangSpawned(int entity)
{
        if (!IsValidEntSafe(entity))
    {
        return;
    }

    SDKUnhook(entity, SDKHook_SpawnPost, OnFlashbangSpawned);

    int owner = ResolveFlashOwner(entity);
    if (owner == 0)
    {
        RequestFrame(DeferredApplyFlashSettings, EntIndexToEntRef(entity));
        return;
    }

    ApplyFlashSettings(entity, owner);
}

   
   void DeferredApplyFlashSettings(int ref)
{
    int entity = EntRefToEntIndex(ref);
    if (!IsValidEntSafe(entity))
    {
        return;
    }

    int owner = ResolveFlashOwner(entity);
    if (owner == 0)
    {
        return;
    }

    ApplyFlashSettings(entity, owner);
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

    SkinStyle style = view_as<SkinStyle>(g_iSkin[owner]);
    int skin = GetSkinIndex(style);
    SetEntProp(entity, Prop_Send, "m_nSkin", skin);
    SetEntProp(entity, Prop_Data, "m_nSkin", skin);

    SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
    int r = g_iColor[owner][0];
    int g = g_iColor[owner][1];
    int b = g_iColor[owner][2];
    SetEntityRenderColor(entity, r, g, b, 255);
}

void ApplyFlashWeaponViewmodel(int client, int weapon)
{
    if (!IsClientActive(client) || !IsValidEntSafe(weapon))
    {
        return;
    }

    SkinStyle style = view_as<SkinStyle>(g_iSkin[client]);
    int skin = GetSkinIndex(style);
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

    for (int slot = 0; slot < 2; slot++)
    {
        int viewmodel = GetEntPropEnt(client, Prop_Send, "m_hViewModel", slot);
        if (viewmodel <= MaxClients || !IsValidEdict(viewmodel))
        {
            continue;
        }

        if (g_bViewModelReady && g_iViewModelIndex != -1)
        {
            SetEntityModel(viewmodel, MODEL_FLASHBANG_VIEW);
            SetEntProp(viewmodel, Prop_Send, "m_nModelIndex", g_iViewModelIndex);
            SetEntProp(viewmodel, Prop_Data, "m_nModelIndex", g_iViewModelIndex);
        }
        else if (g_bProjectileModelReady && g_iProjectileModelIndex != -1)
        {
            SetEntityModel(viewmodel, MODEL_FLASHBANG_PROJECTILE);
            SetEntProp(viewmodel, Prop_Send, "m_nModelIndex", g_iProjectileModelIndex);
            SetEntProp(viewmodel, Prop_Data, "m_nModelIndex", g_iProjectileModelIndex);
        }

        SetEntProp(viewmodel, Prop_Send, "m_nSkin", skin);
        SetEntProp(viewmodel, Prop_Data, "m_nSkin", skin);
        SetEntityRenderMode(viewmodel, RENDER_TRANSCOLOR);
        SetEntityRenderColor(viewmodel, r, g, b, 255);
    }
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

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            UpdateActiveFlashViewmodel(i);
        }
    }
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = false;
}

// === МЕНЮ ===
public Action CmdOpenMenu(int client, int args)
{
    if (!IsClientInGame(client)) return Plugin_Handled;

    Menu m = new Menu(MenuHandler_Main);
    m.SetTitle("Настройки флешки");
    m.AddItem("skin",  "1. Выбрать стиль");
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
    s.SetTitle("Выбрать стиль флешки");
    s.AddItem("1", "Fullbright");
    s.AddItem("2", "NoShadows");
    s.AddItem("3", "Wireframe");
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
        SkinStyle style = SKIN_FULLBRIGHT;
        if (choice == 2)
        {
            style = SKIN_NOSHADOWS;
        }
        else if (choice == 3)
        {
            style = SKIN_WIREFRAME;
        }

        g_iSkin[client] = view_as<int>(style);

        // Сохранить
        char buff[16];
        IntToString(view_as<int>(style), buff, sizeof(buff));
        SetClientCookie(client, g_hCookieSkin, buff);

        UpdateActiveFlashViewmodel(client);

        PrintToChat(client, "\x04[Flash]\x01 Стиль установлен: \x03%s", g_sSkinLabels[view_as<int>(style)]);
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
