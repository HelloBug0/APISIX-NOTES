local etcdv2  = require("resty.etcd.v2")
local etcdv3  = require("resty.etcd.v3")
local utils   = require("resty.etcd.utils")
local typeof  = require("typeof")
local require = require
local pcall   = pcall
local prefix_v3 = {
    ["3.5."] = "/v3",
    ["3.4."] = "/v3",
    ["3.3."] = "/v3beta",
    ["3.2."] = "/v3alpha",
}

local _M = {version = 0.9}


local function etcd_version(opts)
    local etcd_obj, err = etcdv2.new(opts)
    if not etcd_obj then
        return nil, err
    end

    local ver
    ver, err = etcd_obj:version()
    if not ver then
        return nil, err
    end

    return ver.body
end

-- 返回etcd数据的序列化方法，目前有两种序列化方法，json和raw，默认是json
-- 参考 lua-resty-etcd-master/etcd/serializers/
local function require_serializer(serializer_name)
    if serializer_name then
        local ok, module = pcall(require, "resty.etcd.serializers." .. serializer_name)
        if ok then
            return module
        end
    end

    return require("resty.etcd.serializers.json")
end

--[[ APISIX 在调用etcd.new时，opts赋值如下：
    etcd_conf.http_host = etcd_conf.host
    etcd_conf.host = nil
    etcd_conf.prefix = nil
    etcd_conf.protocol = "v3"
    etcd_conf.api_prefix = "/v3"
    etcd_conf.ssl_verify = true

    if etcd_conf.tls and etcd_conf.tls.verify == false then
        etcd_conf.ssl_verify = false
    end
    ]]
function _M.new(opts)
    opts = opts or {}
    if not typeof.table(opts) then
        return nil, 'opts must be table'
    end

    opts.timeout = opts.timeout or 5    -- 5 sec
    opts.http_host = opts.http_host or "http://127.0.0.1:2379"
    opts.ttl  = opts.ttl or -1

    -- 获得etcd的版本信息，默认是v2
    local protocol = opts and opts.protocol or "v2"
    -- typeof.string(variable) 判断变量是否是string类型，如果是，则返回true
    local serializer_name = typeof.string(opts.serializer) and opts.serializer
    opts.serializer = require_serializer(serializer_name)

    if protocol == "v3" then
        -- if opts special the api_prefix,no need to check version
        -- 如果没有指定前缀，或者指定的前缀没有对应的版本，则重新获得前缀
        if not opts.api_prefix or not utils.has_value(prefix_v3, opts.api_prefix) then
            local ver, err = etcd_version(opts)
            if not ver then
                return nil, err
            end
            local sub_ver = ver.etcdserver:sub(1, 4)
            opts.api_prefix = prefix_v3[sub_ver] or "/v3beta"
        end
        return etcdv3.new(opts)
    end

    opts.api_prefix = "/v2"

    return etcdv2.new(opts)
end


return _M
