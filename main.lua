local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ReaderView = require("apps/reader/modules/readerview")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local ReaderHeader = WidgetContainer:extend{
    name = "readerheader",
    is_doc_only = true,
}

local DEFAULT_SETTINGS = {
    enabled = true,
    layout = "centered",
    center_template = "{author} {separator} {title}",
    left_template = "{author}",
    right_template = "{title}",
    separator = "-",
    font_face = "ffont",
    font_size = nil,
    font_bold = nil,
    top_padding = "small",
    use_book_margins = true,
    margin = "large",
    max_width_pct = 100,
    left_max_width_pct = 48,
    right_max_width_pct = 48,
}

local original_paintTo = ReaderView.paintTo
local patch_installed = false
local menu_patch_installed = false

local function copyDefaults()
    local settings = {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        settings[key] = value
    end
    return settings
end

local function getSettings()
    local settings = G_reader_settings:readSetting("reader_header") or {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    return settings
end

local function saveSetting(key, value)
    local settings = getSettings()
    settings[key] = value
    G_reader_settings:saveSetting("reader_header", settings)
end

local function getFooterSettings()
    return G_reader_settings:readSetting("footer") or {}
end

local function getPadding(name)
    if name == "tiny" then
        return Size.padding.tiny
    elseif name == "default" then
        return Size.padding.default
    elseif name == "large" then
        return Size.padding.large
    end
    return Size.padding.small
end

local function getMargin(name)
    if name == "tiny" then
        return Size.padding.tiny
    elseif name == "small" then
        return Size.padding.small
    elseif name == "default" then
        return Size.padding.default
    end
    return Size.padding.large
end

local function formatAuthor(authors)
    authors = authors or ""
    if authors:find("\n") then
        return T(_("%1 et al."), util.splitToArray(authors, "\n")[1] .. ",")
    end
    return authors
end

local function collectValues(view, settings)
    local book_title = ""
    local book_author = ""
    if view.ui.doc_props then
        book_title = view.ui.doc_props.display_title or ""
        book_author = formatAuthor(view.ui.doc_props.authors)
    end

    local pageno = view.state.page or 1
    local pages = view.ui.doc_settings.data.doc_pages or 1
    local pages_left_book = pages - pageno
    local percentage = (pageno / pages) * 100
    local book_chapter = ""
    local pages_chapter = 0
    local pages_left = 0
    local pages_done = 0

    if view.ui.toc then
        book_chapter = view.ui.toc:getTocTitleByPage(pageno) or ""
        pages_chapter = view.ui.toc:getChapterPageCount(pageno) or pages
        pages_left = view.ui.toc:getChapterPagesLeft(pageno) or view.ui.document:getTotalPagesLeft(pageno)
        pages_done = view.ui.toc:getChapterPagesDone(pageno) or 0
    end
    pages_done = pages_done + 1

    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
        battery = batt_prefix .. batt_lvl .. "%"
    end

    return {
        title = book_title,
        author = book_author,
        chapter = book_chapter,
        page = tostring(pageno),
        pages = tostring(pages),
        page_progress = ("%d / %d"):format(pageno, pages),
        percentage = ("%.1f%%"):format(percentage),
        chapter_progress = pages_done .. " // " .. pages_chapter,
        pages_left = tostring(pages_left),
        pages_left_book = tostring(pages_left_book),
        time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or "",
        battery = battery,
        separator = settings.separator or "-",
    }
end

local function expandTemplate(template, values)
    template = template or ""
    return (template:gsub("{([%w_]+)}", function(key)
        return values[key] or ""
    end):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fitText(text, face, bold, max_width)
    if text == nil or text == "" then
        return ""
    end
    local text_widget = TextWidget:new{
        text = text:gsub(" ", "\u{00A0}"),
        max_width = max_width,
        face = face,
        bold = bold,
        padding = 0,
    }
    local fitted_text, add_ellipsis = text_widget:getFittedText()
    text_widget:free()
    if add_ellipsis then
        fitted_text = fitted_text .. "..."
    end
    return BD.auto(fitted_text)
end

local function getContentWidth(view, settings)
    local fallback_margin = getMargin(settings.margin)
    local left_margin = fallback_margin
    local right_margin = fallback_margin
    if settings.use_book_margins then
        local margins = view.document:getPageMargins()
        left_margin = margins.left or fallback_margin
        right_margin = margins.right or fallback_margin
    end
    return Screen:getWidth() - left_margin - right_margin, left_margin, right_margin
end

local function paintCenteredHeader(view, bb, x, y, settings, face, bold, fgcolor, top_padding, values)
    local avail_width, left_margin, right_margin = getContentWidth(view, settings)
    local max_width = avail_width * settings.max_width_pct / 100
    local header_text = TextWidget:new{
        text = fitText(expandTemplate(settings.center_template, values), face, bold, max_width),
        face = face,
        bold = bold,
        fgcolor = fgcolor,
        padding = 0,
    }
    local header = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = header_text:getSize().h + top_padding },
        VerticalGroup:new{
            VerticalSpan:new{ width = top_padding },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_margin },
                header_text,
                HorizontalSpan:new{ width = right_margin },
            },
        },
    }
    header:paintTo(bb, x, y)
end

local function paintCorneredHeader(view, bb, x, y, settings, face, bold, fgcolor, top_padding, values)
    local avail_width = getContentWidth(view, settings)
    local left_header_text = TextWidget:new{
        text = fitText(expandTemplate(settings.left_template, values), face, bold, avail_width * settings.left_max_width_pct / 100),
        face = face,
        bold = bold,
        fgcolor = fgcolor,
        padding = 0,
    }
    local right_header_text = TextWidget:new{
        text = fitText(expandTemplate(settings.right_template, values), face, bold, avail_width * settings.right_max_width_pct / 100),
        face = face,
        bold = bold,
        fgcolor = fgcolor,
        padding = 0,
    }
    local dynamic_space = avail_width - left_header_text:getSize().w - right_header_text:getSize().w
    if dynamic_space < 0 then
        dynamic_space = 0
    end
    local header = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = math.max(left_header_text:getSize().h, right_header_text:getSize().h) + top_padding },
        VerticalGroup:new{
            VerticalSpan:new{ width = top_padding },
            HorizontalGroup:new{
                left_header_text,
                HorizontalSpan:new{ width = dynamic_space },
                right_header_text,
            },
        },
    }
    header:paintTo(bb, x, y)
end

local function paintHeader(view, bb, x, y)
    if view.render_mode ~= nil then return end
    if bb ~= Screen.bb then return end

    local settings = getSettings()
    if not settings.enabled then return end

    local footer_settings = getFooterSettings()
    local font_size = settings.font_size or footer_settings.text_font_size or 14
    local bold = settings.font_bold
    if bold == nil then
        bold = footer_settings.text_font_bold or false
    end

    local face = Font:getFace(settings.font_face or "ffont", font_size)
    local fgcolor = Blitbuffer.COLOR_BLACK
    local top_padding = getPadding(settings.top_padding)
    local values = collectValues(view, settings)

    if settings.layout == "cornered" then
        paintCorneredHeader(view, bb, x, y, settings, face, bold, fgcolor, top_padding, values)
    else
        paintCenteredHeader(view, bb, x, y, settings, face, bold, fgcolor, top_padding, values)
    end
end

local function installPaintPatch()
    if patch_installed then return end
    ReaderView.paintTo = function(self, bb, x, y)
        original_paintTo(self, bb, x, y)
        paintHeader(self, bb, x, y)
    end
    patch_installed = true
end

local function appendHeaderMenu(menu_items, plugin)
    if not menu_items.status_bar then
        menu_items.status_bar = {
            text = _("Status bar"),
            sub_item_table = {},
        }
    end

    local sub_items = menu_items.status_bar.sub_item_table or {}
    menu_items.status_bar.sub_item_table = sub_items

    for _, item in ipairs(sub_items) do
        if item.reader_header_settings then
            return
        end
    end

    table.insert(sub_items, plugin:getHeaderMenuTable())
end

local function installStatusBarMenuPatch(plugin)
    if menu_patch_installed then return end

    local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
    if not ok or not ReaderFooter or not ReaderFooter.addToMainMenu then
        return
    end

    local original_addToMainMenu = ReaderFooter.addToMainMenu
    ReaderFooter.addToMainMenu = function(footer, menu_items)
        original_addToMainMenu(footer, menu_items)
        appendHeaderMenu(menu_items, plugin)
    end
    menu_patch_installed = true
end

local function refreshReader()
    UIManager:setDirty(nil, "ui")
end

function ReaderHeader:init()
    installPaintPatch()
    installStatusBarMenuPatch(self)
    if self.ui and self.ui.menu and not self._menu_registered then
        self.ui.menu:registerToMainMenu(self)
        self._menu_registered = true
    end
end

function ReaderHeader:onReaderReady()
    installPaintPatch()
    installStatusBarMenuPatch(self)
    if self.ui and self.ui.menu and not self._menu_registered then
        self.ui.menu:registerToMainMenu(self)
        self._menu_registered = true
    end
end

function ReaderHeader:showTokens()
    UIManager:show(InfoMessage:new{
        text = _([[Template tokens:
{title}, {author}, {chapter}, {page}, {pages}, {page_progress}, {percentage}, {chapter_progress}, {pages_left}, {pages_left_book}, {time}, {battery}, {separator}]]),
        timeout = 12,
    })
end

function ReaderHeader:editTextSetting(title, key)
    local settings = getSettings()
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = tostring(settings[key] or ""),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        saveSetting(key, input_dialog:getInputText())
                        UIManager:close(input_dialog)
                        refreshReader()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function ReaderHeader:editNumberSetting(title, key, min_value, max_value)
    local settings = getSettings()
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = tostring(settings[key] or DEFAULT_SETTINGS[key] or ""),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(input_dialog:getInputText())
                        if value then
                            if min_value and value < min_value then value = min_value end
                            if max_value and value > max_value then value = max_value end
                            saveSetting(key, value)
                            refreshReader()
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function ReaderHeader:resetSettings()
    local confirm_box
    confirm_box = ConfirmBox:new{
        text = _("Reset reader header settings to defaults?"),
        ok_text = _("Reset"),
        ok_callback = function()
            G_reader_settings:saveSetting("reader_header", copyDefaults())
            refreshReader()
        end,
    }
    UIManager:show(confirm_box)
end

function ReaderHeader:getHeaderMenuTable()
    return {
        reader_header_settings = true,
        text = _("Header"),
        sub_item_table = {
            {
                text = _("Enable header"),
                checked_func = function()
                    return getSettings().enabled
                end,
                callback = function()
                    saveSetting("enabled", not getSettings().enabled)
                    refreshReader()
                end,
            },
            {
                text = _("Layout"),
                sub_item_table = {
                    {
                        text = _("Centered"),
                        checked_func = function()
                            return getSettings().layout == "centered"
                        end,
                        callback = function()
                            saveSetting("layout", "centered")
                            refreshReader()
                        end,
                    },
                    {
                        text = _("Cornered"),
                        checked_func = function()
                            return getSettings().layout == "cornered"
                        end,
                        callback = function()
                            saveSetting("layout", "cornered")
                            refreshReader()
                        end,
                    },
                },
            },
            {
                text = _("Center text"),
                callback = function()
                    self:editTextSetting(_("Center text"), "center_template")
                end,
            },
            {
                text = _("Left text"),
                callback = function()
                    self:editTextSetting(_("Left text"), "left_template")
                end,
            },
            {
                text = _("Right text"),
                callback = function()
                    self:editTextSetting(_("Right text"), "right_template")
                end,
            },
            {
                text = _("Separator"),
                callback = function()
                    self:editTextSetting(_("Separator"), "separator")
                end,
            },
            {
                text = _("Font size"),
                callback = function()
                    self:editNumberSetting(_("Font size"), "font_size", 6, 72)
                end,
            },
            {
                text = _("Bold"),
                checked_func = function()
                    local settings = getSettings()
                    if settings.font_bold == nil then
                        return getFooterSettings().text_font_bold or false
                    end
                    return settings.font_bold
                end,
                callback = function()
                    local settings = getSettings()
                    local current = settings.font_bold
                    if current == nil then
                        current = getFooterSettings().text_font_bold or false
                    end
                    saveSetting("font_bold", not current)
                    refreshReader()
                end,
            },
            {
                text = _("Top padding"),
                sub_item_table = {
                    { text = _("Tiny"), checked_func = function() return getSettings().top_padding == "tiny" end, callback = function() saveSetting("top_padding", "tiny"); refreshReader() end },
                    { text = _("Small"), checked_func = function() return getSettings().top_padding == "small" end, callback = function() saveSetting("top_padding", "small"); refreshReader() end },
                    { text = _("Default"), checked_func = function() return getSettings().top_padding == "default" end, callback = function() saveSetting("top_padding", "default"); refreshReader() end },
                    { text = _("Large"), checked_func = function() return getSettings().top_padding == "large" end, callback = function() saveSetting("top_padding", "large"); refreshReader() end },
                },
            },
            {
                text = _("Use book margins"),
                checked_func = function()
                    return getSettings().use_book_margins
                end,
                callback = function()
                    saveSetting("use_book_margins", not getSettings().use_book_margins)
                    refreshReader()
                end,
            },
            {
                text = _("Fixed margin"),
                sub_item_table = {
                    { text = _("Tiny"), checked_func = function() return getSettings().margin == "tiny" end, callback = function() saveSetting("margin", "tiny"); refreshReader() end },
                    { text = _("Small"), checked_func = function() return getSettings().margin == "small" end, callback = function() saveSetting("margin", "small"); refreshReader() end },
                    { text = _("Default"), checked_func = function() return getSettings().margin == "default" end, callback = function() saveSetting("margin", "default"); refreshReader() end },
                    { text = _("Large"), checked_func = function() return getSettings().margin == "large" end, callback = function() saveSetting("margin", "large"); refreshReader() end },
                },
            },
            {
                text = _("Center max width percent"),
                callback = function()
                    self:editNumberSetting(_("Center max width percent"), "max_width_pct", 10, 100)
                end,
            },
            {
                text = _("Left max width percent"),
                callback = function()
                    self:editNumberSetting(_("Left max width percent"), "left_max_width_pct", 10, 100)
                end,
            },
            {
                text = _("Right max width percent"),
                callback = function()
                    self:editNumberSetting(_("Right max width percent"), "right_max_width_pct", 10, 100)
                end,
            },
            {
                text = _("Available tokens"),
                callback = function()
                    self:showTokens()
                end,
            },
            {
                text = _("Reset defaults"),
                callback = function()
                    self:resetSettings()
                end,
            },
        },
    }
end

function ReaderHeader:addToMainMenu(menu_items)
    appendHeaderMenu(menu_items, self)
end

return ReaderHeader
