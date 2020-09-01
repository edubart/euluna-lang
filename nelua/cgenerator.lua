local CEmitter = require 'nelua.cemitter'
local iters = require 'nelua.utils.iterators'
local traits = require 'nelua.utils.traits'
local errorer = require 'nelua.utils.errorer'
local stringer = require 'nelua.utils.stringer'
local bn = require 'nelua.utils.bn'
local cdefs = require 'nelua.cdefs'
local cbuiltins = require 'nelua.cbuiltins'
local typedefs = require 'nelua.typedefs'
local CContext = require 'nelua.ccontext'
local types = require 'nelua.types'
local primtypes = typedefs.primtypes

local function izipargnodes(vars, argnodes)
  local iter, ts, i = iters.izip2(vars, argnodes)
  local lastargindex = #argnodes
  local lastargnode = argnodes[#argnodes]
  local calleetype = lastargnode and lastargnode.attr.calleetype
  if lastargnode and lastargnode.tag:sub(1,4) == 'Call' and (not calleetype or not calleetype.is_type) then
    -- last arg is a runtime call
    assert(calleetype)
    -- we know the callee type
    return function()
      local var, argnode
      i, var, argnode = iter(ts, i)
      if not i then return nil end
      if i >= lastargindex and lastargnode.attr.multirets then
        -- argnode does not exists, fill with multiple returns type
        -- in case it doest not exists, the argtype will be false
        local callretindex = i - lastargindex + 1
        local argtype = calleetype:get_return_type(callretindex)
        return i, var, argnode, argtype, callretindex, calleetype
      else
        local argtype = argnode and argnode.attr.type
        return i, var, argnode, argtype, nil
      end
    end
  else
    -- no calls from last argument
    return function()
      local var, argnode
      i, var, argnode = iter(ts, i)
      if not i then return end
      -- we are sure this argument have no type, set argtype to false
      local argtype = argnode and argnode.attr.type
      return i, var, argnode, argtype
    end
  end
end

local function destroy_variable(context, emitter, vartype, varname)
  if not vartype:has_destroyable() then return end
  local destroymt = vartype:get_metafield('__destroy')
  if destroymt then
    emitter:add_indent_ln(context:declname(destroymt), '(&', varname, ');')
  end
  for _,field in ipairs(vartype.fields) do
    if field.type:has_destroyable() then
      destroy_variable(context, emitter, field.type, varname..'.'..field.name)
    end
  end
end

local function destroy_callee_returns(context, emitter, retvalname, calleetype, ignoreindexes)
  for i,returntype in ipairs(calleetype.rettypes) do
    if returntype:has_destroyable() and not ignoreindexes[i] then
      local retargname
      if calleetype:has_multiple_returns() then
        retargname = string.format('%s.r%d', retvalname, i)
      else
        retargname = retvalname
      end
      destroy_variable(context, emitter, returntype, retargname)
    end
  end
end

local function destroy_scope_variables(context, emitter, scope)
  for i=#scope.symbols,1,-1 do
    local symbol = scope.symbols[i]
    if not symbol.moved then
      local symtype = scope.symbols[i].type
      if symbol.scopedestroy then
        destroy_variable(context, emitter, symtype, context:declname(symbol))
      end
    end
  end
  if scope.deferblocks then
    for i=#scope.deferblocks,1,-1 do
      local deferblock = scope.deferblocks[i]
      emitter:add_indent_ln('{')
      context:push_scope(deferblock.scope.parent)
      emitter:add(deferblock)
      context:pop_scope()
      emitter:add_indent_ln('}')
    end
  end
end

local function destroy_upscopes_variables(context, emitter, kind)
  local scope = context.scope
  repeat
    destroy_scope_variables(context, emitter, scope)
    scope = scope.parent
  until (scope.kind == kind or scope == context.rootscope)
  destroy_scope_variables(context, emitter, scope)
end

local function copy_variable(context, emitter, vartype, varname, srcvarname)
  local copymt = vartype:get_metafield('__copy')
  if copymt then
    emitter:add_indent_ln(context:declname(copymt), '(&', varname, ', &', srcvarname, ');')
  end
  for _,field in ipairs(vartype.fields) do
    if field.type:has_copyable() then
      copy_variable(context, emitter, field.type, varname..'.'..field.name, srcvarname..'.'..field.name)
    end
  end
end

local function create_variable(context, emitter, type, val, valtype)
  if not valtype and traits.is_astnode(val) then
    valtype = val.attr.type
  end
  local copying = false
  if type == valtype and traits.is_astnode(val) and val.attr.lvalue and type:has_copyable() then
    if not val.attr.maymove or val.attr.moved then
      copying = true
    else
      val.attr.moved = true
    end
  end
  if copying then
    emitter:add_ln('({')
    emitter:inc_indent()
    emitter:add_indent_ln(type, ' _t1 = {0};')
    emitter:add_indent(type, '* _t2 = &')
    emitter:add_val2type(type, val, valtype)
    emitter:add_ln(';')
    copy_variable(context, emitter, type, '_t1', '(*_t2)')
    emitter:add_indent_ln('_t1;')
    emitter:dec_indent()
    emitter:add_indent('})')
  else
    emitter:add_val2type(type, val, valtype)
  end
end

local function visit_assignments(context, emitter, varnodes, valnodes, decl)
  local usetemporary = false
  if not decl and #valnodes > 1 then
    -- multiple assignments must assign to a temporary first (in case of a swap)
    usetemporary = true
  end
  local defemitter = CEmitter(context, emitter.depth)
  local multiretvalname
  for _,varnode,valnode,valtype,lastcallindex in izipargnodes(varnodes, valnodes or {}) do
    local varattr = varnode.attr
    local noinit = varattr.noinit or varattr.cexport
    local vartype = varattr.type
    if not vartype.is_type and (not varattr.nodecl or not decl) and not varattr.comptime then
      local declared, defined = false, false
      if decl and varattr.staticstorage then
        -- declare main variables in the top scope
        local decemitter = CEmitter(context)
        decemitter:add_indent()
        if not varattr.nostatic and not varattr.cexport then
          decemitter:add('static ')
        end
        decemitter:add(varnode)
        if valnode and valnode.attr.initializer then
          -- initialize to const values
          decemitter:add(' = ')
          assert(not lastcallindex)
          local state = context:push_state()
          state.ininitializer = true
          decemitter:add_val2type(vartype, valnode)
          context:pop_state()
          defined = true
        else
          -- pre initialize to zeros
          if not noinit then
            decemitter:add(' = ')
            decemitter:add_zeroinit(vartype)
          end
        end
        decemitter:add_ln(';')
        context:add_declaration(decemitter:generate())
        declared = true
      end

      if lastcallindex == 1 then
        -- last assigment value may be a multiple return call
        multiretvalname = context:genuniquename('ret')
        local retctype = context:funcretctype(valnode.attr.calleetype)
        emitter:add_indent_ln(retctype, ' ', multiretvalname, ' = ', valnode, ';')
      end

      local dodestroy = not decl and vartype:has_destroyable() and traits.is_astnode(valnode)
      local docopy = vartype:has_copyable() and traits.is_astnode(valnode)
      if docopy or dodestroy then
        usetemporary = true
      end
      local retvalname
      if lastcallindex then
        retvalname = string.format('%s.r%d', multiretvalname, lastcallindex)
      elseif usetemporary then
        retvalname = context:genuniquename('asgntmp')
        emitter:add_indent(vartype, ' ', retvalname, ' = ')
        create_variable(context, emitter, vartype, valnode)
        emitter:add_ln(';')
        if dodestroy then
          destroy_variable(context, emitter, vartype, context:declname(varnode.attr))
        end
      end

      if not declared or (not defined and (valnode or lastcallindex)) then
        -- declare or define if needed
        defemitter:add_indent()
        if not declared then
          defemitter:add(varnode)
        else
          defemitter:add(context:declname(varattr))
        end
        if valnode or not noinit then
          -- initialize variable
          defemitter:add(' = ')
          if retvalname then
            defemitter:add_val2type(vartype, retvalname, valtype, varnode.checkcast)
          else
            defemitter:add_val2type(vartype, valnode)
          end
        end
        defemitter:add_ln(';')
      end
    elseif varattr.cinclude then
      -- not declared, might be an imported variable from C
      context:add_include(varattr.cinclude)
    end
  end
  emitter:add(defemitter:generate())
end

local typevisitors = {}

local function emit_type_attributes(decemitter, type)
  if type.aligned then
    decemitter:add(' __attribute__((aligned(', type.aligned, ')))')
  end
  if type.packed then
    decemitter:add(' __attribute__((packed))')
  end
end

typevisitors[types.ArrayType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  local decemitter = CEmitter(context, 0)
  decemitter:add('typedef struct {', type.subtype, ' data[', type.length, '];} ', type.codename)
  emit_type_attributes(decemitter, type)
  decemitter:add_ln(';')
  decemitter:add_ln('nelua_static_assert(sizeof(',type.codename,') == ', type.size,
                    ', "Nelua and C disagree on type size");')
  context:add_declaration(decemitter:generate(), type.codename)
end

typevisitors[types.PointerType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  context.declarations[type.codename] = true
  local decemitter = CEmitter(context, 0)
  local index = nil
  if type.subtype.is_record and not type.subtype.nodecl and not context.declarations[type.subtype.codename] then
    -- offset declaration of pointers before records
    index = #context.declarations+2
  end
  decemitter:add_ln('typedef ', type.subtype, '* ', type.codename, ';')
  if not index then
    index = #context.declarations+1
  end
  table.insert(context.declarations, index, decemitter:generate())
end

typevisitors[types.RecordType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  context.declarations[type.codename] = true
  local decemitter = CEmitter(context, 0)
  decemitter:add_ln('typedef struct ', type.codename, ' ', type.codename, ';')
  table.insert(context.declarations, decemitter:generate())
  local defemitter = CEmitter(context, 0)
  --if #type.fields > 0 then
    defemitter:add('struct ', type.codename)
    defemitter:add_ln(' {')
    for _,field in ipairs(type.fields) do
      local fieldctype
      if field.type.is_array then
        fieldctype = field.type.subtype
      else
        fieldctype = context:ctype(field.type)
      end
      defemitter:add('  ', fieldctype, ' ', field.name)
      if field.type.is_array then
        defemitter:add('[', field.type.length, ']')
      end
      defemitter:add_ln(';')
    end
    defemitter:add('}')
    emit_type_attributes(defemitter, type)
    defemitter:add_ln(';')
  --end
  defemitter:add_ln('nelua_static_assert(sizeof(',type.codename,') == ', type.size,
                    ', "Nelua and C disagree on type size");')
  table.insert(context.declarations, defemitter:generate())
end

typevisitors[types.EnumType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  local decemitter = CEmitter(context, 0)
  decemitter:add_ln('typedef ', type.subtype, ' ', type.codename, ';')
  context:add_declaration(decemitter:generate(), type.codename)
end

typevisitors[types.FunctionType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  local decemitter = CEmitter(context, 0)
  decemitter:add('typedef ', context:funcretctype(type), ' (*', type.codename, ')(')
  for i,argtype in ipairs(type.argtypes) do
    if i>1 then
      decemitter:add(', ')
    end
    decemitter:add(argtype)
  end
  decemitter:add_ln(');')
  context:add_declaration(decemitter:generate(), type.codename)
end

typevisitors[types.PolyFunctionType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  local decemitter = CEmitter(context, 0)
  decemitter:add_ln('typedef void* ', type.codename, ';')
  context:add_declaration(decemitter:generate(), type.codename)
end

typevisitors[types.Type] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  if type.is_any then --luacov:enable
    context:ensure_runtime_builtin('nlany')
  elseif type.is_niltype then
    context:ensure_runtime_builtin('nlniltype')
  else
    errorer.assertf(cdefs.primitive_ctypes[type.codename],
      'C type visitor for "%s" is not defined', type)
  end
end

local visitors = {}

function visitors.Number(context, node, emitter)
  local attr = node.attr
  if not attr.type.is_float and not attr.untyped and not context.state.ininitializer then
    emitter:add_ctypecast(attr.type)
  end
  emitter:add_numeric_literal(attr)
end

function visitors.String(_, node, emitter)
  local attr = node.attr
  if attr.type.is_stringy then
    emitter:add_string_literal(attr.value, attr.type.is_cstring)
  else
    if attr.type == primtypes.cchar then
      emitter:add("'", string.char(bn.tointeger(attr.value)), "'")
    else
      emitter:add_numeric_literal(attr)
    end
  end
end

function visitors.Boolean(_, node, emitter)
  emitter:add_booleanlit(node.attr.value)
end

function visitors.Nil(_, _, emitter)
  emitter:add_nil_literal()
end

function visitors.Varargs(_, _, emitter)
  emitter:add('...')
end

function visitors.Table(context, node, emitter)
  local attr = node.attr
  local childnodes, type = node[1], attr.type
  local len = #childnodes
  if len == 0 and (type.is_record or type.is_array) then
    if not context.state.ininitializer then
      emitter:add_ctypecast(type)
    end
    emitter:add_zeroinit(type)
  elseif type.is_record then
    if context.state.ininitializer then
      local state = context:push_state()
      state.inrecordinitializer = true
      emitter:add('{', childnodes, '}')
      context:pop_state()
    else
      emitter:add_ln('({')
      emitter:inc_indent()
      emitter:add_indent(type, ' __rec = ')
      emitter:add_zeroinit(type)
      emitter:add_ln(';')
      for _,childnode in ipairs(childnodes) do
        local fieldname = childnode.fieldname
        local childvalnode
        if childnode.tag  == 'Pair' then
          childvalnode = childnode[2]
        else
          childvalnode = childnode
        end
        local childvaltype = childvalnode.attr.type
        if childvaltype.is_array then
          emitter:add_indent('(*(', childvaltype, '*)__rec.', fieldname, ') = ')
        else
          emitter:add_indent('__rec.', fieldname, ' = ')
        end
        create_variable(context, emitter, childvaltype,  childvalnode)
        emitter:add_ln(';')
      end
      emitter:add_indent_ln('__rec;')
      emitter:dec_indent()
      emitter:add_indent('})')
    end
  elseif type.is_array then
    if context.state.ininitializer then
      if context.state.inrecordinitializer then
        emitter:add('{', childnodes, '}')
      else
        emitter:add('{{', childnodes, '}}')
      end
    else
      emitter:add_ctypecast(type)
      emitter:add('{{', childnodes, '}}')
    end
  else --luacov:disable
    error('not implemented yet')
  end --luacov:enable
end

function visitors.Pair(context, node, emitter)
  local namenode, valuenode = node:args()
  local parenttype = node.parenttype
  if parenttype and parenttype.is_record then
    assert(traits.is_string(namenode))
    emitter:add('.', cdefs.quotename(namenode), ' = ')
    create_variable(context, emitter, valuenode.attr.type, valuenode)
  else --luacov:disable
    error('not implemented yet')
  end --luacov:enable
end

-- TODO: Function

function visitors.PragmaCall(context, node, emitter)
  local name, args = node:args()
  if name == 'cinclude' then
    context:add_include(table.unpack(args))
  elseif name == 'cemit' then
    local code, scope = table.unpack(args)
    if traits.is_string(code) and not stringer.endswith(code, '\n') then
      code = code .. '\n'
    end
    if scope == 'declaration' and traits.is_string(code) then
      context:add_declaration(code)
    elseif scope == 'definition' and traits.is_string(code)  then
      context:add_definition(code)
    elseif not scope and traits.is_function(code) then
      code(emitter)
    elseif not scope and traits.is_string(code) then
      emitter:add(code)
    end
  elseif name == 'cdefine' then
    context:add_declaration(string.format('#define %s\n', args[1]))
  elseif name == 'cflags' then
    table.insert(context.compileopts.cflags, args[1])
  elseif name == 'ldflags' then
    table.insert(context.compileopts.ldflags, args[1])
  elseif name == 'linklib' then
    table.insert(context.compileopts.linklibs, args[1])
  end
end

function visitors.Id(context, node, emitter)
  local attr = node.attr
  assert(not attr.type.is_comptime)
  if attr.type.is_nilptr then
    emitter:add_null()
  elseif attr.comptime then
    emitter:add_literal(attr)
  else
    emitter:add(context:declname(attr))
  end
end

function visitors.Paren(_, node, emitter)
  local innernode = node:args()
  emitter:add(innernode)
  --emitter:add('(', innernode, ')')
end

visitors.FuncType = visitors.Type
visitors.ArrayType = visitors.Type
visitors.PointerType = visitors.Type

function visitors.IdDecl(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  if attr.comptime or type.is_comptime then
    emitter:add(context:ensure_runtime_builtin('nlunusedvar'), ' ', context:declname(attr))
    return
  end
  if attr.funcdecl then
    emitter:add(context:declname(attr))
    return
  end
  if type.is_type then return end
  if attr.cexport then emitter:add('extern ') end
  if attr.register then emitter:add('register ') end
  --if attr.const then emitter:add('const ') end
  if attr.volatile then emitter:add('volatile ') end
  if attr.restrict then emitter:add('__restrict ') end
  if attr.static then emitter:add('static ') end
  if attr.cqualifier then emitter:add(attr.cqualifier, ' ') end
  emitter:add(type, ' ', context:declname(attr))
  if attr.cattribute then emitter:add(' __attribute__((', attr.cattribute, '))') end
  if type:has_destroyable() then
    attr.scopedestroy = true
  end
end

local function visitor_Call(context, node, emitter, argnodes, callee, calleeobjnode)
  local isblockcall = context:get_parent_node().tag == 'Block'
  if isblockcall then
    emitter:add_indent()
  end
  local attr = node.attr
  local calleetype = attr.calleetype
  if calleetype.is_procedure then
    -- function call
    local tmpargs = {}
    local tmpcount = 0
    local lastcalltmp
    local sequential = false
    local serialized = false
    local callargtypes = attr.pseudoargtypes or calleetype.argtypes
    local ismethod = attr.pseudoargtypes ~= nil
    for i,_,argnode,_,lastcallindex in izipargnodes(callargtypes, argnodes) do
      if (argnode and argnode.attr.sideeffect) or lastcallindex == 1 then
        -- expressions with side effects need to be evaluated in sequence
        -- and expressions with multiple returns needs to be stored in a temporary
        tmpcount = tmpcount + 1
        local tmpname = '__tmp' .. tmpcount
        tmpargs[i] = tmpname
        if lastcallindex == 1 then
          lastcalltmp = tmpname
        end
        if tmpcount >= 2 or lastcallindex then
          -- only need to evaluate in sequence mode if we have two or more temporaries
          -- or the last argument is a multiple return call
          sequential = true
          serialized = true
        end
      end
    end

    local handlereturns
    local retvalname
    local returnfirst
    local enclosed = calleetype:has_multiple_returns()
    local destroyable = calleetype:has_destroyable_return()
    if not attr.multirets and (enclosed or destroyable) then
      -- we are handling the returns
      returnfirst = not isblockcall
      handlereturns = true
      serialized = true
    end

    if serialized then
      -- break apart the call into many statements
      if not isblockcall then
        emitter:add('(')
      end
      emitter:add_ln('{')
      emitter:inc_indent()
    end

    if sequential then
      for _,tmparg,argnode,argtype,_,lastcalletype in izipargnodes(tmpargs, argnodes) do
        -- set temporary values in sequence
        if tmparg then
          if lastcalletype then
            -- type for result of multiple return call
            argtype = context:funcretctype(lastcalletype)
          end
          emitter:add_indent_ln(argtype, ' ', tmparg, ' = ', argnode, ';')
        end
      end
    end

    if serialized then
      emitter:add_indent()
      if handlereturns then
        -- save the return type
        local retctype = context:funcretctype(calleetype)
        retvalname = context:genuniquename('ret')
        emitter:add(retctype, ' ', retvalname, ' = ')
      end
    end

    if ismethod then
      emitter:add(context:declname(attr.calleesym), '(')
      emitter:add_val2type(calleetype.argtypes[1], calleeobjnode)
    else
      if attr.pointercall then
        emitter:add('(*')
      end
      if not traits.is_string(callee) and attr.calleesym then
        emitter:add(context:declname(attr.calleesym))
      else
        emitter:add(callee)
      end
      if attr.pointercall then
        emitter:add(')')
      end
      emitter:add('(')
    end

    for i,funcargtype,argnode,argtype,lastcallindex in izipargnodes(callargtypes, argnodes) do
      if i > 1 or ismethod then emitter:add(', ') end
      local arg = argnode
      if sequential then
        if lastcallindex then
          arg = string.format('%s.r%d', lastcalltmp, lastcallindex)
        elseif tmpargs[i] then
          arg = tmpargs[i]
        end
      end

      create_variable(context, emitter, funcargtype, arg, argtype)
    end
    emitter:add(')')

    if serialized then
      -- end sequential expression
      emitter:add_ln(';')
      if handlereturns and destroyable then
        local ignoredestroyindexes = {}
        if returnfirst then
          ignoredestroyindexes[1] = true
        end
        destroy_callee_returns(context, emitter, retvalname, calleetype, ignoredestroyindexes)
      end
      if returnfirst then
        -- get just the first result in multiple return functions
        if enclosed then
          emitter:add_indent_ln(retvalname, '.r1;')
        else
          emitter:add_indent_ln(retvalname, ';')
        end
      end
      emitter:dec_indent()
      emitter:add_indent('}')
      if not isblockcall then
        emitter:add(')')
      end
    end
  else
    --TODO: handle better calls on any types
    emitter:add(callee, '(', argnodes, ')')
  end
  if isblockcall then
    emitter:add_ln(";")
  end
end

function visitors.Call(context, node, emitter)
  if node.attr.omitcall then return end
  local argnodes, calleenode = node:args()
  local calleetype = node.attr.calleetype
  local callee = calleenode
  if calleenode.attr.builtin then
    local builtin = cbuiltins.inlines[calleenode.attr.name]
    callee = builtin(context, node, emitter)
  end
  if calleetype.is_type then
    -- type cast
    local type = node.attr.type
    if #argnodes == 1 then
      local argnode = argnodes[1]
      if argnode.attr.type ~= type then
        -- type really differs, cast it
        emitter:add_val2type(type, argnode, argnode.attr.type)
      else
        -- same type, no need to cast
        emitter:add(argnode)
      end
    else
      emitter:add_ctyped_zerotype(type)
    end
  elseif callee then
    visitor_Call(context, node, emitter, argnodes, callee, nil)
  end
end

function visitors.CallMethod(context, node, emitter)
  local name, argnodes, calleeobjnode = node:args()

  visitor_Call(context, node, emitter, argnodes, nil, calleeobjnode)

  --[[
  local name, args, callee, block_call = node:args()
  if block_call then
    emitter:add_indent()
  end
  local sep = #args > 0 and ', ' or ''
  emitter:add(callee, '.', cdefs.quotename(name), '(', callee, sep, args, ')')
  if block_call then
    emitter:add_ln()
  end
  ]]
end

-- indexing
function visitors.DotIndex(context, node, emitter)
  local name, objnode = node:args()
  local attr = node.attr
  local type = attr.type
  local objtype = objnode.attr.type
  local poparray = false
  if type.is_array and not attr.globalfield then
    emitter:add('(*(', type, '*)')
    poparray = true
  end
  if objtype.is_type then
    objtype = node.indextype
    if objtype.is_enum then
      local field = objtype.fields[name]
      emitter:add_numeric_literal(field, objtype.subtype)
    elseif objtype.is_record then
      if attr.comptime then
        emitter:add_literal(attr)
      else
        emitter:add(context:declname(attr))
      end
    else --luacov:disable
      error('not implemented yet')
    end --luacov:enable
  elseif objtype.is_pointer then
    emitter:add(objnode, '->', cdefs.quotename(name))
  else
    emitter:add(objnode, '.', cdefs.quotename(name))
  end
  if poparray then
    emitter:add(')')
  end
end

visitors.ColonIndex = visitors.DotIndex

function visitors.ArrayIndex(context, node, emitter)
  local indexnode, objnode = node:args()
  local objtype = objnode.attr.type
  local pointer = false
  if objtype.is_pointer and not objtype.is_generic_pointer then
    -- indexing a pointer to an array
    objtype = objtype.subtype
    pointer = true
  end

  if objtype.is_record then
    if node.attr.lvalue then
      emitter:add('(*')
    end
    visitor_Call(context, node, emitter, {indexnode}, nil, objnode)
    if node.attr.lvalue then
      emitter:add(')')
    end
  else
    if not objtype.is_array then --luacov:disable
      error('not implemented yet')
    end --luacov:enable

    if pointer then
      emitter:add('((', objtype.subtype, '*)', objnode, ')[')
    elseif objtype.length == 0 then
      emitter:add('((', objtype.subtype, '*)&', objnode, ')[')
    else
      emitter:add(objnode, '.data[')
    end
    if not node.attr.checkbounds then
      emitter:add(indexnode)
    else
      local indextype = indexnode.attr.type
      emitter:add(context:ensure_runtime_builtin('nelua_assert_bounds_', indextype))
      emitter:add('(', indexnode, ', ', objtype.length, ')')
    end
    emitter:add(']')
  end
end

function visitors.Block(context, node, emitter)
  local statnodes = node:args()
  emitter:inc_indent()
  local scope = context:push_forked_scope('block', node)
  do
    emitter:add_traversal_list(statnodes, '')
  end
  if not node.attr.returnending and not scope.alreadydestroyed then
    destroy_scope_variables(context, emitter, scope)
  end
  context:pop_scope()
  emitter:dec_indent()
end

function visitors.Return(context, node, emitter)
  local retnodes = node:args()
  local numretnodes = #retnodes

  -- destroy parent blocks
  local defemitter = CEmitter(context, emitter.depth)
  local desemitter = CEmitter(context, emitter.depth)
  local funcscope = context.scope:get_parent_of_kind('function') or context.rootscope
  context.scope.alreadydestroyed = true
  funcscope.has_return = true
  if funcscope == context.rootscope then
    -- in main body
    node:assertraisef(numretnodes <= 1, "multiple returns in main is not supported yet")
    if numretnodes == 0 then
      -- main must always return an integer
      defemitter:add_indent_ln('return 0;')
    else
      -- return one value (an integer expected)
      local retnode = retnodes[1]
      defemitter:add_indent('return ')
      defemitter:add_val2type(primtypes.cint, retnode)
      defemitter:add_ln(';')
    end
  else
    local functype = funcscope.functype
    local numfuncrets = functype:get_return_count()
    if not functype:has_multiple_returns() then
      if numfuncrets == 0 then
        -- no returns
        assert(numretnodes == 0)
        defemitter:add_indent_ln('return;')
      elseif numfuncrets == 1 then
        -- one return
        local retnode, rettype = retnodes[1], functype:get_return_type(1)
        defemitter:add_indent('return ')
        if retnode then
          -- return value is present
          retnode.attr.maymove = true
          create_variable(context, defemitter, rettype, retnode)
          defemitter:add_ln(';')
        else
          -- no return value present, generate a zeroed one
          defemitter:add_ctyped_zerotype(rettype)
          defemitter:add_ln(';')
        end
      end
    else
      -- multiple returns
      local funcretctype = context:funcretctype(functype)
      local retemitter = CEmitter(context, defemitter.depth)
      local multiretvalname
      retemitter:add('return (', funcretctype, '){')
      local ignoredestroyindexes = {}
      local usedlastcalletype
      for i,funcrettype,retnode,rettype,lastcallindex,lastcalletype in izipargnodes(functype.rettypes, retnodes) do
        if i>1 then retemitter:add(', ') end
        if lastcallindex == 1 then
          usedlastcalletype = lastcalletype
          assert(usedlastcalletype)
          -- last assignment value may be a multiple return call
          defemitter:add_indent_ln('{')
          defemitter:inc_indent()
          multiretvalname = context:genuniquename('ret')
          local retctype = context:funcretctype(retnode.attr.calleetype)
          defemitter:add_indent_ln(retctype, ' ', multiretvalname, ' = ', retnode, ';')
        end
        if lastcallindex then
          local retvalname = string.format('%s.r%d', multiretvalname, lastcallindex)
          create_variable(context, retemitter, funcrettype, retvalname, rettype)
          ignoredestroyindexes[lastcallindex] = true
        else
          retnode.attr.maymove = true
          create_variable(context, retemitter, funcrettype, retnode)
        end
      end
      retemitter:add_ln('};')
      if usedlastcalletype then
        destroy_callee_returns(context, defemitter, multiretvalname, usedlastcalletype, ignoredestroyindexes)
      end
      defemitter:add_indent(retemitter:generate())
      if multiretvalname then
        defemitter:dec_indent()
        defemitter:add_indent_ln('}')
      end
    end
  end
  destroy_upscopes_variables(context, desemitter, 'function')
  emitter:add(desemitter:generate())
  emitter:add(defemitter:generate())
end

function visitors.If(_, node, emitter)
  local ifparts, elseblock = node:args()
  for i,ifpart in ipairs(ifparts) do
    local condnode, blocknode = ifpart[1], ifpart[2]
    if i == 1 then
      emitter:add_indent("if(")
      emitter:add_val2type(primtypes.boolean, condnode)
      emitter:add_ln(") {")
    else
      emitter:add_indent("} else if(")
      emitter:add_val2type(primtypes.boolean, condnode)
      emitter:add_ln(") {")
    end
    emitter:add(blocknode)
  end
  if elseblock then
    emitter:add_indent_ln("} else {")
    emitter:add(elseblock)
  end
  emitter:add_indent_ln("}")
end

function visitors.Switch(_, node, emitter)
  local valnode, caseparts, elsenode = node:args()
  emitter:add_indent_ln("switch(", valnode, ") {")
  emitter:inc_indent()
  for _,casepart in ipairs(caseparts) do
    for i=1, #casepart-2 do
      emitter:add_indent_ln("case ", casepart[i], ":")
    end
    emitter:add_indent_ln("case ", casepart[#casepart-1], ': {') -- last case
    emitter:add(casepart[#casepart]) -- block
    emitter:inc_indent() emitter:add_indent_ln('break;') emitter:dec_indent()
    emitter:add_indent_ln("}")
  end
  if elsenode then
    emitter:add_indent_ln('default: {')
    emitter:add(elsenode)
    emitter:inc_indent() emitter:add_indent_ln('break;') emitter:dec_indent()
    emitter:add_indent_ln("}")
  end
  emitter:dec_indent()
  emitter:add_indent_ln("}")
end

function visitors.Do(context, node, emitter)
  local blocknode = node:args()
  local doemitter = CEmitter(context, emitter.depth)
  doemitter:add(blocknode)
  if doemitter:is_empty() then return end
  emitter:add_indent_ln("{")
  emitter:add(doemitter:generate())
  emitter:add_indent_ln("}")
end

function visitors.Defer(context, node)
  local blocknode = node:args()
  local deferblocks = context.scope.deferblocks
  if not deferblocks then
    deferblocks = {}
    context.scope.deferblocks = deferblocks
  end
  table.insert(deferblocks, blocknode)
end

function visitors.While(context, node, emitter)
  local condnode, blocknode = node:args()
  emitter:add_indent("while(")
  emitter:add_val2type(primtypes.boolean, condnode)
  emitter:add_ln(') {')
  context:push_forked_scope('loop', node)
  emitter:add(blocknode)
  context:pop_scope()
  emitter:add_indent_ln("}")
end

function visitors.Repeat(context, node, emitter)
  local blocknode, condnode = node:args()
  emitter:add_indent_ln("while(true) {")
  context:push_forked_cleaned_scope('loop', node)
  emitter:add(blocknode)
  emitter:inc_indent()
  emitter:add_indent('if(')
  emitter:add_val2type(primtypes.boolean, condnode)
  emitter:add_ln(') {')
  emitter:inc_indent()
  emitter:add_indent_ln('break;')
  emitter:dec_indent()
  emitter:add_indent_ln('}')
  context:pop_scope()
  emitter:dec_indent()
  emitter:add_indent_ln('}')
end

function visitors.ForNum(context, node, emitter)
  local itvarnode, begvalnode, compop, endvalnode, stepvalnode, blocknode  = node:args()
  compop = node.attr.compop
  local fixedstep = node.attr.fixedstep
  local fixedend = node.attr.fixedend
  local itvarattr = itvarnode.attr
  local itmutate = itvarattr.mutate
  context:push_forked_scope('loop', node)
  do
    local ccompop = cdefs.compare_ops[compop]
    local ittype = itvarattr.type
    local itname = context:declname(itvarattr)
    local itforname = itmutate and '__it' or itname
    emitter:add_indent('for(', ittype, ' ', itforname, ' = ')
    emitter:add_val2type(ittype, begvalnode)
    local cmpval
    if not fixedend or not compop then
      emitter:add(', __end = ')
      emitter:add_val2type(ittype, endvalnode)
      cmpval = '__end'
    else
      cmpval = endvalnode
    end
    local stepval
    if not fixedstep then
      emitter:add(', __step = ')
      emitter:add_val2type(ittype, stepvalnode)
      stepval = '__step'
    else
      stepval = fixedstep
    end
    emitter:add('; ')
    if compop then
      emitter:add(itforname, ' ', ccompop, ' ')
      if traits.is_string(cmpval) then
        emitter:add(cmpval)
      else
        emitter:add_val2type(ittype, cmpval)
      end
    else
      -- step is an expression, must detect the compare operation at runtime
      assert(not fixedstep)
      emitter:add('__step >= 0 ? ', itforname, ' <= __end : ', itforname, ' >= __end')
    end
    emitter:add_ln('; ', itforname, ' = ', itforname, ' + ', stepval, ') {')
    emitter:inc_indent()
    if itmutate then
      emitter:add_indent_ln(itvarnode, ' = __it;')
    end
    emitter:dec_indent()
    emitter:add(blocknode)
    emitter:add_indent_ln('}')
  end
  context:pop_scope()
end

--[[
function visitors.ForIn(_, node, emitter)
  local itvarnodes, inexpnodes, blocknode = node:args()
  emitter:add_indent_ln("{")
  emitter:inc_indent()
  --visit_assignments(context, emitter, itvarnodes, inexpnodes, true)
  emitter:add_indent("while(true) {")
  emitter:add(blocknode)
  emitter:add_indent_ln("}")
  emitter:dec_indent()
  emitter:add_indent_ln("}")
end
]]

function visitors.Break(context, _, emitter)
  destroy_upscopes_variables(context, emitter, 'loop')
  context.scope.alreadydestroyed = true
  emitter:add_indent_ln('break;')
end

function visitors.Continue(context, _, emitter)
  destroy_upscopes_variables(context, emitter, 'loop')
  context.scope.alreadydestroyed = true
  emitter:add_indent_ln('continue;')
end

function visitors.Label(context, node, emitter)
  emitter:add_ln(context:declname(node.attr), ':;')
end

function visitors.Goto(context, node, emitter)
  emitter:add_indent_ln('goto ', context:declname(node.attr.label), ';')
end

function visitors.VarDecl(context, node, emitter)
  local varscope, varnodes, valnodes = node:args()
  visit_assignments(context, emitter, varnodes, valnodes, true)
end

function visitors.Assign(context, node, emitter)
  local vars, vals = node:args()
  visit_assignments(context, emitter, vars, vals)
end

function visitors.FuncDef(context, node, emitter)
  local attr = node.attr
  local type = attr.type

  if type.is_polyfunction then
    for _,polyeval in ipairs(type.evals) do
      emitter:add(polyeval.node)
    end
    return
  end

  local varscope, varnode, argnodes, retnodes, annotnodes, blocknode = node:args()

  local numrets = type:get_return_count()
  local qualifier = ''
  if not attr.entrypoint and not attr.nostatic and not attr.cexport then
    qualifier = 'static '
  end
  local declare, define = not attr.nodecl, true

  if attr.cinclude then
    context:add_include(attr.cinclude)
  end
  if attr.cimport then
    qualifier = ''
    define = false
  end

  if attr.cexport then
    qualifier = qualifier .. 'extern '
  end
  if attr.volatile then
    qualifier = qualifier .. 'volatile '
  end
  if attr.inline then
    qualifier = qualifier .. 'inline '
  end
  if attr.noinline then
    qualifier = qualifier .. context:ensure_runtime_builtin('nelua_noinline') .. ' '
  end
  if attr.noreturn then
    qualifier = qualifier .. context:ensure_runtime_builtin('nelua_noreturn') .. ' '
  end
  if attr.cqualifier then qualifier = qualifier .. attr.cqualifier .. ' ' end
  if attr.cattribute then
    qualifier = string.format('%s__attribute__((%s)) ', qualifier, attr.cattribute)
  end

  local decemitter, defemitter, implemitter = CEmitter(context), CEmitter(context), CEmitter(context)
  local retctype = context:funcretctype(type)
  if type:has_multiple_returns() then
    node:assertraisef(declare, 'functions with multiple returns must be declared')

    local retemitter = CEmitter(context)
    retemitter:add_indent_ln('typedef struct ', retctype, ' {')
    retemitter:inc_indent()
    for i=1,numrets do
      local rettype = type:get_return_type(i)
      assert(rettype)
      retemitter:add_indent_ln(rettype, ' ', 'r', i, ';')
    end
    retemitter:dec_indent()
    retemitter:add_indent_ln('} ', retctype, ';')
    context:add_declaration(retemitter:generate())
  end

  decemitter:add_indent(qualifier, retctype, ' ')
  defemitter:add_indent(retctype, ' ')

  decemitter:add(varnode)
  defemitter:add(varnode)
  local funcscope = context:push_forked_scope('function', node)
  funcscope.functype = type
  do
    decemitter:add('(')
    defemitter:add('(')
    if varnode.tag == 'ColonIndex' then
      decemitter:add(node.attr.metafuncselftype, ' self')
      defemitter:add(node.attr.metafuncselftype, ' self')
      if #argnodes > 0 then
        decemitter:add(', ')
        defemitter:add(', ')
      end
    end
    decemitter:add_ln(argnodes, ');')
    defemitter:add_ln(argnodes, ') {')
    implemitter:add(blocknode)
    if not blocknode.attr.returnending then
      implemitter:inc_indent()
      destroy_scope_variables(context, implemitter, funcscope)
      implemitter:dec_indent()
    end
  end
  context:pop_scope()
  implemitter:add_indent_ln('}')
  if declare then
    context:add_declaration(decemitter:generate())
  end
  if define then
    context:add_definition(defemitter:generate())
    if attr.entrypoint and not context.hookmain then
      context:add_definition(function() return context.mainemitter:generate() end)
    end
    context:add_definition(implemitter:generate())
  end
end

function visitors.UnaryOp(_, node, emitter)
  local attr = node.attr
  if attr.comptime then
    emitter:add_literal(attr)
    return
  end
  local opname, argnode = node:args()
  local op = cdefs.unary_ops[opname]
  assert(op)
  local surround = not node.attr.inconditional
  if surround then emitter:add('(') end
  if traits.is_string(op) then
    emitter:add(op, argnode)
  else
    local builtin = cbuiltins.operators[opname]
    builtin(node, emitter, argnode)
  end
  if surround then emitter:add(')') end
end

function visitors.BinaryOp(context, node, emitter)
  if node.attr.comptime then
    emitter:add_literal(node.attr)
    return
  end
  local opname, lnode, rnode = node:args()
  local type = node.attr.type
  local op = cdefs.binary_ops[opname]
  assert(op)
  local surround = not node.attr.inconditional
  if surround then emitter:add('(') end
  if node.attr.dynamic_conditional then
    emitter:add_ln('({')
    emitter:inc_indent()
    if node.attr.ternaryor then
      -- lua style "ternary" operator
      emitter:add_indent_ln(type, ' t_;')
      emitter:add_indent('bool cond_ = ')
      emitter:add_val2type(primtypes.boolean, lnode[2])
      emitter:add_ln(';')
      emitter:add_indent_ln('if(cond_) {')
      emitter:add_indent('  t_ = ')
      create_variable(context, emitter, type, lnode[3])
      emitter:add_ln(';')
      emitter:add_indent('  cond_ = ')
      emitter:add_val2type(primtypes.boolean, 't_', type)
      emitter:add_ln(';')
      emitter:add_indent_ln('}')
      emitter:add_indent_ln('if(!cond_) {')
      emitter:add_indent('  t_ = ')
      create_variable(context, emitter, type, rnode)
      emitter:add_ln(';')
      emitter:add_indent_ln('}')
      emitter:add_indent_ln('t_;')
    else
      emitter:add_indent(type, ' t1_ = ')
      create_variable(context, emitter, type, lnode)
      --TODO: be smart and remove this unused code
      emitter:add_ln(';')
      emitter:add_indent_ln(type, ' t2_ = {0};')
      if opname == 'and' then
        assert(not node.attr.ternaryand)
        emitter:add_indent('bool cond_ = ')
        emitter:add_val2type(primtypes.boolean, 't1_', type)
        emitter:add_ln(';')
        emitter:add_indent_ln('if(cond_) {')
        emitter:inc_indent()
        emitter:add_indent('t2_ = ')
        create_variable(context, emitter, type, rnode)
        emitter:add_ln(';')
        emitter:add_indent('cond_ = ')
        emitter:add_val2type(primtypes.boolean, 't2_', type)
        emitter:add_ln(';')
        emitter:dec_indent()
        emitter:add_indent_ln('}')
        destroy_variable(context, emitter, type, 't1_')
        emitter:add_indent_ln('cond_ ? t2_ : (', type, '){0};')
      elseif opname == 'or' then
        emitter:add_indent('bool cond_ = ')
        emitter:add_val2type(primtypes.boolean, 't1_', type)
        emitter:add_ln(';')
        emitter:add_indent_ln('if(!cond_) {')
        emitter:inc_indent()
        emitter:add_indent('t2_ = ')
        create_variable(context, emitter, type, rnode)
        emitter:add_ln(';')
        destroy_variable(context, emitter, type, 't1_')
        emitter:dec_indent()
        emitter:add_indent_ln('}')
        emitter:add_indent_ln('cond_ ? t1_ : t2_;')
      end
    end
    emitter:dec_indent()
    emitter:add_indent('})')
  else
    local sequential = lnode.attr.sideeffect and rnode.attr.sideeffect
    local lname = lnode
    local rname = rnode
    if sequential then
      -- need to evaluate args in sequence when one expression has side effects
      emitter:add_ln('({')
      emitter:inc_indent()
      emitter:add_indent_ln(lnode.attr.type, ' t1_ = ', lnode, ';')
      emitter:add_indent_ln(rnode.attr.type, ' t2_ = ', rnode, ';')
      emitter:add_indent()
      lname = 't1_'
      rname = 't2_'
    end
    if traits.is_string(op) then
      emitter:add(lname, ' ', op, ' ', rname)
    else
      local builtin = cbuiltins.operators[opname]
      builtin(node, emitter, lnode, rnode, lname, rname)
    end
    if sequential then
      emitter:add_ln(';')
      emitter:dec_indent()
      emitter:add_indent('})')
    end
  end
  if surround then emitter:add(')') end
end

local generator = {}

local function emit_features_setup(context)
  local emitter = CEmitter(context)
  do -- warnings
    emitter:add_ln('#ifdef __GNUC__')
      -- throw error on implict declarations
      emitter:add_ln('#pragma GCC diagnostic error   "-Wimplicit-function-declaration"')
      emitter:add_ln('#pragma GCC diagnostic error   "-Wimplicit-int"')
      -- importing C functions can cause this warn
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wincompatible-pointer-types"')
      -- C zero initialization for anything
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wmissing-braces"')
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wmissing-field-initializers"')
      -- usage of no_sanitize_memory/no_sanitize_address cause this warning
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wattributes"')
      -- the code generator may generate unused variables, parameters, functions
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused-parameter"')
      emitter:add_ln('#if defined(__clang__)')
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused"')
      emitter:add_ln('#else')
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused-variable"')
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused-function"')
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused-but-set-variable"')
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wunused-label"')
        -- for ignoring const* on pointers
        emitter:add_ln('#pragma GCC diagnostic ignored "-Wdiscarded-qualifiers"')
      emitter:add_ln('#endif')
      -- the code generator may generate always true/false expressions for integers
      emitter:add_ln('#pragma GCC diagnostic ignored "-Wtype-limits"')
    emitter:add_ln('#endif')
  end
  do -- static assert macro
    emitter:add([[#if __STDC_VERSION__ >= 201112L
#define nelua_static_assert _Static_assert
#else
#define nelua_static_assert(x, y)
#endif
]])
    emitter:add_ln('nelua_static_assert(sizeof(void*) == ', primtypes.pointer.size,
                ', "Nelua and C disagree on architecture size");')
  end
  context:add_declaration(emitter:generate())
end

local function emit_main(ast, context)
  emit_features_setup(context)
  context:add_include('<stddef.h>')
  context:add_include('<stdint.h>')
  context:add_include('<stdbool.h>')

  local mainemitter = CEmitter(context, -1)
  context.mainemitter = mainemitter

  if not context.entrypoint or context.hookmain then
    mainemitter:inc_indent()
    mainemitter:add_ln("int nelua_main() {")
    mainemitter:add_traversal(ast)
    if not context.rootscope.has_return then
      -- main() must always return an integer
      mainemitter:inc_indent()
      mainemitter:add_indent_ln("return 0;")
      mainemitter:dec_indent()
    end
    mainemitter:add_ln("}")
    mainemitter:dec_indent()

    context:add_declaration('int nelua_main();\n')
  else
    mainemitter:inc_indent()
    mainemitter:add_traversal(ast)
    mainemitter:dec_indent()
  end

  if not context.entrypoint then
    mainemitter:add_indent_ln('int main(int argc, char **argv) {')
    mainemitter:inc_indent(2)
    mainemitter:add_indent_ln('return nelua_main();')
    mainemitter:dec_indent(2)
    mainemitter:add_indent_ln('}')
  end

  if not context.entrypoint or context.hookmain then
    context:add_definition(mainemitter:generate())
  end
end

function generator.generate(ast, context)
  CContext.promote_context(context, visitors, typevisitors)

  emit_main(ast, context)

  context:evaluate_templates()

  local code = table.concat({
    '/* ------------------------------ DECLARATIONS ------------------------------ */\n',
    table.concat(context.declarations),
    '/* ------------------------------ DEFINITIONS ------------------------------- */\n',
    table.concat(context.definitions)
  })

  return code, context.compileopts
end

generator.compiler = require('nelua.ccompiler')

return generator
