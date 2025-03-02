local Context = require('render-markdown.core.context')
local list = require('render-markdown.core.list')
local logger = require('render-markdown.core.logger')
local state = require('render-markdown.state')
local str = require('render-markdown.core.str')

---@class render.md.handler.buf.MarkdownInline
---@field private marks render.md.Marks
---@field private config render.md.BufferConfig
---@field private context render.md.Context
local Handler = {}
Handler.__index = Handler

---@param buf integer
---@return render.md.handler.buf.MarkdownInline
function Handler.new(buf)
    local self = setmetatable({}, Handler)
    self.marks = list.new_marks()
    self.config = state.get_config(buf)
    self.context = Context.get(buf)
    return self
end

---@param root TSNode
---@return render.md.Mark[]
function Handler:parse(root)
    self.context:query(root, state.inline_query, function(capture, info)
        if capture == 'code' then
            self:code(info)
        elseif capture == 'shortcut' then
            self:shortcut(info)
        elseif capture == 'link' then
            self:link(info)
        else
            logger.unhandled_capture('inline', capture)
        end
    end)
    return self.marks:get()
end

---@private
---@param info render.md.NodeInfo
function Handler:code(info)
    local code = self.config.code
    if not code.enabled or not vim.tbl_contains({ 'normal', 'full' }, code.style) then
        return
    end
    self.marks:add(true, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        hl_group = code.highlight_inline,
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:shortcut(info)
    local callout = self:get_callout(info)
    if callout ~= nil then
        self:callout(info, callout)
        return
    end

    local checkbox = self:get_checkbox(info)
    if checkbox ~= nil then
        self:checkbox(info, checkbox)
        return
    end

    local line = info:line('on')
    if line ~= nil and line:find('[' .. info.text .. ']', 1, true) ~= nil then
        self:wiki_link(info)
        return
    end
end

---@private
---@param info render.md.NodeInfo
---@return render.md.CustomComponent?
function Handler:get_callout(info)
    local text = info.text:lower()
    for _, callout in pairs(self.config.callout) do
        if text == callout.raw:lower() then
            return callout
        end
    end
    return nil
end

---@private
---@param info render.md.NodeInfo
---@return render.md.CustomComponent?
function Handler:get_checkbox(info)
    local text = info.text
    for _, checkbox in pairs(self.config.checkbox.custom) do
        if text == checkbox.raw then
            return checkbox
        end
    end
    return nil
end

---@private
---@param info render.md.NodeInfo
---@param callout render.md.CustomComponent
function Handler:callout(info, callout)
    if not self.config.quote.enabled then
        return
    end

    ---Support for overriding title: https://help.obsidian.md/Editing+and+formatting/Callouts#Change+the+title
    ---@return string, boolean
    local function custom_title()
        local content = info:parent('inline')
        if content ~= nil then
            local line = str.split(content.text, '\n')[1]
            if #line > #callout.raw and vim.startswith(line:lower(), callout.raw:lower()) then
                local icon = str.split(callout.rendered, ' ')[1]
                local title = vim.trim(line:sub(#callout.raw + 1))
                return icon .. ' ' .. title, true
            end
        end
        return callout.rendered, false
    end

    local text, conceal = custom_title()
    local added = self.marks:add(true, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        virt_text = { { text, callout.highlight } },
        virt_text_pos = 'overlay',
        conceal = conceal and '' or nil,
    })
    if added then
        self.context:add_component(info, callout)
    end
end

---@private
---@param info render.md.NodeInfo
---@param checkbox render.md.CustomComponent
function Handler:checkbox(info, checkbox)
    if not self.config.checkbox.enabled then
        return
    end
    local inline = self.config.checkbox.position == 'inline'
    local icon, highlight = checkbox.rendered, checkbox.highlight
    local added = self.marks:add(true, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        virt_text = { { inline and icon or str.pad_to(info.text, icon), highlight } },
        virt_text_pos = 'inline',
        conceal = '',
    })
    if added then
        self.context:add_component(info, checkbox)
    end
end

---@private
---@param info render.md.NodeInfo
function Handler:wiki_link(info)
    local link = self.config.link
    if not link.enabled then
        return
    end

    local parts = str.split(info.text:sub(2, -2), '|')
    local link_component = self:link_component(parts[1])

    local icon, highlight = link.hyperlink, link.highlight
    if link_component ~= nil then
        icon, highlight = link_component.icon, link_component.highlight
    end
    local link_text = icon .. parts[#parts]
    local added = self.marks:add(true, info.start_row, info.start_col - 1, {
        end_row = info.end_row,
        end_col = info.end_col + 1,
        virt_text = { { link_text, highlight } },
        virt_text_pos = 'inline',
        conceal = '',
    })
    if added then
        self.context:add_offset(info, str.width(link_text) - str.width(info.text))
    end
end

---@private
---@param info render.md.NodeInfo
function Handler:link(info)
    local link = self.config.link
    if not link.enabled then
        return
    end

    if info.type == 'email_autolink' then
        local link_text = link.email .. info.text:sub(2, -2)
        self.marks:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { link_text, link.highlight } },
            virt_text_pos = 'inline',
            conceal = '',
        })
    else
        local link_text, highlight = link.hyperlink, link.highlight
        if info.type == 'image' then
            link_text = link.image
        elseif info.type == 'inline_link' then
            local destination = info:child('link_destination')
            local link_component = destination ~= nil and self:link_component(destination.text) or nil
            if link_component ~= nil then
                link_text, highlight = link_component.icon, link_component.highlight
            end
        end

        local added = self.marks:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { link_text, highlight } },
            virt_text_pos = 'inline',
        })
        if added then
            self.context:add_offset(info, str.width(link_text))
        end
    end
end

---@private
---@param destination string
---@return render.md.LinkComponent?
function Handler:link_component(destination)
    ---@type render.md.LinkComponent[]
    local link_components = vim.tbl_filter(function(link_component)
        return destination:find(link_component.pattern) ~= nil
    end, self.config.link.custom)
    table.sort(link_components, function(a, b)
        return str.width(a.pattern) < str.width(b.pattern)
    end)
    return link_components[#link_components]
end

---@class render.md.handler.MarkdownInline: render.md.Handler
local M = {}

---@param root TSNode
---@param buf integer
---@return render.md.Mark[]
function M.parse(root, buf)
    return Handler.new(buf):parse(root)
end

return M
