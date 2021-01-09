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

local table        = require("apisix.core.table")
local config_local = require("apisix.core.config_local")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local etcd_apisix  = require("apisix.core.etcd")
local etcd         = require("resty.etcd")
local new_tab      = require("table.new")
local clone_tab    = require("table.clone")
local check_schema = require("apisix.core.schema").check
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable
local ngx_sleep    = require("apisix.core.utils").sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local sub_str      = string.sub
local tostring     = tostring
local tonumber     = tonumber
local xpcall       = xpcall
local debug        = debug
local error        = error
local created_obj  = {}


local _M = {
    version = 0.3,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}


local mt = {
    __index = _M,
    __tostring = function(self)
        return " etcd key: " .. self.key
    end
}


local function getkey(etcd_cli, key)
    if not etcd_cli then
        return nil, "not inited"
    end

    local res, err = etcd_cli:readdir(key)
    if not res then
        -- log.error("failed to get key from etcd: ", err)
        return nil, err
    end

    if type(res.body) ~= "table" then
        return nil, "failed to get key from etcd"
    end

    res, err = etcd_apisix.get_format(res, key, true)
    if not res then
        return nil, err
    end

    return res
end


local function readdir(etcd_cli, key)
    if not etcd_cli then
        return nil, "not inited"
    end

    local res, err = etcd_cli:readdir(key)
    if not res then
        -- log.error("failed to get key from etcd: ", err)
        return nil, err
    end

    if type(res.body) ~= "table" then
        return nil, "failed to read etcd dir"
    end

    res, err = etcd_apisix.get_format(res, key .. '/', true)
    if not res then
        return nil, err
    end

    return res
end

--[[ 读取版本为modified_index的key，读超时为timeout秒
对该函数的理解需要参考：https://github.com/api7/lua-resty-etcd/
可参考APISX-NOTES目录下lua-resty-etcd-master对该库的相关注释
]]
local function waitdir(etcd_cli, key, modified_index, timeout)
    if not etcd_cli then
        return nil, nil, "not inited"
    end

    local opts = {}
    opts.start_revision = modified_index
    opts.timeout = timeout
    opts.need_cancel = true
    -- 三个返回值依次是：数据读取函数，错误信息、http连接句柄
    local res_func, func_err, http_cli = etcd_cli:watchdir(key, opts)
    if not res_func then
        return nil, func_err
    end

    -- in etcd v3, the 1st res of watch is watch info, useless to us.
    -- try twice to skip create info
    local res, err = res_func() -- 需要读取两次？
    if not res or not res.result or not res.result.events then
        res, err = res_func()
    end

    if http_cli then -- 断开http连接
        local res_cancel, err_cancel = etcd_cli:watchcancel(http_cli)
        if res_cancel == 1 then
            log.info("cancel watch connection success")
        else
            log.error("cancel watch failed: ", err_cancel)
        end
    end

    if not res then
        -- log.error("failed to get key from etcd: ", err)
        return nil, err
    end

    if type(res.result) ~= "table" then
        return nil, "failed to wait etcd dir"
    end
    return etcd_apisix.watch_format(res) -- 格式化请求结果
end


local function short_key(self, str)
    return sub_str(str, #self.key + 2)
end


-- 更新当前key的版本信息
function _M.upgrade_version(self, new_ver)
    new_ver = tonumber(new_ver)
    if not new_ver then
        return
    end

    local pre_index = self.prev_index

    if new_ver <= pre_index then
        return
    end

    self.prev_index = new_ver
    return
end


local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments" -- 第一个返回值使用false更好
    end

    -- 第一次调用该函数以及在出错的情况下需要重新读取全部信息，此时self.need_reload = true
    if self.need_reload then
        local res, err = readdir(self.etcd_cli, self.key)
        if not res then
            return false, err
        end

        -- 结果为空
        local dir_res, headers = res.body.node or {}, res.headers
        log.debug("readdir key: ", self.key, " res: ",
                  json.delay_encode(dir_res))
        if not dir_res then
            return false, err -- 此处 err 指定类似"empty result"更好？
        end

        if self.values then -- 第一次调用时，self.values为空
            for i, val in ipairs(self.values) do
                if val and val.clean_handlers then
                    for _, clean_handler in ipairs(val.clean_handlers) do
                        clean_handler(val)
                    end
                    val.clean_handlers = nil
                end
            end

            self.values = nil
            self.values_hash = nil
        end

        local changed = false

        if self.single_item then -- 当前key为文件
            self.values = new_tab(1, 0)
            self.values_hash = new_tab(0, 1)

            local item = dir_res
            local data_valid = item.value ~= nil

            -- 校验key对应的值的语法合法性
            if data_valid and self.item_schema then
                data_valid, err = check_schema(self.item_schema, item.value)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.encode(item.value))
                end
            end

            if data_valid then
                changed = true
                insert_tab(self.values, item)
                self.values_hash[self.key] = #self.values

                item.clean_handlers = {}

                if self.filter then
                    self.filter(item)
                end
            end

            self:upgrade_version(item.modifiedIndex)

        else -- 当前key为目录
            if not dir_res.nodes then
                dir_res.nodes = {}
            end

            self.values = new_tab(#dir_res.nodes, 0)
            self.values_hash = new_tab(0, #dir_res.nodes)

            -- 遍历当前目录下的所有文件
            for _, item in ipairs(dir_res.nodes) do
                local key = short_key(self, item.key)
                local data_valid = true
                -- 每个文件的取值必须是table类型
                if type(item.value) ~= "table" then
                    data_valid = false
                    log.error("invalid item data of [", self.key .. "/" .. key,
                              "], val: ", item.value,
                              ", it shoud be a object")
                end

                -- 校验文件对应的值的语法合法性
                if data_valid and self.item_schema then
                    data_valid, err = check_schema(self.item_schema, item.value)
                    if not data_valid then
                        log.error("failed to check item data of [", self.key,
                                  "] err:", err, " ,val: ", json.encode(item.value))
                    end
                end

                -- 保存所有的key value
                if data_valid then
                    changed = true
                    insert_tab(self.values, item)
                    self.values_hash[key] = #self.values

                    item.value.id = key
                    item.clean_handlers = {}

                    if self.filter then
                        self.filter(item)
                    end
                end

                self:upgrade_version(item.modifiedIndex)
            end
        end

        if headers then
            self:upgrade_version(headers["X-Etcd-Index"])
        end

        if changed then -- self.conf_version用于判断版本是否变更，如果发生变更，则之后本地的数据需要更新为最新版本
            self.conf_version = self.conf_version + 1
        end

        self.need_reload = false
        return true
    end

    -- 监听key是否有变更，非全量读取
    local dir_res, err = waitdir(self.etcd_cli, self.key, self.prev_index + 1, self.timeout)
    log.info("waitdir key: ", self.key, " prev_index: ", self.prev_index + 1)
    log.info("res: ", json.delay_encode(dir_res, true))

    if not dir_res then
        if err == "compacted" then -- 当出现该错误时，说明监听的key被压缩，需要 重新全量读取数据
            self.need_reload = true
            log.warn("waitdir [", self.key, "] err: ", err,
                     ", need to fully reload")
            return false -- 注意这里没有返回err，使得函数 _automatic_fetch 调用当前函数时，睡眠时间更短
        end

        return false, err
    end

    local res = dir_res.body.node
    local err_msg = dir_res.body.message
    if err_msg then -- 根据错误信息，确定是否需要重新读取数据
        if err_msg == "The event in requested index is outdated and cleared"
           and dir_res.body.errorCode == 401 then
            self.need_reload = true
            log.warn("waitdir [", self.key, "] err: ", err_msg,
                     ", need to fully reload")
            return false
        end
        return false, err -- 此时err有值吗？还是应该时err_msg?
    end

    if not res then
        if err == "The event in requested index is outdated and cleared" then
            self.need_reload = true
            log.warn("waitdir [", self.key, "] err: ", err,
                     ", need to fully reload")
            return false
        end

        return false, err
    end

    local res_copy = res
    -- waitdir will return [res] even for self.single_item = true
    for _, res in ipairs(res_copy) do
        local key
        -- 根据文件、目录获得key的真实取值
        if self.single_item then
            key = self.key
        else
            key = short_key(self, res.key)
        end

        -- 校验value的类型合法性
        if res.value and not self.single_item and type(res.value) ~= "table" then
            self:upgrade_version(res.modifiedIndex)
            return false, "invalid item data of [" .. self.key .. "/" .. key
                            .. "], val: " .. res.value
                            .. ", it shoud be a object"
        end

        -- 校验语法合法性
        if res.value and self.item_schema then
            local ok, err = check_schema(self.item_schema, res.value)
            if not ok then
                self:upgrade_version(res.modifiedIndex)

                return false, "failed to check item data of ["
                                .. self.key .. "] err:" .. err
            end
        end

        -- 更新版本信息
        self:upgrade_version(res.modifiedIndex)

        -- 如果目录下面还有目录，则当前程序还不支持
        if res.dir then
            if res.value then
                return false, "todo: support for parsing `dir` response "
                                .. "structures. " .. json.encode(res)
            end
            return false
        end

        -- 以下巧妙的将key value更新到self.values, self.values_hash
        -- values_hash是一个哈希表，根据key找到key在self.values数组里的下标
        local pre_index = self.values_hash[key]
        if pre_index then
            -- 获得当前key的下标，取出key上一个版本的取值，在释放时，根据其处理函数，可认为是析构函数（可以为多个），做销毁工作
            local pre_val = self.values[pre_index]
            if pre_val and pre_val.clean_handlers then
                for _, clean_handler in ipairs(pre_val.clean_handlers) do
                    clean_handler(pre_val)
                end
                pre_val.clean_handlers = nil
            end

           -- 如果当前key有新值，则覆盖原来取值，设置value的析构函数表为空
            if res.value then
                if not self.single_item then
                    res.value.id = key
                end

                self.values[pre_index] = res
                res.clean_handlers = {}
                log.info("update data by key: ", key)

            -- 当前key被删除，则从数组self.values和字典self.values_hash删除当前key
            else
                self.sync_times = self.sync_times + 1
                self.values[pre_index] = false
                self.values_hash[key] = nil
                log.info("delete data by key: ", key)
            end

        -- 如果当前key是新增的，则直接插入数组和字典即可
        elseif res.value then
            res.clean_handlers = {}
            insert_tab(self.values, res)
            self.values_hash[key] = #self.values
            if not self.single_item then
                res.value.id = key
            end

            log.info("insert data by key: ", key)
        end

        -- avoid space waste、
        -- 如果删除次数大于100次，则重建数组self.values和字典self.values_hash
        if self.sync_times > 100 then
            local values_original = table.clone(self.values)
            table.clear(self.values)

            for i = 1, #values_original do
                local val = values_original[i]
                if val then
                    table.insert(self.values, val)
                end
            end

            table.clear(self.values_hash)
            log.info("clear stale data in `values_hash` for key: ", key)

            for i = 1, #self.values do
                key = short_key(self, self.values[i].key)
                self.values_hash[key] = i
            end

            self.sync_times = 0
        end

        -- /plugins' filter need to known self.values when it is called
        -- so the filter should be called after self.values set.
        if self.filter then
            self.filter(res)
        end

        self.conf_version = self.conf_version + 1
    end

    return self.values
end


function _M.get(self, key)
    if not self.values_hash then
        return
    end

    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end


function _M.getkey(self, key)
    if not self.running then
        return nil, "stoped"
    end

    return getkey(self.etcd_cli, key)
end


local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    local i = 0
    --[[ exiting 即ngx.worker.exiting() 返回一个boolean值, 表明当前当前工作进程是否已经存在，
    如果是在重新加载或者关闭过程中，则视为不存在。
    自己之前在开发过程中有需要用到这个函数功能的场景，即判断执行到当前函数时，是否是在reload,
    当时因为不知道这个函数，利用共享内存里的变量在reload时不会重启的特性来判断的是否是reload。
    更好的思路应该是查找是否有对应功能的函数，其次是向官方提出这个需求，或者自己开发出该API。
    因为自己用到，别人也很有可能用到。]]

    -- 循环条件：如果是在重启，而且当前工作进程正在运行，且i满足条件则循环执行
    -- 这里为什么要使用循环条件self.running呢？
    -- 如果在循环之后会再次调用_automatic_fetch， 为什么还要设置循环呢，本身定时器就是一个循环不是吗？
    -- 如果一定要用循环的话，循环32次是如何确定的？为什么不是16次，20次？
    -- 已向APISIX社区提issue，地址：https://github.com/apache/apisix/issues/3229
    while not exiting() and self.running and i <= 32 do
        i = i + 1

        local ok, err = xpcall(function()
            if not self.etcd_cli then
                -- 创建访问etcd的句柄
                local etcd_cli, err = etcd.new(self.etcd_conf)
                if not etcd_cli then
                    error("failed to create etcd instance for key ["
                          .. self.key .. "]: " .. (err or "unknown"))
                end
                self.etcd_cli = etcd_cli
            end

            -- 从etcd中同步信息，同步key为self.key
            -- sync_data 执行成功返回true, 执行失败返回nil/false，有时false后面会返回错误信息，有时不会返回
            local ok, err = sync_data(self)
            if err then
                if err ~= "timeout" and err ~= "Key not found"
                    and self.last_err ~= err then
                    log.error("failed to fetch data from etcd: ", err, ", ",
                              tostring(self))
                end

                -- 记录最后一次的错误信息，并保存错误发生的时间
                if err ~= self.last_err then
                    self.last_err = err
                    self.last_err_time = ngx_time()
                elseif then -- 如果错误保存的时间超过30s，则清空错误信息，也就是说只保存30s内的错误
                    if ngx_time() - self.last_err_time >= 30 then
                        self.last_err = nil
                    end
                end
            -- 满足以下两个睡眠条件之一都有函数执行失败，如果返回了错误信息，睡眠0.5秒，如果没有返回错误信息，睡眠0.05秒
            -- 为什么睡眠时间这样安排，具体看sync_data返回值
                ngx_sleep(0.5)
            elseif not ok then
                ngx_sleep(0.05)
            end

        end, debug.traceback)

        if not ok then -- 如果函数执行失败，睡眠3s，跳出循环
            log.error("failed to fetch data from etcd: ", err, ", ",
                      tostring(self))
            ngx_sleep(3)
            break
        end
    end

    -- 设置定时器，继续执行函数_automatic_fetch
    if not exiting() and self.running then
        ngx_timer_at(0, _automatic_fetch, self)
    end
end


function _M.new(key, opts)
    -- 获得配置文件信息
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end

    -- 获得配置文件中etcd相关的配置
    --[[ 默认配置如下：
etcd:
  host:                           # it's possible to define multiple etcd hosts addresses of the same etcd cluster.
    - "http://127.0.0.1:2379"     # multiple etcd address, if your etcd cluster enables TLS, please use https scheme,
                                  # e.g. "https://127.0.0.1:2379".
  prefix: "/apisix"               # apisix configurations prefix
  timeout: 30                     # 30 seconds
  # user: root                    # root username for etcd
  # password: 5tHkHhYkjr6cQY      # root password for etcd
  tls:
      verify: true                # whether to verify the etcd endpoint certificate when setup a TLS connection to etcd,
                                  # the default value is true, e.g. the certificate will be verified strictly.
    ]]
    local etcd_conf = clone_tab(local_conf.etcd)
    local prefix = etcd_conf.prefix
    etcd_conf.http_host = etcd_conf.host
    etcd_conf.host = nil
    etcd_conf.prefix = nil
    etcd_conf.protocol = "v3"
    etcd_conf.api_prefix = "/v3"
    etcd_conf.ssl_verify = true

    -- 是否对etcd进行鉴权
    -- default to verify etcd cluster certificate
    if etcd_conf.tls and etcd_conf.tls.verify == false then
        etcd_conf.ssl_verify = false
    end

    local automatic = opts and opts.automatic -- 监听etcd数据的变更，更新本地配置
    local item_schema = opts and opts.item_schema -- json语法定义表，用于检查json是否符合定义
    local filter_fun = opts and opts.filter -- 过滤函数，具体用法稍后详解
    local timeout = opts and opts.timeout -- 监听etcd数据变更时，未检测到数据变更的超时时间，该时间之后，函数返回
    local single_item = opts and opts.single_item -- 监听etcd的数据，该数据是单独的key，还是该key所在的目录

    local obj = setmetatable({
        etcd_cli = nil,
        etcd_conf = etcd_conf,
        key = key and prefix .. key,
        automatic = automatic,
        item_schema = item_schema,
        sync_times = 0,
        running = true,
        conf_version = 0,
        values = nil,
        need_reload = true,
        routes_hash = nil,
        prev_index = 0,
        last_err = nil,
        last_err_time = nil,
        timeout = timeout,
        single_item = single_item,
        filter = filter_fun,
    }, mt)

    if automatic then -- 自动监听etcd数据的变化，由于访问etcd的操作，不能在init_worker阶段执行，所以使用定时器达到目的
        if not key then
            return nil, "missing `key` argument"
        end

        ngx_timer_at(0, _automatic_fetch, obj)

    else -- 获得etcd句柄，让用户自己利用该句柄去获得etcd数据？目前代码宏未用到此处逻辑
        local etcd_cli, err = etcd.new(etcd_conf)
        if not etcd_cli then
            return nil, "failed to start a etcd instance: " .. err
        end
        obj.etcd_cli = etcd_cli
    end

    if key then
        created_obj[key] = obj
    end

    return obj
end


function _M.close(self)
    self.running = false
end


function _M.fetch_created_obj(key)
    return created_obj[key]
end


local function read_etcd_version(etcd_cli)
    if not etcd_cli then
        return nil, "not inited"
    end

    local data, err = etcd_cli:version()
    if not data then
        return nil, err
    end

    local body = data.body
    if type(body) ~= "table" then
        return nil, "failed to read response body when try to fetch etcd "
                    .. "version"
    end

    return body
end


function _M.server_version(self)
    if not self.running then
        return nil, "stoped"
    end

    return read_etcd_version(self.etcd_cli)
end


return _M
