local lib = {}
if string.packsize and string.unpack then
  lib.size = string.packsize
  lib.unpack = string.unpack
  lib.zerostring = "z"
  lib.prefixstring = function(bytes)
    if bytes then return string.format("s%d", bytes)
    else return "s" end
  end
else
  local struct = require("struct")
  lib.size = struct.size
  lib.unpack = struct.unpack
  lib.zerostring = "s"
  lib.prefixstring = function(bytes)
    if bytes then return string.format("I%dc0", bytes)
    else return "%Tc0" end
  end
end

local unpack = unpack or table.unpack

local Blob = {}

-- Mark the current position in the blob with the given name.
-- If no name is provided, an anonymous marker is pushed to a stack.
Blob.mark = function (self, name)
  if type(name) == "string" then
    self.markers[name] = self.pos
  else table.insert(self.markers, self.pos) end
  return self.pos
end

-- Restore the position to the position of the mark with the given name.
-- If no name is given, an anonymous marker is popped (and thus removed)
-- from a stack
Blob.restore = function (self, name)
  -- only drop anonymous markers
  local pos
  if type(name) == "string" then pos = self.markers[name]
  else pos = self:drop(name) end

  self.pos = pos
  return pos
end

-- Drop a marker without altering the position.
-- If no name is given, drop the topmost marker from the stack.
-- Return the dropped position
Blob.drop = function (self, name) 
  if type(name) == "string" then
    local ret = self.markers[name]
    self.markers[name] = nil
    return ret
  else return table.remove(self.markers) end
end


-- Expose a method to manuall set the position
Blob.seek = function(self, pos) self.pos = pos end

Blob.unpack = function(self, formatstring, ...)
  local unpacked
  -- This allows the user to call blob:unpack("%d", myvar)
  -- instead of creating the formatted string first.
  if ... then
    formatstring = string.format(formatstring, ...)
  end

  unpacked = {lib.unpack(formatstring,
    self.buffer, self.pos + self.offset)}
  -- The new position is the last entry of that table
  self.pos = table.remove(unpacked)
  self.pos = self.pos - self.offset
  return unpack(unpacked)
end

Blob.size = function(self, ...)
  local total = 0
  for _, f in ipairs({...}) do
    total = total + lib.size(f)
  end
  return total
end

Blob.array = function(self, limit, fun)
  local t = {}
  for i=1,limit do
    -- fun might return multiple values, but table.insert easily gets confused by that.
    -- This makes sure that only the first value is passed to table.insert.
    local capture = fun(self)
    table.insert(t, capture)
  end
  return t
end

Blob.pad = function(self, size, position, ...)
  -- if no position was specified, calculate the padding relative to the start
  if position == nil then position = 1
  -- A position can be a numeric value
  elseif type(position) == "number" then ; -- skip the other checks
  -- Padding with absolute position will skip `size` byes:
  elseif position == "absolute" then ;
  -- A position can also refer to a previously saved marker
  elseif self.markers[position] then position = self.markers[position]
  else
    error("position must either be nil, a number, \"absolute\", or the name of a saved marker")
  end

  assert(size, "size must be specified")
  -- Size can be a number
  if type(size) == "number" then ; -- skip the other checks
  -- Size can also refer to a custom type. The varargs can be used to pass
  -- arguments to that custom type.
  elseif Blob.types[size] then
    local formatstring
    if type(Blob.types[size]) == "function" then
      formatstring = Blob.types[size](...)
    else formatstring = Blob.types[size] end
    size = self:size(formatstring)
  -- Otherwise we expect size to be a format string that can be passed to
  -- the size function
  elseif type(size) == "string" then size = self:size(size)
  else
    error("size must either be a number, refer to a custom type, or be a valid format string")
  end

  if position == "absolute" then
    self.pos = self.pos + size
    return
  end

  local relative_pos = self.pos - position

  -- do not pad if we are at the correct boundary
  if relative_pos % size == 0 then return
  else
    local pad_bytes = size - (relative_pos % size)
    -- advance position by that many bytes
    self.pos = self.pos + pad_bytes
  end
end

Blob.types = {
  byte = "c1",
  bytes = function(count)
    return string.format("c%d", count)
  end,
  word = "c2",
  dword = "c4",
  zerostring = lib.zerostring,
  prefixstring = lib.prefixstring,  
}

-- Create a new blob from a given binary string
Blob.new = function(string, offset)
  local blob = setmetatable({
    buffer = string,
    pos = 1,
    offset = offset or 0,
    markers = {}
  }, {
    __index = function(self, name)
      if Blob.types[name] then 
        return function(_, ...)
          local formatstring
          if type(Blob.types[name]) == "function" then
            formatstring = Blob.types[name](...)
          else formatstring = Blob.types[name] end
          return self:unpack(formatstring)
        end
      else return Blob[name] end
    end
  })
  return blob
end

-- Create a new blob from the content of the given file
Blob.load = function(filename)
  local f = assert(io.open(filename, "rb"), "Could not open file ".. filename)
  local buffer = f:read("*all")
  f:close()
  local blob = Blob.new(buffer)
  return blob
end

-- Split off an existing blob at the current position of this blob.
-- Note that this does not copy the content of the given blob.
-- If a length is given, advance the original blob by that many bytes
-- after splitting off the new blob.
Blob.split = function(blob, length)
  local new = Blob.new(blob.buffer, blob.pos - 1 + blob.offset)
  blob.pos = blob.pos + (length or 0)
  return new
end

return Blob
