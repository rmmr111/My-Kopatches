-- Clean bar tab for KOReader top menu
-- Adds a new tab at the far left with Wi-Fi, action buttons, and frontlight/warmth sliders.
-- Works in both File Manager and Book Reader views.
-- Additional buttons for the Clean bar tab.
-- Adds optional buttons for OPDS Catalog, NotionSync, and Reading Streak.
-- OPDS Catalog is included with KOReader and allows browsing OPDS book catalogs.
-- NotionSync plugin by Cezary Pukownik: https://github.com/CezaryPukownik/notionsync.koplugin
-- Reading Streak plugin by advokatb: https://github.com/advokatb/readingstreak.koplugin

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local Widget = require("ui/widget/widget")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local datetime = require("datetime")
local BD = require("ui/bidi")
local Screen = Device.screen

-- A selected Clean-style icon is the normal SVG. To avoid requiring a second
-- hand-maintained bold file for each custom icon, optionally create a cached
-- thick-stroke SVG (one-time, on first use). The native IconWidget does not
-- expose a stroke-width parameter. Only explicit numeric SVG stroke-widths
-- are safe to modify; filled-only icons and PNGs keep their original drawing.
local bold_svg_cache = {}
local function cleanBarBoldIconPath(icon_name)
    if type(icon_name) ~= "string" or icon_name == "" then return nil end
    if bold_svg_cache[icon_name] ~= nil then
        return bold_svg_cache[icon_name] or nil
    end
    local ok, result = pcall(function()
        local original = IconWidget:new{ icon = icon_name }
        local path = original.file
        if type(path) ~= "string" or not path:match("%.svg$") then return nil end
        local input = io.open(path, "rb")
        if not input then return nil end
        local svg = input:read("*a")
        input:close()
        if not svg or #svg > 256 * 1024 or not svg:find("<svg", 1, true) then return nil end
        -- Never change arbitrary filled artwork or raster content.
        if not svg:find('stroke%s*=') and not svg:find('stroke%s*:') then return nil end
        local replacements = 0
        local function thicken(value)
            local width = tonumber(value)
            if not width or width <= 0 then return value end
            replacements = replacements + 1
            return string.format("%.3g", math.min(width * 1.6, 12))
        end
        -- Support ordinary XML SVG stroke-width declarations, single or
        -- double-quoted, and inline CSS. No SVG parser or heavyweight renderer.
        local modified = svg:gsub('(stroke%-width%s*=%s*")([%d%.]+)(")',
            function(a, val, b) return a .. thicken(val) .. b end)
        modified = modified:gsub("(stroke%-width%s*=%s*')([%d%.]+)(')",
            function(a, val, b) return a .. thicken(val) .. b end)
        modified = modified:gsub('(stroke%-width%s*:%s*)([%d%.]+)',
            function(a, val) return a .. thicken(val) end)
        if replacements == 0 or modified == svg then return nil end
        local ok_storage, DataStorage = pcall(require, "datastorage")
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not (ok_storage and ok_lfs) then return nil end
        local root = DataStorage:getDataDir() .. "/cache"
        if lfs.attributes(root, "mode") ~= "directory" then pcall(lfs.mkdir, root) end
        local folder = root .. "/cleanbar-bold-svg"
        if lfs.attributes(folder, "mode") ~= "directory" then pcall(lfs.mkdir, folder) end
        if lfs.attributes(folder, "mode") ~= "directory" then return nil end
        -- The content fingerprint avoids stale cache data after a user
        -- replaces an SVG with the same filename.
        local hash = 5381
        for i = 1, #svg do hash = (hash * 33 + svg:byte(i)) % 4294967291 end
        local dest = string.format("%s/%s-%08x.svg", folder,
            icon_name:gsub("[^%w_%-]", "_"), hash)
        if lfs.attributes(dest, "mode") ~= "file" then
            local output = io.open(dest, "wb")
            if not output then return nil end
            output:write(modified)
            output:close()
        end
        return dest
    end)
    bold_svg_cache[icon_name] = ok and result or false
    return bold_svg_cache[icon_name] or nil
end

-- Keep saved icon choices compatible when the bundled SVGs move from
-- resources/icons/ to the user-icons subdirectory icons/cleanbar/.
-- Only Clean bar's own names are migrated; unrelated custom icons are untouched.
local function migrateCleanBarIconName(name)
    if type(name) ~= "string" then return name end
    if name:match("^cleanbar_thin_[%w_%-]+$") then
        return "cleanbar/" .. name
    end
    -- Older experimental builds exposed separate bold icons. Preserve those
    -- selections using the current single-SVG automatic stroke treatment.
    local old_bold = name:match("^cleanbar_bold_([%w_%-]+)$")
    if old_bold then
        return "cleanbar/cleanbar_thin_" .. old_bold
    end
    return name
end

-- ============================================================
-- Configuration
-- ============================================================

local config_default = {
    button_order = { "wifi", "night", "rotate", "clean", "kobo_bluetooth", "custom1", "custom2", "custom3", "restart", "sleep", "usb", "search", "quickrss", "cloud", "zlibrary", "calibre", "notion", "streak", "opds", "exit" },
    show_buttons = {
        wifi = true,
        night = true,
        rotate = true,
        clean = true,
        kobo_bluetooth = false,
        custom1 = false,
        custom2 = false,
        custom3 = false,
        usb = false,
        search = false,
        quickrss = false,
        cloud = false,
        zlibrary = false,
        calibre = false,
        restart = true,
        exit = false,
        sleep = true,
        -- External plugin buttons (disabled by default; enable if plugin is installed)
        notion = false,
        streak = false,
        opds = false,			 
    },
    custom_buttons = {
        custom1 = {
            label = "Custom 1",
            icon = "quick_search",
            action_type = "event",
            event = "",
            event_arg = "",
            dispatch = "broadcast",
            plugin = "",
            method = "",
            menu_label = "",
            menu_tab_label = "",
            menu_key = "",
        },
        custom2 = {
            label = "Custom 2",
            icon = "quick_cloud",
            action_type = "event",
            event = "",
            event_arg = "",
            dispatch = "broadcast",
            plugin = "",
            method = "",
            menu_label = "",
            menu_tab_label = "",
            menu_key = "",
        },
        custom3 = {
            label = "Custom 3",
            icon = "quick_opds",
            action_type = "event",
            event = "",
            event_arg = "",
            dispatch = "broadcast",
            plugin = "",
            method = "",
            menu_label = "",
            menu_tab_label = "",
            menu_key = "",
        },
    },
    show_frontlight = true,
    show_warmth = true,
    selected_light_control = "brightness", -- last selected icon; brightness or warmth
    slider_style = "simple",
    button_style = "circle",
    open_on_start = false,
    clean_mode = false,
    -- Clean mode custom menu: keys are discovered from KOReader's standard
    -- menu tabs at runtime. The table stores which original menu entries
    -- should be copied into the clean custom menu tab.
    clean_menu_items = {},
    -- Patch menu shortcuts: only stable paths/labels are saved, never Lua functions.
    clean_patch_actions = {},
    -- Verified installed-plugin dispatcher actions selected for Menu Clean.
    clean_plugin_actions = {},
    -- Verifiable paths to menus installed by enabled plugins.
    clean_plugin_menu_actions = {},
    -- Stable order of user-selected entries in the Clean custom menu.
    -- Stored beside other Clean bar settings, independent of patch reinstall.
    clean_menu_order = {},
    clean_menu_initialized = false,
    -- Top tabs. Explicit settings survive a patch upgrade; existing menus remain unchanged.
    clean_left_tab_icon = "cleanbar/cleanbar_thin_panel",
    clean_middle_tab_icon = "cleanbar/cleanbar_thin_menu",
    clean_right_tab_icon = "cleanbar/cleanbar_thin_library",
    clean_right_destination = "auto",
}

local config

local valid_slider_styles = {
    simple = true,
    bold = true,
    fine = true,
    pill = true,
    segmented = true,
}

local valid_button_styles = {
    circle = true, -- Original Clean bar
    premium = true,
    clean_icons = true, -- No visible button circles; only the active icon is inverted.
}

local function normalizeButtonOrder()
    if type(config.button_order) ~= "table" then
        config.button_order = {}
    end

    local normalized = {}
    local seen = {}
    local function addButtonId(id)
        if config_default.show_buttons[id] ~= nil and not seen[id] then
            table.insert(normalized, id)
            seen[id] = true
        end
    end

    -- Preserve the user's saved order first.
    for _, id in ipairs(config.button_order) do
        addButtonId(id)
    end

    -- Force the Clean button into old configs in a visible/useful spot.
    -- Older versions appended missing buttons at the end, which could make
    -- Clean hard to find in the SortWidget pages.
    if not seen.clean then
        local inserted = false
        for i, id in ipairs(normalized) do
            if id == "rotate" then
                table.insert(normalized, i + 1, "clean")
                seen.clean = true
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(normalized, 1, "clean")
            seen.clean = true
        end
    end

    -- Add any other buttons introduced by newer patch versions.
    for _, id in ipairs(config_default.button_order) do
        if id ~= "clean" then
            addButtonId(id)
        end
    end

    config.button_order = normalized
end

local function refreshCleanBarPanel(touch_menu)
    if touch_menu and touch_menu.item_table and touch_menu.item_table.panel and touch_menu.updateItems then
        touch_menu:updateItems(1)
    else
        UIManager:setDirty("all", "ui")
    end
end

local CLEAN_BAR_SETTINGS_KEY = "clean_bar_panel"
local LEGACY_SETTINGS_KEY = table.concat({"quick", "settings", "panel"}, "_")

local function loadConfig()
    config = G_reader_settings:readSetting(CLEAN_BAR_SETTINGS_KEY)
    if config == nil then
        local legacy_config = G_reader_settings:readSetting(LEGACY_SETTINGS_KEY)
        if legacy_config ~= nil then
            config = legacy_config
            G_reader_settings:saveSetting(CLEAN_BAR_SETTINGS_KEY, config)
        end
    end
    if config == nil then
        config = {}
    end
    for k, v in pairs(config_default) do
        if config[k] == nil then
            config[k] = v
        end
    end
    if type(config.show_buttons) == "table" then
        for k, v in pairs(config_default.show_buttons) do
            if config.show_buttons[k] == nil then
                config.show_buttons[k] = v
            end
        end
    else
        config.show_buttons = config_default.show_buttons
    end
    if type(config.clean_menu_items) ~= "table" then
        config.clean_menu_items = {}
    end
    if type(config.clean_patch_actions) ~= "table" then
        config.clean_patch_actions = {}
    end
    if type(config.clean_plugin_actions) ~= "table" then
        config.clean_plugin_actions = {}
    end
    if type(config.clean_plugin_menu_actions) ~= "table" then
        config.clean_plugin_menu_actions = {}
    end
    if type(config.clean_menu_order) ~= "table" then
        config.clean_menu_order = {}
    end
    if config.clean_menu_initialized == nil then
        config.clean_menu_initialized = false
    end
    if type(config.clean_left_tab_icon) ~= "string" or config.clean_left_tab_icon == "" then
        config.clean_left_tab_icon = "cleanbar/cleanbar_thin_panel"
    end
    if type(config.clean_middle_tab_icon) ~= "string" or config.clean_middle_tab_icon == "" then
        config.clean_middle_tab_icon = "cleanbar/cleanbar_thin_menu"
    end
    if type(config.clean_right_tab_icon) ~= "string" or config.clean_right_tab_icon == "" then
        config.clean_right_tab_icon = "cleanbar/cleanbar_thin_library"
    end
    -- v9's generic plugin/menu destination could block KOReader while it
    -- enumerated recursive or dynamic menus. Retire it without altering any
    -- other saved preferences. Old selections fall back to the file manager.
    config.clean_right_menu_action = nil
    if config.clean_right_destination ~= "auto" and config.clean_right_destination ~= "bookshelf"
        and config.clean_right_destination ~= "filemanager" and config.clean_right_destination ~= "home"
        and config.clean_right_destination ~= "projecttitle" then
        config.clean_right_destination = "filemanager"
    end
    if type(config.custom_buttons) ~= "table" then
        config.custom_buttons = {}
    end
    for id, defaults in pairs(config_default.custom_buttons) do
        if type(config.custom_buttons[id]) ~= "table" then
            config.custom_buttons[id] = {}
        end
        for key, value in pairs(defaults) do
            if config.custom_buttons[id][key] == nil then
                config.custom_buttons[id][key] = value
            end
        end
    end
    -- Migrate only previous Clean bar SVG selections; keep the rest of the
    -- persisted settings and the user's custom/icon choices unchanged.
    config.clean_left_tab_icon = migrateCleanBarIconName(config.clean_left_tab_icon)
    config.clean_middle_tab_icon = migrateCleanBarIconName(config.clean_middle_tab_icon)
    config.clean_right_tab_icon = migrateCleanBarIconName(config.clean_right_tab_icon)
    for _, button_cfg in pairs(config.custom_buttons) do
        if type(button_cfg) == "table" then
            button_cfg.icon = migrateCleanBarIconName(button_cfg.icon)
        end
    end
    if not valid_slider_styles[config.slider_style] then
        config.slider_style = "simple"
    end
    -- All retired experimental button styles return to the original style.
    if not valid_button_styles[config.button_style] then
        config.button_style = "circle"
    end
    -- Slider variants were retired: original style is the only standalone one.
    -- Premium uses its own matching slider appearance.
    config.slider_style = "simple"

    if config.selected_light_control ~= "warmth" then
        config.selected_light_control = "brightness"
    end

    normalizeButtonOrder()
end

local function saveConfig()
    G_reader_settings:saveSetting(CLEAN_BAR_SETTINGS_KEY, config)
end

local function showInfo(text)
    local ok, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok and InfoMessage then
        UIManager:show(InfoMessage:new{
            text = text,
        })
    end
end

-- Forward declaration. Assigned after the Clean tabs are defined.
-- Used by the Clean button and settings menu to rebuild the visible
-- TouchMenu bar immediately, without asking the user to close/reopen it.
local refreshCleanModeMenu

-- Small localised string helper for labels introduced by this patch.
-- KOReader's gettext will translate built-in strings, but our new custom
-- strings do not have .po entries, so Portuguese is supplied directly when
-- the UI language appears to be Portuguese.
local custom_strings = {
    buttons = { en = "Buttons", pt = "Botões" },
    top_tabs = { en = "Top tabs", pt = "Separadores superiores" },
    left_tab_icon = { en = "Clean bar icon", pt = "Ícone Clean bar" },
    middle_tab_icon = { en = "Custom menu icon", pt = "Ícone Menu personalizado" },
    right_tab_icon = { en = "Library icon", pt = "Ícone Biblioteca" },
    right_tab_destination = { en = "Library action", pt = "Ação de biblioteca" },
    destination_auto = { en = "Automatic (KOReader home)", pt = "Automático (início do KOReader)" },
    destination_bookshelf = { en = "Bookshelf", pt = "Bookshelf" },
    destination_filemanager = { en = "File manager", pt = "Gestor de ficheiros" },
    destination_projecttitle = { en = "Project: Title", pt = "Project: Title" },
    destination_home = { en = "Home folder", pt = "Pasta inicial" },
    destination_not_found = { en = "This destination is no longer available; opening File Manager.", pt = "Este destino deixou de estar disponível; a abrir o gestor de ficheiros." },
    visible_buttons = { en = "Show or hide buttons", pt = "Mostrar ou ocultar botões" },
    configure_buttons = { en = "Customize buttons", pt = "Personalizar botões" },
    label_edit = { en = "Change label", pt = "Alterar etiqueta" },
    label_editor_title = { en = "Button label", pt = "Etiqueta do botão" },
    choose_icon_title = { en = "Select an icon", pt = "Selecionar ícone" },
    icon_picker_find = { en = "Search icons", pt = "Pesquisar ícones" },
    icon_picker_page = { en = "Page", pt = "Página" },
    icon_picker_all = { en = "All icons", pt = "Todos os ícones" },
    icon_picker_common = { en = "Common", pt = "Principais" },
    icon_picker_other = { en = "Other", pt = "Outros" },
    icon_picker_back = { en = "Back", pt = "Voltar" },
    icon_picker_next = { en = "Next", pt = "Seguinte" },
    icon_picker_clear = { en = "Clear search", pt = "Limpar pesquisa" },
    menu_full_list = { en = "All menu options", pt = "Todas as opções do menu" },
    koreader_options = { en = "KOReader options", pt = "Opções do KOReader" },
    original_menus = { en = "Original menus", pt = "Menus originais" },
    menu_dispatcher = { en = "Additional KOReader actions", pt = "Ações adicionais do KOReader" },
    menu_selected = { en = "Selected options", pt = "Opções selecionadas" },
    menu_action_only = { en = "This option is not executable", pt = "Esta opção não executa nenhuma ação" },

    current_icon = { en = "Icon", pt = "Ícone" },
    current_action = { en = "Action", pt = "Ação" },
    other_icons = { en = "Other icons", pt = "Outros ícones" },
    preferred_icons = { en = "Common icons", pt = "Ícones principais" },
    technical_actions = { en = "Advanced: manual action", pt = "Avançado: ação manual" },
    custom_slot_1 = { en = "Custom button 1", pt = "Botão personalizado 1" },
    custom_slot_2 = { en = "Custom button 2", pt = "Botão personalizado 2" },
    custom_slot_3 = { en = "Custom button 3", pt = "Botão personalizado 3" },
    no_action = { en = "No action selected", pt = "Sem ação selecionada" },
    show_frontlight = { en = "Show brightness control", pt = "Mostrar controlo de luminosidade" },
    show_warmth = { en = "Show light temperature control", pt = "Mostrar controlo de temperatura da luz" },
    always_open = { en = "Always open on this tab", pt = "Abrir sempre neste separador" },
    cancel = { en = "Cancel", pt = "Cancelar" },
    save = { en = "Save", pt = "Guardar" },
    unconfigured = { en = "Not configured", pt = "Não configurado" },
    action_search = { en = "File search", pt = "Pesquisa de ficheiros" },
    action_cloud = { en = "Cloud storage", pt = "Armazenamento na nuvem" },
    action_opds = { en = "OPDS catalog", pt = "Catálogo OPDS" },
    action_library = { en = "Bookshelf", pt = "Biblioteca" },
    icon_clean = { en = "Clean", pt = "Clean" },
    icon_menu = { en = "Menu", pt = "Menu" },
    icon_home = { en = "Library", pt = "Biblioteca" },
    icon_wifi = { en = "Wi-Fi", pt = "Wi-Fi" },
    icon_bluetooth = { en = "Bluetooth", pt = "Bluetooth" },
    icon_night = { en = "Night", pt = "Noite" },
    icon_rotate = { en = "Rotation", pt = "Rotação" },
    icon_restart = { en = "Restart", pt = "Reiniciar" },
    icon_sleep = { en = "Sleep", pt = "Suspender" },
    icon_search = { en = "Search", pt = "Pesquisa" },
    icon_usb = { en = "USB", pt = "USB" },
    icon_cloud = { en = "Cloud", pt = "Nuvem" },
    icon_exit = { en = "Exit", pt = "Sair" },
    icon_calibre = { en = "Calibre", pt = "Calibre" },
    icon_notion = { en = "Notion", pt = "Notion" },
    icon_opds = { en = "OPDS", pt = "OPDS" },
    icon_rss = { en = "RSS", pt = "RSS" },
    icon_streak = { en = "Reading streak", pt = "Sequência de leitura" },
    icon_store = { en = "Store", pt = "Loja" },
    icon_sun = { en = "Brightness", pt = "Luminosidade" },
    icon_thermometer = { en = "Temperature", pt = "Temperatura" },
    icon_appstore = { en = "Appstore", pt = "Appstore" },
    clean_enabled = { en = "Clean mode enabled.", pt = "Modo Clean ativado." },
    clean_disabled = { en = "Clean mode disabled.", pt = "Modo Clean desativado." },
    clean_mode = { en = "Clean Mode", pt = "Modo Clean" },
    clean_bar = { en = "Clean bar", pt = "Clean bar" },
    arrange_clean_bar_buttons = { en = "Arrange Clean bar buttons", pt = "Organizar botões da Clean bar" },
    custom_buttons = { en = "Custom buttons", pt = "Botões personalizados" },
    custom_button = { en = "Custom button", pt = "Botão personalizado" },
    configure_custom_button = { en = "Configure custom button", pt = "Configurar botão personalizado" },
    show_custom_button = { en = "Show in Clean bar", pt = "Mostrar na Clean bar" },
    reset_custom_button = { en = "Reset custom button", pt = "Repor botão personalizado" },
    custom_button_saved = { en = "Custom button saved.", pt = "Botão personalizado guardado." },
    custom_button_not_configured = { en = "This custom button is not configured yet.", pt = "Este botão personalizado ainda não está configurado." },
    kobo_bluetooth_missing = { en = "Kobo plugin Bluetooth is not available.", pt = "O Bluetooth do Kobo plugin não está disponível." },
    custom_button_action_missing = { en = "Custom button action not found.", pt = "A ação do botão personalizado não foi encontrada." },
    custom_button_help = { en = "Action type: event or module. Event uses a KOReader event name. Module calls a plugin/module method.", pt = "Tipo de ação: event ou module. Event usa um evento do KOReader. Module chama um método de plugin/módulo." },
    examples = { en = "Examples", pt = "Exemplos" },
    apply_example = { en = "Use this example", pt = "Usar este exemplo" },
    label = { en = "Label", pt = "Etiqueta" },
    icon = { en = "Icon", pt = "Ícone" },
    action_type = { en = "Action type", pt = "Tipo de ação" },
    event_name = { en = "Event name", pt = "Nome do evento" },
    event_argument = { en = "Event argument", pt = "Argumento do evento" },
    dispatch_method = { en = "Dispatch method", pt = "Método de envio" },
    plugin_or_module = { en = "Plugin/module", pt = "Plugin/módulo" },
    method_name = { en = "Method name", pt = "Nome do método" },
    choose_installed_plugin = { en = "Choose installed plugin/action", pt = "Escolher plugin/ação instalada" },
    no_plugin_actions_found = { en = "No installed plugin actions found.", pt = "Não foram encontradas ações de plugins instalados." },
    plugin_action_selected = { en = "Plugin action selected.", pt = "Ação de plugin selecionada." },
    choose_action = { en = "Choose action", pt = "Escolher ação" },
    installed_patches = { en = "Installed patches", pt = "Patches instalados" },
    patch_add_menu = { en = "Add to Clean menu", pt = "Adicionar ao Menu Clean" },
    patch_remove_menu = { en = "Remove from Clean menu", pt = "Remover do Menu Clean" },
    patch_use_button = { en = "Use in a Clean bar button", pt = "Usar num botão da Clean bar" },
    patch_use_this_button = { en = "Use in this button", pt = "Usar neste botão" },
    patch_no_items = { en = "No menu options here", pt = "Sem opções neste menu" },
    patch_no_patches = { en = "No installed patches found", pt = "Não foram encontrados patches instalados" },
    patch_no_long_search = { en = "Open one submenu at a time; only compatible menu actions can be used.", pt = "Abre um submenu de cada vez; apenas as ações compatíveis podem ser utilizadas." },
    choose_plugin_event = { en = "Installed plugin action", pt = "Ação de plugin instalado" },
    choose_icon = { en = "Choose icon", pt = "Escolher ícone" },
    edit_manual_action = { en = "Edit label, icon or manual action", pt = "Editar etiqueta, ícone ou ação manual" },
    no_menu_actions_found = { en = "No KOReader menu actions found.", pt = "Não foram encontradas ações dos menus do KOReader." },
    no_icons_found = { en = "No icons found.", pt = "Não foram encontrados ícones." },
    action_selected = { en = "Action selected.", pt = "Ação selecionada." },
    icon_selected = { en = "Icon selected.", pt = "Ícone selecionado." },
    builtin_actions = { en = "Built-in actions", pt = "Ações integradas" },
    installed_plugin_dirs = { en = "Installed plugins", pt = "Plugins instalados" },
    slider_style = { en = "Slider style", pt = "Estilo das barras" },
    slider_style_simple = { en = "Simple line", pt = "Linha simples" },
    slider_style_bold = { en = "Bold bar", pt = "Barra cheia" },
    slider_style_fine = { en = "Fine line", pt = "Linha fina" },
    slider_style_pill = { en = "Pill track", pt = "Cápsula" },
    slider_style_segmented = { en = "Segmented", pt = "Segmentada" },
    button_style = { en = "Button style", pt = "Estilo dos botões" },
    button_style_circle = { en = "Original", pt = "Padrão original" },
    button_style_pill = { en = "Pill", pt = "Pílula" },
    button_style_rounded_square = { en = "Rounded square", pt = "Quadrado arredondado" },
    button_style_segmented_bar = { en = "Segmented bar", pt = "Barra segmentada" },
    button_style_pressed = { en = "Pressed on", pt = "Premido" },
    button_style_premium = { en = "Premium / Stock", pt = "Premium / Stock" },
    button_style_clean_icons = { en = "Clean — icons only", pt = "Clean — só ícones" },
    search_menu = { en = "Search menu options", pt = "Pesquisar opções do menu" },
    search_hint = { en = "Type a menu or plugin name", pt = "Escreve um menu ou plugin" },
    search_empty = { en = "No matching menu options", pt = "Nenhuma opção encontrada" },
    arrange_clean_bar_buttons = { en = "Arrange Clean bar buttons", pt = "Organizar botões da Clean bar" },
    customize_menu = { en = "Customize menu", pt = "Personalizar menu" },
    customize_clean_menu = { en = "Customize Clean bar menu", pt = "Personalizar menu Clean bar" },
    backup_settings = { en = "Configuration backups", pt = "Cópias de segurança" },
    backup_save = { en = "Save configuration", pt = "Guardar configuração" },
    backup_restore = { en = "Restore configuration", pt = "Restaurar configuração" },
    backup_manage = { en = "Manage saved configurations", pt = "Gerir configurações guardadas" },
    backup_check = { en = "Check compatibility", pt = "Verificar compatibilidade" },
    backup_delete = { en = "Delete backup", pt = "Apagar backup" },
    backup_rename = { en = "Rename backup", pt = "Renomear cópia" },
    backup_renamed = { en = "Backup renamed:", pt = "Cópia renomeada:" },
    backup_confirm = { en = "Restore these settings and SVG icons? Incompatible actions will be kept but cannot run until available.", pt = "Restaurar estas definições e ícones SVG? As ações incompatíveis serão mantidas mas não funcionarão até estarem disponíveis." },
    backup_delete_confirm = { en = "Permanently delete this backup?", pt = "Eliminar definitivamente esta cópia?" },
    backup_empty = { en = "No saved configurations. Copy portable ZIPs to settings/cleanbar_backups/ to import them.", pt = "Sem configurações guardadas. Para importar, copia os ZIPs para settings/cleanbar_backups/." },
    backup_saved = { en = "Configuration saved:", pt = "Configuração guardada:" },
    backup_restored = { en = "Configuration restored. Reopen the top bar to see the new icons and order:", pt = "Configuração restaurada. Fecha e reabre a barra superior para atualizar os ícones e a ordem:" },
    backup_deleted = { en = "Backup deleted.", pt = "Cópia eliminada." },
    clean_bar_settings_entry = { en = "⚙  Cleanbar settings", pt = "⚙  Definições Cleanbar" },
    arrange_clean_menu = { en = "Arrange menu items", pt = "Organizar itens do menu" },
    arrange_clean_menu_empty = { en = "Select at least two menu items first.", pt = "Seleciona primeiro pelo menos dois itens do menu." },
    select_all = { en = "Select all", pt = "Selecionar tudo" },
    deselect_all = { en = "Deselect all", pt = "Desmarcar tudo" },
    reset_default = { en = "Reset default Clean menu", pt = "Repor menu Clean predefinido" },
    no_items_selected = { en = "No custom items selected yet. Open Customize menu to choose them.", pt = "Ainda não escolheste itens. Abre Personalizar menu para os escolher." },
    menu_source_unknown = { en = "Menu", pt = "Menu" },
    custom_menu_tab = { en = "Custom menu", pt = "Menu personalizado" },
    home_library_tab = { en = "Home", pt = "Biblioteca" },
    fallback_library = { en = "Library / file browser", pt = "Biblioteca / explorador de ficheiros" },
    fallback_search = { en = "File search", pt = "Pesquisa de ficheiros" },
    fallback_cloud = { en = "Cloud storage", pt = "Nuvem" },
    fallback_opds = { en = "OPDS catalog", pt = "Catálogo OPDS" },
}

local function isPortugueseUI()
    -- KOReader loads its selected UI locale from the 'language' setting.
    -- Always prefer that over the device's system locale/environment.
    local language = G_reader_settings:readSetting("language")
    if type(language) == "string" and language ~= "" then
        return language:lower():match("^pt") ~= nil
    end
    -- Default KOReader language is English when no language is saved.
    return false
end

local function CT(key)
    local entry = custom_strings[key]
    if not entry then
        return key
    end
    if isPortugueseUI() then
        return entry.pt
    end
    return entry.en
end

local button_label_strings = {
    wifi = { en = "Wi-Fi", pt = "Wi-Fi" },
    night = { en = "Night", pt = "Noite" },
    rotate = { en = "Rotate", pt = "Rodar" },
    clean = { en = "Clean", pt = "Clean" },
    kobo_bluetooth = { en = "BT", pt = "BT" },
    custom1 = { en = "Custom 1", pt = "Custom 1" },
    custom2 = { en = "Custom 2", pt = "Custom 2" },
    custom3 = { en = "Custom 3", pt = "Custom 3" },
    usb = { en = "USB", pt = "USB" },
    restart = { en = "Restart", pt = "Reiniciar" },
    exit = { en = "Exit", pt = "Sair" },
    sleep = { en = "Sleep", pt = "Suspender" },
    search = { en = "Search", pt = "Pesquisa" },
    quickrss = { en = "QuickRSS", pt = "QuickRSS" },
    cloud = { en = "Cloud", pt = "Nuvem" },
    zlibrary = { en = "Z-Lib", pt = "Z-Lib" },
    calibre = { en = "Calibre", pt = "Calibre" },
    notion = { en = "NotionSync", pt = "NotionSync" },
    streak = { en = "Streak", pt = "Sequência" },
    opds = { en = "OPDS", pt = "OPDS" },
}

local function BL(key)
    local entry = button_label_strings[key]
    if not entry then
        return key
    end
    if isPortugueseUI() then
        return entry.pt
    end
    return entry.en
end

loadConfig()

-- ============================================================
-- Kobo plugin Bluetooth integration
-- ============================================================

local function findKoboPluginBluetooth()
    if not (Device.isKobo and Device:isKobo()) then
        return nil
    end

    local function scanHost(host)
        if type(host) ~= "table" then
            return nil
        end

        local direct = host.kobo_bluetooth or host.KoboBluetooth
        if type(direct) == "table" and (type(direct.toggleBluetooth) == "function" or type(direct.onBluetoothAction) == "function") then
            return direct
        end

        for _, child in pairs(host) do
            if type(child) == "table" then
                if type(child.kobo_bluetooth) == "table" then
                    local bt = child.kobo_bluetooth
                    if type(bt.toggleBluetooth) == "function" or type(bt.onBluetoothAction) == "function" then
                        return bt
                    end
                end
                if child.name == "kobo_bluetooth" and (type(child.toggleBluetooth) == "function" or type(child.onBluetoothAction) == "function") then
                    return child
                end
            end
        end

        return nil
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    local bt = scanHost(reader)
    if bt then return bt end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager.instance
    bt = scanHost(fm)
    if bt then return bt end

    return nil
end

local function isKoboPluginBluetoothAvailable()
    local bt = findKoboPluginBluetooth()
    if not bt then
        return false
    end
    if type(bt.isDeviceSupported) == "function" then
        local ok, supported = pcall(function()
            return bt:isDeviceSupported()
        end)
        return ok and supported == true
    end
    return true
end

local function isKoboPluginBluetoothOn()
    local bt = findKoboPluginBluetooth()
    if not bt or type(bt.isBluetoothEnabled) ~= "function" then
        return false
    end
    local ok, enabled = pcall(function()
        return bt:isBluetoothEnabled()
    end)
    return ok and enabled == true
end

local function toggleKoboPluginBluetooth(touch_menu)
    local bt = findKoboPluginBluetooth()
    if not bt then
        showInfo(CT("kobo_bluetooth_missing"))
        return
    end

    local ok = false
    if type(bt.toggleBluetooth) == "function" then
        ok = pcall(function()
            bt:toggleBluetooth(true)
        end)
    elseif type(bt.onBluetoothAction) == "function" then
        ok = pcall(function()
            bt:onBluetoothAction("toggle")
        end)
    end

    if not ok then
        -- Fallback through the dispatcher-style event registered by kobo.koplugin.
        ok = pcall(function()
            UIManager:broadcastEvent(Event:new("BluetoothAction", "toggle"))
        end)
    end

    if not ok then
        showInfo(CT("kobo_bluetooth_missing"))
        return
    end

    UIManager:scheduleIn(1, function()
        refreshCleanBarPanel(touch_menu)
    end)
end

-- ============================================================
-- Minimal slider widget: thin line + filled segment + round thumb
-- ============================================================

local ThinSliderWidget = Widget:extend{
    width = Screen:scaleBySize(400),
    height = Screen:scaleBySize(48),
    percentage = 0,
    track_height = Screen:scaleBySize(2),
    fill_height = Screen:scaleBySize(7),
    knob_size = Screen:scaleBySize(28),
    trackcolor = Blitbuffer.COLOR_BLACK,
    fillcolor = Blitbuffer.COLOR_BLACK,
    knobcolor = Blitbuffer.COLOR_BLACK,
}

function ThinSliderWidget:getSize()
    return Geom:new{
        w = self.width,
        h = self.height,
    }
end

function ThinSliderWidget:setPercentage(percentage)
    self.percentage = math.max(0, math.min(1, percentage or 0))
end

function ThinSliderWidget:getPercentageFromPosition(pos)
    if not self.dimen then return nil end
    local knob_size = self.knob_size or 0
    local usable_width = math.max(self.width - knob_size, 1)
    local x = pos.x - self.dimen.x - knob_size / 2
    local percentage = x / usable_width
    if BD.mirroredUILayout() then
        percentage = 1 - percentage
    end
    return math.max(0, math.min(1, percentage))
end

function ThinSliderWidget:paintTo(bb, x, y)
    local size = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new{
            x = x,
            y = y,
            w = size.w,
            h = size.h,
        }
    else
        self.dimen.x = x
        self.dimen.y = y
        self.dimen.w = size.w
        self.dimen.h = size.h
    end

    local percentage = math.max(0, math.min(1, self.percentage or 0))
    if BD.mirroredUILayout() then
        percentage = 1 - percentage
    end

    local knob_size = self.knob_size
    local knob_radius = math.floor(knob_size / 2)
    local usable_width = math.max(self.width - knob_size, 1)
    local center_x = x + knob_radius + Math.round(usable_width * percentage)

    local track_h = math.max(1, self.track_height)
    local fill_h = math.max(track_h, self.fill_height)
    local track_y = y + Math.round((self.height - track_h) / 2)
    local fill_y = y + Math.round((self.height - fill_h) / 2)
    local knob_y = y + Math.round((self.height - knob_size) / 2)
    local active_w = math.max(0, center_x - x)
    local style = self.style or "simple"

    if style == "clean_capsule" then
        -- Modern monochrome capsule, designed for both existing button styles.
        -- The knob is white with a black outline, and progress is solid black.
        local pill_h = math.max(Screen:scaleBySize(16), track_h)
        local pill_y = y + Math.round((self.height - pill_h) / 2)
        bb:paintRoundedRect(x, pill_y, self.width, pill_h,
            Blitbuffer.COLOR_LIGHT_GRAY, math.floor(pill_h / 2))
        if active_w > 0 then
            bb:paintRoundedRect(x, pill_y, active_w, pill_h,
                Blitbuffer.COLOR_BLACK, math.floor(pill_h / 2))
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size,
            Blitbuffer.COLOR_BLACK, knob_radius)
        local ring = math.max(Screen:scaleBySize(2), 1)
        local inner_size = math.max(2, knob_size - ring * 2)
        bb:paintRoundedRect(center_x - math.floor(inner_size / 2),
            y + Math.round((self.height - inner_size) / 2),
            inner_size, inner_size, Blitbuffer.COLOR_WHITE, math.floor(inner_size / 2))

    elseif style == "bold" then
        -- Chunkier rounded bar, closer to a modern quick-settings control.
        local bold_track_h = math.max(track_h, Screen:scaleBySize(6))
        local bold_fill_h = math.max(fill_h, Screen:scaleBySize(10))
        local bold_track_y = y + Math.round((self.height - bold_track_h) / 2)
        local bold_fill_y = y + Math.round((self.height - bold_fill_h) / 2)
        bb:paintRoundedRect(x, bold_track_y, self.width, bold_track_h, Blitbuffer.COLOR_LIGHT_GRAY, math.floor(bold_track_h / 2))
        if active_w > 0 then
            bb:paintRoundedRect(x, bold_fill_y, active_w, bold_fill_h, self.fillcolor, math.floor(bold_fill_h / 2))
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size, self.knobcolor, knob_radius)

    elseif style == "fine" then
        -- Very light line with a smaller thumb; useful when the panel should
        -- look more airy and take less visual weight.
        local fine_track_h = math.max(1, Screen:scaleBySize(1))
        local fine_fill_h = math.max(fine_track_h, Screen:scaleBySize(4))
        local fine_track_y = y + Math.round((self.height - fine_track_h) / 2)
        local fine_fill_y = y + Math.round((self.height - fine_fill_h) / 2)
        bb:paintRect(x, fine_track_y, self.width, fine_track_h, self.trackcolor)
        if active_w > 0 then
            bb:paintRect(x, fine_fill_y, active_w, fine_fill_h, self.fillcolor)
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size, self.knobcolor, knob_radius)

    elseif style == "pill" then
        -- Full-height capsule with a white thumb and black ring, inspired by
        -- device quick setting sliders but kept monochrome-friendly.
        local pill_h = math.max(Screen:scaleBySize(14), fill_h)
        local pill_y = y + Math.round((self.height - pill_h) / 2)
        bb:paintRoundedRect(x, pill_y, self.width, pill_h, Blitbuffer.COLOR_LIGHT_GRAY, math.floor(pill_h / 2))
        if active_w > 0 then
            bb:paintRoundedRect(x, pill_y, active_w, pill_h, self.fillcolor, math.floor(pill_h / 2))
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size, Blitbuffer.COLOR_BLACK, knob_radius)
        local inner = math.max(Screen:scaleBySize(10), knob_size - Screen:scaleBySize(8))
        local inner_radius = math.floor(inner / 2)
        bb:paintRoundedRect(center_x - inner_radius, y + Math.round((self.height - inner) / 2), inner, inner, Blitbuffer.COLOR_WHITE, inner_radius)

    elseif style == "premium" then
        -- Matching e-ink track: subtle inactive grey, visible black fill.
        local bar_h = Screen:scaleBySize(4)
        local bar_y = y + Math.round((self.height - bar_h) / 2)
        bb:paintRoundedRect(x, bar_y, self.width, bar_h, Blitbuffer.COLOR_LIGHT_GRAY, math.floor(bar_h / 2))
        if active_w > 0 then
            bb:paintRoundedRect(x, bar_y, active_w, bar_h, Blitbuffer.COLOR_BLACK, math.floor(bar_h / 2))
        end
        local thumb = Screen:scaleBySize(22)
        local thumb_x = center_x - math.floor(thumb / 2)
        local thumb_y = y + math.floor((self.height - thumb) / 2)
        bb:paintRoundedRect(thumb_x, thumb_y, thumb, thumb, Blitbuffer.COLOR_BLACK, math.floor(thumb / 2))
    elseif style == "segmented" then
        -- A stepped segmented bar. Good on e-ink because each level is very
        -- visible and does not rely on subtle greys.
        local segments = 14
        local gap = Screen:scaleBySize(3)
        local seg_h = math.max(Screen:scaleBySize(8), fill_h)
        local seg_y = y + Math.round((self.height - seg_h) / 2)
        local seg_w = math.max(1, math.floor((self.width - gap * (segments - 1)) / segments))
        local filled_segments = math.floor(percentage * segments + 0.5)
        for i = 1, segments do
            local sx = x + (i - 1) * (seg_w + gap)
            local color = i <= filled_segments and self.fillcolor or Blitbuffer.COLOR_LIGHT_GRAY
            bb:paintRoundedRect(sx, seg_y, seg_w, seg_h, color, math.floor(seg_h / 2))
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size, self.knobcolor, knob_radius)

    else
        -- Reference/simple style: thin line + thicker active segment.
        bb:paintRect(x, track_y, self.width, track_h, self.trackcolor)
        if active_w > 0 then
            bb:paintRect(x, fill_y, active_w, fill_h, self.fillcolor)
        end
        bb:paintRoundedRect(center_x - knob_radius, knob_y, knob_size, knob_size, self.knobcolor, knob_radius)
    end
end

-- ============================================================
-- Button definitions (data-driven)
-- ============================================================


local custom_button_slots = { "custom1", "custom2", "custom3" }

local function isCustomButtonId(id)
    return id == "custom1" or id == "custom2" or id == "custom3"
end

local function getCustomButtonConfig(id)
    if not isCustomButtonId(id) then
        return nil
    end
    if type(config.custom_buttons) ~= "table" then
        config.custom_buttons = {}
    end
    if type(config.custom_buttons[id]) ~= "table" then
        config.custom_buttons[id] = {}
    end
    local cfg = config.custom_buttons[id]
    local defaults = config_default.custom_buttons[id] or {}
    for key, value in pairs(defaults) do
        if cfg[key] == nil then
            cfg[key] = value
        end
    end
    return cfg
end

local function customButtonDisplayLabel(id)
    local cfg = getCustomButtonConfig(id)
    if cfg and cfg.auto_label_key and not cfg.label_manually_selected then
        return CT(cfg.auto_label_key)
    end
    if cfg and type(cfg.label) == "string" and cfg.label ~= "" then
        if cfg.label == "Custom 1" and id == "custom1" then return CT("custom_slot_1") end
        if cfg.label == "Custom 2" and id == "custom2" then return CT("custom_slot_2") end
        if cfg.label == "Custom 3" and id == "custom3" then return CT("custom_slot_3") end
        return cfg.label
    end
    return CT(({ custom1 = "custom_slot_1", custom2 = "custom_slot_2", custom3 = "custom_slot_3" })[id])
end

local function parseCustomEventArg(value)
    if value == nil then
        return nil, false
    end
    if type(value) ~= "string" then
        return value, true
    end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" then
        return nil, false
    end
    local lower = text:lower()
    if lower == "true" then return true, true end
    if lower == "false" then return false, true end
    if lower == "nil" or lower == "null" then return nil, true end
    local number = tonumber(text)
    if number ~= nil then return number, true end
    return text, true
end

local function findPluginOrModuleObject(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local function matches(child)
        if type(child) ~= "table" then
            return false
        end
        return child.name == name
            or child.id == name
            or child.title == name
            or child["_name"] == name
    end

    local function scanHost(host)
        if type(host) ~= "table" then
            return nil
        end
        if type(host[name]) == "table" then
            return host[name]
        end
        for _, child in pairs(host) do
            if matches(child) then
                return child
            end
        end
        return nil
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local found = scanHost(ok_reader and ReaderUI.instance)
    if found then return found end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    found = scanHost(ok_fm and FileManager.instance)
    if found then return found end

    local ok_required, required = pcall(require, name)
    if ok_required and type(required) == "table" then
        return required
    end

    return nil
end


local function cbTrim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function cbSafeText(value)
    if type(value) == "string" then
        return value
    elseif type(value) == "function" then
        local ok, result = pcall(value)
        if ok and type(result) == "string" then
            return result
        end
    end
    return nil
end

local function cbMenuItemLabel(item)
    if type(item) ~= "table" then
        return nil
    end
    local text = cbSafeText(item.text) or cbSafeText(item.text_func)
    if type(text) == "string" then
        text = cbTrim(text)
    end
    if text and text ~= "" then
        return text
    end
    return nil
end

local function cbTabLabel(tab, index)
    if type(tab) ~= "table" then
        return CT("menu_source_unknown") .. " " .. tostring(index)
    end
    local text = cbSafeText(tab.text) or cbSafeText(tab.name) or cbSafeText(tab.title)
    if type(text) == "string" then
        text = cbTrim(text)
    end
    if text and text ~= "" then
        return text
    end
    if type(tab.icon) == "string" and tab.icon ~= "" then
        return tab.icon
    end
    return CT("menu_source_unknown") .. " " .. tostring(index)
end

-- The old exhaustive "KOReader menu item" index was removed deliberately.
-- Existing saved legacy shortcuts are left in preferences but are not invoked
-- through the unsafe 10-level dynamic traversal. New patch shortcuts use a
-- targeted, one-path-at-a-time resolver instead.
local resolveSavedPatchMenuItem
local resolveSavedPluginMenuItem
local resolveCleanNativeShortcut
local CleanBarBackup -- portable backup dependency guard, assigned later

local function runCustomButtonAction(id, touch_menu)
    local cfg = getCustomButtonConfig(id)
    if not cfg then
        return
    end
    -- A restored button remains visible, but cannot call an absent plugin or
    -- patch. The user's saved configuration is kept for later reinstallation.
    if CleanBarBackup and not CleanBarBackup.actionAvailable(cfg) then
        showInfo(CT("custom_button_action_missing"))
        return
    end

    local action_type = (cfg.action_type or "event"):lower()
    if action_type == "plugin_menu" then
        local record = config.clean_plugin_menu_actions[cfg.menu_key or ""]
        local item = record and resolveSavedPluginMenuItem(record)
        if item and touch_menu and type(touch_menu.onMenuSelect) == "function" then
            local ok = pcall(touch_menu.onMenuSelect, touch_menu, item)
            if ok then return end
        end
        showInfo(CT("custom_button_action_missing"))
        return
    elseif action_type == "patch" then
        local record = config.clean_patch_actions[cfg.menu_key or ""]
        local item = record and resolveSavedPatchMenuItem(record)
        if item and touch_menu and type(touch_menu.onMenuSelect) == "function" then
            local ok = pcall(touch_menu.onMenuSelect, touch_menu, item)
            if ok then return end
        end
        showInfo(CT("custom_button_action_missing"))
        return
    elseif action_type == "menu" then
        -- Only shortcuts created by this safe picker are executable. Retire
        -- old recursive-menu shortcuts without changing the stored settings.
        local key = cfg.menu_key
        if type(key) == "string" and key:match("^cleanbar:native:v10:")
            and resolveCleanNativeShortcut then
            local item = resolveCleanNativeShortcut(key:sub(#"cleanbar:native:v10:" + 1))
            if item and touch_menu and type(touch_menu.onMenuSelect) == "function" then
                local ok = pcall(touch_menu.onMenuSelect, touch_menu, item)
                if ok then return end
            end
        end
        showInfo(CT("custom_button_action_missing"))
        return
    end

    if action_type == "event" then
        local event_name = cfg.event or ""
        event_name = event_name:match("^%s*(.-)%s*$")
        if event_name == "" then
            showInfo(CT("custom_button_not_configured"))
            return
        end
        local arg, has_arg = parseCustomEventArg(cfg.event_arg)
        local event = has_arg and Event:new(event_name, arg) or Event:new(event_name)
        if (cfg.dispatch or "broadcast"):lower() == "send" then
            UIManager:sendEvent(event)
        else
            UIManager:broadcastEvent(event)
        end
        return
    end

    if action_type == "module" or action_type == "plugin" then
        local obj = findPluginOrModuleObject(cfg.plugin or "")
        local method = cfg.method or ""
        method = method:match("^%s*(.-)%s*$")
        if obj and method ~= "" and type(obj[method]) == "function" then
            local ok = pcall(function()
                obj[method](obj)
            end)
            if ok then
                return
            end
        end
        showInfo(CT("custom_button_action_missing"))
        return
    end

    showInfo(CT("custom_button_action_missing"))
end

local button_defs = {
    wifi = {
        icon = "quick_wifi",
        label = "Wi-Fi",
        label_func = function()
            -- Keep the button label stable. Long SSIDs are still visible in the
            -- status/connection state, but they should not resize or shift the
            -- action icon row.
            return BL("wifi")
        end,
        active_func = function() return NetworkMgr:isWifiOn() end,
        callback = function(touch_menu)
            if NetworkMgr:isWifiOn() then
                NetworkMgr:toggleWifiOff()
            else
                NetworkMgr:toggleWifiOn()
            end
            UIManager:scheduleIn(1, function()
                if touch_menu.item_table and touch_menu.item_table.panel then
                    touch_menu:updateItems(1)
                end
            end)
        end,
    },
    night = {
        icon = "quick_nightmode",
        label_func = function() return BL("night") end,
        active_func = function() return G_reader_settings:isTrue("night_mode") end,
        callback = function(touch_menu)
            local night_mode = G_reader_settings:isTrue("night_mode")
            Screen:toggleNightMode()
            UIManager:ToggleNightMode(not night_mode)
            G_reader_settings:saveSetting("night_mode", not night_mode)
            touch_menu:updateItems(1)
            UIManager:setDirty("all", "full")
        end,
    },
    rotate = {
        icon = "quick_rotate",
        label_func = function() return BL("rotate") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("SwapRotation"))
        end,
    },
    clean = {
        -- Toggles the clean-layout mode.
        icon = "Clean",
        label_func = function() return BL("clean") end,
        active_func = function()
            return config.clean_mode
        end,
        callback = function(touch_menu)
            config.clean_mode = not config.clean_mode
            saveConfig()

            if refreshCleanModeMenu and touch_menu and refreshCleanModeMenu(touch_menu) then
                return
            end

            -- Fallback for unusual KOReader builds: no warning, just redraw/close.
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            elseif touch_menu and UIManager.close then
                UIManager:close(touch_menu)
            end
        end,
    },
    kobo_bluetooth = {
        icon = "quick_bluetooth",
        label_func = function() return BL("kobo_bluetooth") end,
        available_func = function() return isKoboPluginBluetoothAvailable() end,
        active_func = function() return isKoboPluginBluetoothOn() end,
        callback = function(touch_menu)
            toggleKoboPluginBluetooth(touch_menu)
        end,
    },
    custom1 = {
        icon = function()
            local cfg = getCustomButtonConfig("custom1")
            return (cfg and cfg.icon ~= "" and cfg.icon) or "quick_search"
        end,
        label_func = function() return customButtonDisplayLabel("custom1") end,
        callback = function(touch_menu)
            runCustomButtonAction("custom1", touch_menu)
        end,
    },
    custom2 = {
        icon = function()
            local cfg = getCustomButtonConfig("custom2")
            return (cfg and cfg.icon ~= "" and cfg.icon) or "quick_cloud"
        end,
        label_func = function() return customButtonDisplayLabel("custom2") end,
        callback = function(touch_menu)
            runCustomButtonAction("custom2", touch_menu)
        end,
    },
    custom3 = {
        icon = function()
            local cfg = getCustomButtonConfig("custom3")
            return (cfg and cfg.icon ~= "" and cfg.icon) or "quick_opds"
        end,
        label_func = function() return customButtonDisplayLabel("custom3") end,
        callback = function(touch_menu)
            runCustomButtonAction("custom3", touch_menu)
        end,
    },
    usb = {
        icon = "quick_usb",
        label_func = function() return BL("usb") end,
        callback = function()
            if Device:canToggleMassStorage() then
                UIManager:broadcastEvent(Event:new("RequestUSBMS"))
            end
        end,
    },
    restart = {
        icon = "quick_restart",
        label_func = function() return BL("restart") end,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Are you sure you want to restart KOReader?"),
                ok_text = _("Restart"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            })
        end,
    },
    exit = {
        icon = "quick_exit",
        label_func = function() return BL("exit") end,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Are you sure you want to exit KOReader?"),
                ok_text = _("Exit"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Exit"))
                end,
            })
        end,
    },
    sleep = {
        icon = "quick_sleep",
        label_func = function() return BL("sleep") end,
        callback = function()
            if Device:canSuspend() then
                UIManager:broadcastEvent(Event:new("RequestSuspend"))
            elseif Device:canPowerOff() then
                UIManager:broadcastEvent(Event:new("RequestPowerOff"))
            end
        end,
    },
    search = {
        icon = "quick_search",
        label_func = function() return BL("search") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowFileSearch"))
        end,
    },
    quickrss = {
        icon = "quick_quickrss",
        label_func = function() return BL("quickrss") end,
        callback = function()
            local ok, QuickRSSUI = pcall(require, "modules/ui/feed_view")
            if ok and QuickRSSUI then
                local view = QuickRSSUI:new{}
                UIManager:show(view)
                view:_fetch()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("QuickRSS plugin is not installed."),
                })
            end
        end,
    },
    cloud = {
        icon = "quick_cloud",
        label_func = function() return BL("cloud") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowCloudStorage"))
        end,
    },
    zlibrary = {
        icon = "quick_zlib",
        label_func = function() return BL("zlibrary") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("ZlibrarySearch"))
        end,
    },
    calibre = {
        icon = "quick_calibre",
        label_func = function() return BL("calibre") end,
        active_func = function()
            local CW = package.loaded["wireless"]
            return CW ~= nil and CW.calibre_socket ~= nil
        end,
        callback = function(touch_menu)
            local CW = package.loaded["wireless"]
            if CW and CW.calibre_socket ~= nil then
                UIManager:broadcastEvent(Event:new("CloseWirelessConnection"))
            else
                UIManager:broadcastEvent(Event:new("StartWirelessConnection"))
            end
            UIManager:scheduleIn(1, function()
                touch_menu:updateItems(1)
            end)
        end,
    },
	notion = {
        icon = "quick_notion",
        label_func = function() return BL("notion") end,
        callback = function()
            local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
            local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
            local ui = (ok_r and ReaderUI.instance) or (ok_f and FileManager.instance)
            if ui and ui.NotionSync then
                ui.NotionSync:onSyncAllBooksRequested()
            end
        end,
    },
    streak = {
        icon = "quick_streak",
        label_func = function() return BL("streak") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowReadingStreakCalendar"))
        end,
    },
    opds = {
        icon = "quick_opds",
        label_func = function() return BL("opds") end,
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowOPDSCatalog"))
        end,
    },		  
}

-- Display names for the settings menu
local button_display_names = {
    wifi = BL("wifi"),
    night = isPortugueseUI() and "Modo noturno" or _("Night mode"),
    rotate = BL("rotate"),
    clean = BL("clean"),
    kobo_bluetooth = BL("kobo_bluetooth"),
    custom1 = customButtonDisplayLabel("custom1"),
    custom2 = customButtonDisplayLabel("custom2"),
    custom3 = customButtonDisplayLabel("custom3"),
    usb = BL("usb"),
    restart = BL("restart"),
    exit = BL("exit"),
    sleep = BL("sleep"),
    search = isPortugueseUI() and "Pesquisa de ficheiros" or _("File search"),
    quickrss = BL("quickrss"),
    cloud = isPortugueseUI() and "Nuvem" or _("Cloud storage"),
    zlibrary = isPortugueseUI() and "Z-Library" or _("Z-Library"),
    calibre = BL("calibre"),
	notion   = isPortugueseUI() and "Notion" or _("Notion"),
    streak   = BL("streak"),
    opds     = BL("opds"),
}

local function isButtonAvailable(id)
    local def = button_defs[id]
    if not def then
        return false
    end
    if type(def.available_func) == "function" then
        local ok, available = pcall(def.available_func)
        return ok and available == true
    end
    return true
end

-- ============================================================
-- Panel builder — returns panel widget + refs for tap handling
-- ============================================================

local function createCleanBarPanel(touch_menu)
    local panel_width = touch_menu.item_width
    local padding = Screen:scaleBySize(20)
    local inner_width = panel_width - padding * 2
    local powerd = Device:getPowerDevice()

    -- Refs table: stored on touch_menu for gesture handling.
    local refs = { buttons = {}, controls = {} }

    local function valueToPercentage(value, min_value, max_value)
        local range = math.max(max_value - min_value, 1)
        return math.max(0, math.min(1, (value - min_value) / range))
    end

    -- ----- Status row: clock on the left, symbols/battery on the right -----

    local function makeStatusRow()
        local status_font = Font:getFace("ffont")
        local status_icon_size = Screen:scaleBySize(26)

        local time_text = BD.wrap(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")))
        local time_widget = TextWidget:new{
            text = time_text,
            face = status_font,
            max_width = math.floor(inner_width / 2),
        }

        local right_status = HorizontalGroup:new{ align = "center" }

        if NetworkMgr:isWifiOn() then
            table.insert(right_status, IconWidget:new{
                icon = "quick_wifi",
                width = status_icon_size,
                height = status_icon_size,
                alpha = true,
            })
            table.insert(right_status, HorizontalSpan:new{ width = Screen:scaleBySize(8) })
        end

        if Device:hasBattery() then
            local batt_lvl = powerd:getCapacity()
            local batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), batt_lvl)
            table.insert(right_status, TextWidget:new{
                text = BD.wrap(batt_symbol) .. BD.wrap(tostring(batt_lvl) .. "%"),
                face = status_font,
                max_width = math.floor(inner_width / 2),
            })
        end

        local time_size = time_widget:getSize()
        local status_size = right_status:getSize()
        local gap = math.max(Screen:scaleBySize(8), inner_width - time_size.w - status_size.w)

        return HorizontalGroup:new{
            align = "center",
            time_widget,
            HorizontalSpan:new{ width = gap },
            right_status,
        }
    end

    -- ----- Top row: action buttons -----

    -- No visual indicator: the icon row remains swipeable when it has
    -- more than six visible actions, with the original row dimensions.

    local visible_buttons = {}
    for _, id in ipairs(config.button_order) do
        if config.show_buttons[id] and isButtonAvailable(id) then
            table.insert(visible_buttons, { id = id, def = button_defs[id] })
        end
    end

    local num_buttons = #visible_buttons
    -- Six stable positions form a horizontally swipable viewport. Unlike
    -- page navigation, swipes move through an overlapping sequence; the
    -- action order and saved preferences are left untouched.
    local row_visible_count = math.min(num_buttons, 6)
    local row_max_offset = math.max(0, num_buttons - row_visible_count)
    local row_offset = math.max(0, math.min(row_max_offset,
        math.floor(tonumber(touch_menu._clean_bar_button_offset) or 0)))
    touch_menu._clean_bar_button_offset = row_offset
    if row_max_offset > 0 then
        refs.icon_row_scroll = {
            offset = row_offset, max_offset = row_max_offset,
            visible_count = row_visible_count, total_count = num_buttons,
        }
    end
    local top_row = HorizontalGroup:new{ align = "center" }

    if num_buttons > 0 then
        -- Every action gets a fixed-width slot. This prevents labels with
        -- different lengths, such as a Wi-Fi SSID, from pushing the icon row
        -- out of alignment.
        local button_style = valid_button_styles[config.button_style] and config.button_style or "circle"
        local min_btn_gap = Screen:scaleBySize(6)
        local btn_gap = button_style == "segmented_bar" and 0 or Screen:scaleBySize(16)
        local button_slot_width = math.floor((inner_width - btn_gap * math.max(row_visible_count - 1, 0)) / row_visible_count)
        if button_slot_width < Screen:scaleBySize(76)
            and button_style ~= "segmented_bar" then
            btn_gap = min_btn_gap
            button_slot_width = math.floor((inner_width - btn_gap * math.max(row_visible_count - 1, 0)) / row_visible_count)
        end
        -- Slightly larger action targets, capped inside each fixed-width column.
        -- Applies to all three styles without changing button actions.
        local action_btn_size = math.min(button_slot_width,
            math.max(Screen:scaleBySize(60),
                math.min(Screen:scaleBySize(106), math.floor(button_slot_width * 0.92))))
        if button_style == "segmented_bar" then
            -- The segmented style is a single square bar split into equal cells.
            -- Each cell gets the full slot width so icon alignment never depends on labels.
            action_btn_size = math.max(Screen:scaleBySize(58), math.min(Screen:scaleBySize(74), button_slot_width))
        end
        local icon_size = math.floor(action_btn_size * 0.65)
        -- Reduce button captions only (22 -> 18, long captions 18 -> 16).
        -- Leave clock, sliders and all other UI fonts untouched.
        local label_font = Font:getFace("xx_smallinfofont")
        local compact_label_font = Font:getFace("xx_smallinfofont", 16)
        local normal_border = Screen:scaleBySize(2)
        local thin_border = math.max(1, Screen:scaleBySize(1))
        local label_max_width = button_slot_width

        local fixed_label_slot_h = Screen:scaleBySize(30)
        local fixed_icon_slot_h = action_btn_size
        local fixed_button_gap = Screen:scaleBySize(5)

        local function normalizeLabel(text)
            -- Do not let KOReader truncate words with ellipses. Some labels are
            -- intentionally shortened to stable, readable aliases.
            local visible_label = text or ""
            local lower = string.lower(visible_label)
            if lower == "storefront" or lower == "store front" then
                return "Store"
            elseif lower == "bluetooth" then
                return "BT"
            elseif lower == "configuração" or lower == "configuracao" then
                return "Config"
            elseif lower == "reiniciar" then
                return "Rein."
            end
            return visible_label
        end

        local function makeFixedLabel(label_text)
            local visible_label = normalizeLabel(label_text)
            local use_compact_label = string.len(visible_label or "") > 5
            local label = TextWidget:new{
                text = visible_label,
                face = use_compact_label and compact_label_font or label_font,
                max_width = label_max_width,
            }
            return CenterContainer:new{
                dimen = Geom:new{ w = button_slot_width, h = fixed_label_slot_h },
                label,
            }
        end

        -- These are newly packaged outline variants, leaving all original icons
        -- untouched. Unrecognised/personal icons retain their saved appearance.
        local thin_action_icons = {
            quick_wifi = "cleanbar/cleanbar_thin_wifi",
            quick_nightmode = "cleanbar/cleanbar_thin_night",
            quick_rotate = "cleanbar/cleanbar_thin_rotate",
            Clean = "cleanbar/cleanbar_thin_clean",
            quick_bluetooth = "cleanbar/cleanbar_thin_bluetooth",
            quick_exit = "cleanbar/cleanbar_thin_exit",
            quick_restart = "cleanbar/cleanbar_thin_restart",
            quick_sleep = "cleanbar/cleanbar_thin_sleep",
            quick_search = "cleanbar/cleanbar_thin_search",
            quick_cloud = "cleanbar/cleanbar_thin_cloud",
            quick_zlib = "cleanbar/cleanbar_thin_store",
            Koreaderrightqq = "cleanbar/cleanbar_thin_book",
            quick_usb = "cleanbar/cleanbar_thin_usb",
            quick_calibre = "cleanbar/cleanbar_thin_calibre",
            quick_calibre_dark = "cleanbar/cleanbar_thin_calibre",
            quick_opds = "cleanbar/cleanbar_thin_opds",
            quick_notion = "cleanbar/cleanbar_thin_notion",
            quick_streak = "cleanbar/cleanbar_thin_streak",
            quick_quickrss = "cleanbar/cleanbar_thin_rss",
        }
        -- Clean style: thicken the selected SVG's strokes lazily, without
        -- requiring a second icon choice or adding a filled button face.
        local function makeIcon(icon_name, invert_icon, icon_alpha, bold_clean)
            local resolved = thin_action_icons[icon_name] or icon_name
            local bold_file = bold_clean and cleanBarBoldIconPath(resolved) or nil
            local params = {
                width = icon_size,
                height = icon_size,
                alpha = icon_alpha,
                invert = invert_icon,
            }
            if bold_file then params.file = bold_file else params.icon = resolved end
            return IconWidget:new(params)
        end

        local function makeActionButton(icon_name, label_text, active)
            local style = button_style
            local frame_width = action_btn_size
            local frame_height = action_btn_size
            local border = active and 0 or normal_border
            local radius = math.floor(action_btn_size / 2)
            local background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            local invert_icon = active or nil
            local icon_alpha = not active

            if style == "premium" then
                -- High-contrast e-ink: active black face with a white glyph;
                -- inactive grey face with a black glyph. A flattened white
                -- icon inverted over the black face is essential here: using
                -- alpha=true on black rendered the black SVG strokes invisible.
                frame_width = math.floor(action_btn_size * 0.92)
                frame_height = frame_width
                radius = math.floor(frame_height / 2)
                border = 0
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
                invert_icon = active or nil
                icon_alpha = not active
            elseif style == "clean_icons" then
                -- Never draw a visible button in this style. Keep the same
                -- transparent touch target, but switch only the SVG stroke
                -- thickness to indicate activity. The e-ink night inversion
                -- can then invert the glyph without painting an opaque square.
                border = 0
                background = nil
                radius = 0
                invert_icon = nil
                icon_alpha = true
            elseif style == "pill" then
                -- A real pill: clearly wider and lower than the circle style.
                frame_width = math.min(button_slot_width, math.floor(button_slot_width * 0.86))
                frame_height = math.max(Screen:scaleBySize(34), math.floor(action_btn_size * 0.58))
                radius = math.floor(frame_height / 2)
                border = thin_border
                background = active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
                invert_icon = nil
                icon_alpha = true
            elseif style == "rounded_square" then
                frame_width = math.floor(action_btn_size * 0.92)
                frame_height = math.floor(action_btn_size * 0.92)
                radius = math.floor(action_btn_size * 0.18)
                border = normal_border
                background = active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
                invert_icon = nil
                icon_alpha = true
            elseif style == "segmented_bar" then
                -- One continuous square strip: each fixed-width cell contains
                -- both the icon and the label, so separators line up cleanly.
                local cell_height = fixed_icon_slot_h + fixed_button_gap + fixed_label_slot_h
                local cell_icon_slot = CenterContainer:new{
                    dimen = Geom:new{ w = button_slot_width, h = fixed_icon_slot_h },
                    makeIcon(icon_name, nil, true),
                }
                local cell_label_slot = makeFixedLabel(label_text)
                local cell_content = VerticalGroup:new{
                    align = "center",
                    cell_icon_slot,
                    VerticalSpan:new{ width = fixed_button_gap },
                    cell_label_slot,
                }
                local cell = FrameContainer:new{
                    width = button_slot_width,
                    height = cell_height,
                    radius = 0,
                    bordersize = thin_border,
                    background = active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
                    padding = 0,
                    CenterContainer:new{
                        dimen = Geom:new{
                            w = button_slot_width - thin_border * 2,
                            h = cell_height - thin_border * 2,
                        },
                        cell_content,
                    },
                }
                return cell, cell
            elseif style == "pressed" then
                -- Distinct from the full-black active style: active buttons look
                -- pressed-in using a grey face and heavier border, while inactive
                -- buttons remain light.
                frame_width = math.floor(action_btn_size * 0.96)
                frame_height = math.floor(action_btn_size * 0.76)
                radius = math.floor(frame_height * 0.28)
                border = active and math.max(normal_border, Screen:scaleBySize(3)) or thin_border
                background = active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
                invert_icon = nil
                icon_alpha = true
            end

            local icon = makeIcon(icon_name, invert_icon, icon_alpha, style == "clean_icons" and active)

            local frame = FrameContainer:new{
                width = frame_width,
                height = frame_height,
                radius = radius,
                bordersize = border,
                background = background,
                padding = 0,
                CenterContainer:new{
                    dimen = Geom:new{
                        w = frame_width - border * 2,
                        h = frame_height - border * 2,
                    },
                    icon,
                },
            }

            local frame_slot = CenterContainer:new{
                dimen = Geom:new{ w = button_slot_width, h = fixed_icon_slot_h },
                frame,
            }
            local label_slot = makeFixedLabel(label_text)
            local slot = VerticalGroup:new{
                align = "center",
                frame_slot,
                VerticalSpan:new{ width = fixed_button_gap },
                label_slot,
            }

            return slot, frame
        end

        for i = row_offset + 1, row_offset + row_visible_count do
            local entry = visible_buttons[i]
            local def = entry.def
            local label_text = def.label_func and def.label_func() or def.label
            local active = def.active_func and def.active_func() or false
            local icon_name = type(def.icon) == "function" and def.icon() or def.icon
            local btn_widget, btn_circle = makeActionButton(icon_name, label_text, active)

            table.insert(refs.buttons, {
                widget = btn_circle,
                callback = function()
                    def.callback(touch_menu)
                end,
            })

            table.insert(top_row, btn_widget)
            if i < row_offset + row_visible_count then
                table.insert(top_row, HorizontalSpan:new{ width = btn_gap })
            end
        end
    end

    -- ----- Compact light controls: two selectable icons, one capsule -----
    -- Keep KOReader's original frontlight / warmth APIs and value granularity.
    -- All references below remain compatible with handlePanelGesture.

    local small_font = Font:getFace("smallinfofont")
    local control_font = Font:getFace("ffont")
    local control_size = Screen:scaleBySize(46)
    local toggle_size = Screen:scaleBySize(50)
    local slider_gap = Screen:scaleBySize(12)
    local slider_height = Screen:scaleBySize(52)
    local slider_width = inner_width - 2 * control_size - 2 * slider_gap
    local controls_group = VerticalGroup:new{ align = "center" }

    local function addControlRef(widget, callback)
        table.insert(refs.controls, { widget = widget, callback = callback })
    end

    local have_brightness = config.show_frontlight
    local have_warmth = config.show_warmth and Device:hasNaturalLight()
    local selected = config.selected_light_control == "warmth" and "warmth" or "brightness"
    if selected == "warmth" and not have_warmth then selected = "brightness" end
    if selected == "brightness" and not have_brightness then selected = "warmth" end

    local function makeRoundControl(symbol, callback)
        local border = math.max(1, Screen:scaleBySize(1))
        local frame = FrameContainer:new{
            width = control_size, height = control_size,
            radius = math.floor(control_size / 2),
            bordersize = border, background = Blitbuffer.COLOR_LIGHT_GRAY,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = control_size - border * 2, h = control_size - border * 2 },
                TextWidget:new{ text = symbol, face = control_font },
            },
        }
        addControlRef(frame, callback)
        return CenterContainer:new{
            dimen = Geom:new{ w = control_size, h = slider_height }, frame,
        }
    end

    local function makeSelectControl(icon_name, is_active, callback)
        -- Match the top action buttons: Premium keeps its dark selection,
        -- while Clean uses a thicker SVG stroke with no filled background.
        local style = valid_button_styles[config.button_style] and config.button_style or "circle"
        local premium = style == "premium"
        local clean_icons = style == "clean_icons"
        local border = (premium or clean_icons) and 0 or Screen:scaleBySize(2)
        local selector_size = premium and math.floor(toggle_size * 0.92) or toggle_size
        local background
        if clean_icons then
            background = nil
        elseif premium then
            background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
        else
            background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        end
        local frame = FrameContainer:new{
            width = selector_size, height = selector_size,
            radius = clean_icons and 0 or math.floor(selector_size / 2),
            bordersize = border, padding = 0,
            background = background,
            CenterContainer:new{
                dimen = Geom:new{ w = selector_size - border * 2, h = selector_size - border * 2 },
                (function()
                    local thick = clean_icons and is_active and cleanBarBoldIconPath(icon_name) or nil
                    local params = {
                        width = Screen:scaleBySize(29), height = Screen:scaleBySize(29),
                        invert = not clean_icons and (is_active or nil) or nil,
                        alpha = clean_icons or not is_active,
                    }
                    if thick then params.file = thick else params.icon = icon_name end
                    return IconWidget:new(params)
                end)(),
            },
        }
        addControlRef(frame, callback)
        return CenterContainer:new{
            dimen = Geom:new{ w = toggle_size, h = toggle_size }, frame,
        }
    end

    local function makeCapsule(value, min_value, max_value)
        local range = math.max(max_value - min_value, 1)
        return ThinSliderWidget:new{
            width = slider_width, height = slider_height,
            percentage = math.max(0, math.min(1, (value - min_value) / range)),
            style = "clean_capsule",
            track_height = Screen:scaleBySize(18),
            fill_height = Screen:scaleBySize(18),
            knob_size = Screen:scaleBySize(32),
        }
    end

    if have_brightness or have_warmth then
        -- Only build the currently selected slider; the other remains fully
        -- configured on the device, and no value changes when switching icons.
        local state
        local label_text
        local function setControlValue(value) end

        if selected == "brightness" then
            state = {
                min = powerd.fl_min, max = powerd.fl_max,
                cur = powerd:frontlightIntensity(),
            }
            label_text = isPortugueseUI() and "Luminosidade" or _("Brightness")
        else
            state = {
                min = powerd.fl_warmth_min, max = powerd.fl_warmth_max,
                cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
            }
            label_text = isPortugueseUI() and "Temperatura da luz" or _("Warmth")
        end

        local slider = makeCapsule(state.cur, state.min, state.max)
        local value_widget = TextWidget:new{
            text = tostring(state.cur), face = small_font,
            max_width = Screen:scaleBySize(65),
        }
        local value_slot_width = Screen:scaleBySize(66)
        local label_widget = TextWidget:new{
            text = label_text, face = small_font,
            max_width = math.max(Screen:scaleBySize(82),
                inner_width - 2 * toggle_size - 3 * slider_gap - value_slot_width),
        }
        local function updateActiveControl()
            local range = math.max(state.max - state.min, 1)
            slider:setPercentage((state.cur - state.min) / range)
            value_widget:setText(tostring(state.cur))
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        setControlValue = function(value)
            value = math.max(state.min, math.min(state.max, value))
            if value == state.cur then return end
            if selected == "brightness" then
                powerd:setIntensity(value)
                state.cur = powerd:frontlightIntensity()
            else
                powerd:setWarmth(powerd:fromNativeWarmth(value))
                state.cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
            end
            updateActiveControl()
        end

        local control_header = HorizontalGroup:new{ align = "center" }
        if have_brightness then
            table.insert(control_header, makeSelectControl("cleanbar/cleanbar_thin_sun", selected == "brightness", function()
                if selected ~= "brightness" then
                    config.selected_light_control = "brightness"
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end
            end))
        end
        if have_warmth then
            if have_brightness then
                table.insert(control_header, HorizontalSpan:new{ width = Screen:scaleBySize(9) })
            end
            table.insert(control_header, makeSelectControl("cleanbar/cleanbar_thin_thermometer", selected == "warmth", function()
                if selected ~= "warmth" then
                    config.selected_light_control = "warmth"
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end
            end))
        end
        table.insert(control_header, HorizontalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(control_header, label_widget)
        -- Do not query the group's size while adding its children; some
        -- KOReader versions cache HorizontalGroup dimensions on first getSize.
        local icon_count = (have_brightness and 1 or 0) + (have_warmth and 1 or 0)
        local icons_width = icon_count * toggle_size
            + (icon_count == 2 and Screen:scaleBySize(9) or 0)
        local remaining = math.max(Screen:scaleBySize(6),
            inner_width - icons_width - Screen:scaleBySize(14)
            - label_widget:getSize().w - value_slot_width)
        table.insert(control_header, HorizontalSpan:new{ width = remaining })
        table.insert(control_header, CenterContainer:new{
            dimen = Geom:new{ w = value_slot_width, h = toggle_size }, value_widget,
        })

        local control_row = HorizontalGroup:new{
            align = "center",
            makeRoundControl("−", function() setControlValue(state.cur - 1) end),
            HorizontalSpan:new{ width = slider_gap },
            slider,
            HorizontalSpan:new{ width = slider_gap },
            makeRoundControl("+", function() setControlValue(state.cur + 1) end),
        }

        if selected == "brightness" then
            refs.fl_progress = slider
            refs.fl_state = state
            refs.setBrightness = setControlValue
        else
            refs.nl_progress = slider
            refs.nl_state = state
            refs.setWarmth = setControlValue
        end

        table.insert(controls_group, control_header)
        table.insert(controls_group, VerticalSpan:new{ width = Screen:scaleBySize(5) })
        table.insert(controls_group, control_row)

    end

    -- ----- Assemble panel -----

    local panel = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        makeStatusRow(),
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
    }

    if num_buttons > 0 then
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_width, h = top_row:getSize().h },
            top_row,
        })
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end

    if #controls_group > 0 then
        table.insert(panel, controls_group)
    end
    table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    touch_menu._clean_bar_refs = refs

    return panel
end

-- ============================================================
-- Gesture handler for panel taps/pans
-- ============================================================

local function handlePanelGesture(touch_menu, ges)
    local refs = touch_menu._clean_bar_refs
    if not refs then return false end

    if refs.fl_progress and refs.fl_progress.dimen
       and ges.pos:intersectWith(refs.fl_progress.dimen) then
        local perc = refs.fl_progress:getPercentageFromPosition(ges.pos)
        if perc and refs.setBrightness then
            local fl = refs.fl_state
            local new_val = Math.round(fl.min + perc * (fl.max - fl.min))
            refs.setBrightness(new_val)
            return true
        end
    end

    if refs.nl_progress and refs.nl_progress.dimen
       and ges.pos:intersectWith(refs.nl_progress.dimen) then
        local perc = refs.nl_progress:getPercentageFromPosition(ges.pos)
        if perc and refs.setWarmth then
            local nl = refs.nl_state
            local new_val = Math.round(nl.min + perc * (nl.max - nl.min))
            refs.setWarmth(new_val)
            return true
        end
    end

    for _, control_ref in ipairs(refs.controls or {}) do
        if control_ref.widget.dimen and ges.pos:intersectWith(control_ref.widget.dimen) then
            control_ref.callback()
            return true
        end
    end

    for _, btn_ref in ipairs(refs.buttons) do
        if btn_ref.widget.dimen and ges.pos:intersectWith(btn_ref.widget.dimen) then
            btn_ref.callback()
            return true
        end
    end

    return false
end

-- Horizontal swipes over the icon row only; outside that region KOReader
-- keeps its own page-changing and vertical gesture behaviour. The row is
-- redrawn in full after a swipe (no e-ink animation or offscreen clipping).
local function handleButtonRowSwipe(touch_menu, ges)
    local refs = touch_menu._clean_bar_refs
    local scroll = refs and refs.icon_row_scroll
    if not (scroll and ges and (ges.direction == "west" or ges.direction == "east")) then
        return false
    end
    local first = refs.buttons and refs.buttons[1]
    if not (first and first.widget and first.widget.dimen) then return false end
    local rect = first.widget.dimen
    local top = rect.y - Screen:scaleBySize(8)
    -- Extend below the icon frame to include its label, but never the
    -- brightness/temperature controls on the next row.
    local bottom = rect.y + rect.h + Screen:scaleBySize(40)
    local left, right = math.huge, -math.huge
    for _, button in ipairs(refs.buttons) do
        local d = button.widget and button.widget.dimen
        if d then
            left = math.min(left, d.x)
            right = math.max(right, d.x + d.w)
        end
    end
    -- Gesture recognizers may supply both an initial and a final position.
    -- Accept either as long as it is inside the actual action row.
    local function inRow(pos)
        return pos and pos.x and pos.y
            and pos.x >= left - Screen:scaleBySize(15)
            and pos.x <= right + Screen:scaleBySize(15)
            and pos.y >= top and pos.y <= bottom
    end
    if not (inRow(ges.start_pos) or inRow(ges.pos)) then return false end

    -- Move three slots per flick while retaining overlap; the final flick
    -- may be smaller so every final icon remains reachable.
    local step = math.min(3, scroll.visible_count)
    local next_offset = scroll.offset + (ges.direction == "west" and step or -step)
    next_offset = math.max(0, math.min(scroll.max_offset, next_offset))
    if next_offset ~= scroll.offset then
        touch_menu._clean_bar_button_offset = next_offset
        refreshCleanBarPanel(touch_menu)
    end
    return true -- consume even at the edges; never change KOReader menu page
end

-- ============================================================
-- Hook TouchMenu to support panel tabs
-- ============================================================

local TouchMenu = require("ui/widget/touchmenu")
local FocusManager = require("ui/widget/focusmanager")

-- Hook updateItems for panel rendering
local orig_updateItems = TouchMenu.updateItems

function TouchMenu:updateItems(target_page, target_item_id)
    if not self.item_table or not self.item_table.panel then
        self._clean_bar_refs = nil -- clear refs when switching away from panel tab
        return orig_updateItems(self, target_page, target_item_id)
    end

    -- Custom panel mode: render the panel widget instead of menu items
    self.item_group:clear()
    self.layout = {}
    table.insert(self.item_group, self.bar)
    table.insert(self.layout, self.bar.icon_widgets)

    -- Build panel (also sets self._clean_bar_refs)
    local panel_fn = self.item_table.panel
    local panel = type(panel_fn) == "function" and panel_fn(self) or panel_fn
    table.insert(self.item_group, panel)

    -- Footer (no pagination, just time/battery)
    table.insert(self.item_group, self.footer_top_margin)
    table.insert(self.item_group, self.footer)
    self.page_info_text:setText("")
    self.page_info_left_chev:showHide(false)
    self.page_info_right_chev:showHide(false)

    -- Clock and battery are now shown at the top of the panel.
    self.time_info:setText("")

    -- Recalculate dimen
    local old_dimen = self.dimen:copy()
    self.dimen.w = self.width
    self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
    self:moveFocusTo(self.cur_tab, 1, FocusManager.NOT_FOCUS)

    local keep_bg = old_dimen and self.dimen.h >= old_dimen.h
    UIManager:setDirty((self.is_fresh or keep_bg) and self.show_parent or "all", function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        local refresh_type = "ui"
        if self.is_fresh then
            refresh_type = "flashui"
            self.is_fresh = false
        end
        return refresh_type, refresh_dimen
    end)
end

-- Hook onTapCloseAllMenus to intercept taps on panel widgets
local orig_onTapCloseAllMenus = TouchMenu.onTapCloseAllMenus

function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
    if self._clean_bar_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then
            return true
        end
    end
    return orig_onTapCloseAllMenus(self, arg, ges_ev)
end

-- Hook switchMenuTab to force Clean bar tab on menu open
local orig_switchMenuTab = TouchMenu.switchMenuTab
-- Assigned below, once the custom-menu builder has been defined. Importantly,
-- this is never invoked merely by a downward swipe opening the Clean bar.
local refreshCleanCustomTab

local function closeCleanBarTouchMenu(touch_menu)
    if not touch_menu then
        return
    end

    -- In Reader view the TouchMenu sits inside ReaderMenu.menu_container.
    -- Closing the parent container avoids leaving a dead overlay behind.
    if touch_menu.show_parent then
        pcall(function()
            UIManager:close(touch_menu.show_parent)
        end)
    end
    pcall(function()
        UIManager:close(touch_menu)
    end)
end

local function findBookshelfPluginInstance()
    local function looksLikeBookshelf(obj)
        return type(obj) == "table"
           and (obj.name == "bookshelf"
                or type(obj.onSetBookshelf) == "function"
                or type(obj.onToggleBookshelf) == "function")
    end

    local function scanHost(host)
        if type(host) ~= "table" then
            return nil
        end

        -- Plugins registered with registerModule are usually inserted as
        -- numeric children of ReaderUI/FileManager. First prefer the child
        -- explicitly bound to this host; in Reader view this is the instance
        -- that owns the active document and Bookshelf's smooth transition.
        for _, child in pairs(host) do
            if looksLikeBookshelf(child) and child.ui == host then
                return child
            end
        end

        -- Some KOReader modules are also exposed by name on the host.
        for _, key in ipairs({ "bookshelf", "Bookshelf" }) do
            if looksLikeBookshelf(host[key]) then
                return host[key]
            end
        end

        -- Fallback: any Bookshelf-like child.
        for _, child in pairs(host) do
            if looksLikeBookshelf(child) then
                return child
            end
        end

        return nil
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    local bookshelf = scanHost(reader)
    if bookshelf then
        return bookshelf
    end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager.instance
    return scanHost(fm)
end

local function tryReaderMenuBookshelfHome(touch_menu)
    -- Best Bookshelf compatibility path: reuse the Reader menu's own
    -- file-browser/Home callback. bookshelf.koplugin patches that callback
    -- in Reader view when Start with = Bookshelf, so the callback captures
    -- the correct Reader-side Bookshelf instance and uses its smooth
    -- _safeShow() transition instead of our patch guessing which plugin
    -- instance to call.
    if G_reader_settings:readSetting("start_with") ~= "bookshelf" then
        return false
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    if not (reader and reader.document and reader.menu and reader.menu.menu_items) then
        return false
    end

    -- Only reuse this callback when Bookshelf has actually wrapped it.
    -- Otherwise it is KOReader's stock FileManager callback and would create
    -- exactly the FileManager-then-Bookshelf hop we are avoiding.
    if reader.menu._bookshelf_fm_tab_wrapped ~= true then
        return false
    end

    local fm_item = reader.menu.menu_items.filemanager
    if type(fm_item) ~= "table" or type(fm_item.callback) ~= "function" then
        return false
    end

    local ok = pcall(function()
        fm_item.callback(touch_menu)
    end)
    return ok
end

local function shouldUseBookshelfHome(bookshelf)
    if G_reader_settings:readSetting("start_with") == "bookshelf" then
        return true
    end

    -- If the user opened the current book from Bookshelf, its full-screen
    -- widget may still be in KOReader's window stack underneath the Reader.
    -- In that case, the Home icon should return to that screen even when
    -- "Start with" is not set to Bookshelf.
    if bookshelf and type(bookshelf._isShowing) == "function" then
        local ok, shown = pcall(function()
            return bookshelf:_isShowing()
        end)
        if ok and shown then
            return true
        end
    end

    return false
end

local function openBookshelfHomeFromCleanBar(touch_menu, force)
    -- First try the path bookshelf.koplugin installs into the Reader menu.
    -- This avoids the FileManager-then-Bookshelf visual hop when the correct
    -- Reader-side instance is available.
    if tryReaderMenuBookshelfHome(touch_menu) then
        return true
    end

    local bookshelf = findBookshelfPluginInstance()
    if not force and not shouldUseBookshelfHome(bookshelf) then
        return false
    end

    if not bookshelf then
        return false
    end

    -- Important: call Bookshelf's own instance methods instead of sending a
    -- normal UIManager:sendEvent. The Clean bar TouchMenu is the topmost
    -- widget, so sendEvent can be swallowed by the menu and never reach the
    -- Reader-side Bookshelf plugin. Calling the instance directly lets
    -- Bookshelf decide whether to use its in-reader transition or just show
    -- the existing home widget.
    closeCleanBarTouchMenu(touch_menu)

    if type(bookshelf.onSetBookshelf) == "function" then
        local ok = pcall(function()
            bookshelf:onSetBookshelf(true)
        end)
        if ok then
            return true
        end
    end

    if type(bookshelf.onToggleBookshelf) == "function" then
        local ok = pcall(function()
            bookshelf:onToggleBookshelf()
        end)
        if ok then
            return true
        end
    end

    if type(bookshelf._safeShow) == "function" then
        local ok = pcall(function()
            bookshelf:_safeShow()
        end)
        if ok then
            return true
        end
    end

    if type(bookshelf.show) == "function" then
        local ok = pcall(function()
            bookshelf:show()
        end)
        if ok then
            return true
        end
    end

    return false
end

local function goToHomeLibraryFromCleanBar(touch_menu)
    -- Prefer the active Bookshelf home screen when the user has configured
    -- KOReader to start with Bookshelf. This keeps Clean bar compatible with
    -- bookshelf.koplugin and avoids fighting its own transition/refresh logic.
    if openBookshelfHomeFromCleanBar(touch_menu) then
        return true
    end

    -- If Bookshelf is configured as home but the direct path above failed,
    -- avoid deliberately doing the plain FileManager fallback: that is the
    -- visual hop the user is trying to avoid. Send Bookshelf's dispatcher
    -- event after closing the Clean bar as a last compatibility attempt.
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    if reader and reader.document and G_reader_settings:readSetting("start_with") == "bookshelf" then
        closeCleanBarTouchMenu(touch_menu)
        UIManager:nextTick(function()
            pcall(function()
                UIManager:broadcastEvent(Event:new("SetBookshelf", true))
            end)
            pcall(function()
                UIManager:sendEvent(Event:new("SetBookshelf", true))
            end)
        end)
        return true
    end

    -- Reader view fallback: close the active top menu, close the document, then
    -- show the FileManager with the current book selected. Calling reader:onHome()
    -- directly can cause an extra repaint on some e-ink devices because it
    -- performs the close using KOReader's default full-refresh path.
    if reader and reader.document then
        local file = reader.document.file
        closeCleanBarTouchMenu(touch_menu)

        UIManager:nextTick(function()
            pcall(function()
                UIManager:avoidFlashOnNextRepaint()
            end)
            pcall(function()
                reader:handleEvent(Event:new("CloseConfigMenu"))
            end)
            pcall(function()
                reader:onClose(false)
            end)
            pcall(function()
                reader:showFileManager(file)
            end)
        end)
        return true
    end

    -- FileManager view fallback: jump to KOReader's HOME folder instead of
    -- opening another menu.
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager.instance
    if fm then
        closeCleanBarTouchMenu(touch_menu)
        UIManager:nextTick(function()
            if fm.onHome then
                fm:onHome()
            elseif fm.file_chooser and fm.file_chooser.goHome then
                fm.file_chooser:goHome()
            end
        end)
        return true
    end

    closeCleanBarTouchMenu(touch_menu)
    UIManager:broadcastEvent(Event:new("ShowFileBrowser"))
    return true
end

-- Direct FileManager destination: do not redirect to Bookshelf even when it
-- is configured as the KOReader start screen. Project: Title decorates this UI.
local function openStandardFileManagerFromCleanBar(touch_menu, home_folder)
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    if reader and reader.document then
        local file = reader.document.file
        closeCleanBarTouchMenu(touch_menu)
        UIManager:nextTick(function()
            pcall(function() UIManager:avoidFlashOnNextRepaint() end)
            pcall(function() reader:handleEvent(Event:new("CloseConfigMenu")) end)
            pcall(function() reader:onClose(false) end)
            pcall(function() reader:showFileManager(file) end)
            if home_folder then
                local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
                local fm = ok_fm and FileManager.instance
                if fm and type(fm.onHome) == "function" then pcall(fm.onHome, fm) end
            end
        end)
        return true
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager.instance
    if fm then
        closeCleanBarTouchMenu(touch_menu)
        if home_folder then
            UIManager:nextTick(function()
                if type(fm.onHome) == "function" then pcall(fm.onHome, fm)
                elseif fm.file_chooser and fm.file_chooser.goHome then
                    pcall(fm.file_chooser.goHome, fm.file_chooser)
                end
            end)
        end
        return true
    end
    closeCleanBarTouchMenu(touch_menu)
    UIManager:broadcastEvent(Event:new("ShowFileBrowser"))
    return true
end

local function openConfiguredRightTab(touch_menu)
    local destination = config.clean_right_destination
    if destination == "filemanager" then
        return openStandardFileManagerFromCleanBar(touch_menu, false)
    elseif destination == "home" then
        return openStandardFileManagerFromCleanBar(touch_menu, true)
    elseif destination == "bookshelf" then
        if openBookshelfHomeFromCleanBar(touch_menu, true) then return true end
        return openStandardFileManagerFromCleanBar(touch_menu, false)
    elseif destination == "projecttitle" then
        -- Project: Title customises the normal FileManager UI; it is not
        -- a separate library screen or a generic menu action to execute.
        return openStandardFileManagerFromCleanBar(touch_menu, false)
    end
    return goToHomeLibraryFromCleanBar(touch_menu)
end

function TouchMenu:switchMenuTab(tab_num)
    local tab = self.tab_item_table and self.tab_item_table[tab_num]
    if type(tab) == "table" and tab._clean_bar_home_patch == true then
        return openConfiguredRightTab(self)
    end
    -- The index of plugin, patch and nested KOReader menu actions may be
    -- expensive (or depend on a live TouchMenu). Delay it until the user
    -- actually opens the custom-menu tab, never during TouchMenu:init().
    if type(tab) == "table" and tab._clean_bar_custom_patch == true
        and refreshCleanCustomTab then
        refreshCleanCustomTab(self)
    end

    orig_switchMenuTab(self, tab_num)
    -- When "open on start" is enabled, always reset last_index to Clean bar tab
    if config.open_on_start then
        self.last_index = 1
    end
end

-- Hook onSwipe to intercept pan/swipe on sliders
local orig_onSwipe = TouchMenu.onSwipe

function TouchMenu:onSwipe(arg, ges_ev)
    if self._clean_bar_refs and self.item_table and self.item_table.panel then
        if handleButtonRowSwipe(self, ges_ev) then
            return true
        end
        if handlePanelGesture(self, ges_ev) then
            return true
        end
    end
    if orig_onSwipe then
        return orig_onSwipe(self, arg, ges_ev)
    end
end

-- ============================================================
-- Clean bar tab definition
-- ============================================================

local clean_bar_tab = {
    icon = "cleanbar/cleanbar_thin_panel",
    remember = false,
    panel = createCleanBarPanel,
}

-- ============================================================
-- Settings menu builder
-- ============================================================


local function getButtonDisplayName(id)
    if isCustomButtonId(id) then
        return customButtonDisplayLabel(id)
    end
    return button_display_names[id] or id
end

local function getCustomButtonSummary(id)
    local names = { custom1 = "custom_slot_1", custom2 = "custom_slot_2", custom3 = "custom_slot_3" }
    return CT(names[id]) .. " · " .. customButtonDisplayLabel(id)
end

local function saveCustomButtonFromFields(id, fields)
    local cfg = getCustomButtonConfig(id)
    if not cfg then return end
    cfg.label = fields[1] or cfg.label or ""
    cfg.icon = fields[2] or cfg.icon or ""
    cfg.label_manually_selected = true
    cfg.icon_manually_selected = true
    cfg.action_type = (fields[3] or cfg.action_type or "event"):lower()
    cfg.event = fields[4] or ""
    cfg.event_arg = fields[5] or ""
    cfg.dispatch = (fields[6] or cfg.dispatch or "broadcast"):lower()
    cfg.plugin = fields[7] or ""
    cfg.method = fields[8] or ""
    cfg.source_plugin = nil -- manual edits are no longer tied to old plugin picker
    if cfg.action_type ~= "menu" then
        cfg.menu_label = ""
        cfg.menu_tab_label = ""
        cfg.menu_key = ""
    end
    saveConfig()
end

local function showCustomButtonEditor(id, touch_menu)
    local ok, MultiInputDialog = pcall(require, "ui/widget/multiinputdialog")
    if not ok or not MultiInputDialog then
        showInfo("MultiInputDialog not available.")
        return
    end

    local cfg = getCustomButtonConfig(id)
    local dialog
    dialog = MultiInputDialog:new{
        title = CT("edit_manual_action"),
        fields = {
            { description = CT("label"), text = cfg.label or "", hint = "Store" },
            { description = CT("icon"), text = cfg.icon or "", hint = "custommenu" },
            { description = CT("action_type"), text = cfg.action_type or "event", hint = "event | menu | module" },
            { description = CT("event_name"), text = cfg.event or "", hint = "ShowFileSearch" },
            { description = CT("event_argument"), text = cfg.event_arg or "", hint = "true" },
            { description = CT("dispatch_method"), text = cfg.dispatch or "broadcast", hint = "broadcast" },
            { description = CT("plugin_or_module"), text = cfg.plugin or "", hint = "storefront" },
            { description = CT("method_name"), text = cfg.method or "", hint = "onShowStorefront" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        saveCustomButtonFromFields(id, dialog:getFields())
                        UIManager:close(dialog)
                        config.show_buttons[id] = true
                        saveConfig()
                        refreshCleanBarPanel(touch_menu)
                        showInfo(CT("custom_button_saved"))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function applyCustomButtonConfig(id, new_config, touch_menu)
    local cfg = getCustomButtonConfig(id)
    if not cfg then return end
    local saved_label = cfg.label_manually_selected and cfg.label or nil
    local saved_icon = cfg.icon_manually_selected and cfg.icon or nil
    cfg.auto_label_key = nil
    cfg.source_plugin = nil -- previous plugin ownership must not survive a new action
    for key, value in pairs(new_config or {}) do
        cfg[key] = value
    end
    if saved_label then cfg.label = saved_label end
    if saved_icon then cfg.icon = saved_icon end
    config.show_buttons[id] = true
    saveConfig()
    refreshCleanBarPanel(touch_menu)
    showInfo(CT("action_selected"))
end

local function applyCustomButtonExample(id, example, touch_menu)
    applyCustomButtonConfig(id, example.config, touch_menu)
end

local function buildBuiltinActionMenu(id)
    local examples = {
        {
            text = CT("action_search"),
            config = { label = isPortugueseUI() and "Pesquisa" or "Search", icon = "quick_search", action_type = "event", event = "ShowFileSearch", auto_label_key = "action_search", event_arg = "", dispatch = "broadcast", plugin = "", method = "", menu_label = "", menu_tab_label = "", menu_key = "" },
        },
        {
            text = CT("action_cloud"),
            config = { label = isPortugueseUI() and "Nuvem" or "Cloud", icon = "quick_cloud", action_type = "event", event = "ShowCloudStorage", auto_label_key = "action_cloud", event_arg = "", dispatch = "broadcast", plugin = "", method = "", menu_label = "", menu_tab_label = "", menu_key = "" },
        },
        {
            text = CT("action_opds"),
            config = { label = "OPDS", icon = "quick_opds", action_type = "event", event = "ShowOPDSCatalog", auto_label_key = "action_opds", event_arg = "", dispatch = "broadcast", plugin = "", method = "", menu_label = "", menu_tab_label = "", menu_key = "" },
        },
        {
            text = CT("action_library"),
            config = { label = CT("action_library"), icon = "Koreaderrightqq", action_type = "event", event = "SetBookshelf", auto_label_key = "action_library", event_arg = "true", dispatch = "broadcast", plugin = "", method = "", menu_label = "", menu_tab_label = "", menu_key = "" },
        },
    }

    local items = {}
    for _, example in ipairs(examples) do
        table.insert(items, {
            text = example.text,
            callback = function(touch_menu)
                applyCustomButtonExample(id, example, touch_menu)
            end,
        })
    end
    return items
end

local function shellQuote(path)
    path = tostring(path or "")
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function cleanBarListDir(path)
    local entries = {}
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs and lfs and lfs.dir then
        local ok = pcall(function()
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    table.insert(entries, entry)
                end
            end
        end)
        if ok then
            table.sort(entries)
            return entries
        end
    end

    local ok_io, pipe = pcall(function()
        return io.popen("ls -1 " .. shellQuote(path) .. " 2>/dev/null")
    end)
    if ok_io and pipe then
        for line in pipe:lines() do
            if line ~= "" then
                table.insert(entries, line)
            end
        end
        pipe:close()
    end
    table.sort(entries)
    return entries
end

local function cleanBarFileExists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function collectPluginSearchPaths()
    local paths = { "plugins", "./plugins" }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        local getters = { "getDataDir", "getSettingsDir" }
        for _, getter in ipairs(getters) do
            if type(DataStorage[getter]) == "function" then
                local ok, base = pcall(function() return DataStorage[getter]() end)
                if ok and type(base) == "string" and base ~= "" then
                    table.insert(paths, base .. "/plugins")
                    table.insert(paths, base .. "/../plugins")
                end
            end
        end
    end
    table.insert(paths, "/mnt/onboard/.adds/koreader/plugins")
    table.insert(paths, "/mnt/onboard/koreader/plugins")

    local unique = {}
    local result = {}
    for _, path in ipairs(paths) do
        if type(path) == "string" and path ~= "" and not unique[path] then
            table.insert(result, path)
            unique[path] = true
        end
    end
    return result
end

local function nicePluginLabel(value)
    if type(value) ~= "string" or value == "" then
        return CT("menu_source_unknown")
    end
    local label = value:gsub("%.koplugin$", "")
    label = label:gsub("[_%-]", " ")
    return label:gsub("^%l", string.upper)
end

local function parseDispatcherActionsFromMainLua(main_lua_path)
    local file = io.open(main_lua_path, "r")
    if not file then
        return {}
    end
    local content = file:read("*a") or ""
    file:close()

    local actions = {}
    local seen = {}
    for block in content:gmatch("Dispatcher%s*:%s*registerAction%s*%b()") do
        local event = block:match("event%s*=%s*['\"]([^'\"]+)['\"]")
        local title = block:match("title%s*=%s*_%s*%(%s*['\"]([^'\"]+)['\"]")
            or block:match("title%s*=%s*['\"]([^'\"]+)['\"]")
        if event and not seen[event] then
            table.insert(actions, { event = event, title = title or event,
                explicit_registration = true })
            seen[event] = true
        end
    end

    -- Fallback for plugins that define actions more dynamically but still keep
    -- plain event fields in main.lua.
    for event in content:gmatch("event%s*=%s*['\"]([^'\"]+)['\"]") do
        if not seen[event] then
            table.insert(actions, { event = event, title = event })
            seen[event] = true
        end
    end

    table.sort(actions, function(a, b)
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)
    return actions
end

local function collectInstalledPluginEvents()
    local groups = {}
    local seen_plugin = {}
    local disabled = G_reader_settings:readSetting("plugins_disabled")

    for _, plugins_dir in ipairs(collectPluginSearchPaths()) do
        for _, entry in ipairs(cleanBarListDir(plugins_dir)) do
            if entry:match("%.koplugin$") then
                local path = plugins_dir .. "/" .. entry
                local main_lua = path .. "/main.lua"
                local plugin_name = entry:gsub("%.koplugin$", "")
                if not seen_plugin[plugin_name] and cleanBarFileExists(main_lua)
                    and not (type(disabled) == "table" and disabled[plugin_name] == true) then
                    local actions = parseDispatcherActionsFromMainLua(main_lua)
                    table.insert(groups, {
                        name = plugin_name,
                        label = nicePluginLabel(plugin_name),
                        icon = "custommenu",
                        path = path,
                        actions = actions,
                    })
                    seen_plugin[plugin_name] = true
                end
            end
        end
    end

    table.sort(groups, function(a, b)
        return tostring(a.label):lower() < tostring(b.label):lower()
    end)
    return groups
end

-- Read the live dispatcher registration. A string found in a plugin's Lua
-- source alone is not proof it is currently an executable action.
local invalidateCleanChoiceCache
local function cleanBarRegisteredPluginEvents()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or type(Dispatcher.registerAction) ~= "function"
        or not debug or type(debug.getupvalue) ~= "function" then return {} end
    local registered = {}
    for i = 1, 12 do
        local name, value = debug.getupvalue(Dispatcher.registerAction, i)
        if not name then break end
        if type(value) == "table" then
            for _, record in pairs(value) do
                if type(record) == "table" and type(record.event) == "string"
                    and record.event ~= "" and not record.arg and not record.args
                    and not record.string and not record.configurable then
                    registered[record.event] = true
                end
            end
        end
    end
    return registered
end

local function cleanBarPluginShortcutKey(plugin, event)
    return "cleanbar:plugin:" .. plugin .. ":" .. event
end

local function buildInstalledPluginEventMenu(id, only_plugin)
    local groups = collectInstalledPluginEvents()
    local registered = cleanBarRegisteredPluginEvents()
    if #groups == 0 then
        return {{ text = CT("no_plugin_actions_found"), enabled = false }}
    end
    local items = {}
    for _, group in ipairs(groups) do
      if not only_plugin or group.name == only_plugin then
        local group_name, group_label = group.name, group.label
        local action_items = {}
        for _, action in ipairs(group.actions) do
            if action.explicit_registration and registered[action.event] then
                local event_name, action_title = action.event, action.title
                local key = cleanBarPluginShortcutKey(group_name, event_name)
                action_items[#action_items + 1] = {
                    text = action_title,
                    checked_func = not id and function()
                        return config.clean_menu_items[key] == true
                    end or nil,
                    keep_menu_open = not id,
                    callback = function(touch_menu)
                        if id then
                            applyCustomButtonConfig(id, {
                                label = action_title, icon = "custommenu",
                                action_type = "event", event = event_name,
                                event_arg = "", dispatch = "broadcast",
                                source_plugin = group_name,
                                plugin = "", method = "", menu_label = "",
                                menu_tab_label = "", menu_key = "",
                            }, touch_menu)
                        else
                            if config.clean_menu_items[key] then
                                config.clean_menu_items[key] = nil
                            else
                                config.clean_plugin_actions[key] = {
                                    plugin = group_name, event = event_name,
                                    label = action_title,
                                }
                                config.clean_menu_items[key] = true
                            end
                            saveConfig()
                            if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
                        end
                    end,
                }
            end
        end
        if #action_items == 0 then
            action_items[1] = {text = CT("no_plugin_actions_found"), enabled = false}
        end
        if only_plugin then
            for _, option in ipairs(action_items) do items[#items + 1] = option end
        else
            items[#items + 1] = {
                text = group_label, sub_item_table_func = function() return action_items end,
            }
        end
      end
    end
    return #items > 0 and items or
        {{ text = CT("no_plugin_actions_found"), enabled = false }}
end

-- Original recursive KOReader action picker removed: see patch explorer below.

local function collectAvailableIcons()
    local icons = {
        "Clean", "Top-com", "custommenu", "Koreaderrightqq",
        "quick_wifi", "quick_bluetooth", "quick_nightmode", "quick_rotate", "quick_restart",
        "quick_sleep", "quick_search", "quick_usb", "quick_cloud",
        "quick_exit", "quick_calibre", "quick_notion", "quick_opds",
        "quick_quickrss", "quick_streak", "quick_zlib",
        "cleanbar/cleanbar_thin_sun", "cleanbar/cleanbar_thin_thermometer",
        "cleanbar/cleanbar_thin_panel", "cleanbar/cleanbar_thin_menu", "cleanbar/cleanbar_thin_library",
        "cleanbar/cleanbar_thin_clean_appstore",
    }
    local seen = {}
    local result = {}
    local function add(icon)
        if type(icon) == "string" and icon ~= "" and not seen[icon] then
            table.insert(result, icon)
            seen[icon] = true
        end
    end
    for _, icon in ipairs(icons) do
        add(icon)
    end

    local icon_dirs = {
        "icons", "./icons", "resources/icons", "./resources/icons",
        "/mnt/onboard/.adds/koreader/icons", "/mnt/onboard/.adds/koreader/resources/icons",
    }
    for _, dir in ipairs(icon_dirs) do
        for _, entry in ipairs(cleanBarListDir(dir)) do
            local name = entry:match("^(.+)%.svg$")
            -- No stale duplicates from resources/icons or icons root.
            if name and not name:match("^cleanbar_bold_")
                and not name:match("^cleanbar_thin_") then
                add(name)
            end
        end
    end
    -- The native IconWidget accepts relative icon paths beneath
    -- DataStorage:getDataDir()/icons; it does not search subfolders by name.
    -- Scan this directory only when the user opens the icon picker.
    local custom_root
    local ok_storage, DataStorage = pcall(require, "datastorage")
    if ok_storage then custom_root = DataStorage:getDataDir() .. "/icons/cleanbar" end
    local cleanbar_dirs = { "icons/cleanbar", "./icons/cleanbar" }
    if custom_root then cleanbar_dirs[#cleanbar_dirs + 1] = custom_root end
    for _, dir in ipairs(cleanbar_dirs) do
        for _, entry in ipairs(cleanBarListDir(dir)) do
            local name = entry:match("^(.+)%.svg$")
            if name and name:match("^cleanbar_") and not name:match("^cleanbar_bold_") then
                add("cleanbar/" .. name)
            end
        end
    end
    table.sort(result, function(a, b) return a:lower() < b:lower() end)
    return result
end

-- Use KOReader's native ButtonDialog/ButtonTable for real SVG previews.
-- TouchMenuItem intentionally renders text and checkboxes only: item.icon is not
-- an inline row icon. A paginated two-button row avoids patching TouchMenu globals.
local function showIconPreviewPicker(id, parent_touch_menu, initial_query, initial_page, category)
    local names = {
        Clean = "icon_clean", ["Top-com"] = "icon_menu", custommenu = "icon_menu",
        Koreaderrightqq = "icon_home", quick_wifi = "icon_wifi", quick_bluetooth = "icon_bluetooth",
        quick_nightmode = "icon_night", quick_rotate = "icon_rotate", quick_restart = "icon_restart",
        quick_sleep = "icon_sleep", quick_search = "icon_search", quick_usb = "icon_usb",
        quick_cloud = "icon_cloud", quick_exit = "icon_exit", quick_calibre = "icon_calibre",
        quick_notion = "icon_notion", quick_opds = "icon_opds", quick_quickrss = "icon_rss",
        quick_streak = "icon_streak", quick_zlib = "icon_store",
        ["cleanbar/cleanbar_thin_sun"] = "icon_sun", ["cleanbar/cleanbar_thin_thermometer"] = "icon_thermometer",
        ["cleanbar/cleanbar_thin_panel"] = "icon_menu", ["cleanbar/cleanbar_thin_menu"] = "icon_menu", ["cleanbar/cleanbar_thin_library"] = "icon_home",
        ["cleanbar/cleanbar_thin_clean_appstore"] = "icon_appstore",
    }
    local function niceIconName(icon)
        local text = tostring(icon or ""):match("([^/]+)$") or ""
        text = text:gsub("^cleanbar_thin_", ""):gsub("^cleanbar_bold_", "")
        text = text:gsub("^cleanbar_", ""):gsub("^quick_", "")
        text = text:gsub("[_%-]+", " ")
        return text:gsub("^%l", string.upper)
    end
    local icons = collectAvailableIcons()
    local query = type(initial_query) == "string" and initial_query or ""
    category = category == "common" and "common" or category == "other" and "other" or "all"
    local filtered = {}
    for _, icon_name in ipairs(icons) do
        local pretty = names[icon_name] and CT(names[icon_name]) or niceIconName(icon_name)
        local type_match = category == "all"
            or (category == "common" and names[icon_name] ~= nil)
            or (category == "other" and names[icon_name] == nil)
        if type_match and (query == "" or (pretty .. " " .. icon_name):lower():find(query:lower(), 1, true)) then
            filtered[#filtered + 1] = { name = icon_name, label = pretty }
        end
    end
    table.sort(filtered, function(a, b)
        local aa, bb = names[a.name] and 0 or 1, names[b.name] and 0 or 1
        if aa ~= bb then return aa < bb end
        return a.label:lower() < b.label:lower()
    end)
    local page_size = 7
    local max_page = math.max(1, math.ceil(#filtered / page_size))
    local page = math.max(1, math.min(initial_page or 1, max_page))
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function activeIcon()
        if id == "__tab_left" then return config.clean_left_tab_icon end
        if id == "__tab_middle" then return config.clean_middle_tab_icon end
        if id == "__tab_right" then return config.clean_right_tab_icon end
        local cfg = getCustomButtonConfig(id)
        return cfg and cfg.icon
    end
    local function choose(icon_name)
        if id == "__tab_left" or id == "__tab_middle" or id == "__tab_right" then
            if id == "__tab_left" then config.clean_left_tab_icon = icon_name
            elseif id == "__tab_middle" then config.clean_middle_tab_icon = icon_name
            else config.clean_right_tab_icon = icon_name end
            saveConfig()
            UIManager:close(dialog)
            if refreshCleanModeMenu then refreshCleanModeMenu(parent_touch_menu) end
        else
            local cfg = getCustomButtonConfig(id)
            cfg.icon = icon_name
            cfg.icon_manually_selected = true
            config.show_buttons[id] = true
            saveConfig()
            UIManager:close(dialog)
            refreshCleanBarPanel(parent_touch_menu)
        end
    end
    local function goTo(new_page)
        UIManager:close(dialog)
        showIconPreviewPicker(id, parent_touch_menu, query, new_page, category)
    end
    local function openSearch()
        UIManager:close(dialog)
        local InputDialog = require("ui/widget/inputdialog")
        local search_dialog
        search_dialog = InputDialog:new{
            title = CT("icon_picker_find"), input = query,
            buttons = {{
                { text = CT("cancel"), id = "close", callback = function()
                    UIManager:close(search_dialog)
                    showIconPreviewPicker(id, parent_touch_menu, query, page, category)
                end },
                { text = CT("search_menu"), callback = function()
                    local q = search_dialog:getInputText() or ""
                    UIManager:close(search_dialog)
                    showIconPreviewPicker(id, parent_touch_menu, q, 1, category)
                end },
            }},
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end
    local function changeCategory(new_category)
        UIManager:close(dialog)
        showIconPreviewPicker(id, parent_touch_menu, query, 1, new_category)
    end
    local rows = {
        {{ text = CT("icon_picker_find"), callback = openSearch },
         { text = CT("icon_picker_clear"), callback = function()
             UIManager:close(dialog)
             showIconPreviewPicker(id, parent_touch_menu, "", 1, category)
         end }},
        {
            { text = (category == "all" and "✓ " or "") .. CT("icon_picker_all"),
              callback = function() changeCategory("all") end },
            { text = (category == "common" and "✓ " or "") .. CT("icon_picker_common"),
              callback = function() changeCategory("common") end },
            { text = (category == "other" and "✓ " or "") .. CT("icon_picker_other"),
              callback = function() changeCategory("other") end },
        },
    }
    if #filtered == 0 then
        rows[#rows + 1] = {{ text = CT("no_icons_found"), enabled = false }}
    end
    local icon_width = Screen:scaleBySize(60)
    local icon_size = Screen:scaleBySize(28)
    for i = (page-1)*page_size + 1, math.min(page*page_size, #filtered) do
        local entry = filtered[i]
        local selected = activeIcon() == entry.name
        local cb = function() choose(entry.name) end
        rows[#rows + 1] = {
            { icon = entry.name, icon_width = icon_size, icon_height = icon_size,
              width = icon_width, callback = cb },
            { text = (selected and "✓  " or "    ") .. entry.label,
              align = "left", font_bold = false, callback = cb },
        }
    end
    rows[#rows + 1] = {
        { text = "◂  " .. CT("icon_picker_back"),
          enabled = page > 1, callback = function() goTo(page-1) end },
        { text = string.format("%d / %d", page, max_page), enabled = false },
        { text = CT("icon_picker_next") .. "  ▸",
          enabled = page < max_page, callback = function() goTo(page+1) end },
    }
    dialog = ButtonDialog:new{
        title = CT("choose_icon_title"),
        buttons = rows,
        width = math.floor(Screen:getWidth()*0.91),
    }
    UIManager:show(dialog)
end

local function showCustomButtonLabelEditor(id, touch_menu)
    local InputDialog = require("ui/widget/inputdialog")
    local cfg = getCustomButtonConfig(id)
    local dialog
    dialog = InputDialog:new{
        title = CT("label_editor_title"),
        input = customButtonDisplayLabel(id),
        buttons = {
            {
                { text = CT("cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = CT("save"), is_enter_default = true, callback = function()
                    local new_label = cbTrim(dialog:getInputText())
                    if new_label ~= "" then
                        cfg.label = new_label
                        cfg.label_manually_selected = true
                        saveConfig()
                        refreshCleanBarPanel(touch_menu)
                    end
                    UIManager:close(dialog)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local buildInstalledPatchesMenu
local buildUnifiedOptionsHub

local function buildCustomButtonSlotMenu(id)
    local defaults = config_default.custom_buttons[id]
    return {
        {
            text = CT("show_custom_button"),
            checked_func = function() return config.show_buttons[id] == true end,
            callback = function(touch_menu)
                config.show_buttons[id] = not config.show_buttons[id]
                saveConfig()
                refreshCleanBarPanel(touch_menu)
            end,
        },
        {
            text_func = function()
                return CT("label") .. ": " .. customButtonDisplayLabel(id)
            end,
            callback = function(touch_menu) showCustomButtonLabelEditor(id, touch_menu) end,
        },
        {
            text_func = function()
                local cfg = getCustomButtonConfig(id)
                local friendly = {
                    quick_wifi = "icon_wifi", quick_bluetooth = "icon_bluetooth",
                    quick_nightmode = "icon_night", quick_rotate = "icon_rotate",
                    quick_restart = "icon_restart", quick_sleep = "icon_sleep",
                    quick_search = "icon_search", quick_usb = "icon_usb",
                    quick_cloud = "icon_cloud", quick_exit = "icon_exit",
                    quick_calibre = "icon_calibre", quick_notion = "icon_notion",
                    quick_opds = "icon_opds", quick_quickrss = "icon_rss",
                    quick_streak = "icon_streak", quick_zlib = "icon_store",
                    custommenu = "icon_menu", Clean = "icon_clean",
                    Koreaderrightqq = "icon_home", ["Top-com"] = "icon_menu",
                    ["cleanbar/cleanbar_thin_sun"] = "icon_sun", ["cleanbar/cleanbar_thin_thermometer"] = "icon_thermometer",
                    ["cleanbar/cleanbar_thin_clean_appstore"] = "icon_appstore",
                }
                local name = tostring(cfg.icon or ""):match("([^/]+)$") or ""
                name = name:gsub("^cleanbar_thin_", ""):gsub("^cleanbar_", "")
                    :gsub("^quick_", ""):gsub("[_%-]+", " "):gsub("^%l", string.upper)
                return CT("current_icon") .. ": " .. (friendly[cfg.icon] and CT(friendly[cfg.icon]) or name)
            end,
            callback = function(touch_menu) showIconPreviewPicker(id, touch_menu, "", 1) end,
        },
        {
            text_func = function()
                local cfg = getCustomButtonConfig(id)
                local action = cfg.action_type or "event"
                local action_name = CT("unconfigured")
                if action == "menu" or action == "patch" or action == "plugin_menu" then
                    action_name = cfg.menu_label ~= "" and cfg.menu_label or action_name
                elseif action == "event" then
                    action_name = cfg.auto_label_key and CT(cfg.auto_label_key)
                        or (cfg.event ~= "" and cfg.event or action_name)
                elseif action == "module" or action == "plugin" then
                    action_name = cfg.method ~= "" and cfg.method or action_name
                end
                return CT("current_action") .. ": " .. action_name
            end,
            sub_item_table = {
                { text = CT("builtin_actions"), sub_item_table_func = function() return buildBuiltinActionMenu(id) end },
                { text = CT("koreader_options"), sub_item_table_func = function()
                    return buildUnifiedOptionsHub(id)
                end },
            },
        },
        {
            text = CT("technical_actions"),
            separator = true,
            callback = function(touch_menu) showCustomButtonEditor(id, touch_menu) end,
        },
        {
            text = CT("reset_custom_button"),
            callback = function(touch_menu)
                config.custom_buttons[id] = {}
                for key, value in pairs(defaults) do
                    config.custom_buttons[id][key] = value
                end
                config.show_buttons[id] = false
                saveConfig()
                refreshCleanBarPanel(touch_menu)
            end,
        },
    }
end

local function buildCustomButtonsSettingsMenu()
    local items = {}
    for _, id in ipairs(custom_button_slots) do
        table.insert(items, {
            text = getCustomButtonSummary(id),
            sub_item_table = buildCustomButtonSlotMenu(id),
        })
    end
    return items
end

local function selectRightDestination(value)
    config.clean_right_destination = value
    saveConfig()
end

-- Only advertise actual library destinations, not arbitrary plugin actions.
-- Plugin folders are checked lazily on opening this settings submenu, never
-- when the user swipes down to open the Clean bar.
local function libraryPluginAvailable(plugin_name)
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled[plugin_name] == true then
        return false
    end
    for _, directory in ipairs(collectPluginSearchPaths()) do
        if cleanBarFileExists(directory .. "/" .. plugin_name .. ".koplugin/main.lua") then
            return true
        end
    end
    -- Bookshelf can also be loaded from a custom plugin path that is not
    -- discoverable from the standard directory list.
    if plugin_name == "bookshelf" then
        return findBookshelfPluginInstance() ~= nil
    end
    return false
end

local function buildRightTabDestinationMenu()
    local entries = {
        { text = CT("destination_auto"), value = "auto" },
        { text = CT("destination_filemanager"), value = "filemanager" },
        { text = CT("destination_home"), value = "home" },
    }
    if libraryPluginAvailable("bookshelf") then
        entries[#entries + 1] = { text = CT("destination_bookshelf"), value = "bookshelf" }
    end
    if libraryPluginAvailable("projecttitle") then
        entries[#entries + 1] = { text = CT("destination_projecttitle"), value = "projecttitle" }
    end
    local menu = {}
    for _, entry in ipairs(entries) do
        menu[#menu + 1] = {
            text = entry.text,
            checked_func = function() return config.clean_right_destination == entry.value end,
            callback = function() selectRightDestination(entry.value) end,
        }
    end
    return menu
end

CleanBarBackup = (function()
-- >>> CLEAN BAR v10 PORTABLE BACKUPS (self-contained, stored ZIP, no shell commands)
-- Only the Clean bar settings and allowed SVG files are exported.
local cb_backup_max_bytes = 12 * 1024 * 1024
local cb_backup_max_svg = 256 * 1024
local cb_backup_max_icons = 200
local cb_backup_format = "cleanbar-portable-v1"

local function cbBackupDir()
    return require("datastorage"):getDataDir() .. "/settings/cleanbar_backups"
end

local function cbUserIconDir()
    return require("datastorage"):getDataDir() .. "/icons"
end

local function cbBackupFs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then return lfs end
    return require("lfs")
end

local function cbBackupMakeDir(path)
    local lfs = cbBackupFs()
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    for segment in path:gmatch("[^/]+") do
        prefix = (prefix == "/" and "/" or prefix == "" and "" or prefix .. "/") .. segment
        if lfs.attributes(prefix, "mode") ~= "directory" then
            local ok = pcall(lfs.mkdir, prefix)
            if not ok or lfs.attributes(prefix, "mode") ~= "directory" then
                return false
            end
        end
    end
    return true
end

local function cbBackupRead(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(limit + 1)
    f:close()
    if not data or #data > limit then return nil end
    return data
end

local function cbBackupWriteNew(path, data)
    if type(data) ~= "string" then return nil, "invalid" end
    -- Even empty existing files must not be silently overwritten.
    local test = io.open(path, "rb")
    if test then test:close(); return nil, "exists" end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return nil, "write" end
    local ok = f:write(data)
    local closed = f:close()
    if not ok or not closed then os.remove(tmp); return nil, "write" end
    local renamed = os.rename(tmp, path)
    if not renamed then os.remove(tmp); return nil, "rename" end
    return true
end

local function cbBackupLe16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function cbBackupLe32(n)
    n = n % 4294967296
    return cbBackupLe16(n % 65536) .. cbBackupLe16(math.floor(n / 65536))
end

local function cbBackupU16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    if not b then error("ZIP truncated") end
    return a + b * 256
end

local function cbBackupU32(s, pos)
    return cbBackupU16(s, pos) + cbBackupU16(s, pos + 2) * 65536
end

local cbBackupCRCtable
local function cbBackupCRC(s)
    local bit = require("bit") -- LuaJIT's bit library, present in KOReader.
    if not cbBackupCRCtable then
        cbBackupCRCtable = {}
        for i = 0, 255 do
            local crc = i
            for _ = 1, 8 do
                if bit.band(crc, 1) ~= 0 then
                    crc = bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
                else
                    crc = bit.rshift(crc, 1)
                end
            end
            cbBackupCRCtable[i] = crc
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        local idx = bit.band(bit.bxor(crc, s:byte(i)), 0xFF)
        crc = bit.bxor(bit.rshift(crc, 8), cbBackupCRCtable[idx])
    end
    return bit.band(bit.bnot(crc), 0xFFFFFFFF) % 4294967296
end

local function cbBackupValidName(name)
    if name == "cleanbar.json" then return true end
    if type(name) ~= "string" or not name:match("^icons/[%w_/%-]+%.svg$") then return false end
    if name:find("..", 1, true) or #name > 200 then return false end
    for seg in name:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return false end
    end
    return true
end

local function cbBackupZipWrite(entries)
    local parts, central, offset, total = {}, {}, 0, 0
    for _, entry in ipairs(entries) do
        local name, contents = entry.name, entry.data
        if not cbBackupValidName(name) or type(contents) ~= "string" then error("Invalid ZIP entry") end
        total = total + #contents
        if total > cb_backup_max_bytes then error("Backup too large") end
        local crc = cbBackupCRC(contents)
        local header = "PK\003\004" .. cbBackupLe16(20) .. cbBackupLe16(0) .. cbBackupLe16(0)
            .. cbBackupLe16(0) .. cbBackupLe16(0) .. cbBackupLe32(crc)
            .. cbBackupLe32(#contents) .. cbBackupLe32(#contents)
            .. cbBackupLe16(#name) .. cbBackupLe16(0)
        local local_part = header .. name .. contents
        parts[#parts + 1] = local_part
        central[#central + 1] = "PK\001\002" .. cbBackupLe16(20) .. cbBackupLe16(20)
            .. cbBackupLe16(0) .. cbBackupLe16(0) .. cbBackupLe16(0) .. cbBackupLe16(0)
            .. cbBackupLe32(crc) .. cbBackupLe32(#contents) .. cbBackupLe32(#contents)
            .. cbBackupLe16(#name) .. cbBackupLe16(0) .. cbBackupLe16(0)
            .. cbBackupLe16(0) .. cbBackupLe16(0) .. cbBackupLe32(0)
            .. cbBackupLe32(offset) .. name
        offset = offset + #local_part
    end
    local catalog = table.concat(central)
    local footer = "PK\005\006" .. cbBackupLe16(0) .. cbBackupLe16(0)
        .. cbBackupLe16(#entries) .. cbBackupLe16(#entries)
        .. cbBackupLe32(#catalog) .. cbBackupLe32(offset) .. cbBackupLe16(0)
    return table.concat(parts) .. catalog .. footer
end

-- Accept only simple uncompressed entries generated by our portable exporter.
-- No paths, scripts, symlinks, or compressed ZIP bombs are extracted.
local function cbBackupZipRead(blob)
    if not blob or #blob > cb_backup_max_bytes + 150000 or #blob < 22 then error("Invalid backup size") end
    local pos, out, seen, count, total = 1, {}, {}, 0, 0
    while blob:sub(pos, pos + 3) == "PK\003\004" do
        local flags, method = cbBackupU16(blob, pos + 6), cbBackupU16(blob, pos + 8)
        local expected_crc = cbBackupU32(blob, pos + 14)
        local packed, unpacked = cbBackupU32(blob, pos + 18), cbBackupU32(blob, pos + 22)
        local name_len, extra_len = cbBackupU16(blob, pos + 26), cbBackupU16(blob, pos + 28)
        local name = blob:sub(pos + 30, pos + 29 + name_len)
        local begin_data = pos + 30 + name_len + extra_len
        local finish_data = begin_data + packed - 1
        if flags ~= 0 or method ~= 0 or packed ~= unpacked or not cbBackupValidName(name)
            or seen[name] or packed > cb_backup_max_bytes or finish_data > #blob
            or begin_data < pos + 30 or #name ~= name_len then
            error("Unsafe ZIP entry")
        end
        local contents = blob:sub(begin_data, finish_data)
        if cbBackupCRC(contents) ~= expected_crc then error("ZIP checksum mismatch") end
        count, total = count + 1, total + #contents
        if count > cb_backup_max_icons + 1 or total > cb_backup_max_bytes then error("Backup limits exceeded") end
        out[name], seen[name] = contents, true
        pos = finish_data + 1
    end
    if blob:sub(pos, pos + 3) ~= "PK\001\002" or out["cleanbar.json"] == nil then
        error("Invalid ZIP catalog")
    end
    -- A central-directory entry count is checked by scanning the stored catalog.
    local catalog_count = 0
    while blob:sub(pos, pos + 3) == "PK\001\002" do
        local namelen = cbBackupU16(blob, pos + 28)
        local extralen = cbBackupU16(blob, pos + 30)
        local commentlen = cbBackupU16(blob, pos + 32)
        local name = blob:sub(pos + 46, pos + 45 + namelen)
        if not seen[name] or out[name] == nil then error("Unexpected ZIP catalog entry") end
        catalog_count = catalog_count + 1
        pos = pos + 46 + namelen + extralen + commentlen
    end
    if blob:sub(pos, pos + 3) ~= "PK\005\006" or catalog_count ~= count
        or cbBackupU16(blob, pos + 10) ~= count or pos + 21 ~= #blob then
        error("Invalid ZIP footer")
    end
    return out
end

local function cbBackupConfigCopy(value, depth, visiting, stats)
    depth = depth or 0
    visiting = visiting or {}
    stats = stats or { count = 0 }
    stats.count = stats.count + 1
    if stats.count > 20000 or depth > 20 then error("Configuration too complex") end
    local kind = type(value)
    if kind == "nil" or kind == "boolean" then return value end
    if kind == "string" then
        if #value > 16384 then error("Configuration text too long") end
        return value
    end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("Invalid number") end
        return value
    end
    if kind ~= "table" or visiting[value] then error("Unsupported configuration data") end
    visiting[value] = true
    local result = {}
    for k, v in pairs(value) do
        if type(k) ~= "string" and type(k) ~= "number" then error("Invalid setting name") end
        result[k] = cbBackupConfigCopy(v, depth + 1, visiting, stats)
    end
    visiting[value] = nil
    return result
end

local function cbBackupIconRef(name)
    if type(name) ~= "string" then return nil end
    local path = name:gsub("%.svg$", "")
    if path:match("^[%w_/%-]+$") and not path:find("..", 1, true) then
        return "icons/" .. path .. ".svg"
    end
    return nil
end

local function cbBackupSourceIcons(snapshot)
    local icon_dir, files, seen, total = cbUserIconDir(), {}, {}, 0
    local function add(name)
        if not cbBackupValidName(name) or seen[name] then return end
        local source = icon_dir .. "/" .. name:sub(#"icons/" + 1)
        local svg = cbBackupRead(source, cb_backup_max_svg)
        if not svg then
            -- Some pre-v10 custom icons were put into resources/icons.
            local old = require("datastorage"):getDataDir() .. "/resources/" .. name
            svg = cbBackupRead(old, cb_backup_max_svg)
            if not svg and (cbBackupFs().attributes(source, "mode") == "file"
                or cbBackupFs().attributes(old, "mode") == "file") then
                error("SVG unreadable or too large: " .. name)
            end
        end
        if not svg then return end -- KOReader's built-in icon; no custom file.
        if not svg:find("<svg", 1, true) then error("Invalid SVG: " .. name) end
        total = total + #svg
        if #files >= cb_backup_max_icons or total > cb_backup_max_bytes - 65536 then
            error("Too many custom SVG icons")
        end
        seen[name] = true
        files[#files + 1] = { name = name, data = svg }
    end
    local cleanbar_dir = icon_dir .. "/cleanbar"
    for _, entry in ipairs(cleanBarListDir(cleanbar_dir)) do
        if entry:match("^[%w_%-]+%.svg$") then add("icons/cleanbar/" .. entry) end
    end
    add(cbBackupIconRef(snapshot.clean_left_tab_icon))
    add(cbBackupIconRef(snapshot.clean_middle_tab_icon))
    add(cbBackupIconRef(snapshot.clean_right_tab_icon))
    for _, item in pairs(snapshot.custom_buttons or {}) do
        if type(item) == "table" then add(cbBackupIconRef(item.icon)) end
    end
    table.sort(files, function(a,b) return a.name < b.name end)
    return files
end

local function cbBackupLocation(name)
    return cbBackupDir() .. "/" .. name
end

local function cbBackupExport(label)
    local rapidjson = require("rapidjson")
    local snap = cbBackupConfigCopy(config)
    local manifest = {
        format = cb_backup_format,
        saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        settings = snap,
    }
    local json, err = rapidjson.encode(manifest)
    if not json then error(err or "JSON encoding error") end
    local entries = {{ name = "cleanbar.json", data = json }}
    for _, entry in ipairs(cbBackupSourceIcons(snap)) do entries[#entries + 1] = entry end
    if not cbBackupMakeDir(cbBackupDir()) then error("Cannot create backup directory") end
    local clean_label = tostring(label or "")
    for source, dest in pairs({["á"]="a",["à"]="a",["â"]="a",["ã"]="a",
        ["é"]="e",["ê"]="e",["í"]="i",["ó"]="o",["ô"]="o",["õ"]="o",
        ["ú"]="u",["ç"]="c",["Á"]="A",["É"]="E",["Í"]="I",
        ["Ó"]="O",["Ú"]="U",["Ç"]="C"}) do
        clean_label = clean_label:gsub(source, dest)
    end
    clean_label = clean_label:gsub("[^%w_%- ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #clean_label > 60 then clean_label = clean_label:sub(1,60) end
    if clean_label == "" then clean_label = "Cleanbar_" .. os.date("%Y%m%d_%H%M%S") end
    local target, count = cbBackupLocation(clean_label .. ".zip"), 2
    while cbBackupFs().attributes(target) do
        target = cbBackupLocation(clean_label .. "_" .. count .. ".zip")
        count = count + 1
    end
    local ok, why = cbBackupWriteNew(target, cbBackupZipWrite(entries))
    if not ok then error(why or "Cannot write backup") end
    return target:match("([^/]+)$"), #entries - 1
end

local function cbBackupLoad(name)
    if not name:match("^[%w_%- ]+%.zip$") or #name > 100 then error("Invalid backup filename") end
    local data = cbBackupRead(cbBackupLocation(name), cb_backup_max_bytes + 150000)
    local entries = cbBackupZipRead(data)
    local rapidjson = require("rapidjson")
    local decoded = rapidjson.decode(entries["cleanbar.json"])
    if type(decoded) ~= "table" or decoded.format ~= cb_backup_format or type(decoded.settings) ~= "table" then
        error("Unsupported Clean bar backup")
    end
    -- Reject unsupported JSON values or cyclic data before any writes.
    decoded.settings = cbBackupConfigCopy(decoded.settings)
    return decoded, entries
end

local function cbBackupPatchPresent(filename)
    if type(filename) ~= "string" or not filename:match("^[%w_%-]+%.lua$") then return false end
    local root = require("datastorage"):getDataDir()
    return cleanBarFileExists(root .. "/patches/" .. filename)
        or cleanBarFileExists("patches/" .. filename)
end

local function cbBackupPluginPresent(name)
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") then return false end
    return libraryPluginAvailable(name)
end

local function cbBackupActionAvailable(cfg)
    if type(cfg) ~= "table" then return false end
    local act = cfg.action_type or "event"
    if act == "patch" then
        local record = config.clean_patch_actions[cfg.menu_key or ""]
        return type(record) == "table" and cbBackupPatchPresent(record.patch)
    elseif act == "plugin_menu" then
        local record = config.clean_plugin_menu_actions[cfg.menu_key or ""]
        return type(record) == "table" and cbBackupPluginPresent(record.plugin)
    elseif act == "plugin" then
        return cbBackupPluginPresent(cfg.plugin)
    elseif act == "event" then
        if type(cfg.source_plugin) == "string" and cfg.source_plugin ~= "" then
            return cbBackupPluginPresent(cfg.source_plugin)
        end
        -- Legacy plugin-event buttons predate source_plugin: if their event
        -- matches a previously saved plugin shortcut, verify its owner too.
        for _, record in pairs(config.clean_plugin_actions or {}) do
            if type(record) == "table" and record.event == cfg.event
                and not cbBackupPluginPresent(record.plugin) then return false end
        end
    end
    -- Built-in events and module actions retain their normal runtime checks.
    return true
end

local function cbBackupCompatibility(snapshot, entries)
    local issues, count = {}, 0
    local function missing(label)
        count = count + 1
        if #issues < 8 then issues[#issues + 1] = label end
    end
    for slot, cfg in pairs(snapshot.custom_buttons or {}) do
        if type(cfg) == "table" and snapshot.show_buttons and snapshot.show_buttons[slot] then
            local act = cfg.action_type or "event"
            if act == "patch" then
                local item = snapshot.clean_patch_actions and snapshot.clean_patch_actions[cfg.menu_key or ""]
                if not item or not cbBackupPatchPresent(item.patch) then missing(slot .. ": patch") end
            elseif act == "plugin_menu" then
                local item = snapshot.clean_plugin_menu_actions and snapshot.clean_plugin_menu_actions[cfg.menu_key or ""]
                if not item or not cbBackupPluginPresent(item.plugin) then missing(slot .. ": plugin") end
            elseif act == "plugin" and not cbBackupPluginPresent(cfg.plugin) then
                missing(slot .. ": " .. tostring(cfg.plugin or "plugin"))
            elseif act == "event" then
                local owner = cfg.source_plugin
                if not owner or owner == "" then
                    for _, action in pairs(snapshot.clean_plugin_actions or {}) do
                        if type(action) == "table" and action.event == cfg.event then
                            owner = action.plugin
                            break
                        end
                    end
                end
                if owner and owner ~= "" and not cbBackupPluginPresent(owner) then
                    missing(slot .. ": " .. owner)
                end
            end
        end
    end
    for key, item in pairs(snapshot.clean_patch_actions or {}) do
        if snapshot.clean_menu_items and snapshot.clean_menu_items[key] and
            type(item) == "table" and not cbBackupPatchPresent(item.patch) then
            missing("Patch: " .. tostring(item.patch))
        end
    end
    for _, tab in ipairs({"clean_plugin_actions", "clean_plugin_menu_actions"}) do
        for key, item in pairs(snapshot[tab] or {}) do
            if snapshot.clean_menu_items and snapshot.clean_menu_items[key]
                and type(item) == "table" and not cbBackupPluginPresent(item.plugin) then
                missing("Plugin: " .. tostring(item.plugin))
            end
        end
    end
    if snapshot.clean_right_destination == "bookshelf" and not cbBackupPluginPresent("bookshelf") then
        missing("Bookshelf")
    elseif snapshot.clean_right_destination == "projecttitle" and not cbBackupPluginPresent("projecttitle") then
        missing("Project: Title")
    end
    for _, icon in pairs({ snapshot.clean_left_tab_icon, snapshot.clean_middle_tab_icon,
                              snapshot.clean_right_tab_icon }) do
        local path = cbBackupIconRef(icon)
        if path and icon:match("^cleanbar/") and not entries[path]
            and not cleanBarFileExists(cbUserIconDir() .. "/" .. path:sub(7)) then
            missing("SVG: " .. tostring(icon))
        end
    end
    for slot, item in pairs(snapshot.custom_buttons or {}) do
        if type(item) == "table" and type(item.icon) == "string"
            and item.icon:match("^cleanbar/") then
            local path = cbBackupIconRef(item.icon)
            if path and not entries[path]
                and not cleanBarFileExists(cbUserIconDir() .. "/" .. path:sub(7)) then
                missing("SVG " .. tostring(slot) .. ": " .. item.icon)
            end
        end
    end
    return count, issues
end

local function cbBackupRemapIcon(snapshot, old_name, new_name)
    for _, key in ipairs({"clean_left_tab_icon", "clean_middle_tab_icon", "clean_right_tab_icon"}) do
        if snapshot[key] == old_name then snapshot[key] = new_name end
    end
    for _, cfg in pairs(snapshot.custom_buttons or {}) do
        if type(cfg) == "table" and cfg.icon == old_name then cfg.icon = new_name end
    end
end

local function cbBackupRestore(decoded, entries, touch_menu)
    local snapshot = decoded.settings
    -- Always preserve the destination device's current layout and icons first.
    -- Refuse to overwrite settings if this safeguard cannot be written.
    cbBackupExport("Antes_do_restauro_" .. os.date("%Y%m%d_%H%M%S"))
    local icon_root, created = cbUserIconDir(), {}
    local icons = {}
    for name, contents in pairs(entries) do
        if name ~= "cleanbar.json" then icons[#icons + 1] = { name = name, data = contents } end
    end
    table.sort(icons, function(a,b) return a.name < b.name end)
    -- Preflight all paths, sizes, and SVG markup before writing any file.
    for _, icon in ipairs(icons) do
        if #icon.data > cb_backup_max_svg or not icon.data:find("<svg", 1, true)
            or icon.data:lower():find("<script", 1, true)
            or icon.data:lower():find("<foreignobject", 1, true)
            or icon.data:lower():find("javascript:", 1, true) then
            error("Invalid SVG file")
        end
    end
    local function rollback()
        for _, path in ipairs(created) do os.remove(path) end
    end
    for _, icon in ipairs(icons) do
        local original_ref = icon.name:sub(#"icons/" + 1):gsub("%.svg$", "")
        local target_name = icon.name:sub(#"icons/" + 1)
        local target = icon_root .. "/" .. target_name
        local present = cbBackupRead(target, cb_backup_max_svg)
        local target_exists = cbBackupFs().attributes(target, "mode") == "file"
        if present ~= icon.data then
            if target_exists then
                -- Never overwrite another device's modified SVG. Give the
                -- restored one a distinct name and remap saved references.
                local base = target_name:match("([^/]+)%.svg$") or "icon"
                local stem = string.format("cleanbar/cleanbar_restored_%08x_%s",
                    cbBackupCRC(icon.data), base)
                local suffix = 1
                repeat
                    target_name = stem .. (suffix > 1 and "_" .. suffix or "") .. ".svg"
                    target = icon_root .. "/" .. target_name
                    suffix = suffix + 1
                until cbBackupFs().attributes(target, "mode") ~= "file"
                    or cbBackupRead(target, cb_backup_max_svg) == icon.data
                cbBackupRemapIcon(snapshot, original_ref, target_name:gsub("%.svg$", ""))
            end
            local parent = target:match("^(.*)/[^/]+$")
            if not cbBackupMakeDir(parent) then rollback(); error("Cannot create SVG folder") end
            if cbBackupFs().attributes(target, "mode") ~= "file" then
                local ok = cbBackupWriteNew(target, icon.data)
                if not ok then rollback(); error("Cannot restore SVG") end
                created[#created + 1] = target
            end
        end
    end
    -- Update only Clean bar's settings, leaving every other KOReader setting
    -- and all plugins/patches untouched.
    local original = config
    local ok, why = pcall(function()
        G_reader_settings:saveSetting(CLEAN_BAR_SETTINGS_KEY, snapshot)
        loadConfig()
        saveConfig()
    end)
    if not ok then
        G_reader_settings:saveSetting(CLEAN_BAR_SETTINGS_KEY, original)
        config = original
        rollback()
        error(why)
    end
    if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
    -- The top menu is rebuilt the next time it opens. Avoid rebuilding a
    -- TouchMenu while a nested restore confirmation is still closing.
    return #created
end

local function cbBackupList()
    local result = {}
    for _, filename in ipairs(cleanBarListDir(cbBackupDir())) do
        if filename:match("^[%w_%- ]+%.zip$") then result[#result + 1] = filename end
    end
    table.sort(result, function(a, b) return a:lower() > b:lower() end)
    return result
end

local function cbBackupReport(filename)
    local decoded, entries = cbBackupLoad(filename)
    local missing, issues = cbBackupCompatibility(decoded.settings, entries)
    local icons = 0
    for name in pairs(entries) do if name ~= "cleanbar.json" then icons = icons + 1 end end
    local selected_buttons, selected_menu = 0, 0
    for _, enabled in pairs(decoded.settings.show_buttons or {}) do
        if enabled == true then selected_buttons = selected_buttons + 1 end
    end
    for _, enabled in pairs(decoded.settings.clean_menu_items or {}) do
        if enabled == true then selected_menu = selected_menu + 1 end
    end
    local message = (isPortugueseUI() and "Configuração: " or "Configuration: ") .. filename
        .. "\n" .. (isPortugueseUI() and "Guardada em: " or "Saved at: ") .. tostring(decoded.saved_at or "?")
        .. "\n" .. (isPortugueseUI() and "Botões ativos: " or "Visible buttons: ") .. selected_buttons
        .. "\n" .. (isPortugueseUI() and "Opções do Menu Clean: " or "Clean menu entries: ") .. selected_menu
        .. "\n" .. (isPortugueseUI() and "Ícones SVG: " or "SVG icons: ") .. icons
        .. "\n" .. (isPortugueseUI() and "Dependências em falta: " or "Missing dependencies: ") .. missing
    if missing > 0 then
        message = message .. "\n" .. table.concat(issues, "\n")
        if missing > #issues then message = message .. "\n..." end
    end
    message = message .. "\n" .. (isPortugueseUI()
        and "Nota: compatibilidade interna de ações e menus confirma-se ao utilizar."
        or "Note: internal action/menu compatibility is confirmed on use.")
    return message, decoded, entries
end

local function cbBackupShowError(why)
    showInfo((isPortugueseUI() and "Erro no backup Clean bar: " or "Clean bar backup error: ") .. tostring(why))
end

local function cbBackupSaveDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = CT("backup_save"),
        input = "Cleanbar_" .. os.date("%Y%m%d_%H%M%S"),
        buttons = {{
            { text = CT("cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = CT("backup_save"), is_enter_default = true, callback = function()
                local label = dialog:getInputText()
                UIManager:close(dialog)
                local ok, name, icons = pcall(cbBackupExport, label)
                if ok then
                    showInfo(CT("backup_saved") .. "\n" .. name .. " (" .. icons .. " SVG)")
                else cbBackupShowError(name) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function cbBackupOpenRestore(filename, touch_menu)
    local ok, report, decoded, entries = pcall(cbBackupReport, filename)
    if not ok then cbBackupShowError(report); return end
    local confirm = ConfirmBox:new{
        text = report .. "\n\n" .. CT("backup_confirm"),
        ok_text = CT("backup_restore"),
        cancel_text = CT("cancel"),
        ok_callback = function()
            local done, outcome = pcall(cbBackupRestore, decoded, entries, touch_menu)
            if done then showInfo(CT("backup_restored") .. " (" .. outcome .. " SVG)")
            else cbBackupShowError(outcome) end
        end,
    }
    UIManager:show(confirm)
end

local function cbBackupDelete(filename)
    UIManager:show(ConfirmBox:new{
        text = CT("backup_delete_confirm") .. "\n" .. filename,
        ok_text = CT("backup_delete"), cancel_text = CT("cancel"),
        ok_callback = function()
            if os.remove(cbBackupLocation(filename)) then showInfo(CT("backup_deleted"))
            else cbBackupShowError("Cannot delete backup") end
        end,
    })
end

local function cbBackupRenameDialog(filename)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = CT("backup_rename"),
        input = filename:gsub("%.zip$", ""),
        buttons = {{
            { text = CT("cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = CT("backup_rename"), callback = function()
                local label = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                if label:match("^[%w_%- ]+$") and #label <= 60 then
                    local new_name = label .. ".zip"
                    if new_name == filename then return end
                    if cbBackupFs().attributes(cbBackupLocation(new_name)) then
                        cbBackupShowError("Name already exists")
                    elseif os.rename(cbBackupLocation(filename), cbBackupLocation(new_name)) then
                        showInfo(CT("backup_renamed") .. " " .. new_name)
                    else cbBackupShowError("Cannot rename backup") end
                else cbBackupShowError("Invalid name") end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function cbBackupItems(mode)
    local items = {}
    for _, filename in ipairs(cbBackupList()) do
        local current_name = filename
        local actions = {
            { text = CT("backup_check"), callback = function()
                local ok, report = pcall(cbBackupReport, current_name)
                if ok then showInfo(report) else cbBackupShowError(report) end
            end },
        }
        if mode == "manage" then
            actions[#actions + 1] = { text = CT("backup_rename"), callback = function()
                cbBackupRenameDialog(current_name)
            end }
            actions[#actions + 1] = { text = CT("backup_delete"), callback = function()
                cbBackupDelete(current_name)
            end }
        else
            actions[#actions + 1] = { text = CT("backup_restore"), callback = function(touch_menu)
                cbBackupOpenRestore(current_name, touch_menu)
            end }
        end
        items[#items + 1] = { text = current_name, sub_item_table = actions }
    end
    if #items == 0 then return {{ text = CT("backup_empty"), enabled = false }} end
    return items
end
-- <<< CLEAN BAR v10 PORTABLE BACKUPS
    return { saveDialog = cbBackupSaveDialog, items = cbBackupItems,
             actionAvailable = cbBackupActionAvailable }
end)()

local function buildSettingsMenu()
    normalizeButtonOrder()

    -- Button toggle sub-items. Use the same order as the action bar, so
    -- Clean is always listed and new buttons are not hidden at the end.
    local button_toggle_items = {}
    for _, id in ipairs(config.button_order) do
        if isButtonAvailable(id) and not isCustomButtonId(id) then
            table.insert(button_toggle_items, {
                text = getButtonDisplayName(id),
                checked_func = function() return config.show_buttons[id] end,
                callback = function(touch_menu)
                    config.show_buttons[id] = not config.show_buttons[id]
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end,
            })
        end
    end

    -- Arrange buttons item
    local arrange_button_item = {
        text = CT("arrange_clean_bar_buttons"),
        keep_menu_open = true,
        separator = true,
        callback = function(touch_menu)
            normalizeButtonOrder()
            local SortWidget = require("ui/widget/sortwidget")
            local sort_items = {}
            for _, id in ipairs(config.button_order) do
                if isButtonAvailable(id) then
                    table.insert(sort_items, {
                        text = getButtonDisplayName(id),
                        orig_item = id,
                        dim = not config.show_buttons[id],
                    })
                end
            end
            UIManager:show(SortWidget:new{
                title = CT("arrange_clean_bar_buttons"),
                item_table = sort_items,
                callback = function()
                    local new_order = {}
                    local seen = {}
                    for _, item in ipairs(sort_items) do
                        local id = item.orig_item
                        if id and isButtonAvailable(id) and not seen[id] then
                            table.insert(new_order, id)
                            seen[id] = true
                        end
                    end
                    for _, id in ipairs(config_default.button_order) do
                        if isButtonAvailable(id) and not seen[id] then
                            table.insert(new_order, id)
                            seen[id] = true
                        end
                    end
                    config.button_order = new_order
                    normalizeButtonOrder()
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end,
            })
        end,
    }

    return {
        text = CT("clean_bar"),
        -- Never enumerate our own configuration menu as a KOReader action.
        -- Its dynamic submenus would recursively enumerate the menu again.
        _clean_bar_settings = true,
        sub_item_table = {
            {
                text = CT("buttons"),
                sub_item_table = {
                    arrange_button_item,
                    { text = CT("visible_buttons"), sub_item_table = button_toggle_items },
                    { text = CT("configure_buttons"), sub_item_table = buildCustomButtonsSettingsMenu() },
                },
            },
            {
                text = CT("top_tabs"),
                sub_item_table = {
                    { text = CT("left_tab_icon"),
                      callback = function(touch_menu)
                          showIconPreviewPicker("__tab_left", touch_menu, "", 1)
                      end },
                    { text = CT("middle_tab_icon"),
                      callback = function(touch_menu)
                          showIconPreviewPicker("__tab_middle", touch_menu, "", 1)
                      end },
                    { text = CT("right_tab_icon"),
                      callback = function(touch_menu)
                          showIconPreviewPicker("__tab_right", touch_menu, "", 1)
                      end },
                    { text = CT("right_tab_destination"),
                      sub_item_table_func = buildRightTabDestinationMenu },
                },
            },
            {
                text = CT("show_frontlight"),
                checked_func = function() return config.show_frontlight end,
                callback = function(touch_menu)
                    config.show_frontlight = not config.show_frontlight
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end,
            },
            {
                text = CT("show_warmth"),
                checked_func = function() return config.show_warmth end,
                callback = function(touch_menu)
                    config.show_warmth = not config.show_warmth
                    saveConfig()
                    refreshCleanBarPanel(touch_menu)
                end,
            },
            {
                text = CT("button_style"),
                sub_item_table = {
                    {
                        text = CT("button_style_circle"),
                        checked_func = function() return config.button_style == "circle" end,
                        callback = function(touch_menu)
                            config.button_style = "circle"
                            saveConfig()
                            refreshCleanBarPanel(touch_menu)
                        end,
                    },
                    {
                        text = CT("button_style_premium"),
                        checked_func = function() return config.button_style == "premium" end,
                        callback = function(touch_menu)
                            config.button_style = "premium"
                            saveConfig()
                            refreshCleanBarPanel(touch_menu)
                        end,
                    },
                    {
                        text = CT("button_style_clean_icons"),
                        checked_func = function() return config.button_style == "clean_icons" end,
                        callback = function(touch_menu)
                            config.button_style = "clean_icons"
                            saveConfig()
                            refreshCleanBarPanel(touch_menu)
                        end,
                    },
                },
                separator = true,
            },
            {
                text = CT("clean_mode"),
                checked_func = function() return config.clean_mode end,
                keep_menu_open = true,
                check_callback_updates_menu = true,
                callback = function(touch_menu)
                    config.clean_mode = not config.clean_mode
                    saveConfig()
                    if refreshCleanModeMenu and touch_menu then
                        refreshCleanModeMenu(touch_menu)
                    elseif touch_menu and touch_menu.updateItems then
                        touch_menu:updateItems(1)
                    end
                end,
            },
            {
                text = CT("always_open"),
                checked_func = function() return config.open_on_start end,
                callback = function()
                    config.open_on_start = not config.open_on_start
                    saveConfig()
                end,
            },
            {
                text = CT("backup_settings"), separator = true,
                sub_item_table = {
                    { text = CT("backup_save"), callback = CleanBarBackup.saveDialog },
                    { text = CT("backup_restore"), sub_item_table_func = function() return CleanBarBackup.items("restore") end },
                    { text = CT("backup_manage"), sub_item_table_func = function() return CleanBarBackup.items("manage") end },
                },
            },
        },
    }
end

-- ============================================================
-- Clean mode custom tab
-- ============================================================

local isCleanBarTab
local isCleanCustomTab

local function safeMenuText(value)
    if type(value) == "string" then
        return value
    elseif type(value) == "function" then
        local ok, result = pcall(value)
        if ok and type(result) == "string" then
            return result
        end
    end
    return nil
end

local function getMenuItemLabel(item)
    if type(item) ~= "table" then return nil end
    local text = safeMenuText(item.text)
    if text and text ~= "" then return text end
    text = safeMenuText(item.text_func)
    if text and text ~= "" then return text end
    return nil
end

local function getTabLabel(tab, index)
    if type(tab) ~= "table" then
        return CT("menu_source_unknown") .. " " .. tostring(index)
    end
    local tab_names = {
        filebrowser = { en = "File browser", pt = "Explorador de ficheiros" },
        filemanager = { en = "File manager", pt = "Gestor de ficheiros" },
        settings = { en = "Settings", pt = "Definições" },
        setting = { en = "Settings", pt = "Definições" },
        tools = { en = "Tools", pt = "Ferramentas" },
        search = { en = "Search", pt = "Pesquisa" },
        menu = { en = "Menu", pt = "Menu" },
        appbar = { en = "Main menu", pt = "Menu principal" },
        history = { en = "History", pt = "Histórico" },
        bookmarks = { en = "Bookmarks", pt = "Marcadores" },
        navigation = { en = "Navigation", pt = "Navegação" },
        typeset = { en = "Typography", pt = "Tipografia" },
    }
    local function present(raw)
        if type(raw) ~= "string" or raw == "" then return nil end
        local lower = raw:lower()
        -- Identifiers like 'Appbar.tools' are NOT translated menu titles.
        -- Strip the implementation-specific prefix before finding a label.
        lower = lower:gsub("^appbar[%.:_%-]", "")
        lower = lower:gsub("^appbar/", "")
        local name = tab_names[lower]
        if name then return isPortugueseUI() and name.pt or name.en end
        -- Prefer actual translated KOReader menu captions when present.
        if not raw:lower():match("^appbar[%.:_%-/]") and raw:lower() ~= "appbar" then
            return raw
        end
        local cleaned = lower:gsub("[_%-]", " "):gsub("^%l", string.upper)
        return cleaned ~= "" and cleaned or nil
    end
    local raw_text = safeMenuText(tab.text) or safeMenuText(tab.name) or safeMenuText(tab.title)
    local text = present(raw_text)
    if text then return text end
    text = present(tab.icon)
    if text then return text end
    return CT("menu_source_unknown") .. " " .. tostring(index)
end

local function makeCleanChoiceKey(tab, tab_index, item_index)
    local tab_part = "tab" .. tostring(tab_index)
    if type(tab) == "table" and type(tab.icon) == "string" and tab.icon ~= "" then
        tab_part = tab.icon
    end
    return tab_part .. ":" .. tostring(item_index)
end

local function copyMenuItem(item)
    local copy = {}
    for k, v in pairs(item) do
        copy[k] = v
    end
    return copy
end

local function defaultCleanInclude(choice)
    local text = ((choice.tab_label or "") .. " " .. (choice.label or "")):lower()
    return text:find("file search", 1, true)
        or text:find("pesquisa", 1, true)
        or text:find("search", 1, true)
        or text:find("cloud", 1, true)
        or text:find("nuvem", 1, true)
        or text:find("opds", 1, true)
        or text:find("history", 1, true)
        or text:find("histórico", 1, true)
        or text:find("favorites", 1, true)
        or text:find("favoritos", 1, true)
end

-- Discover actual KOReader menu trees, including entries introduced by plugins
-- and user patches. Keep the original item tables/callbacks intact.
local function getCurrentMenuTabs(source_tabs)
    local reader_context = false
    for _, tab in ipairs(source_tabs or {}) do
        if type(tab) == "table" and tab.icon == "appbar.navigation" then
            reader_context = true
            break
        end
    end
    -- The patch explorer can run without source_tabs (from button settings).
    -- Use the active ReaderUI when reading, not FileManager's stale menu.
    if not source_tabs then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        reader_context = ok_reader and ReaderUI and ReaderUI.instance
            and ReaderUI.instance.document and ReaderUI.instance.menu and true or false
    end
    local ok, Host
    if reader_context then
        ok, Host = pcall(require, "apps/reader/readerui")
    else
        ok, Host = pcall(require, "apps/filemanager/filemanager")
    end
    local menu = ok and Host and Host.instance and Host.instance.menu
    local real_tabs = menu and menu.tab_item_table
    -- The live reader menu is the authoritative source: it contains options
    -- registered by late addToMainMenu() plugins (as verified on the Kobo).
    if type(real_tabs) == "table" and #real_tabs > 0 then
        return real_tabs
    end
    return source_tabs
end

-- ============================================================
-- Verified userpatch actions (v10: provenance-aware / lazy)
-- ============================================================
-- Merely finding "2-foo.lua" is NOT evidence that an arbitrary KOReader menu
-- item belongs to it. Lua debug source identifies functions actually created
-- by an installed patch. We NEVER execute a patch file or pre-expand dynamic
-- native menus while indexing. Dynamic paths are explored only on user tap.
local function cleanBarInstalledPatchFiles()
    local dirs = { "patches", "./patches", "/mnt/onboard/.adds/koreader/patches" }
    local ok_storage, ds = pcall(require, "datastorage")
    if ok_storage and ds and type(ds.getPatchesDir) == "function" then
        local ok, home = pcall(ds.getPatchesDir)
        if ok and type(home) == "string" then dirs[#dirs + 1] = home end
    end
    local ok_userpatch, userpatch = pcall(require, "userpatch")
    if ok_userpatch and userpatch and type(userpatch.arePatchesDisabled) == "function" then
        local ok, disabled = pcall(userpatch.arePatchesDisabled)
        if ok and disabled then return {} end
    end
    local found, files = {}, {}
    for _, dir in ipairs(dirs) do
        for _, filename in ipairs(cleanBarListDir(dir)) do
            if filename:match("^[0-9]+%-.*%.lua$")
                and filename ~= "2-clean-bar.lua"
                and not found[filename]
                and not (ok_userpatch and userpatch and type(userpatch.execution_status) == "table"
                    and userpatch.execution_status[filename] == false) then
                found[filename] = true
                files[#files + 1] = filename
            end
        end
    end
    table.sort(files)
    return files
end

local function cleanBarPatchDisplayName(filename)
    local name = (filename or ""):gsub("^%d+%-+", ""):gsub("%.lua$", "")
    name = name:gsub("[_%-]+", " ")
    return name:gsub("^%l", string.upper)
end

-- Return the patch filename, or nil. Functions defined by core KOReader or
-- by a different patch are NEVER accepted as proof of ownership.
local function cleanBarSourcePatch(fn)
    if type(fn) ~= "function" or not debug or type(debug.getinfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or type(info) ~= "table" or type(info.source) ~= "string" then
        return nil
    end
    local path = info.source:gsub("\\", "/")
    if not path:find("/patches/", 1, true)
        and not path:match("^@patches/")
        and not path:match("^@%./patches/") then
        return nil
    end
    local file = path:match("([^/]+)$")
    if file and file:match("^[0-9]+%-.*%.lua$") and file ~= "2-clean-bar.lua" then
        return file
    end
    return nil
end

-- Inspect the item's own functions, NOT callback upvalues or submenu content
-- from another patch. This prevents false ownership from native menu wrappers.
local patch_item_hooks = {
    -- Only functions which DEFINE an action/menu. A patch that merely changes
    -- a native item's caption or checkmark does not own that native action.
    "callback", "callback_func", "sub_item_table_func",
}
local function cleanBarPatchOwner(item)
    if type(item) ~= "table" then return nil end
    for _, name in ipairs(patch_item_hooks) do
        local owner = cleanBarSourcePatch(rawget(item, name))
        if owner then return owner end
    end
    return nil
end
-- A patch can create a pure container { text=..., sub_item_table={...} }
-- without placing a function on the parent row. Infer ownership ONLY when
-- all executable descendants belong to the same patch. Native mixed menus
-- such as "Status bar" are deliberately excluded.
local function cleanBarPurePatchContainerOwner(item, depth, visited)
    if depth > 8 or type(item) ~= "table"
        or type(item.sub_item_table) ~= "table"
        or type(item.callback) == "function"
        or type(item.callback_func) == "function"
        or type(item.sub_item_table_func) == "function" then return nil end
    visited = visited or {}
    if visited[item] then return nil end
    visited[item] = true
    local owner, found = nil, false
    for _, child in ipairs(item.sub_item_table) do
        if type(child) == "table" then
            local child_owner = cleanBarPatchOwner(child)
            local child_action = type(child.callback) == "function"
                or type(child.callback_func) == "function"
                or type(child.sub_item_table_func) == "function"
            if not child_owner and type(child.sub_item_table) == "table" then
                child_owner = cleanBarPurePatchContainerOwner(child, depth + 1, visited)
            end
            if child_action or type(child.sub_item_table) == "table" then
                if not child_owner or (owner and owner ~= child_owner) then return nil end
                owner = child_owner
                found = true
            end
        end
    end
    -- Even a native category whose only present child is one patch is NOT
    -- that patch's own menu. Require the parent caption to identify the same
    -- patch (exact normalized title); otherwise leave it as navigation.
    if not found or not owner or type(item.text) ~= "string" then return nil end
    local filename_title = owner:gsub("^%d+%-+", ""):gsub("%.lua$", "")
        :gsub("[_%-]+", " "):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local menu_title = item.text:gsub("[_%-]+", " "):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    return filename_title == menu_title and owner or nil
end
local function cleanBarPatchMenuOwner(item)
    return cleanBarPatchOwner(item) or cleanBarPurePatchContainerOwner(item, 0)
end
local function cleanBarSelectablePatchItem(item, patch_file)
    return cleanBarPatchMenuOwner(item) == patch_file
        and (type(item.callback) == "function"
            or type(item.callback_func) == "function"
            or type(item.sub_item_table) == "table"
            or type(item.sub_item_table_func) == "function")
end

local function cleanBarPatchKey(patch_file, tab_icon, path)
    return "cleanbar:patch:" .. patch_file .. ":" .. tostring(tab_icon)
        .. ":" .. table.concat(path, " / ")
end

-- Resolve just the saved route. A shortcut is disabled if the patch no longer
-- owns its destination (including legacy shortcuts saved by the broken v10).
resolveSavedPatchMenuItem = function(record, source_tabs)
    if type(record) ~= "table" or type(record.path) ~= "table"
        or type(record.patch) ~= "string" then return nil end
    local root = getCurrentMenuTabs(source_tabs)
    for _, tab in ipairs(root or {}) do
        if type(tab) == "table" and tab.icon == record.tab_icon
            and not tab._clean_bar_patch and not tab._clean_bar_clean_patch then
            local items, result = tab, nil
            for idx, name in ipairs(record.path) do
                result = nil
                if type(items) ~= "table" then break end
                for _, item in ipairs(items) do
                    if type(item) == "table" and getMenuItemLabel(item) == name then
                        result = item
                        break
                    end
                end
                if not result then break end
                if idx < #record.path then
                    if type(result.sub_item_table) == "table" then
                        items = result.sub_item_table
                    elseif type(result.sub_item_table_func) == "function" then
                        local ok, submenu = pcall(result.sub_item_table_func)
                        if not ok or type(submenu) ~= "table" then return nil end
                        items = submenu
                    else
                        return nil
                    end
                end
            end
            if result and cleanBarSelectablePatchItem(result, record.patch) then
                return result
            end
        end
    end
    return nil
end

local function cleanBarStorePatchChoice(patch_file, tab_icon, path, label)
    local key = cleanBarPatchKey(patch_file, tab_icon, path)
    config.clean_patch_actions[key] = {
        patch = patch_file, tab_icon = tab_icon, path = path, label = label,
        verified = true,
    }
    saveConfig()
    if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
    return key
end

local function cleanBarCopyPath(path, label)
    local result = {}
    for _, p in ipairs(path) do result[#result + 1] = p end
    result[#result + 1] = label
    return result
end

-- Options are only offered for items whose Lua callback/menu function was
-- defined inside the selected patch file. Never assign unrelated native actions.
local function cleanBarVerifiedPatchOptions(item, patch_file, tab_icon, path, target_id)
    local label = getMenuItemLabel(item)
    if not label or not cleanBarSelectablePatchItem(item, patch_file) then
        return {{ text = CT("patch_no_items"), enabled = false }}
    end
    local key = cleanBarPatchKey(patch_file, tab_icon, path)
    local options = {
        { text = (config.clean_menu_items[key] and CT("patch_remove_menu") or CT("patch_add_menu")),
          keep_menu_open = true,
          callback = function()
              if config.clean_menu_items[key] then
                  config.clean_menu_items[key] = nil
              else
                  cleanBarStorePatchChoice(patch_file, tab_icon, path, label)
                  config.clean_menu_items[key] = true
              end
              saveConfig()
              if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
          end },
    }
    local function assign(slot, touch_menu)
        local action_key = cleanBarStorePatchChoice(patch_file, tab_icon, path, label)
        applyCustomButtonConfig(slot, {
            label = label, icon = "custommenu", action_type = "patch",
            event = "", event_arg = "", dispatch = "broadcast",
            plugin = "", method = "", menu_label = label,
            menu_tab_label = cleanBarPatchDisplayName(patch_file),
            menu_key = action_key,
        }, touch_menu)
    end
    if target_id then
        options[#options + 1] = {
            text = CT("patch_use_this_button"),
            callback = function(touch_menu) assign(target_id, touch_menu) end,
        }
    else
        local slots = {}
        for _, id in ipairs(custom_button_slots) do
            local slot = id
            slots[#slots + 1] = {
                text = getCustomButtonSummary(slot),
                callback = function(touch_menu) assign(slot, touch_menu) end,
            }
        end
        options[#options + 1] = {
            text = CT("patch_use_button"), sub_item_table = slots,
        }
    end
    -- Preview the real patch menu without making an unrelated native menu
    -- masquerade as this patch. For a submenu, this preserves its UI choices.
    if type(item.sub_item_table) == "table" or type(item.sub_item_table_func) == "function" then
        options[#options + 1] = {
            text = isPortugueseUI() and "Abrir opções originais" or "Open original options",
            sub_item_table_func = function()
                if type(item.sub_item_table) == "table" then return item.sub_item_table end
                local ok, children = pcall(item.sub_item_table_func)
                return ok and type(children) == "table" and children
                    or {{ text = CT("patch_no_items"), enabled = false }}
            end,
        }
    end
    return options
end

-- Index ONLY already-materialized native menu tables. Do not call a single
-- sub_item_table_func during this pass. This is bounded and cycle-safe.
local function cleanBarStaticPatchItems(tabs)
    local by_patch, seen, count = {}, {}, 0
    local function walk(items, tab_icon, path, depth)
        if depth > 11 or type(items) ~= "table" or seen[items] then return end
        seen[items] = true
        for _, item in ipairs(items) do
            count = count + 1
            if count > 1400 then return end
            if type(item) == "table" and not item._clean_bar_patch
                and not item._clean_bar_clean_patch and not item._clean_bar_settings
                and not item._clean_bar_home_patch then
                local owner = cleanBarPatchMenuOwner(item)
                local label
                if owner or type(item.sub_item_table) == "table" then
                    label = getMenuItemLabel(item)
                end
                if label and label ~= "" then
                    local next_path = cleanBarCopyPath(path, label)
                    if owner and cleanBarSelectablePatchItem(item, owner) then
                        by_patch[owner] = by_patch[owner] or {}
                        by_patch[owner][#by_patch[owner] + 1] = {
                            item = item, tab_icon = tab_icon, path = next_path,
                            label = label,
                        }
                    end
                    if type(item.sub_item_table) == "table" then
                        walk(item.sub_item_table, tab_icon, next_path, depth + 1)
                    end
                end
            end
        end
    end
    for _, tab in ipairs(tabs or {}) do
        if type(tab) == "table" and type(tab.icon) == "string"
            and not tab._clean_bar_patch and not tab._clean_bar_clean_patch
            and not tab._clean_bar_home_patch then
            walk(tab, tab.icon, {}, 0)
        end
    end
    return by_patch
end

-- A fallback for patches injected under dynamic KOReader menus. Each native
-- submenu is evaluated ONLY when the user explicitly opens it. Ordinary
-- navigation items are not assignable unless verified as belonging to patch.
local function cleanBarPatchGuidedBrowse(items, patch_file, tab_icon, path, target_id, depth)
    if depth > 11 or type(items) ~= "table" then
        return {{ text = CT("patch_no_items"), enabled = false }}
    end
    local result = {}
    for _, item in ipairs(items) do
        if type(item) == "table" and not item._clean_bar_settings
            and not item._clean_bar_patch and not item._clean_bar_clean_patch
            and not item._clean_bar_home_patch and not item.ignored_by_menu_search then
            local has_children = type(item.sub_item_table) == "table"
                or type(item.sub_item_table_func) == "function"
            local owned = cleanBarSelectablePatchItem(item, patch_file)
            if has_children or owned then
                local label = getMenuItemLabel(item)
                if label and label ~= "" then
                    local next_path = cleanBarCopyPath(path, label)
                    result[#result + 1] = {
                        text = label .. (owned and "  ✓" or ""),
                        sub_item_table_func = function()
                            local options = {}
                            if owned then
                                for _, action in ipairs(cleanBarVerifiedPatchOptions(item,
                                    patch_file, tab_icon, next_path, target_id)) do
                                    options[#options + 1] = action
                                end
                            end
                            if has_children then
                                local children = item.sub_item_table
                                if type(item.sub_item_table_func) == "function" then
                                    local ok, list = pcall(item.sub_item_table_func)
                                    children = ok and type(list) == "table" and list or nil
                                end
                                if children then
                                    for _, child in ipairs(cleanBarPatchGuidedBrowse(children,
                                        patch_file, tab_icon, next_path, target_id, depth + 1)) do
                                        options[#options + 1] = child
                                    end
                                end
                            end
                            if #options == 0 then
                                options[1] = { text = CT("patch_no_items"), enabled = false }
                            end
                            return options
                        end,
                    }
                end
            end
        end
    end
    if #result == 0 then return {{ text = CT("patch_no_items"), enabled = false }} end
    return result
end

buildInstalledPatchesMenu = function(target_id)
    local patches = cleanBarInstalledPatchFiles()
    local roots = getCurrentMenuTabs()
    local indexed = cleanBarStaticPatchItems(roots)
    local result = {}
    for _, filename in ipairs(patches) do
        local patch_file = filename
        local verified = indexed[patch_file] or {}
        result[#result + 1] = {
            text = cleanBarPatchDisplayName(patch_file),
            sub_item_table_func = function()
                local entries = {}
                -- Only the items genuinely owned by this patch are shown at
                -- the top of its list; not every generic KOReader menu tab.
                for _, hit in ipairs(verified) do
                    local choice = hit
                    entries[#entries + 1] = {
                        text = choice.label,
                        sub_item_table_func = function()
                            return cleanBarVerifiedPatchOptions(choice.item, patch_file,
                                choice.tab_icon, choice.path, target_id)
                        end,
                    }
                end
                entries[#entries + 1] = {
                    text = isPortugueseUI()
                        and "Procurar opções em submenus…"
                        or "Find options in submenus…",
                    separator = true,
                    sub_item_table_func = function()
                        local tabs = {}
                        for _, tab in ipairs(roots or {}) do
                            if type(tab) == "table" and type(tab.icon) == "string"
                                and not tab._clean_bar_patch and not tab._clean_bar_clean_patch
                                and not tab._clean_bar_home_patch then
                                local t = tab
                                tabs[#tabs + 1] = {
                                    text = getTabLabel(t, 1),
                                    sub_item_table_func = function()
                                        return cleanBarPatchGuidedBrowse(t, patch_file,
                                            t.icon, {}, target_id, 0)
                                    end,
                                }
                            end
                        end
                        return #tabs > 0 and tabs
                            or {{ text = CT("patch_no_items"), enabled = false }}
                    end,
                }
                return entries
            end,
        }
    end
    return #result > 0 and result
        or {{ text = CT("patch_no_patches"), enabled = false }}
end

-- Plugin menus work like verified patch menus: the owner is the actual Lua
-- source of the callback, never the name of a menu tab or a guessed event.
local function cleanBarSourcePlugin(fn)
    if type(fn) ~= "function" or not debug or type(debug.getinfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or type(info) ~= "table" or type(info.source) ~= "string" then
        return nil
    end
    local path = info.source:gsub("\\", "/")
    return path:match("/plugins/([%w_%-]+)%.koplugin/")
        or path:match("^@plugins/([%w_%-]+)%.koplugin/")
end

local function cleanBarPluginMenuOwner(item)
    if type(item) ~= "table" then return nil end
    for _, hook in ipairs({ "callback", "callback_func", "sub_item_table_func" }) do
        local owner = cleanBarSourcePlugin(rawget(item, hook))
        if owner then return owner end
    end
    return nil
end

local function cleanBarPluginMenuKey(plugin_name, tab_icon, path)
    return "cleanbar:pluginmenu:" .. plugin_name .. ":" .. tostring(tab_icon)
        .. ":" .. table.concat(path, " / ")
end

resolveSavedPluginMenuItem = function(record, source_tabs)
    if type(record) ~= "table" or type(record.path) ~= "table"
        or type(record.plugin) ~= "string" then return nil end
    local root = getCurrentMenuTabs(source_tabs)
    for _, tab in ipairs(root or {}) do
        if type(tab) == "table" and tab.icon == record.tab_icon
            and not tab._clean_bar_patch and not tab._clean_bar_clean_patch then
            local items, result = tab, nil
            for idx, name in ipairs(record.path) do
                result = nil
                if type(items) ~= "table" then break end
                for _, item in ipairs(items) do
                    if type(item) == "table" and getMenuItemLabel(item) == name then
                        result = item
                        break
                    end
                end
                if not result then break end
                if idx < #record.path then
                    if type(result.sub_item_table) == "table" then
                        items = result.sub_item_table
                    elseif type(result.sub_item_table_func) == "function" then
                        -- Only evaluate the one submenu needed by this saved path.
                        local ok, children = pcall(result.sub_item_table_func)
                        if not ok or type(children) ~= "table" then return nil end
                        items = children
                    else return nil end
                end
            end
            if result and cleanBarPluginMenuOwner(result) == record.plugin then
                return result
            end
        end
    end
    return nil
end

local function cleanBarVerifiedPluginOptions(item, plugin, tab_icon, path, target_id)
    if cleanBarPluginMenuOwner(item) ~= plugin then
        return {{ text = CT("patch_no_items"), enabled = false }}
    end
    local label = getMenuItemLabel(item)
    local key = cleanBarPluginMenuKey(plugin, tab_icon, path)
    local function saveChoice()
        config.clean_plugin_menu_actions[key] = {
            plugin = plugin, tab_icon = tab_icon, path = path, label = label,
        }
        saveConfig()
        if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
    end
    local function assign(slot, touch_menu)
        saveChoice()
        applyCustomButtonConfig(slot, {
            label = label, icon = "custommenu", action_type = "plugin_menu",
            event = "", event_arg = "", dispatch = "broadcast",
            plugin = "", method = "", menu_label = label,
            menu_tab_label = nicePluginLabel(plugin), menu_key = key,
        }, touch_menu)
    end
    local actions = {
        { text = (config.clean_menu_items[key] and CT("patch_remove_menu") or CT("patch_add_menu")),
          keep_menu_open = true, callback = function()
              if config.clean_menu_items[key] then
                  config.clean_menu_items[key] = nil
              else
                  saveChoice()
                  config.clean_menu_items[key] = true
              end
              saveConfig()
              if invalidateCleanChoiceCache then invalidateCleanChoiceCache() end
          end },
    }
    if target_id then
        actions[#actions + 1] = {
            text = CT("patch_use_this_button"),
            callback = function(touch_menu) assign(target_id, touch_menu) end,
        }
    else
        local slots = {}
        for _, id in ipairs(custom_button_slots) do
            local slot = id
            slots[#slots + 1] = {
                text = getCustomButtonSummary(slot),
                callback = function(touch_menu) assign(slot, touch_menu) end,
            }
        end
        actions[#actions + 1] = { text = CT("patch_use_button"), sub_item_table = slots }
    end
    if type(item.sub_item_table) == "table" or type(item.sub_item_table_func) == "function" then
        actions[#actions + 1] = {
            text = isPortugueseUI() and "Abrir opções originais" or "Open original options",
            sub_item_table_func = function()
                if type(item.sub_item_table) == "table" then return item.sub_item_table end
                local ok, children = pcall(item.sub_item_table_func)
                return ok and type(children) == "table" and children
                    or {{ text = CT("patch_no_items"), enabled = false }}
            end,
        }
    end
    return actions
end

-- This browser reads only materialized menu tables. It descends into a dynamic
-- submenu only after the user opens that specific row, not while listing plugins.
local function cleanBarPluginGuidedBrowse(items, plugin, tab_icon, path, target_id, depth)
    if depth > 11 or type(items) ~= "table" then
        return {{ text = CT("patch_no_items"), enabled = false }}
    end
    local entries = {}
    for _, item in ipairs(items) do
        if type(item) == "table" and not item._clean_bar_settings
            and not item._clean_bar_patch and not item._clean_bar_clean_patch
            and not item._clean_bar_home_patch and not item.ignored_by_menu_search then
            local owned = cleanBarPluginMenuOwner(item) == plugin
            local has_children = type(item.sub_item_table) == "table"
                or type(item.sub_item_table_func) == "function"
            if owned or has_children then
                local label = getMenuItemLabel(item)
                if label and label ~= "" then
                    local next_path = cleanBarCopyPath(path, label)
                    entries[#entries + 1] = {
                        text = label .. (owned and "  ✓" or ""),
                        sub_item_table_func = function()
                            local options = {}
                            if owned then
                                for _, action in ipairs(cleanBarVerifiedPluginOptions(
                                    item, plugin, tab_icon, next_path, target_id)) do
                                    options[#options + 1] = action
                                end
                            end
                            if has_children then
                                local children = item.sub_item_table
                                if type(item.sub_item_table_func) == "function" then
                                    local ok, result = pcall(item.sub_item_table_func)
                                    children = ok and type(result) == "table" and result or nil
                                end
                                if type(children) == "table" then
                                    for _, child in ipairs(cleanBarPluginGuidedBrowse(children,
                                        plugin, tab_icon, next_path, target_id, depth + 1)) do
                                        options[#options + 1] = child
                                    end
                                end
                            end
                            return #options > 0 and options
                                or {{ text = CT("patch_no_items"), enabled = false }}
                        end,
                    }
                end
            end
        end
    end
    return #entries > 0 and entries
        or {{ text = CT("patch_no_items"), enabled = false }}
end

-- Only scan menus already materialised in the KOReader UI. No dynamic
-- submenu factory is invoked while building the per-plugin index.
local function cleanBarStaticPluginItems(tabs)
    local owners, seen, count = {}, {}, 0
    local function walk(items, tab_icon, path, depth)
        if type(items) ~= "table" or depth > 11 or seen[items] or count > 1400 then return end
        seen[items] = true
        for _, item in ipairs(items) do
            count = count + 1
            if count > 1400 then break end
            if type(item) == "table" and not item._clean_bar_settings
                and not item._clean_bar_patch and not item._clean_bar_clean_patch
                and not item._clean_bar_home_patch then
                local owner = cleanBarPluginMenuOwner(item)
                local label
                if owner or type(item.sub_item_table) == "table" then
                    label = getMenuItemLabel(item)
                end
                if label and label ~= "" then
                    local next_path = cleanBarCopyPath(path, label)
                    if owner then
                        owners[owner] = owners[owner] or {}
                        owners[owner][#owners[owner] + 1] = {
                            item = item, tab_icon = tab_icon,
                            path = next_path, label = label,
                        }
                    end
                    if type(item.sub_item_table) == "table" then
                        walk(item.sub_item_table, tab_icon, next_path, depth + 1)
                    end
                end
            end
        end
    end
    for _, tab in ipairs(tabs or {}) do
        if type(tab) == "table" and type(tab.icon) == "string"
            and not tab._clean_bar_patch and not tab._clean_bar_clean_patch
            and not tab._clean_bar_home_patch then
            walk(tab, tab.icon, {}, 0)
        end
    end
    return owners
end

local function buildInstalledPluginsUnifiedMenu(target_id)
    local plugins = collectInstalledPluginEvents()
    if #plugins == 0 then
        return {{ text = CT("no_plugin_actions_found"), enabled = false }}
    end
    local roots = getCurrentMenuTabs()
    local verified_items = cleanBarStaticPluginItems(roots)
    local items = {}
    for _, group in ipairs(plugins) do
        local plugin_name = group.name
        local plugin_label = group.label
        local direct_items = verified_items[plugin_name] or {}
        items[#items + 1] = {
            text = plugin_label,
            sub_item_table_func = function()
                local sections = {}
                -- Present only menus owned by THIS plugin directly, not all
                -- KOReader tabs under every plugin (the prior v10 regression).
                for _, hit in ipairs(direct_items) do
                    local choice = hit
                    sections[#sections + 1] = {
                        text = choice.label,
                        sub_item_table_func = function()
                            return cleanBarVerifiedPluginOptions(choice.item, plugin_name,
                                choice.tab_icon, choice.path, target_id)
                        end,
                    }
                end
                -- For a dynamic submenu, navigate the KOReader tree one tap
                -- at a time; only verified plugin-owned rows can be saved.
                sections[#sections + 1] = {
                    text = isPortugueseUI() and "Procurar opções em submenus…"
                        or "Find options in submenus…",
                    separator = #direct_items > 0,
                    sub_item_table_func = function()
                        local tabs = {}
                        for _, tab in ipairs(roots or {}) do
                            if type(tab) == "table" and type(tab.icon) == "string"
                                and not tab._clean_bar_patch and not tab._clean_bar_clean_patch
                                and not tab._clean_bar_home_patch then
                                local current = tab
                                tabs[#tabs + 1] = {
                                    text = getTabLabel(current, 1),
                                    sub_item_table_func = function()
                                        return cleanBarPluginGuidedBrowse(current, plugin_name,
                                            current.icon, {}, target_id, 0)
                                    end,
                                }
                            end
                        end
                        return #tabs > 0 and tabs
                            or {{ text = CT("patch_no_items"), enabled = false }}
                    end,
                }
                -- Registered no-argument actions are a separate source; they
                -- must not be represented as arbitrary native plugin menus.
                sections[#sections + 1] = {
                    text = CT("choose_plugin_event"),
                    sub_item_table_func = function()
                        return buildInstalledPluginEventMenu(target_id, plugin_name)
                    end,
                }
                return sections
            end,
        }
    end
    return items
end

local function collectCleanMenuChoices(source_tabs)
    local choices, used = {}, {}
    local tabs = getCurrentMenuTabs(source_tabs)
    local in_reader = false
    for _, tab in ipairs(tabs or {}) do
        if type(tab) == "table" and tab.icon == "appbar.navigation" then
            in_reader = true
            break
        end
    end
    local function safeSubmenu(item)
        -- Never execute dynamic submenu functions while building a catalog.
        -- A single dynamic function can perform I/O, recurse or block the UI.
        if type(item.sub_item_table) == "table" then return item.sub_item_table end
        return nil
    end
    local function walk(items, tab, tab_index, tab_label, parent_labels, ancestors, depth)
        if type(items) ~= "table" or depth > 10 or ancestors[items]
            or items.ignored_by_menu_search then return end
        ancestors[items] = true
        local same_name_counts = {}
        for index, item in ipairs(items) do
            if type(item) == "table" and not item.ignored_by_menu_search
                and not item._clean_bar_settings then
                local label = getMenuItemLabel(item)
                if label and label ~= "" and label:lower() ~= "appbar" then
                    local path = {}
                    for _, part in ipairs(parent_labels) do path[#path+1] = part end
                    path[#path+1] = label
                    local tab_id = (type(tab.icon) == "string" and tab.icon ~= "") and tab.icon or tab_label
                    local base_key = "v2:" .. tostring(tab_id) .. ":" .. table.concat(path, " / ")
                    same_name_counts[base_key] = (same_name_counts[base_key] or 0) + 1
                    local key = base_key
                    if same_name_counts[base_key] > 1 then
                        key = base_key .. " #" .. tostring(same_name_counts[base_key])
                    end
                    if not used[key] then
                        used[key] = true
                        choices[#choices+1] = {
                            key = key,
                            legacy_key = depth == 0 and makeCleanChoiceKey(tab, tab_index, index) or nil,
                            tab_label = tab_label,
                            label = label,
                            display = tab_label .. " / " .. table.concat(path, " / "),
                            path = path, item = item, depth = depth,
                            menu_id = type(item.key) == "string" and item.key or nil,
                        }
                    end
                    if depth < 10 then
                        local submenu = safeSubmenu(item)
                        if submenu then walk(submenu, tab, tab_index, tab_label, path, ancestors, depth + 1) end
                    end
                end
            end
        end
        ancestors[items] = nil
    end
    for tab_index, tab in ipairs(tabs or {}) do
        if type(tab) == "table" and not isCleanBarTab(tab) and not isCleanCustomTab(tab) then
            walk(tab, tab, tab_index, getTabLabel(tab, tab_index), {}, {}, 0)
        end
    end
    -- Read-only Dispatcher catalog: KOReader keeps its registry as an upvalue
    -- of registerAction. Only no-argument events can be safely activated from
    -- the Clean menu without inventing event parameters.
    local ok_dispatch, Dispatcher = pcall(require, "dispatcher")
    if ok_dispatch and type(Dispatcher.registerAction) == "function" and debug and debug.getupvalue then
        local registry
        for i = 1, 12 do
            local name, value = debug.getupvalue(Dispatcher.registerAction, i)
            if not name then break end
            if name == "settingsList" and type(value) == "table" then
                registry = value
                break
            end
        end
        if registry then
            local keys = {}
            for name, action in pairs(registry) do
                if type(name) == "string" and type(action) == "table"
                    and action.category == "none" and type(action.event) == "string" and action.event ~= ""
                    and action.arg == nil and action.condition ~= false
                    and (in_reader or (not action.reader and not action.rolling and not action.paging))
                    and (not in_reader or not action.filemanager) then
                    local available = true
                    if type(action.condition_func) == "function" then
                        local ok_cond, result = pcall(action.condition_func)
                        available = ok_cond and result == true
                    end
                    if available then keys[#keys+1] = name end
                end
            end
            table.sort(keys)
            for _, name in ipairs(keys) do
                local action = registry[name]
                local key = "cleanbar:dispatcher:" .. name
                if not used[key] then
                    local label = type(action.title) == "string" and action.title or name
                    local event_name = action.event
                    local event_callback = function()
                        UIManager:broadcastEvent(Event:new(event_name))
                    end
                    local category_label = CT("menu_dispatcher")
                    choices[#choices+1] = {
                        key = key, tab_label = category_label, label = label,
                        display = category_label .. " / " .. label,
                        path = { label }, search_terms = name .. " " .. event_name,
                        item = { text = label, callback = event_callback }, depth = 0,
                    }
                    used[key] = true
                end
            end
        end
    end
    -- Preserve old v2 selection keys and the user's existing Clean menu.
    local migrated = false
    for _, choice in ipairs(choices) do
        if choice.legacy_key and config.clean_menu_items[choice.legacy_key] ~= nil
            and config.clean_menu_items[choice.key] == nil then
            config.clean_menu_items[choice.key] = config.clean_menu_items[choice.legacy_key]
            migrated = true
        end
    end
    if not config.clean_menu_initialized then
        for _, choice in ipairs(choices) do
            if choice.depth == 0 and defaultCleanInclude(choice) then
                config.clean_menu_items[choice.key] = true
            end
        end
        config.clean_menu_initialized = true
        migrated = true
    end
    if migrated then saveConfig() end
    -- Restore shortcuts to individually chosen patch options. Each saved
    -- path resolves only its own submenu chain, never every installed menu.
    for key, record in pairs(config.clean_patch_actions) do
        if config.clean_menu_items[key] == true and type(record) == "table" then
            local item = resolveSavedPatchMenuItem(record, source_tabs)
            if item then
                choices[#choices + 1] = {
                    key = key, label = record.label or getMenuItemLabel(item) or "Patch",
                    tab_label = cleanBarPatchDisplayName(record.patch or "patch.lua"),
                    display = cleanBarPatchDisplayName(record.patch or "patch.lua")
                        .. " / " .. (record.label or ""),
                    path = { record.label or "Patch" },
                    item = item, depth = 1, search_terms = record.patch,
                }
            end
        end
    end
    -- Selected plugin events are kept by stable identifiers. Only restore
    -- shortcuts whose plugin is still active and whose event is registered.
    local selected_plugin_actions = false
    for key in pairs(config.clean_plugin_actions) do
        if config.clean_menu_items[key] == true then selected_plugin_actions = true; break end
    end
    if selected_plugin_actions then
        local registered_plugin_events = cleanBarRegisteredPluginEvents()
        local active_plugins = {}
        for _, plugin_group in ipairs(collectInstalledPluginEvents()) do
            active_plugins[plugin_group.name] = true
        end
        for key, record in pairs(config.clean_plugin_actions) do
            if config.clean_menu_items[key] == true and type(record) == "table"
                and active_plugins[record.plugin] and registered_plugin_events[record.event] then
                local event_name = record.event
                local label = record.label or event_name
                local source_label = nicePluginLabel(record.plugin)
                choices[#choices + 1] = {
                    key = key, tab_label = source_label, label = label,
                    display = source_label .. " / " .. label,
                    path = { label }, depth = 1, search_terms = record.plugin,
                    item = { text = label, callback = function()
                        UIManager:broadcastEvent(Event:new(event_name))
                    end },
                }
            end
        end
    end
    -- Recorded native plugin menu actions resolve only their own saved routes.
    for key, record in pairs(config.clean_plugin_menu_actions) do
        if config.clean_menu_items[key] == true and type(record) == "table" then
            local item = resolveSavedPluginMenuItem(record, source_tabs)
            if item then
                local label = record.label or getMenuItemLabel(item)
                local source_label = nicePluginLabel(record.plugin)
                choices[#choices + 1] = {
                    key = key, tab_label = source_label, label = label,
                    display = source_label .. " / " .. label,
                    path = { label }, depth = 1, search_terms = record.plugin,
                    item = item,
                }
            end
        end
    end
    return choices
end

-- ---------------------------------------------------------------------------
-- Reader-only explicit entry for the physical-page-count userpatch.
--
-- The ordinary menu index can be built before third-party addToMainMenu()
-- entries are available. Unlike searching menu snapshots or matching labels,
-- this fixed choice invokes the handler that the installed userpatch registers.
-- It never modifies ReaderPageMap or either physical-page userpatch.
-- ---------------------------------------------------------------------------
local PHYSICAL_PAGES_CHOICE_KEY = "cleanbar:reader:pagemap_physical_pages"

local function hasReaderNavigationTab(source_tabs)
    for _, tab in ipairs(source_tabs or {}) do
        if type(tab) == "table" and tab.icon == "appbar.navigation" then
            return true
        end
    end
    return false
end

local function openPhysicalPageCountFromCleanBar()
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI and ReaderUI.instance
    local pagemap = reader and reader.pagemap
    if not pagemap or type(pagemap.onPhysicalPageCount) ~= "function" then
        showInfo(isPortugueseUI()
            and "A função de páginas físicas não está disponível neste livro."
            or "Physical page numbers are not available for this book.")
        return
    end
    -- Use the ORIGINAL patch handler. It opens the patch's own dialog and
    -- applies the same book-format guard as the original registered action.
    local ok_action, handled = pcall(pagemap.onPhysicalPageCount, pagemap)
    if not ok_action then
        showInfo(isPortugueseUI()
            and "Não foi possível abrir a função de páginas físicas."
            or "Could not open physical page numbers.")
    elseif handled == false then
        showInfo(isPortugueseUI()
            and "Esta função só está disponível para livros de texto refluível."
            or "This action is only available for reflowable books.")
    end
end

local function ensurePhysicalPagesChoice(choices, source_tabs)
    -- Only in the book Reader; never inject this entry in File Manager.
    if not hasReaderNavigationTab(source_tabs) then return end

    local ok_pagemap, ReaderPageMap = pcall(require, "apps/reader/modules/readerpagemap")
    if not ok_pagemap or type(ReaderPageMap.onPhysicalPageCount) ~= "function" then
        return -- the physical-page-count patch is not installed/active
    end

    -- Avoid showing the original and forced entry twice if the generic menu
    -- index ever begins to capture this particular third-party menu item.
    for i = #choices, 1, -1 do
        local choice = choices[i]
        if type(choice.label) == "string"
            and choice.label:lower():find("match printed page numbers", 1, true) then
            if config.clean_menu_items[choice.key] == true then
                config.clean_menu_items[PHYSICAL_PAGES_CHOICE_KEY] = true
                saveConfig()
            end
            table.remove(choices, i)
        end
    end

    local label = isPortugueseUI()
        and "Igualar páginas às do livro impresso…"
        or "Match printed page numbers…"
    choices[#choices + 1] = {
        key = PHYSICAL_PAGES_CHOICE_KEY,
        tab_label = isPortugueseUI() and "Navegação" or "Navigation",
        label = label,
        display = (isPortugueseUI() and "Navegação / " or "Navigation / ") .. label,
        path = { label },
        search_terms = "pagemap pagemap_physical_pages physical printed page count páginas fisicas físicas impressas",
        item = {
            text = label,
            callback = openPhysicalPageCountFromCleanBar,
        },
        depth = 0,
    }
end

-- The patch's own settings are an intrinsic, permanent part of the Clean
-- custom menu, not a KOReader menu choice. Keep them outside the dynamic
-- discovery catalog so the menu can never recursively discover itself.
-- Build its submenu only when the user opens this entry.
local function embeddedCleanBarSettingsItem()
    return {
        -- TouchMenuItem renders text and checkmarks, but not item.icon.
        -- Use a Unicode settings glyph in the text for an actual left icon,
        -- while keeping the KOReader icon ID for renderers that support it.
        text = CT("clean_bar_settings_entry"),
        icon = "appbar.settings",
        _clean_bar_settings = true,
        separator = true,
        sub_item_table_func = function()
            return buildSettingsMenu().sub_item_table
        end,
    }
end

-- Cache per live root menu: rendering the Clean bar should not recursively
-- scan hundreds of dynamic submenus each time the e-ink menu is opened.
-- The Customize entry explicitly refreshes the live index when selected.
local clean_choice_cache
invalidateCleanChoiceCache = function() clean_choice_cache = nil end
local function getCleanMenuChoices(source_tabs, force_refresh)
    local root = getCurrentMenuTabs(source_tabs)
    if force_refresh or not clean_choice_cache or clean_choice_cache.root ~= root then
        local choices = collectCleanMenuChoices(source_tabs)
        ensurePhysicalPagesChoice(choices, source_tabs)
        clean_choice_cache = { root = root, choices = choices }
    end
    return clean_choice_cache.choices
end

resolveCleanNativeShortcut = function(key)
    if type(key) ~= "string" or key == "" then return nil end
    for _, choice in ipairs(getCleanMenuChoices(nil, true)) do
        if choice.key == key and type(choice.item) == "table" then
            local item = choice.item
            if type(item.callback) == "function" or type(item.callback_func) == "function"
                or type(item.sub_item_table) == "table"
                or type(item.sub_item_table_func) == "function" then
                return item
            end
        end
    end
    return nil
end

local clean_customize_search_text = ""

-- Resolve the saved order by stable menu-choice keys. Unknown keys stay in
-- settings so items supplied by plugins or the other KOReader context may
-- regain their position when discovered again. Never reorder the two native
-- entries (Customize / Cleanbar settings): they are built separately.
local function selectedCleanChoicesInOrder(choices)
    local selected = {}
    for _, choice in ipairs(choices or {}) do
        if config.clean_menu_items[choice.key] == true then
            selected[choice.key] = choice
        end
    end
    local ordered, seen = {}, {}
    for _, key in ipairs(config.clean_menu_order) do
        if type(key) == "string" and selected[key] and not seen[key] then
            ordered[#ordered + 1] = selected[key]
            seen[key] = true
        end
    end
    for _, choice in ipairs(choices or {}) do
        if config.clean_menu_items[choice.key] == true and not seen[choice.key] then
            ordered[#ordered + 1] = choice
            seen[choice.key] = true
        end
    end
    return ordered
end

local function arrangeSelectedCleanMenuItems(choices, touch_menu)
    local selected = selectedCleanChoicesInOrder(choices)
    if #selected < 2 then
        showInfo(CT("arrange_clean_menu_empty"))
        return
    end
    local SortWidget = require("ui/widget/sortwidget")
    local sort_items = {}
    for _, choice in ipairs(selected) do
        sort_items[#sort_items + 1] = {
            text = choice.display or choice.label,
            orig_item = choice.key,
        }
    end
    UIManager:show(SortWidget:new{
        title = CT("arrange_clean_menu"),
        item_table = sort_items,
        callback = function()
            -- Save selected items first, then retain all previously remembered
            -- keys (including inactive plugins and temporarily hidden items).
            local new_order, seen = {}, {}
            local function add(key)
                if type(key) == "string" and not seen[key] then
                    new_order[#new_order + 1] = key
                    seen[key] = true
                end
            end
            for _, item in ipairs(sort_items) do add(item.orig_item) end
            for _, key in ipairs(config.clean_menu_order) do add(key) end
            config.clean_menu_order = new_order
            saveConfig()
            -- The custom tab is refreshed only after explicit sorting;
            -- no menu discovery runs as part of the opening swipe.
            if touch_menu and refreshCleanCustomTab then
                refreshCleanCustomTab(touch_menu)
            end
        end,
    })
end

local function buildCustomizeCleanMenu(choices, target_id, view)
    -- Display choices as a navigable tree (tab > menu > submenus), rather
    -- than flattening every nested item into a thousands-entry selector.
    local tabs, tab_order = {}, {}
    for _, choice in ipairs(choices) do
        local tab = tabs[choice.tab_label]
        if not tab then
            tab = { children = {}, order = {} }
            tabs[choice.tab_label] = tab
            tab_order[#tab_order + 1] = choice.tab_label
        end
        local path = choice.path or { choice.label }
        local node = tab
        for _, component in ipairs(path) do
            local child = node.children[component]
            if not child then
                child = { label = component, children = {}, order = {} }
                node.children[component] = child
                node.order[#node.order + 1] = component
            end
            node = child
        end
        node.choice = choice
    end
    local function toggleChoice(choice, touch_menu)
        if target_id then
            local item = choice.item
            if not item or not (type(item.callback) == "function"
                or type(item.callback_func) == "function"
                or type(item.sub_item_table) == "table"
                or type(item.sub_item_table_func) == "function") then
                showInfo(CT("menu_action_only"))
                return
            end
            applyCustomButtonConfig(target_id, {
                label = choice.label, icon = "custommenu", action_type = "menu",
                event = "", event_arg = "", dispatch = "broadcast",
                plugin = "", method = "", menu_label = choice.label,
                menu_tab_label = choice.tab_label,
                menu_key = "cleanbar:native:v10:" .. choice.key,
            }, touch_menu)
            return
        end
        config.clean_menu_items[choice.key] = config.clean_menu_items[choice.key] ~= true
        if choice.legacy_key then config.clean_menu_items[choice.legacy_key] = nil end
        saveConfig()
    end
    local function paginateMenuEntries(entries)
        if #entries <= 45 then return entries end
        local groups = {}
        for first = 1, #entries, 35 do
            local last = math.min(first + 34, #entries)
            local page = {}
            for index = first, last do page[#page + 1] = entries[index] end
            groups[#groups + 1] = {
                text = (isPortugueseUI() and "Opções " or "Options ") .. tostring(first) .. "–" .. tostring(last),
                sub_item_table_func = function() return page end,
            }
        end
        return groups
    end
    local function nodeMenu(node)
        local entries = {}
        if node.choice and #node.order > 0 then
            local choice = node.choice
            entries[#entries + 1] = {
                text = target_id and CT("patch_use_this_button")
                    or (isPortugueseUI() and "Adicionar este menu completo" or "Add this entire menu"),
                checked_func = not target_id and function()
                    return config.clean_menu_items[choice.key] == true
                end or nil,
                keep_menu_open = not target_id,
                callback = function(touch_menu) toggleChoice(choice, touch_menu) end,
                separator = true,
            }
        end
        for _, label in ipairs(node.order) do
            local child = node.children[label]
            if #child.order > 0 then
                entries[#entries + 1] = {
                    text = label,
                    sub_item_table_func = function() return nodeMenu(child) end,
                }
            elseif child.choice then
                local choice = child.choice
                entries[#entries + 1] = {
                    text = label,
                    checked_func = not target_id and function()
                        return config.clean_menu_items[choice.key] == true
                    end or nil,
                    keep_menu_open = not target_id,
                    callback = function(touch_menu) toggleChoice(choice, touch_menu) end,
                }
            end
        end
        return paginateMenuEntries(entries)
    end
    -- Search stays inside one popup workflow: type a query, select directly
    -- from a paginated ButtonDialog. Never redirect the user to a separate
    -- "Search results" menu (or enumerate dynamic submenu callbacks).
    local function matchingChoices(query)
        local results = {}
        query = tostring(query or ""):lower():match("^%s*(.-)%s*$")
        if query == "" then return results end
        for _, choice in ipairs(choices) do
            local haystack = (choice.display or ""):lower()
            if choice.search_terms then
                haystack = haystack .. " " .. choice.search_terms:lower()
            end
            if choice.menu_id then
                haystack = haystack .. " " .. choice.menu_id:lower()
            end
            if haystack:find(query, 1, true) then
                results[#results + 1] = choice
            end
        end
        return results
    end

    local openSearchDialog
    local function showSearchResultsPopup(query, requested_page, parent_touch_menu)
        local ButtonDialog = require("ui/widget/buttondialog")
        local results = matchingChoices(query)
        -- Five hits per page keep paths readable on narrow e-ink screens.
        local per_page = 5
        local page_count = math.max(1, math.ceil(#results / per_page))
        local page = math.max(1, math.min(requested_page or 1, page_count))
        local popup
        local function reopen(new_page)
            UIManager:close(popup)
            showSearchResultsPopup(query, new_page, parent_touch_menu)
        end
        local rows = {
            {{ text = string.format("%s (%d)",
                isPortugueseUI() and "Resultados" or "Results", #results),
                enabled = false }},
        }
        if #results == 0 then
            rows[#rows + 1] = {{ text = CT("search_empty"), enabled = false }}
        else
            for i = (page - 1) * per_page + 1, math.min(page * per_page, #results) do
                local choice = results[i]
                local selected = config.clean_menu_items[choice.key] == true
                local description = choice.display or choice.label or ""
                rows[#rows + 1] = {{
                    text = (not target_id and (selected and "✓  " or "☐  ") or "") .. description,
                    align = "left",
                    callback = function()
                        UIManager:close(popup)
                        toggleChoice(choice, parent_touch_menu)
                        if not target_id then
                            -- Keep searching and selecting multiple items
                            -- without leaving this popup for a menu results page.
                            showSearchResultsPopup(query, page, parent_touch_menu)
                        end
                    end,
                }}
            end
        end
        rows[#rows + 1] = {
            { text = "◂  " .. CT("icon_picker_back"), enabled = page > 1,
              callback = function() reopen(page - 1) end },
            { text = string.format("%d / %d", page, page_count), enabled = false },
            { text = CT("icon_picker_next") .. "  ▸", enabled = page < page_count,
              callback = function() reopen(page + 1) end },
        }
        rows[#rows + 1] = {
            { text = isPortugueseUI() and "Nova pesquisa" or "Search again",
              callback = function()
                UIManager:close(popup)
                openSearchDialog(parent_touch_menu)
            end },
            { text = CT("cancel"), id = "close", callback = function()
                UIManager:close(popup)
            end },
        }
        popup = ButtonDialog:new{
            title = CT("search_menu"),
            buttons = rows,
            width = math.floor(Screen:getWidth() * 0.92),
        }
        UIManager:show(popup)
    end

    openSearchDialog = function(touch_menu)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = CT("search_menu"),
            input = clean_customize_search_text,
            buttons = {{
                { text = CT("cancel"), id = "close", callback = function()
                    UIManager:close(dialog)
                end },
                { text = _("Search"), is_enter_default = true, callback = function()
                    local query = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                    clean_customize_search_text = query
                    UIManager:close(dialog)
                    if query ~= "" then
                        showSearchResultsPopup(query, 1, touch_menu)
                    end
                end },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    -- All choices stay available, but never render a 200+ page flat selector.
    -- The already-built tree is the native e-ink-friendly navigation model:
    -- original tab > actual submenu > selectable leaf.
    local function browseAll()
        local items = {}
        for _, tab_name in ipairs(tab_order) do
            local tab = tabs[tab_name]
            items[#items + 1] = {
                text = tab_name,
                sub_item_table_func = function() return nodeMenu(tab) end,
            }
        end
        if #items == 0 then
            return { { text = CT("search_empty"), enabled = false } }
        end
        return items
    end
    local function selectedOnly()
        local items = {}
        for _, choice in ipairs(choices) do
            if config.clean_menu_items[choice.key] == true then
                local selected_choice = choice
                items[#items+1] = {
                    text = selected_choice.display,
                    checked_func = function() return config.clean_menu_items[selected_choice.key] == true end,
                    keep_menu_open = true, callback = function() toggleChoice(selected_choice) end,
                }
            end
        end
        if #items == 0 then return {{ text = CT("no_items_selected"), enabled = false }} end
        return items
    end
    -- The same original-menu tree and search work in both destinations.
    -- The hub invokes only the requested branch, avoiding redundant root rows.
    if view == "native" then return browseAll() end
    if view == "search_popup" then return openSearchDialog end
    local menu = {
        {
            text = CT("arrange_clean_menu"),
            keep_menu_open = true,
            enabled_func = function() return #selectedCleanChoicesInOrder(choices) >= 2 end,
            callback = function(touch_menu)
                arrangeSelectedCleanMenuItems(choices, touch_menu)
            end,
            separator = true,
        },
        { text = CT("menu_selected"), sub_item_table_func = selectedOnly },
        { text = CT("koreader_options"), separator = true,
          sub_item_table_func = function() return buildUnifiedOptionsHub(nil, choices) end },
        { text = CT("select_all"), keep_menu_open = true, callback = function()
            for _, choice in ipairs(choices) do
                if choice.depth == 0 then config.clean_menu_items[choice.key] = true end
            end
            saveConfig()
        end },
        { text = CT("deselect_all"), keep_menu_open = true, callback = function()
            config.clean_menu_items = {}
            saveConfig()
        end },
        { text = CT("reset_default"), separator = true, keep_menu_open = true, callback = function()
            config.clean_menu_items = {}
            for _, choice in ipairs(choices) do
                if choice.depth == 0 and defaultCleanInclude(choice) then
                    config.clean_menu_items[choice.key] = true
                end
            end
            saveConfig()
        end },
    }
    -- Keep the physical-pages patch as an explicitly selectable option.
    -- Clean bar settings themselves are always embedded in the custom tab.
    for _, choice in ipairs(choices) do
        if choice.key == PHYSICAL_PAGES_CHOICE_KEY then
            table.insert(menu, 3, {
                text = (isPortugueseUI() and "Páginas físicas (patch)" or "Physical pages (patch)"),
                checked_func = function()
                    return config.clean_menu_items[PHYSICAL_PAGES_CHOICE_KEY] == true
                end,
                keep_menu_open = true,
                callback = function() toggleChoice(choice) end,
            })
            break
        end
    end
    -- Category links live exclusively under "All menu options".
    -- Do not duplicate them at the root: this keeps the settings short.
    return menu
end

-- Unified action browser for Menu Clean and all custom quick-buttons.
-- Children are assembled lazily; loading a list never recursively runs KOReader
-- or plugin submenu builders. The same native choices feed both destinations.
buildUnifiedOptionsHub = function(target_id, indexed_choices)
    local function choices()
        return indexed_choices or getCleanMenuChoices(nil, true)
    end
    return {
        { text = CT("search_menu"), callback = function(touch_menu)
            -- Open the input dialog directly. Results appear in a popup;
            -- there is no intermediate submenu or saved search-results row.
            local open_popup = buildCustomizeCleanMenu(choices(), target_id, "search_popup")
            open_popup(touch_menu)
        end },
        { text = CT("original_menus"), sub_item_table_func = function()
            return buildCustomizeCleanMenu(choices(), target_id, "native")
        end },
        { text = CT("installed_patches"), sub_item_table_func = function()
            return buildInstalledPatchesMenu(target_id)
        end },
    }
end

local function buildFallbackCleanItems()
    return {
        {
            text = CT("fallback_library"),
            callback = function()
                goToHomeLibraryFromCleanBar(nil)
            end,
        },
        {
            text = CT("fallback_search"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowFileSearch"))
            end,
        },
        {
            text = CT("fallback_cloud"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowCloudStorage"))
            end,
        },
        {
            text = CT("fallback_opds"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowOPDSCatalog"))
            end,
        },
    }
end

local function buildCleanCustomMenu(source_tabs)
    local choices = getCleanMenuChoices(source_tabs, false)
    local menu = {
        {
            text = CT("customize_clean_menu"),
            icon = "custommenu",
            sub_item_table_func = function()
                return buildCustomizeCleanMenu(getCleanMenuChoices(source_tabs, true))
            end,
        },
        embeddedCleanBarSettingsItem(), -- Native permanent second entry.
    }

    local added = 0
    for _, choice in ipairs(selectedCleanChoicesInOrder(choices)) do
        table.insert(menu, copyMenuItem(choice.item))
        added = added + 1
    end

    if #choices == 0 then
        for _, item in ipairs(buildFallbackCleanItems()) do
            table.insert(menu, item)
        end
    elseif added == 0 then
        table.insert(menu, {
            text = CT("no_items_selected"),
            enabled = false,
        })
    end

    -- Native permanent entry remains second even if every user action is
    -- unselected, reset, or missing from late plugin discovery.
    return menu
end

-- In Clean mode we expose three visible tabs:
-- 1) Clean bar (Top-com)
-- 2) Custom menu (custommenu): user-selected KOReader menu entries
-- 3) Home/library (Koreaderrightqq): direct action, no dropdown
local clean_menu_tab = {
    icon = "cleanbar/cleanbar_thin_menu",
    remember = false,
    text = CT("custom_menu_tab"),
}

local clean_home_tab = {
    icon = "cleanbar/cleanbar_thin_library",
    remember = false,
    text = CT("home_library_tab"),
    _clean_bar_home_patch = true,
}

local function setTabItems(tab, items)
    -- TouchMenu expects the tab itself to be the item array. Keep the
    -- metadata fields, but replace all numeric menu entries.
    for i = #tab, 1, -1 do
        table.remove(tab, i)
    end
    for _, item in ipairs(items or {}) do
        table.insert(tab, item)
    end
end

clean_bar_tab._clean_bar_patch = true
clean_menu_tab._clean_bar_clean_patch = true
clean_menu_tab._clean_bar_custom_patch = true
clean_home_tab._clean_bar_clean_patch = true

isCleanBarTab = function(tab)
    return type(tab) == "table" and tab._clean_bar_patch == true
end

isCleanCustomTab = function(tab)
    return type(tab) == "table" and tab._clean_bar_clean_patch == true
end

local function hasCleanBarTab(tab_item_table)
    if type(tab_item_table) ~= "table" then
        return false
    end
    for _, tab in ipairs(tab_item_table) do
        if isCleanBarTab(tab) then
            return true
        end
    end
    return false
end

local function ensureCleanBarTab(tab_item_table)
    if type(tab_item_table) ~= "table" then
        return
    end

    -- Apply configured icon also in the normal KOReader tab layout.
    clean_bar_tab.icon = config.clean_left_tab_icon
    -- Remove stale/duplicate copies first. This matters when KOReader rebuilds
    -- menus or when the patch is reloaded during testing.
    for i = #tab_item_table, 1, -1 do
        if isCleanBarTab(tab_item_table[i]) or isCleanCustomTab(tab_item_table[i]) then
            table.remove(tab_item_table, i)
        end
    end

    table.insert(tab_item_table, 1, clean_bar_tab)
end

-- Populate this lightweight placeholder during ordinary menu opening.
-- No deep discovery, plugin submenus, or Dispatcher introspection is run
-- until the custom tab is explicitly selected.
local function deferredCustomizeMenu(source_tabs)
    return {
        text = CT("customize_clean_menu"),
        icon = "custommenu",
        sub_item_table_func = function()
            return buildCustomizeCleanMenu(getCleanMenuChoices(source_tabs, true))
        end,
    }
end

local function deferredCleanCustomItems(source_tabs)
    -- Also available if the full plugin menu index fails or has not run yet.
    return { deferredCustomizeMenu(source_tabs), embeddedCleanBarSettingsItem() }
end

refreshCleanCustomTab = function(touch_menu)
    local source_tabs = touch_menu._clean_bar_full_tab_item_table or touch_menu.tab_item_table
    local ok, items = pcall(buildCleanCustomMenu, source_tabs)
    if ok and type(items) == "table" then
        setTabItems(clean_menu_tab, items)
    else
        -- A broken/late plugin submenu must not break the top menu gesture.
        setTabItems(clean_menu_tab, deferredCleanCustomItems(source_tabs))
    end
end

local function getCleanTabs(source_tabs)
    -- Critical: a swipe opening the top bar must be cheap and reliable.
    -- The previous version ran an exhaustive 10-level dynamic-menu crawl
    -- here, inside TouchMenu:init(), which could prevent the bar opening.
    clean_bar_tab.icon = config.clean_left_tab_icon
    clean_menu_tab.icon = config.clean_middle_tab_icon
    clean_home_tab.icon = config.clean_right_tab_icon
    clean_menu_tab.text = CT("custom_menu_tab")
    setTabItems(clean_menu_tab, deferredCleanCustomItems(source_tabs))

    clean_home_tab.text = CT("home_library_tab")
    setTabItems(clean_home_tab, {})

    return {
        clean_bar_tab,
        clean_menu_tab,
        clean_home_tab,
    }
end

local function applyCleanBarTabs(menu)
    if not menu.tab_item_table then
        return
    end

    -- Keep KOReader's real tab table intact. Clean mode is applied later,
    -- right before TouchMenu builds the visible icon bar, so disabling Clean
    -- mode restores the standard menus without needing a restart.
    ensureCleanBarTab(menu.tab_item_table)
end

refreshCleanModeMenu = function(touch_menu)
    if not touch_menu or not touch_menu.tab_item_table or not touch_menu.bar then
        return false
    end

    -- Keep a reference to the real KOReader tabs so we can restore them
    -- when Clean mode is disabled. When we are currently in Clean mode,
    -- touch_menu.tab_item_table contains only our filtered tabs, so the
    -- saved full table is essential.
    local full_tabs = touch_menu._clean_bar_full_tab_item_table
    if not full_tabs then
        if config.clean_mode then
            full_tabs = touch_menu.tab_item_table
        else
            full_tabs = touch_menu.tab_item_table
        end
    end
    ensureCleanBarTab(full_tabs)
    touch_menu._clean_bar_full_tab_item_table = full_tabs

    if config.clean_mode then
        touch_menu.tab_item_table = getCleanTabs(full_tabs)
    else
        touch_menu.tab_item_table = full_tabs
    end

    local icons = {}
    for _, tab in ipairs(touch_menu.tab_item_table) do
        table.insert(icons, tab.icon)
    end

    -- TouchMenuBar is a local class inside KOReader's touchmenu.lua, but
    -- the existing bar instance can safely rebuild itself with a new icons
    -- table. This updates the visible top bar immediately.
    local ok = pcall(function()
        touch_menu.layout = {}
        touch_menu.bar.icons = icons
        touch_menu.bar.width = touch_menu.width
        touch_menu.bar.show_parent = touch_menu.show_parent
        touch_menu.bar.menu = touch_menu
        touch_menu.bar:init()
        touch_menu.item_table_stack = {}
        touch_menu.parent_id = nil
        touch_menu.page = 1
        touch_menu.bar:switchToTab(1)
    end)

    if not ok then
        return false
    end

    UIManager:setDirty(touch_menu.show_parent or "all", "ui")
    return true
end

-- TouchMenu builds its icon bar from tab_item_table during :init().
-- Filtering here is what actually hides the standard KOReader icons in
-- Clean mode; changing updateItems() alone cannot rebuild the tab bar.
local orig_touchmenu_init = TouchMenu.init

function TouchMenu:init(...)
    if self.tab_item_table and hasCleanBarTab(self.tab_item_table) then
        if config.clean_mode then
            local original_tabs = self._clean_bar_full_tab_item_table or self.tab_item_table
            ensureCleanBarTab(original_tabs)
            self._clean_bar_full_tab_item_table = original_tabs
            self.tab_item_table = getCleanTabs(original_tabs)
            self.last_index = 1
        else
            local original_tabs = self._clean_bar_full_tab_item_table or self.tab_item_table
            ensureCleanBarTab(original_tabs)
            self._clean_bar_full_tab_item_table = original_tabs
            self.tab_item_table = original_tabs
        end
    end

    return orig_touchmenu_init(self, ...)
end

-- ============================================================
-- Inject tab and settings into both FileManager and Reader menus
-- ============================================================

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local ReaderMenu = require("apps/reader/modules/readermenu")
local ReaderMenuOrder = require("ui/elements/reader_menu_order")

local orig_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    table.insert(FileManagerMenuOrder.setting, "----------------------------")
    table.insert(FileManagerMenuOrder.setting, "clean_bar_config")
    self.menu_items.clean_bar_config = buildSettingsMenu()
    orig_fm_setUpdateItemTable(self)
    applyCleanBarTabs(self)
end

local orig_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable

function ReaderMenu:setUpdateItemTable()
    table.insert(ReaderMenuOrder.setting, "----------------------------")
    table.insert(ReaderMenuOrder.setting, "clean_bar_config")
    self.menu_items.clean_bar_config = buildSettingsMenu()
    orig_reader_setUpdateItemTable(self)
    applyCleanBarTabs(self)
end
