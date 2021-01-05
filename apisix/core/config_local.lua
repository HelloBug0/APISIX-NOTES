--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local log = require("apisix.core.log")
local profile = require("apisix.core.profile")
local table = require("apisix.core.table")
local yaml = require("tinyyaml")

local io_open = io.open
local type = type
local str_gmatch = string.gmatch
local string = string
local pairs = pairs
local getmetatable = getmetatable

-- 获得本地默认配置文件名，通常为 /usr/local/apisix/conf/config-default.yaml
local local_default_conf_path = profile:yaml_path("config-default")
-- 获得本地配置文件名，通常为 /usr/local/apisix/conf/config.yaml
local local_conf_path = profile:yaml_path("config")
-- 用于保存配置数据
local config_data


local _M = {}

-- 全量读取指定的文件，返回文件内容
local function read_file(path)
    local file, err = io_open(path, "rb")   -- read as binary mode
    if not file then
        log.error("failed to read config file:" .. path, ", error info:", err)
        return nil, err
    end

    local content = file:read("*a") -- `*a` reads the whole file
    file:close()
    return content
end

function _M.clear_cache()
    config_data = nil
end


local function is_empty_yaml_line(line)
    -- 如果无有效配置信息，即是空行或仅包含空格或仅包含注释行，则返回真
    return line == '' or string.find(line, '^%s*$') or
           string.find(line, '^%s*#')
end

--[[ 如果 config.yaml 仅配置如下内容：
apisix:
  admin_key:

该函数会输出如下内容：
nginx: [debug] [lua] config_local.lua:75: merge_conf(): table key: apisix
nginx: [debug] [lua] config_local.lua:65: tinyyaml_type(): table type: map
nginx: [debug] [lua] config_local.lua:75: merge_conf(): table key: admin_key
nginx: [debug] [lua] config_local.lua:65: tinyyaml_type(): table type: null

其中 nginx: [debug] [lua] config_local.lua:75: merge_conf(): 日志输出为测试笔者添加的输出
由此可以看出，yaml配置的每一个取值都会有一个类型，如果类型为 null，则表示取值为空
  ]]
local function tinyyaml_type(t)
    local mt = getmetatable(t)
    if mt then
        log.debug("table type: ", mt.__type)
        return mt.__type
    end
end


--[[ base为默认配置，new_tab 为用户配置，用户配置会覆盖默认配置，即将用户配置写入到默认配置 ]]
local function merge_conf(base, new_tab, ppath)
    ppath = ppath or "" -- ppath用于日志输出

    for key, val in pairs(new_tab) do
        if type(val) == "table" then
            if tinyyaml_type(val) == "null" then
                base[key] = nil

            -- 用户配置 val 为列表，无需进一步合并，直接写入到默认配置
            elseif table.isarray(val) then
                base[key] = val

            else -- val 为字典类型，则需要将用户配置和默认配置需要进一步合并
                -- 如果默认配置为空，则设置默认配置为空表
                if base[key] == nil then
                    base[key] = {}
                end

                -- 递归合并配置
                local ok, err = merge_conf(
                    base[key],
                    val,
                    ppath == "" and key or ppath .. "->" .. key
                )
                if not ok then
                    return nil, err
                end
            end
        else -- val 非 table 类型，可直接赋值
            -- 需要首先判断 base[key] 是否为空，如果为空，可直接进行赋值
            -- 这里首先判断是否为空，再赋值，为了避免 base[key] 和 val 类型不同，类型不同，说明是错误的配置
            if base[key] == nil then
                base[key] = val
            -- 此时 base[key] != nil，所以可以直接利用type函数判断类型，
            elseif type(base[key]) ~= type(val) then
                return false, "failed to merge, path[" ..
                              (ppath == "" and key or ppath .. "->" .. key) ..
                              "] expect: " ..
                              type(base[key]) .. ", but got: " .. type(val)
            else -- 此时base[key] 和 val 类型一定相同
                base[key] = val
            end
        end
    end

    return base
end

--[[ 读取配置文件 /usr/local/apisix/conf/config-default.yaml 和配置文件 /usr/local/apisix/conf/config.yaml，
如果配置文件 config.yaml不为空，将两个配置文件的配置进行合并，默认配置文件 config-default.yaml 中配置的值会被 config.yaml 覆盖 ]]
function _M.local_conf(force)
    -- 如果非强制加载配置，以及 config_data 非空，则直接返回缓存的配置信息
    if not force and config_data then
        return config_data
    end

    -- 获得本地默认配置文件内容
    local default_conf_yaml, err = read_file(local_default_conf_path)
    if type(default_conf_yaml) ~= "string" then
        return nil, "failed to read config-default file:" .. err
    end
    -- 获得 yaml 文件解析后的配置信息
    config_data = yaml.parse(default_conf_yaml)

    -- 获得本地配置文件内容
    local user_conf_yaml = read_file(local_conf_path) or ""
    local is_empty_file = true
    -- 判断本地配置文件是否为空
    -- 根据字符串匹配读取每一行，判断是否为空，若不为空，则文件不为空
    for line in str_gmatch(user_conf_yaml .. '\n', '(.-)\r?\n') do
        if not is_empty_yaml_line(line) then
            is_empty_file = false
            break
        end
    end

    -- 如果文件不为空，则解析本地配置文件内容
    if not is_empty_file then
        local user_conf = yaml.parse(user_conf_yaml)
        if not user_conf then
            return nil, "invalid config.yaml file"
        end

        -- 将本地配置文件和本地默认配置文件合并
        config_data, err = merge_conf(config_data, user_conf)
        if err then
            return nil, err
        end
    end

    -- 返回配置文件解析结果
    return config_data
end


return _M
