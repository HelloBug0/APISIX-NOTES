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
local log          = require("apisix.core.log")
local tablepool    = require("tablepool")
local get_var      = require("resty.ngxvar").fetch
-- 获得nginx request请求实体，通过该实体，可以获得更多的请求变量
-- 参考：https://github.com/api7/lua-var-nginx-module
local get_request  = require("resty.ngxvar").request
-- 获得请求中的cookie信息，参考：https://github.com/cloudflare/lua-resty-cookie
local ck           = require "resty.cookie"
local setmetatable = setmetatable
local ffi          = require("ffi")
local C            = ffi.C
local sub_str      = string.sub
local rawset       = rawset
local ngx_var      = ngx.var
local re_gsub      = ngx.re.gsub
local type         = type
local error        = error
local ngx          = ngx


ffi.cdef[[
int memcmp(const void *s1, const void *s2, size_t n);
]]


local _M = {version = 0.2}


do
    local var_methods = {
        method = ngx.req.get_method,
        cookie = function () return ck:new() end
    }

    local ngx_var_names = {
        upstream_scheme            = true,
        upstream_host              = true,
        upstream_upgrade           = true,
        upstream_connection        = true,
        upstream_uri               = true,

        upstream_mirror_host       = true,

        upstream_cache_zone        = true,
        upstream_cache_zone_info   = true,
        upstream_no_cache          = true,
        upstream_cache_key         = true,
        upstream_cache_bypass      = true,
        upstream_hdr_expires       = true,
        upstream_hdr_cache_control = true,
    }

    local mt = {
        __index = function(t, key) -- 函数的两个参数分别表示当前表、从表中取值的key
            if type(key) ~= "string" then
                -- 输出函数调用栈，并打印错误信息
                error("invalid argument, expect string value", 2)
            end

            local val
            local method = var_methods[key]
            if method then
                val = method() -- 获得请求方法获得获得cooike的句柄

            elseif C.memcmp(key, "cookie_", 7) == 0 then -- 直接使用C函数，提高程序执行效率
                local cookie = t.cookie -- 这里是一个递归调用，会走上面的if method分支，返回ck:new()返回值，这里称为cookie句柄
                if cookie then
                    local err
                    val, err = cookie:get(sub_str(key, 8)) -- 根据cookie句柄获得当前key的value
                    if not val then
                        log.warn("failed to fetch cookie value by key: ",
                                 key, " error: ", err)
                    end
                end

            elseif C.memcmp(key, "http_", 5) == 0 then
                key = key:lower()
                key = re_gsub(key, "-", "_", "jo") -- 将key中的-替换为_
                val = get_var(key, t._request) -- 从_request中获得key的value，_request从函数set_vars_meta中获得

            elseif key == "route_id" then
                val = ngx.ctx.api_ctx and ngx.ctx.api_ctx.route_id

            elseif key == "service_id" then
                val = ngx.ctx.api_ctx and ngx.ctx.api_ctx.service_id

            elseif key == "consumer_name" then
                val = ngx.ctx.api_ctx and ngx.ctx.api_ctx.consumer_name

            else
                val = get_var(key, t._request)
            end

            if val ~= nil then
                -- 当val取得时，将key-value键值对保存在t中
                -- 这里使用rawset是指在保存key-value时，不执行__newindex元方法
                -- 对应的有rawget(table, key)，在获得值时，不执行__index原方法
                rawset(t, key, val)
            end

            return val
        end,

        __newindex = function(t, key, val)
            if ngx_var_names[key] then -- 仅允许ngx_var_names中定义的key保存在ngx.var中
                ngx_var[key] = val
            end

            -- log.info("key: ", key, " new val: ", val)
            rawset(t, key, val)
        end,
    }

function _M.set_vars_meta(ctx)
    local var = tablepool.fetch("ctx_var", 0, 32)
    var._request = get_request()
    setmetatable(var, mt)
    ctx.var = var
end

function _M.release_vars(ctx)
    if ctx.var == nil then
        return
    end

    tablepool.release("ctx_var", ctx.var)
    ctx.var = nil
end

end -- do


return _M
