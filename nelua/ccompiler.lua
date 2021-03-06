local pegger = require 'nelua.utils.pegger'
local stringer = require 'nelua.utils.stringer'
local fs = require 'nelua.utils.fs'
local except = require 'nelua.utils.except'
local executor = require 'nelua.utils.executor'
local tabler = require 'nelua.utils.tabler'
local sstream = require 'nelua.utils.sstream'
local console = require 'nelua.utils.console'
local config = require 'nelua.configer'.get()
local cdefs = require 'nelua.cdefs'
local memoize = require 'nelua.utils.memoize'
local version = require 'nelua.version'

local compiler = {
  source_extension = '.c'
}

function compiler.has_source_extension(filename)
  return filename:find('%.[ch]$')
end

local function get_compiler_cflags(compileopts)
  local ccinfo = compiler.get_cc_info()
  local compiler_flags = cdefs.compilers_flags[config.cc] or cdefs.compiler_base_flags
  local cflags = sstream()
  --luacov:disable
  for _,cfile in ipairs(compileopts.cfiles) do
    cflags:add(' "'..cfile..'"')
  end
  for _,incdir in ipairs(compileopts.incdirs) do
    cflags:add(' -I "'..incdir..'"')
  end
  cflags:add(' '..compiler_flags.cflags_base)
  if config.maximum_performance then
    cflags:add(' '..compiler_flags.cflags_maximum_performance)
    if config.cflags_maximum_performance then
      cflags:add(' '..config.cflags_maximum_performance)
    end
  elseif config.release then
    cflags:add(' '..compiler_flags.cflags_release)
    if config.cflags_release then
      cflags:add(' '..config.cflags_release)
    end
  else
    cflags:add(' '..compiler_flags.cflags_debug)
    if config.cflags_debug then
      cflags:add(' '..config.cflags_debug)
    end
  end
  if config.shared then
    cflags:add(' -shared -fPIC')
  elseif config.static then
    cflags:add(' -c')
  end
  if #config.cflags > 0 then
    cflags:add(' '..config.cflags)
  end
  --luacov:enable
  if #compileopts.cflags > 0 then
    cflags:add(' ')
    cflags:addlist(compileopts.cflags, ' ')
  end
  if not config.static then
    if #compileopts.ldflags > 0 then
      cflags:add(' -Wl,')
      cflags:addlist(compileopts.ldflags, ',')
    end
    if #compileopts.linklibs > 0 then
      cflags:add(' -l')
      cflags:addlist(compileopts.linklibs, ' -l')
    end
    if ccinfo.is_linux then -- always link math library on linux
      cflags:add(' -lm')
    end
  end
  return cflags:tostring():sub(2)
end

local function get_compile_args(cfile, binfile, cflags)
  local env = { cfile = cfile, binfile = binfile, cflags = cflags, cc = config.cc }
  return pegger.substitute('$(cc) "$(cfile)" -o "$(binfile)" $(cflags)', env)
end

local function get_cc_defines(cc, ...)
  local tmpname = fs.tmpname()
  local code = {}
  for i=1,select('#', ...) do
    local header = select(i, ...)
    code[#code+1] = '#include ' .. header
  end
  fs.ewritefile(tmpname, table.concat(code))
  local ext = cc:find('%+%+') and 'c++' or 'c'
  local cccmd = string.format('%s -x %s -E -dM %s', cc, ext, tmpname)
  local ok, ret, stdout, stderr = executor.execex(cccmd)
  fs.deletefile(tmpname)
  if not ok or ret ~= 0 then
    except.raisef("failed to retrieve compiler information: %s", stderr or '')
  end
  return pegger.parse_c_defines(stdout)
end
get_cc_defines = memoize(get_cc_defines)

function compiler.get_cc_defines(...)
  local cc = config.cc
  if config.cflags and #config.cflags > 0 then
    cc = cc..' '..config.cflags
  end
  return get_cc_defines(cc, ...)
end

local function get_cc_info(cc, cflags)
  -- parse compiler defines to detect target features
  if cflags and #cflags > 0 then
    cc = cc..' '..config.cflags
  end
  local ccdefs = get_cc_defines(cc)
  local ccinfo = {
    defines = ccdefs,
    is_win32 = not not (ccdefs.__WIN32__ or ccdefs.__WIN32 or ccdefs.WIN32),
    is_win64 = not not (ccdefs.__WIN64__ or ccdefs.__WIN64 or ccdefs.WIN64),
    is_mingw = not not (ccdefs.__MINGW64__ or ccdefs.__MINGW32__),
    is_linux = not not (ccdefs.__linux__ or ccdefs.__linux or ccdefs.linux),
    is_unix = not not (ccdefs.__unix__ or ccdefs.__unix or ccdefs.unix),
    is_apple = not not (ccdefs.__APPLE__),
    is_mach = not not (ccdefs.__MACH__),
    is_gnu_linux = not not (ccdefs.__gnu_linux__),
    is_clang = not not (ccdefs.__clang__),
    is_gcc = not not (ccdefs.__GNUC__),
    is_tcc = not not (ccdefs.__TINYC__),
    is_emscripten = not not (ccdefs.__EMSCRIPTEN__),
    is_wasm = not not (ccdefs.__wasm__ or ccdefs.__wasm),
    is_x86_64 = not not (ccdefs.__x86_64__ or ccdefs.__x86_64 or ccdefs._M_X64),
    is_x86_32 = not not (ccdefs.__i386__ or ccdefs.__i386 or ccdefs._M_X86),
    is_arm = not not (ccdefs.__ARM_EABI__ or ccdefs.__aarch64__),
    is_arm64 = not not (ccdefs.__aarch64__),
    is_riscv = not not (ccdefs.__riscv),
    is_cpp = not not (ccdefs.__cplusplus),
  }
  ccinfo.is_windows = ccinfo.is_win32
  return ccinfo
end
get_cc_info = memoize(get_cc_info)

function compiler.get_cc_info()
  return get_cc_info(config.cc, config.cflags)
end

function compiler.generate_code(ccode, cfile, compileopts)
  local ccinfo = compiler.get_cc_info().text
  local cflags = get_compiler_cflags(compileopts)
  local binfile = cfile:gsub('.c$','')
  local ccmd = get_compile_args(cfile, binfile, cflags)
  -- file heading
  local hash = stringer.hash(string.format("%s%s%s", ccode, ccinfo, ccmd))
  local heading = string.format(
[[/* Generated by %s */
/* Compile command: %s */
/* Compile hash: %s */
]], version.NELUA_VERSION, ccmd, hash)
  local sourcecode = heading .. ccode
  -- check if write is actually needed
  local current_sourcecode = fs.readfile(cfile)
  if not config.no_cache and current_sourcecode and current_sourcecode == sourcecode then
    if config.verbose then console.info("using cached generated " .. cfile) end
    return cfile
  end
  -- create file
  fs.eensurefilepath(cfile)
  fs.ewritefile(cfile, sourcecode)
  if config.verbose then console.info("generated " .. cfile) end
end

local function detect_binary_extension(outfile, ccinfo)
  --luacov:disable
  if ccinfo.is_wasm then
    if outfile:match('%.wasm$') then
      return '.wasm', true
    else
      return '.html', true
    end
  elseif ccinfo.is_windows then
    if config.shared then
      return '.dll'
    elseif config.static then
      return '.a'
    else
      return '.exe', true
    end
  elseif ccinfo.is_apple then
    if config.shared then
      return '.dylib'
    elseif config.static then
      return '.a'
    else
      return '', true
    end
  else
    if config.shared then
      return '.so'
    elseif config.static then
      return '.a'
    else
      return '', true
    end
  end
  --luacov:enable
end

function compiler.compile_static_library(objfile, outfile)
  local ar = config.cc:gsub('[a-z+]+$', 'ar')
  local arcmd = string.format('%s rcs %s %s', ar, outfile, objfile)
  if config.verbose then console.info(arcmd) end
  -- compile the file
  local success, status, _, stderr = executor.execex(arcmd)
  if not success or status ~= 0 then --luacov:disable
    except.raisef("static library compilation for '%s' failed:\n%s", outfile, stderr or '')
  end --luacov:enable
  if stderr then
    io.stderr:write(stderr)
  end
end

function compiler.compile_binary(cfile, outfile, compileopts)
  local cflags = get_compiler_cflags(compileopts)
  local ccinfo = compiler.get_cc_info()
  local binext, isexe = detect_binary_extension(outfile, ccinfo)
  local binfile = outfile
  if not stringer.endswith(binfile, binext) then binfile = binfile .. binext end
  -- if the file with that hash already exists skip recompiling it
  if not config.no_cache then
    local cfile_mtime = fs.getmodtime(cfile)
    local binfile_mtime = fs.getmodtime(binfile)
    if cfile_mtime and binfile_mtime and cfile_mtime <= binfile_mtime then
      if config.verbose then console.info("using cached binary " .. binfile) end
      return binfile, isexe
    end
  end
  -- ensure the directory exists for the binary file
  fs.eensurefilepath(binfile)
  -- we may use an intermediary file
  local midfile = binfile
  if config.static then -- compile to an object first for static libraries
    midfile = binfile:gsub('.[a-z]+$', '.o')
  end
  -- generate compile command
  local cccmd = get_compile_args(cfile, midfile, cflags)
  if config.verbose then console.info(cccmd) end
  -- compile the file
  local success, status, _, stderr = executor.execex(cccmd)
  if not success or status ~= 0 then --luacov:disable
    except.raisef("C compilation for '%s' failed:\n%s", binfile, stderr or '')
  end --luacov:enable
  if stderr then
    io.stderr:write(stderr)
  end
  -- compile static library
  if config.static then
    compiler.compile_static_library(midfile, binfile)
    fs.deletefile(midfile)
  end
  return binfile, isexe
end

function compiler.get_gdb_version() --luacov:disable
  local ok, ret, stdout = executor.execex(config.gdb .. ' -v')
  if ok and ret and stdout:match("GNU gdb") then
    return stdout:match('%d+%.%d+')
  end
end --luacov:enable

function compiler.get_run_command(binaryfile, runargs)
  binaryfile = fs.abspath(binaryfile)
  -- run with a gdb?
  if config.debug then --luacov:disable
    local gdbver = compiler.get_gdb_version()
    if gdbver then
      local gdbargs = {
        '-q',
        '-ex', 'set confirm off',
        '-ex', 'set breakpoint pending on',
        '-ex', 'break abort',
        '-ex', 'run',
        '-ex', 'bt -frame-info source-and-location',
        '-ex', 'quit',
        '--args', binaryfile,
      }
      tabler.insertvalues(gdbargs, runargs)
      return config.gdb, gdbargs
    end
  end --luacov:enable
  -- choose the runner
  local exe, args
  if binaryfile:match('%.html$') then  --luacov:disable
    exe = 'emrun'
    args = tabler.insertvalues({binaryfile}, runargs)
  elseif binaryfile:match('%.wasm$') then
    exe = 'wasmer'
    args = tabler.insertvalues({binaryfile}, runargs)
  else --luacov:enable
    exe = binaryfile
    args = tabler.icopy(runargs)
  end
  return exe, args
end

return compiler
