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

--[[ 总体设计思路如下：
1.每个路由都可以有自己的日志服务器，即不同的路由可以将自己的日志发送到不同的日志服务器上
2.日志信息根据路由ID进行分类，自己保存自己的日志信息，自己对应自己的日志服务器
3.每个日志服务器对应一个缓存，缓存大小可用户设置，发送的日志会首先保存至缓存中，待缓存满时将日志发送出去
4.日志有缓存的同时有一个定时器，定时器定时将缓存里数据发送出去。因为缓存是否满，是在每一次发送日志的时候进行判断的，
如果没有定时器的话，而且缓存一直未满，就可能有日志无法发送出去
]]
local core = require("apisix.core")
local log_util = require("apisix.utils.log-util")
local batch_processor = require("apisix.utils.batch-processor")
local logger_socket = require("resty.logger.socket")
local plugin_name = "syslog"
local ngx = ngx
local buffers = {}
local ipairs   = ipairs
local stale_timer_running = false;
local timer_at = ngx.timer.at
local tostring = tostring


local schema = {
    type = "object",
    properties = {
        host = {type = "string"},
        port = {type = "integer"},
        name = {type = "string", default = "sys logger"},
        flush_limit = {type = "integer", minimum = 1, default = 4096},
        drop_limit = {type = "integer", default = 1048576},
        timeout = {type = "integer", minimum = 1, default = 3},
        sock_type = {type = "string", default = "tcp", enum = {"tcp", "udp"}},
        max_retry_times = {type = "integer", minimum = 1, default = 1},
        retry_interval = {type = "integer", minimum = 0, default = 1},
        pool_size = {type = "integer", minimum = 5, default = 5},
        tls = {type = "boolean", default = false},
        batch_max_size = {type = "integer", minimum = 1, default = 1000},
        buffer_duration = {type = "integer", minimum = 1, default = 60},
        include_req_body = {type = "boolean", default = false}
    },
    required = {"host", "port"}
}


local lrucache = core.lrucache.new({
    ttl = 300, count = 512, serial_creating = true,
})


local _M = {
    version = 0.1,
    priority = 401,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.flush_syslog(logger)
    local ok, err = logger:flush(logger)
    if not ok then
        core.log.error("failed to flush message:", err)
    end

    return ok
end


local function send_syslog_data(conf, log_message, api_ctx)
    local err_msg
    local res = true

    -- 从缓存中获得发送日志句柄，如果缓存中不存在，重新创建句柄，并放在缓存中
    -- fetch it from lrucache
    local logger, err = core.lrucache.plugin_ctx(
        lrucache, api_ctx, nil, logger_socket.new, logger_socket, {
            host = conf.host,
            port = conf.port,
            flush_limit = conf.flush_limit,
            drop_limit = conf.drop_limit,
            timeout = conf.timeout,
            sock_type = conf.sock_type,
            max_retry_times = conf.max_retry_times,
            retry_interval = conf.retry_interval,
            pool_size = conf.pool_size,
            tls = conf.tls,
        }
    )

    if not logger then
        res = false
        err_msg = "failed when initiating the sys logger processor".. err
    end

    -- reuse the logger object
    local ok, err = logger:log(core.json.encode(log_message))
    if not ok then
        res = false
        err_msg = "failed to log message" .. err
    end

    return res, err_msg
end


-- remove stale objects from the memory after timer expires
local function remove_stale_objects(premature)
    if premature then
        return
    end

    for key, batch in ipairs(buffers) do
        if #batch.entry_buffer.entries == 0 and #batch.batch_to_process == 0 then
            core.log.debug("removing batch processor stale object, route id:", tostring(key))
            buffers[key] = nil
        end
    end

    stale_timer_running = false
end


-- log phase in APISIX
function _M.log(conf, ctx)
    -- 获得需要发送的日志信息，包含请求和响应信息，以及路由相关信息
    local entry = log_util.get_full_log(ngx, conf)

    if not entry.route_id then
        core.log.error("failed to obtain the route id for sys logger")
        return
    end

    local log_buffer = buffers[entry.route_id]

    -- 每隔30min清除一次buffers中的过期数据，通过变量stale_time_running取值表明是否有定时器在运行
    if not stale_timer_running then
        -- run the timer every 30 mins if any log is present
        timer_at(1800, remove_stale_objects)
        stale_timer_running = true
    end

    if log_buffer then
        log_buffer:push(entry)
        return
    end

    -- Generate a function to be executed by the batch processor
    local cp_ctx = core.table.clone(ctx)
    local func = function(entries, batch_max_size)
        local data, err
        if batch_max_size == 1 then
            data, err = core.json.encode(entries[1]) -- encode as single {}
        else
            data, err = core.json.encode(entries) -- encode as array [{}]
        end

        if not data then
            return false, 'error occurred while encoding the data: ' .. err
        end

        return send_syslog_data(conf, data, cp_ctx)
    end

    local config = {
        name = conf.name,
        retry_delay = conf.retry_interval,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_times,
        buffer_duration = conf.buffer_duration,
        inactive_timeout = conf.timeout,
    }

    local err
    log_buffer, err = batch_processor:new(func, config)

    if not log_buffer then
        core.log.error("error when creating the batch processor: ", err)
        return
    end

    buffers[entry.route_id] = log_buffer
    log_buffer:push(entry)

end


return _M
