local class = require 'euluna.utils.class'
local traits = require 'euluna.utils.traits'
local iters = require 'euluna.utils.iterators'
local Scope = require 'euluna.scope'

local TraverseContext = class()

local function traverser_default_visitor(self, ast, ...)
  local nargs = traits.is_astnode(ast) and ast.nargs or #ast
  for _,arg in iters.inpairs(ast, nargs) do
    --print(traits.is_astnode(ast) and ast.tag or 'list', nargs, _)
    if traits.is_astnode(arg) then
      self:traverse(arg, ...)
    elseif traits.is_table(arg) then
      traverser_default_visitor(self, arg, ...)
    end
  end
end

function TraverseContext:_init(visitors, default_visitor)
  self.scope = Scope()
  self.visitors = visitors
  if default_visitor == true then
    self.default_visitor = traverser_default_visitor
  end
  self.asts = {}
end

function TraverseContext:push_scope(kind)
  local scope = self.scope:fork(kind)
  self.scope = scope
  return scope
end

function TraverseContext:pop_scope()
  self.scope = self.scope.parent
end

function TraverseContext:push_ast(ast)
  table.insert(self.asts, ast)
end

function TraverseContext:pop_ast()
  table.remove(self.asts)
end

function TraverseContext:get_parent_ast()
  return self.asts[#self.asts - 1]
end

function TraverseContext:iterate_parent_asts()
  local i = #self.asts
  return function(asts)
    i = i - 1
    if i <= 0 then return nil end
    return asts[i]
  end, self.asts
end

function TraverseContext:get_parent_ast_if(f)
  for ast in self:iterate_parent_asts() do
    if f(ast) then return ast end
  end
end

function TraverseContext:traverse(ast, ...)
  assert(traits.is_astnode(ast), "trying to traverse a non ast value")
  local visitor_func = self.visitors[ast.tag] or self.default_visitor
  ast:assertf(visitor_func, "visitor for AST node '%s' does not exist", ast.tag)
  self:push_ast(ast)
  local ret = visitor_func(self, ast, ...)
  self:pop_ast()
  return ret
end

return TraverseContext