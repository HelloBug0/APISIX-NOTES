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
local core = require("apisix.core")
local setmetatable = setmetatable
local timer_at = ngx.timer.at
local ipairs = ipairs
local table = table
local now = ngx.now
local type = type
local batch_processor = {}
local batch_processor_mt = {
    __index = batch_processor -- 如果在索引processor时，没有找到指定的字段，则从batch_processor中查找
}
local execute_func
local create_buffer_timer


local schema = {
    type = "object",
    properties = {
        name = {type = "string", default = "log buffer"},
        max_retry_count = {type = "integer", minimum = 0, default= 0},
        retry_delay = {type = "integer", minimum = 0, default= 1},
        buffer_duration = {type = "integer", minimum = 1, default= 60},
        inactive_timeout = {type = "integer", minimum = 1, default= 5},
        batch_max_size = {type = "integer", minimum = 1, default= 1000},
    }
}


-- 设置定时器，执行日志发送函数
local function schedule_func_exec(self, delay, batch)
    local hdl, err = timer_at(delay, execute_func, self, batch)
    if not hdl then
        core.log.error("failed to create process timer: ", err)
        return
    end
end


function execute_func(premature, self, batch)
    if premature then
        return
    end

    -- 根据函数调用结果和尝试次数，多次调用日志发送函数
    local ok, err = self.func(batch.entries, self.batch_max_size)
    if not ok then
        core.log.error("Batch Processor[", self.name,
                       "] failed to process entries: ", err)
        batch.retry_count = batch.retry_count + 1
        if batch.retry_count <= self.max_retry_count then
            schedule_func_exec(self, self.retry_delay,
                               batch)
        else
            core.log.error("Batch Processor[", self.name,"] exceeded ",
                           "the max_retry_count[", batch.retry_count,
                           "] dropping the entries")
        end
        return
    end

    core.log.debug("Batch Processor[", self.name,
                   "] successfully processed the entries")
end


local function flush_buffer(premature, self)
    if premature then
        return
    end

    if now() - self.last_entry_t >= self.inactive_timeout or
       now() - self.first_entry_t >= self.buffer_duration
    then
        core.log.debug("Batch Processor[", self.name ,"] buffer ",
            "duration exceeded, activating buffer flush")
        self:process_buffer()
        self.is_timer_running = false
        return
    end

    -- buffer duration did not exceed or the buffer is active,
    -- extending the timer
    core.log.debug("Batch Processor[", self.name ,"] extending buffer timer")
    create_buffer_timer(self)
end


-- 通过设置定时器的方式发送日志
-- 也就是说有两种方式发送日志：定时器的方式和在日志发送的过程，如果缓冲区不够用的话，也会发送日志
function create_buffer_timer(self)
    local hdl, err = timer_at(self.inactive_timeout, flush_buffer, self)
    if not hdl then
        core.log.error("failed to create buffer timer: ", err)
        return
    end
    self.is_timer_running = true
end


function batch_processor:new(func, config)
    -- 检查config语法是否合法
    local ok, err = core.schema.check(schema, config)
    if not ok then
        return nil, err
    end

    -- 检查函数是否是函数
    if not(type(func) == "function") then
        return nil, "Invalid argument, arg #1 must be a function"
    end

    local processor = {
        func = func,
        buffer_duration = config.buffer_duration,
        inactive_timeout = config.inactive_timeout,
        max_retry_count = config.max_retry_count,
        batch_max_size = config.batch_max_size, -- entries 中保存的日志最大个数，超出该个数会被发送出去
        retry_delay = config.retry_delay,
        name = config.name,
        batch_to_process = {},
        entry_buffer = { entries = {}, retry_count = 0}, -- entries 保存日志信息
        is_timer_running = false,
        first_entry_t = 0,
        last_entry_t = 0
    }

    return setmetatable(processor, batch_processor_mt)
end


function batch_processor:push(entry)
    -- if the batch size is one then immediately send for processing
    if self.batch_max_size == 1 then
        local batch = { entries = { entry }, retry_count = 0 }
        schedule_func_exec(self, 0, batch)
        return
    end

    local entries = self.entry_buffer.entries
    table.insert(entries, entry)

    if #entries == 1 then
        self.first_entry_t = now()
    end
    self.last_entry_t = now()

    -- 添加新的日志时，如果超过缓存的最大日志个数，则首先将日志发送出去，然后再缓存新的日志
    if self.batch_max_size <= #entries then
        core.log.debug("Batch Processor[", self.name ,
                       "] batch max size has exceeded")
        self:process_buffer()
    end

    if not self.is_timer_running then
        create_buffer_timer(self)
    end
end


-- 批处理日志时，将日志首先发送出去，为之后的日志腾出空间
function batch_processor:process_buffer()
    -- If entries are present in the buffer move the entries to processing
    if #self.entry_buffer.entries > 0 then
        core.log.debug("tranferring buffer entries to processing pipe line, ",
            "buffercount[", #self.entry_buffer.entries ,"]")
        self.batch_to_process[#self.batch_to_process + 1] = self.entry_buffer
        self.entry_buffer = { entries = {}, retry_count = 0 }
    end

    for _, batch in ipairs(self.batch_to_process) do
        schedule_func_exec(self, 0, batch)
    end
    self.batch_to_process = {}
end


return batch_processor
