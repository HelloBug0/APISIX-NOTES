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

local _M = {
    version = 0.1,
    profile = os.getenv("APISIX_PROFILE"),
    -- APISIX 工作路径，Nginx工作路径或者当前工作路径，这里的"" 修改为 "./"是否更好？
    apisix_home = (ngx and ngx.config.prefix()) or ""
}


-- 通过增加前缀后缀的方式，获得指定文件名的文件路径
function _M.yaml_path(self, file_name) -- file_name 仅为文件名称，不包含文件路径
    local file_path = self.apisix_home  .. "conf/" .. file_name -- 设置文件路径
    -- 若文件名不是 config-default，则为念路径需要添加环境变量 APISIX_PROFILE 指定的文件后缀
    if self.profile and file_name ~= "config-default" then
        file_path = file_path .. "-" .. self.profile
    end

    -- 添加文件类型
    return file_path .. ".yaml"
end


return _M
