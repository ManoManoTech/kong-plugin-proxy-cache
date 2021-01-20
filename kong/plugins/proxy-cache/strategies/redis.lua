local cjson = require "cjson.safe"
local utils = require "kong.tools.utils"
local redis = require "resty.redis"

local next      = next
local timer_at  = ngx.timer.at

local type         = type
local setmetatable = setmetatable


local _M = {}

local function is_present(str)
  return str and str ~= "" and str ~= ngx.null
end
local function get_redis_connection(conf)
  local red = redis:new()
  red:set_timeout(2000)
  local ok, err = red:connect(conf.host, conf.port)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  if times == 0 then
    if is_present(conf.password) then
      local ok, err = red:auth(conf.password)
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if conf.database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database

      local ok, err = red:select(conf.database)
      if not ok then
        kong.log.err("failed to change Redis database: ", err)
        return nil, err
      end
    end
  end

  return red
end

function _M.new(opts)
  local conf = utils.deep_copy(opts)
  if type(conf.database) ~= "Number" or conf.database == ngx.null then
    conf.database = 0
  end
  local self = {
    opts = conf,
  }

  return setmetatable(self, {
    __index = _M,
  })
end


--- Store a new request entity in redis
-- @string key The request key
-- @table req_obj The request object, represented as a table containing
--   everything that needs to be cached
-- @int[opt] ttl The TTL for the request; if nil, use default TTL specified
--   at strategy instantiation time
--   XXX: Need a delayed store as there is a limitation of OpenResty
--   https://github.com/openresty/lua-nginx-module#cosockets-not-available-everywhere
--
local function delayed_store(premature, opts, key, req_json, ttl)
  if premature then
    return
  end

  local red, err = get_redis_connection(opts)
  if not red then
    kong.log.err("failed to redis create connection: ", err)
  end

  red:init_pipeline()
  red:hmset(key, req_json)
  red:expire(key, ttl)
  local _, err = red:commit_pipeline()
  if err then
    kong.log.err("failed to store: ", err)
    return
  end
  local ok, err = red:set_keepalive(10000, 100)
end

function _M:store(key, req_obj, req_ttl)
  local ttl = req_ttl or self.opts.ttl

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local ok, err = timer_at(0, delayed_store, self.opts, key, req_obj, ttl)
  if not ok then
      kong.log.err("failed to set Redis keepalive: ", err)
      return nil, err
  end

end


--- Fetch a cached request
-- @string key The request key
-- @return Table representing the request
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
      return nil, err
  end
  local req_obj, err = red:hgetall(key)
  if not req_obj then
    return nil, err
  end
  if next(req_obj) == nil then
    return nil, "request object not in cache"
  end

  return req_obj
end


--- Purge an entry from redis
-- @return true on success, nil plus error message otherwise
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
      return nil, err
  end
  red.del(key)
  return true
end

--- Flush the ful db
-- @param free_mem Boolean XXX: not used
-- @return true on success, nil plus error message otherwise
function _M:flush(free_mem)
  local red, err = get_redis_connection(self.opts)
  if not red then
      return nil, err
  end
  red.flushdb()
  return true
end

return _M