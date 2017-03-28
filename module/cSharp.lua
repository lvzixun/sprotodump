local print_r = require "print_r"
local parse_core = require "core"
local buildin_types = parse_core.buildin_types

local gmatch = string.gmatch
local tsort = table.sort
local tconcat = table.concat
local sformat = string.format
local sgsub = string.gsub


-- string help function
local function str_split(str, sep)
  if sep == nil then
    sep = "%s"
  end

  local t={}
  local i=1
  for v in gmatch(str, "([^"..sep.."]+)") do
    t[i] = v
    i = i + 1
  end
  return t
end

local function upper_head(s)
  local c =  string.upper(string.sub(s, 1, 1))
  return c..string.sub(s, 2)
end


-- code format
local function code_format(s, t)
  local s = string.gsub(s, "([\t ]*)#([%w_%d]+)#", 
    function (space, v)
      local entry = t[v]
      local te = type(entry)
      local ret = ""
      if te == "function" then
        ret = entry(v)
        assert(type(ret)=="string")
      else
        ret = tostring(entry)
      end

      if #space > 0 then
        ret = space..string.gsub(ret, "\n", "\n"..space)
      end
      return ret
    end)
  return s
end



-- dump csharp code 
-- class = {
--   {class_name = AAA, type_name = A.A.AAA,  max_field = 11, sproto_type = {}, internal_class = {}},
--   {class_name = BBB, type_name = B.B.BBB,  max_field = 11, sproto_type = {}, internal_class = {}},
-- }

local function _get_max_field_count(sproto_type)
  local maxn = #sproto_type
  local last_tag = -1

  for i=1,#sproto_type do
    local field = sproto_type[i]
    local tag = field.tag

    if tag < last_tag then
      error("tag must in ascending order")
    end

    if tag > last_tag +1 then 
      maxn = maxn + 1
    end
    last_tag = tag
  end

  return maxn
end

local function type2class(type_name, class_name, sproto_type)
  local class = {
    class_name = class_name,
    type_name = type_name, 
    max_field_count = sproto_type and _get_max_field_count(sproto_type) or nil,
    sproto_type = sproto_type,
    internal_class = {},
  }

  return class
end




local function gen_protocol_class(ast)
  local ret = {}
  for k,v in pairs(ast) do
    ret[#ret+1] = {
      name = k, 
      tag = v.tag,
      request = v.request,
      response = v.response,
    }
  end
  table.sort(ret, function (a, b) return a.name < b.name end)

  local cache = {}
  local classes = {}
  for i=1,#ret do
    local name = ret[i].name
    local fold = str_split(name, ".")

    local fullname = ""  
    local per = classes
    for i,v in ipairs(fold) do
      if i == 1 then fullname = v
      else fullname = fullname.."."..v end

      local item = cache[fullname]
      if not item then
        item = {}
        cache[fullname] = item
        table.insert(per, item)
      end

      per = item
      item.name = v
      item.value = ast[fullname]
    end
  end


  ret.classes = classes
  return ret
end



local function gen_type_class(ast)
  local type_name_list = {}
  local class = {}
  local cache = {}

  for k, _ in pairs(ast) do
    type_name_list[#type_name_list+1] = k
  end
  tsort(type_name_list, function (a, b) return a<b end)

  for i=1, #type_name_list do
    local k = type_name_list[i]
    local type_list = str_split(k, ".")
    
    local cur = class
    local type_name = ""
    for i=1,#type_list do
      local class_name = type_list[i]

      if i == 1 then type_name = class_name 
      else type_name = type_name.."."..class_name end

      if not cache[type_name] then
        local sproto_type = ast[type_name]
        local class_info =  type2class(sproto_type and type_name or nil, class_name, sproto_type)
        cur[#cur+1] = class_info
        cache[type_name] = class_info
      end

      cur = cache[type_name].internal_class
    end

  end

  return class
end

local _class_type = {
  string = "string",
  integer = "Int64",
  boolean = "bool",
}
local function _2class_type(t, is_array, key)
  t = _class_type[t] or t

  if is_array and key then -- map
    local tk = _class_type[key.typename]
    assert(tk , "Invalid map key.")
    return string.format("Dictionary<%s, %s>", tk, t)
  elseif is_array and not key then -- arrat
    return "List<"..t..">"
  elseif not is_array and not key then -- element
    return t
  else
    error("Invalid field type.")
  end
end



local encode_field_template =[[
if (base.has_field.has_field (#idx#)) {
  base.serialize.#write_func_name# (this.#name#, #tag#);
}
]]

local _write_func = {
  string = "write_string",
  integer = "write_integer",
  boolean = "write_boolean",
}
local function _encode_field(field, idx)
  local typename = field.typename
  local tag = field.tag
  local name = field.name
  local func_name = _write_func[typename] or "write_obj"

  return code_format(encode_field_template, {
      idx = idx,
      write_func_name = func_name,
      name = name,
      tag = tag,
    })
end


local read_field_template = [[
case #tag#:
  #dump_case_func#
  break;
]]

local _read_func = {
  string = "read_string",
  integer = "read_integer",
  boolean = "read_boolean",
}
local function _read_field(field)
  local typename = field.typename
  local is_array = field.array
  local tag = field.tag
  local name = field.name
  local key = field.key

  local func_name = _read_func[typename]

  local function dump_case_func()
    if func_name then
      if is_array then func_name = func_name.."_list" end
      return code_format("this.#name# = base.deserialize.#func_name# ();", 
        {name = name, func_name = func_name})

    elseif key then
      assert(is_array)
      return code_format("this.#name# = base.deserialize.read_map<#main_key#, #value#>(v => v.#key_name#);",
        {name = name, main_key = _class_type[key.typename], value = typename, key_name = key.name})

    else
      func_name = "read_obj"
      if is_array then func_name = func_name.."_list" end
      return code_format("this.#name# = base.deserialize.#func_name#<#typename#> ();", 
        {name=name, func_name=func_name, typename=typename})
    end
  end

  return code_format(read_field_template, {
      tag = tag,
      dump_case_func = dump_case_func
    })
end



local class_template = [[
public class #class_name# : SprotoTypeBase {
  private static int max_field_count = #max_field_count#;

  #dump_internal_class_func#

  #dump_property_func#

  public #class_name# () : base(max_field_count) {}

  public #class_name# (byte[] buffer) : basse(max_field_count, buffer) {
    this.decode ();
  }

  protected override void decode () {
    int tag = -1;
    while (-1 != (tag = base.deserialize.read_tag ())) {
      switch (tag) {
        #dump_read_field#
        default:
          base.deserialize.read_unknow_data ();
          break;
      }
    }
  }

  public override int encode (SprotoStream stream) {
    base.serialize.open (stream);

    #dump_encode_field_func#
    return base.serialize.close ();
  }
}]]

local class_wrap_template = [[
public class #class_name# {
  #dump_internal_class_func#
}]]

local property_template = [[
private #type# _#name#; // tag #tag#
public #type# #name# {
  get { return _#name#; }
  set { base.has_field.set_field (#idx#, true); _#name# = value; }
}
public bool Has#up_name# {
  get { return base.has_field.has_field (#idx#); }
}]]
local function dump_class(class_info)
  local class_name = class_info.class_name
  local sproto_type = class_info.sproto_type
  local internal_class = class_info.internal_class
  local max_field_count = class_info.max_field_count

  local function dump_internal_class_func()
    local buffer = {}
    for i=1, #internal_class do
      buffer[i] = dump_class(internal_class[i])
    end
    if #buffer==0 then
      return "// no internal class"
    end
    return table.concat(buffer, "\n\n")
  end

  local function dump_property_func()
    local buffer = {}
    for i=1, #sproto_type do
      local field = sproto_type[i]
      local type = _2class_type(field.typename, field.array, field.key)
      local name = field.name
      local tag = field.tag
      buffer[i] = code_format(property_template, {
          type = type,
          name = name,
          idx = i-1,
          tag = tag,
          up_name = upper_head(name),
        })
    end
    return table.concat(buffer, "\n\n")
  end

  local function dump_read_field()
    local buffer = {}
    for i=1, #sproto_type do
      local field = sproto_type[i]
      buffer[i] = _read_field(field)
    end
    return table.concat(buffer, "\n")
  end

  local function dump_encode_field_func()
    local buffer = {}
    for i=1, #sproto_type do
      local field = sproto_type[i]
      buffer[i] = _encode_field(field, i-1)
    end
    return table.concat(buffer, "\n")
  end

  local code_template = sproto_type and class_template or class_wrap_template
  return code_format(code_template, {
      class_name = class_name,
      max_field_count = max_field_count,
      dump_internal_class_func = dump_internal_class_func,
      dump_property_func = dump_property_func,
      dump_read_field = dump_read_field,
      dump_encode_field_func = dump_encode_field_func,
    })
end


local function _gen_sprototype_namespace(package)
  return upper_head(package).."SprotoType"
end


local function _gen_protocol_classname(package)
  return upper_head(package).."Protocol"
end

local protocol_class_template = [[
public class #name# {
  #dump_protocol_property_func#
}]]

local function dump_protocol_class(class)
  local name = class.name
  local value = class.value

  local function dump_protocol_property_func()
    if value then
      assert(#class == 0)
      return code_format("public const int Tag = #tag#;", {tag=value.tag})
    else
      local buffer = {}
      for i,v in ipairs(class) do
        buffer[i] = dump_protocol_class(v)
      end
      return table.concat(buffer, "\n")
    end
  end

  return code_format(protocol_class_template, {
      name = name,
      dump_protocol_property_func = dump_protocol_property_func,
    })
end


local protocol_property_template = [[
Protocol.SetProtocol<#name#> (#name#.Tag);
#protocol_request_func#
#protocol_response_func#]]

local protocol_template = [[
public class #class_name# : ProtocolBase {
  public static #class_name# Instance = new #class_name#();
  private #class_name#() {
    #protocol_property_dump#
  }

  #protocol_class_dump#
}
]]

local function parse_protocol(class, package)
  if not class or #class == 0 then return "" end

  local class_name = _gen_protocol_classname(package)
  local type_namespace = _gen_sprototype_namespace(package)

  local function protocol_property_dump()
    local buffer = {}
    for i, class_info in ipairs(class) do
      local name = class_info.name
      local tag = class_info.tag
      local request_type = class_info.request
      local response_type = class_info.response
      local function protocol_request_func()
        if request_type then
          return code_format("Protocol.SetRequest<#type_namespace#.#request_type#> (#name#.Tag);",{
              type_namespace = type_namespace,
              request_type = request_type,
              name = name,
            })
        else
          return ""
        end
      end

      local function protocol_response_func()
        if response_type then
          return code_format("Protocol.SetResponse<#type_namespace#.#response_type#> (#name#.Tag);", {
              type_namespace = type_namespace,
              response_type = response_type,
              name = name,
            })
        else
          return ""
        end
      end

      buffer[i] = code_format(protocol_property_template, {
          name = name,
          protocol_request_func = protocol_request_func,
          protocol_response_func = protocol_response_func,  
        })
    end
    return table.concat(buffer, "\n")
  end

  local function protocol_class_dump()
    local buffer = {}
    for i,v in ipairs(class.classes) do
      buffer[i] = dump_protocol_class(v)
    end
    return table.concat(buffer, "\n")
  end

  return code_format(protocol_template, {
      class_name = class_name,
      protocol_property_dump = protocol_property_dump,
      protocol_class_dump = protocol_class_dump,
    })
end


local type_template =
[[//  Generated by sprotodump. DO NOT EDIT!
// source: #sproto_name#
using System;
using Sproto;
using System.Collections.Generic;

namespace #namespace# {
  #dump_class_func#
}
]]

local function parse_ast2type(ast, package, name)
  package = package or ""
  local type_class = gen_type_class(ast)

  local function dump_class_func()
    if not type_class or #type_class == 0 then return "" end
    local buffer = {}
    for i=1,#type_class do
      local class_info = type_class[i]
      buffer[i] = dump_class(class_info)
    end
    return table.concat(buffer, "\n\n")
  end

  local namespace = _gen_sprototype_namespace(package)
  return code_format(type_template, {
      sproto_name = name or "input",
      namespace = namespace,
      dump_class_func = dump_class_func,
    })
end


local protocol_template = 
[[//  Generated by sprotodump. DO NOT EDIT!
using System;
using Sproto;
using System.Collections.Generic;

#dump_protocol_class_func#
]]
local function parse_ast2protocol(ast, package)
  package = package or ""
  local protocol_class = gen_protocol_class(ast)
  
  local function dump_protocol_class_func()
    return parse_protocol(protocol_class, package)
  end

  return code_format(protocol_template, {
      dump_protocol_class_func = dump_protocol_class_func,
    })
end


local function parse_ast2all(ast, package, name)
  package = package or ""
  local protocol_class = gen_protocol_class(ast.protocol)

  local type_source = parse_ast2type(ast, package, name)
  local protocol_source = parse_protocol(protocol_class, package) 
  
  return type_source.."\n\n"..protocol_source
end



------------------------------- dump -------------------------------------
local util = require "util"

local function main(trunk, build, param)
  local package = util.path_basename(param.package or "")
  local outfile = param.outfile
  local dir = param.dircetory or ""

  if outfile then
    local data = parse_ast2all(build, package, table.concat(param.sproto_file, " "))
    util.write_file(dir..outfile, data, "w")
  else
    -- dump sprototype
    for i,v in ipairs(trunk) do
      local name = param.sproto_file[i]
      local outcs = util.path_basename(name)..".cs"
      local data = parse_ast2type(v.type, package, name)
      util.write_file(dir..outcs, data, "w")
    end

    -- dump protocol
    if build.protocol then
      local data = parse_ast2protocol(build.protocol, package)
      local outfile = package.."Protocol.cs"
      util.write_file(dir..outfile, data, "w")
    end
  end
end

return main
