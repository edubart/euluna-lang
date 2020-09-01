local ASTBuilder = require 'nelua.astbuilder'

local astbuilder = ASTBuilder()
local stypes = astbuilder.shapetypes
local ntypes = stypes.node

-- primitives
astbuilder:register('Number', {
  stypes.one_of{"dec", "bin", "hex"}, -- number base
  stypes.string:is_optional(), -- integer part
  stypes.string:is_optional(), -- fractional part
  stypes.string:is_optional(), -- exponential part
  stypes.string:is_optional() -- literal
})
astbuilder:register('String', {
  stypes.string, -- value
  stypes.string:is_optional() -- literal
})
astbuilder:register('Boolean', {
  stypes.boolean, -- true or false
})
astbuilder:register('Nil', {})
astbuilder:register('Varargs', {})

-- preprocess
astbuilder:register('Preprocess', {
  stypes.string, -- code
})
astbuilder:register('PreprocessExpr', {
  stypes.string, -- code
})
astbuilder:register('PreprocessName', {
  stypes.string, -- code
})

-- indexing
astbuilder:register('DotIndex', {
  stypes.string + ntypes.PreprocessName, -- name
  ntypes.Node -- expr
})
astbuilder:register('ColonIndex', {
  stypes.string + ntypes.PreprocessName, -- name
  ntypes.Node -- expr
})
astbuilder:register('ArrayIndex', {
  ntypes.Node, -- index expr
  ntypes.Node -- expr
})

-- table
astbuilder:register('Table', {
  stypes.array_of(ntypes.Node) -- pair or exprs
})
astbuilder:register('Pair', {
  ntypes.Node + stypes.string + ntypes.PreprocessName, -- field name (an expr or a string)
  ntypes.Node -- field value expr
})

-- annotation
astbuilder:register('Annotation', {
  stypes.string + ntypes.PreprocessName, -- name
  stypes.array_of(ntypes.String + ntypes.Number + ntypes.Boolean + ntypes.PreprocessExpr) -- args
})

-- used inerally internal
astbuilder:register('PragmaCall', {
  stypes.string, -- name
  stypes.table, -- args exprs
})

-- identifier and types
astbuilder:register('Id', {
  stypes.string + ntypes.PreprocessName, -- name
})
astbuilder:register('IdDecl', {
  stypes.string + ntypes.PreprocessName + ntypes.DotIndex, -- name
  ntypes.Node:is_optional(), -- typexpr
  stypes.array_of(ntypes.Annotation):is_optional(),
})
astbuilder:register('Paren', {
  ntypes.Node -- expr
})

-- types
astbuilder:register('Type', {
  stypes.string + ntypes.PreprocessName, -- type name
})
astbuilder:register('TypeInstance', {
  ntypes.Node, -- typexpr
})
astbuilder:register('FuncType', {
  stypes.array_of(ntypes.Node), -- arguments types
  stypes.array_of(ntypes.Node), -- returns types
})
astbuilder:register('RecordFieldType', {
  stypes.string + ntypes.PreprocessName, -- field name
  ntypes.Node, -- field typexpr
})
astbuilder:register('RecordType', {
  stypes.array_of(ntypes.RecordFieldType), -- field types
})
astbuilder:register('UnionFieldType', {
  (stypes.string + ntypes.PreprocessName):is_optional(), -- field name
  ntypes.Node, -- field typexpr
})
astbuilder:register('UnionType', {
  stypes.array_of(ntypes.Node), -- union field types or typexpr
})
astbuilder:register('EnumFieldType', {
  stypes.string + ntypes.PreprocessName, -- field name
  ntypes.Node:is_optional() -- field numeric value expr
})
astbuilder:register('EnumType', {
  ntypes.Type:is_optional(), -- primitive type
  stypes.array_of(ntypes.EnumFieldType), -- field types
})
astbuilder:register('ArrayType', {
  ntypes.Node, -- subtype typeexpr
  ntypes.Node, -- size expr
})
astbuilder:register('PointerType', {
  ntypes.Node:is_optional(), -- subtype typexpr
})
astbuilder:register('OptionalType', {
  ntypes.Node -- subtype typexpr
})
astbuilder:register('GenericType', {
  stypes.string + ntypes.PreprocessName, -- generic name
  stypes.array_of(ntypes.Node), -- list of typexpr or param expr
})

-- function
astbuilder:register('Function', {
  stypes.array_of(ntypes.IdDecl + ntypes.Varargs), -- typed arguments
  stypes.array_of(ntypes.Node), -- typed returns
  stypes.array_of(ntypes.Annotation):is_optional(),
  ntypes.Node, -- block
})

-- calls
astbuilder:register('Call', {
  stypes.array_of(ntypes.Node), -- args exprs
  ntypes.Node, -- caller expr
})
astbuilder:register('CallMethod', {
  stypes.string + ntypes.PreprocessName, -- method name
  stypes.array_of(ntypes.Node), -- args exprs
  ntypes.Node, -- caller expr
})

-- block
astbuilder:register('Block', {
  stypes.array_of(ntypes.Node) -- statements
})

-- statements
astbuilder:register('Return', {
  stypes.array_of(ntypes.Node) -- returned exprs
})
astbuilder:register('If', {
  stypes.array_of(stypes.shape{ntypes.Node, ntypes.Block}), -- if list {expr, block}
  ntypes.Block:is_optional() -- else block
})
astbuilder:register('Do', {
  ntypes.Block -- block
})
astbuilder:register('Defer', {
  ntypes.Block -- block
})
astbuilder:register('While', {
  ntypes.Node, -- expr
  ntypes.Block -- block
})
astbuilder:register('Repeat', {
  ntypes.Block, -- block
  ntypes.Node -- expr
})
astbuilder:register('ForNum', {
  ntypes.IdDecl, -- iterated var
  ntypes.Node, -- begin expr
  stypes.one_of{"lt", "ne", "gt", "le", "ge"}:is_optional(), -- compare operator
  ntypes.Node, -- end expr
  ntypes.Node:is_optional(), -- increment expr
  ntypes.Block, -- block
})
astbuilder:register('ForIn', {
  stypes.array_of(ntypes.IdDecl):is_optional(), -- iteration vars
  stypes.array_of(ntypes.Node), -- in exprlist
  ntypes.Block -- block
})
astbuilder:register('Break', {})
astbuilder:register('Label', {
  stypes.string + ntypes.PreprocessName -- label name
})
astbuilder:register('Goto', {
  stypes.string + ntypes.PreprocessName -- label name
})
astbuilder:register('VarDecl', {
  stypes.one_of{"local","global"}:is_optional(), -- scope
  stypes.array_of(ntypes.IdDecl), -- var names with types
  stypes.array_of(ntypes.Node):is_optional(), -- expr list, initial assignments values
})
astbuilder:register('Assign', {
  stypes.array_of(ntypes.Node), -- expr list, assign variables
  stypes.array_of(ntypes.Node), -- expr list, assign values
})
astbuilder:register('FuncDef', {
  stypes.one_of{"local","global"}:is_optional(), -- scope
  ntypes.IdDecl + ntypes.Id + ntypes.DotIndex + ntypes.ColonIndex, -- name
  stypes.array_of(ntypes.IdDecl + ntypes.Varargs), -- typed arguments
  stypes.array_of(ntypes.Node), -- typed returns
  stypes.array_of(ntypes.Annotation):is_optional(),
  ntypes.Block -- block
})

-- operations
astbuilder:register('UnaryOp', {
  stypes.string, -- opname
  ntypes.Node -- right expr
})
astbuilder:register('BinaryOp', {
  stypes.string, -- opname
  ntypes.Node, --- left expr
  ntypes.Node -- right expr
})

-- nelua extesions to lua
astbuilder:register('Switch', {
  ntypes.Node, -- switch expr
  stypes.array_of(stypes.shape{ stypes.array_of(ntypes.Node), ntypes.Block}), -- case list {expr list, block}
  ntypes.Block:is_optional() -- else block
})

astbuilder:register('Continue', {})

return astbuilder
