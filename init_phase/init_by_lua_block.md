## 配置相关
以下配置均为 APISIX 默认配置。
### config-default.yaml
```yaml
  # dns_resolver:                   # If not set, read from `/etc/resolv.conf`
  #  - 1.1.1.1
  #  - 8.8.8.8
  dns_resolver_valid: 30          # valid time for dns result 30 seconds
  resolver_timeout: 5             # resolver timeout
```

### nginx.conf
nginx.conf 根据 config-default.yaml 配置文件生成。
```lua
    init_by_lua_block {
        require "resty.core"
        apisix = require("apisix") 

        local dns_resolver = { "183.60.83.19", "183.60.82.98", } 
        local args = {
            dns_resolver = dns_resolver,
        }
        apisix.http_init(args)
    }
```

### 配置解析

####  代码
```lua
require "resty.core"
```
#### 说明
+  这里显示引用 lua-resy-core是因为 lua-resty-core 把 lua-nginx-module 中的部分 API使用 FFI 方式实现，FFI 方式实现的代码可以被 JIT 追踪和优化，性能更高。
+ 当前 Openresty 版本是默认使用 lua-resty-core ，可通过以下方法验证 Openresty 版本是否默认使用 lua-resty-core.
1. nginx.conf 未显示指定`require "resty.core"`

2. 将环境中的 resty.core 重命名未 resty.core.1
     `mv /usr/local/openresty/lualib/resty/core.lua /usr/local/openresty/lualib/resty/core.lua.1`

3.  启动 openresty ，显示以下错误： 
```lua
nginx: [alert] failed to load the 'resty.core' module (https://github.com/openresty/lua-resty-core); ensure you are using an OpenResty release from https://openresty.org/en/download.html (reason: module 'resty.core' not found:
        no field package.preload['resty.core']
        ......
```

- - -

#### 代码
```lua
apisix = require("apisix") 
```
#### 说明
+ apisix 的代码中并没有 apisix.lua 文件，可根据 nginx.conf 中设置的 lua 文件查找路径确定加载的文件，lua 文件查找路径如下：
```lua
lua_package_path  "$prefix/deps/share/lua/5.1/?.lua;$prefix/deps/share/lua/5.1/?/init.lua;/usr/local/apisix/?.lua;/usr/local/apisix/?/init.lua;;/usr/local/apisix/?.lua;./?.lua;/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;";
```
+ 根据以上设置，在查找 apisix 模块的过程中，会根据配置 `/usr/local/apisix/?/init.lua` 查找到 `/usr/local/apisix/apisix/init.lua` 文件，即将 `apisix` 替换 `?` 获得的路径。可通过以下步骤证实模块查找原理如此。

1. 将 apisix/init.lua 文件重命名为 apisix/init.lua.bak
`mv init.lua init.lua.bak`

2. 执行 apisix start，以下错误信息显示了模块的查找路径

```lua
nginx: [error] init_by_lua error: init_by_lua:3: module 'apisix' not found:
        no field package.preload['apisix']
        no file '/usr/local/apisix//deps/share/lua/5.1/apisix.lua'
        no file '/usr/local/apisix//deps/share/lua/5.1/apisix/init.lua'
        no file '/usr/local/apisix/apisix.lua'
        no file '/usr/local/apisix/apisix/init.lua'
        ......
```

- - -

####  代码

```lua
local dns_resolver = { "183.60.83.19", "183.60.82.98", } 
```

#### 说明

+ dns_resolver 数组元素有两个来源，首先是 config-default.yaml 配置文件中 dns_resolver 的配置，如果该配置文件中未配置 dns_resolver ，则从系统配置文件 /etc/resolv.conf 中获得系统配置的 域名解析服务器信息。

+ 文首的 config-default.yaml 中 dns_resolver配置被注释掉，所以是从 /etc/resolv.conf 中获得域名解析服务器信息。
`cat /etc/resolv.conf`
```bash 
options timeout:1 rotate
; generated by /usr/sbin/dhclient-script
nameserver 183.60.83.19
nameserver 183.60.82.98
```

- - -

#### 代码

```lua
local args = {
    dns_resolver = dns_resolver,
}
apisix.http_init(args)
```

#### 说明

+ 设置变量 args，key为"dns_resolver"，value 为{ "183.60.83.19", "183.60.82.98", } 

+ 调用 init.lua 文件中的函数 http_init

#### 代码和注释

```lua
function _M.http_init(args)
-- nginx.conf 中已加载该模块，实际执行时不会重复加载。详见注解1
    require("resty.core")

-- 若当前操作系统是 Linux，设置PCRE引擎的 jit 栈大小为200k。详见注解2
    if require("ffi").os == "Linux" then
        require("ngx.re").opt("jit_stack_size", 200 * 1024)
    end

-- jit编译器参数优化设置。详见注解3
    require("jit.opt").start("minstitch=2", "maxtrace=4000",
                             "maxrecord=8000", "sizemcode=64",
                             "maxmcode=4000", "maxirconst=1000")

-- 解析参数，其中 args = {dns_resolve = { "183.60.83.19", "183.60.82.98", }}，将域名解析服务器信息保存 apisix/core/utils.lua 模块的 resolvers 变量中
    parse_args(args)
-- 初始化 APISIX 标志。详见注解4
    core.id.init()

-- 开启特权进程，特权进程不监听任何虚拟服务器端口号，且和 master 进程有相同的权限，详见注解5
    local process = require("ngx.process")
    local ok, err = process.enable_privileged_agent()
    if not ok then
        core.log.error("failed to enable privileged_agent: ", err)
    end
end
```
##### 注解1

1. 加载模块时，首先查找 package.loaded 表中相应的 module name 是否已经被加载过，不会重复加载已经加载的模块。

2. 如果 package.loaded 中没有加载该模块，首先从 package.path 指定的路径查找 .lua 文件，如果找到，会调用 loadfile 加载；如果没有找到，会从 package.cpath 指定的路径查找 .so 文件，如果找到，会调用 package.loadfile 加载。加载后的模块会设置到 package.loaded 表中。

##### 注解2

+ **ffi.os** 同 jit.os，当前操作系统的名字

+ **ngx.re** ngx.re 提供一些实用的 Lua API，参考`https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/re.md`

1. ngx.re模块的opt函数用于设置PCRE引擎的 jit 栈大小。
2. 若使用默认设置的栈大小，在执行长字符串正则匹配时，会出现错误信息`pcre_exec() failed`。
3. 默认栈大小为32k，使用该函数设置栈大小时不能小于32k
4. 该方法目前仅支持"jit_stack_size"的修改。
5. 若使用该方法，需要在编译nginx时包含pcre库。

##### 注解3

+ jit.opt.* jit 编译器参数优化设置。和使用 LuaJIT 编译器时，使用选项 -O 执行编译器优化设置相同，如 jit.opt.start(2) 等价于-O2 

+ 优化参数解释如下：

参数|含义
---|:--
minstitch|未见官方文档说明，在openresty issues中看到春哥回复过如下内容：`Enabling LuaJIT's trace stitching can ensure as much Lua code is JIT compiled as possible. The lua-resty-core library heavily uses FFI; those FFI-based Lua code paths would be very slow if being interpreted.` 即这个值保证更多的lua代码被jit编译，具体是否取值越大，被编译的可能性更大待定。以上解释来自 `https://github.com/openresty/lua-resty-core/issues/15`
maxtrace|缓存中代码路径最大跟踪个数，默认值`1000`，该参数和以下参数解释来自 `http://luajit.org/running.html`
maxrecord|记录的最大IR指令数，默认值`4000`，IR，Intermediate Representation，即中间码，在 luajit 中用于描述可进行优化的代码路径。参考 `https://lua.ren/topic/tweyseo-WalkOnLuaJIT-1/`
sizemcode|每个机器代码区域大小，kb，默认值`32`
maxmcode|机器代码区域总大小，kb，默认值`512`
maxirconst|跟踪的每个代码路径最大IR常数数，默认值`500`

+ Openresty luajit 配置默认值如下，取值来自 `https://github.com/openresty/luajit2#optimizations` 

参数|默认值
---|:---
minstitch|3
maxtrace|8000
maxrecord|16000
maxmcode|40960

##### 注解4

1. 从 PREFIX/conf/apisix.uid 中读取 APISIX 的唯一标志信息，其中 PREFIX 为 APISIX 的启动路径，如/usr/local/apisix
2. 若文件存在，则 uid 为文件内容，文件为空，则uid为空字符串
3. 若文件不存在，则利用 resty.jit-uuid 生成 uid，并写入文件 PREFIX/conf/apisix.uid 中

##### 注解5

+ 特权进程不监听任何虚拟服务器端口号，且和 master 进程有相同的权限，参考：https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/process.md#enable_privileged_agent

+ 函数 process.enable_privileged_agent() 使用上下文是 init_by_lua， 也会在 init_by_worker 阶段执行，可以用 process.type() 函数判断自己是否是特权进程。参考：https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/process.md#type
