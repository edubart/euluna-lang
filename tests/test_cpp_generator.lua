require 'tests/testcommon'
require 'busted.runner'()

describe("Euluna C++ code generator", function()
  it("should generate empty code", function()
    assert_generate_cpp({}, [[
int main() {
    return 0;
}
    ]])
  end)

  it("should generate simple codes", function()
    assert_generate_cpp([[
      print('hello world')
    ]], [[
#include <iostream>
#include <string>

int main() {
    std::cout << std::string("hello world") << std::endl;
    return 0;
}
    ]])
  end)

  it("should return the correct values", function()
    assert_generate_cpp_and_run("", '', 0)
    assert_generate_cpp_and_run("return", '', 0)
    assert_generate_cpp_and_run("return 0", '', 0)
    assert_generate_cpp_and_run("return 1", '', 1)
  end)

  describe("should compile and run example", function()
    it("hello world", function()
      assert_generate_cpp_and_run("print('hello world')", 'hello world\n')
    end)

    it("primitives", function()
      assert_generate_cpp_and_run([[
        local b = true
        local i   = 1_i   + 1_int   + 1 + 0x1
        local u   = 1_u   + 1_uint
        local i8  = 1_i8  + 1_int8
        local i16 = 1_i16 + 1_int16
        local i32 = 1_i32 + 1_int32
        local i64 = 1_i64 + 1_int64
        local u8  = 1_u8  + 1_uint8
        local u16 = 1_u16 + 1_uint16
        local u32 = 1_u32 + 1_uint32
        local u64 = 1_u64 + 1_uint64
        local is  = 1_isize
        local us  = 1_usize
        local f = 0.2_f32 + 0.4_float32
        local d = 0.2_f64 + 0.4_float64
        local s = 's1' + "s2"
        local c = 65_c
        local c2 = 'A'_c
        local a = [1, 2, 3]
        local n = nil
        discard n
        print(b, i, u, i8, i16, i32, i64, u8, u16, u32, u64, is, us, f, d, s, c, c2, a)
      ]], "true\t4\t2\t2\t2\t2\t2\t2\t2\t2\t2\t1\t1\t0.6\t0.6\ts1s2\tA\tA\t[1, 2, 3]")
    end)

    it("casting with as", function()
      assert_generate_cpp_and_run([[
        local b = 1 as bool
        local i = 8.9 as int
        print(b,i)
      ]], "true\t8")
    end)

    it("arrays", function()
      assert_generate_cpp_and_run([[
        local a = [1,2,3]
        print(a)
        print(#a)
        print(a[0])
        a[0] = 9
        print(a[0])

        local b = [5] of double
        print(b[0])
      ]], '[1, 2, 3]\n3\n1\n9\n5')
    end)

    it("nested arrays", function()
      assert_generate_cpp_and_run([=[
        local a = [ [1],[2],[3] ]
        print(a)
        print(#a)
      ]=], '[[1], [2], [3]]\n3')
    end)

    it("tables", function()
      assert_generate_cpp_and_run([=[
        local a = {1, 2}
        print(a[0])
        a[0] = 9
        print(a[0])
        print(#a)
        local m = {a="1", b="2"}
        print(m["a"])
        m["a"] = "X"
        print(m["a"])

        local a2 = {1,2} of double
      ]=], '1\n9\n2\n1\nX')
    end)

    it("expressions", function()
      assert_generate_cpp_and_run([[
        local a = -(-1)
        local s = $1 .. $2
        print(a, s)
      ]], '1\t12')
    end)

    it("escaped strings", function()
      assert_generate_cpp_and_run([[
        print('\\ \a\b\f\n\r\t\v\'\"??!\x1\x2\x3\x0')
      ]], '\\ \a\b\f\n\r\t\v\'\"??!\01\02\03')
    end)

    it("swapping values", function()
      assert_generate_cpp_and_run([[
        local a, b, c = 1, 2, 3
        a, c, b = c, a, c
        print(a,b,c)
      ]], "3\t3\t1")
    end)

    it("const expressions", function()
      assert_generate_cpp_and_run([[
        const a = 1 + 2 + 3
        print(a)
      ]], "6")
    end)

    it("numeric fors", function()
      assert_generate_cpp_and_run([[
        local s = 0
        for i=1,10 do
          s = s + i
        end
        print(s)

        s=0
        for i=1,<10,1 do
          s = s + i
        end
        print(s)

        s=0
        for i=1,~=10 do
          s = s + i
        end
        print(s)

        s=0
        for i=10,>=0,-1 do
          s = s + i
        end
        print(s)

        function proxy(i) return i end
        s=0
        for i=10,>=proxy(0),-1 do
          s = s + i
        end
        print(s)
      ]], '55\n45\n45\n55\n55')
    end)

    it("if statements", function()
      assert_generate_cpp_and_run([[
        for i=1,4 do
          if i == 1 then
            print('1')
          elseif i == 2 then
            print('2')
          elseif i == 3 then
            print('3')
          else
            print('else')
          end
        end
        print(1 if true else 2)
        print(1 if false else 2)
      ]], '1\n2\n3\nelse\n1\n2')
    end)

    it("switch statements", function()
      assert_generate_cpp_and_run([[
        for i=1,4 do
          switch i
          case 1 then
            print('1')
          case 2 then
            print('2')
          case 3 then
            print('3')
          else
            print('else')
          end
        end
      ]], '1\n2\n3\nelse')
    end)

    it("try and throw", function()
      assert_generate_cpp_and_run([[
        try
          print('try')
          throw 'err'
          print('never runned')
        catch
          print('catchall')
        finally
          print('finally')
        end
      ]], 'try\ncatchall\nfinally')
    end)

    it("do blocks", function()
      assert_generate_cpp_and_run([[
        do
          print('hello')
        end
      ]], 'hello')
    end)

    it("while loops", function()
      assert_generate_cpp_and_run([[
        local i = 0
        while i < 10 do
          i = i + 1
        end
        print(i)
      ]], '10')
    end)

    it("repeat loops", function()
      assert_generate_cpp_and_run([[
        local i = 0
        repeat
          i = i + 1
        until i==10
        print(i)
      ]], '10')
    end)

    it("for in loops", function()
      assert_generate_cpp_and_run([[
        local a = "123"
        for c in items(a) do
          print(c)
        end
      ]], '1\n2\n3')
    end)

    it("goto", function()
      assert_generate_cpp_and_run([[
        for i=0,<3 do
          for j=0,<3 do
            print(i .. j)
            if i+j >= 3 then
              goto endloop
            end
          end
        end
        ::endloop::
      ]], '00\n01\n02\n10\n11\n12')
    end)

    it("breaking and continuing loops", function()
      assert_generate_cpp_and_run([[
        for i=1,10 do
          if i > 5 then break end
          print(i)
        end
        for i=1,10 do
          if i <= 5 then continue end
          print(i)
        end
      ]], '1\n2\n3\n4\n5\n6\n7\n8\n9\n10')
    end)

    it("defer", function()
      assert_generate_cpp_and_run([[
        defer
          print('world')
        end
        print('hello')
      ]], 'hello\nworld')
    end)

    it("binary operators", function()
      assert_generate_cpp_and_run([[
        local s = 1 .. 2 .. 3
        local slen = #s
        local d = 2 ^ 2
        print(s, slen, d)
      ]], "123\t3\t4")
    end)

    it("function early return", function()
      assert_generate_cpp_and_run([[
        function hello()
          print('hello')
          if true then return end
          print('world')
        end
        hello()
      ]], "hello")
    end)

    it("functions", function()
      assert_generate_cpp_and_run([[
        function sum(a, b)
          return a+b
        end
        print(sum(1,2))
      ]], "3")
    end)

    it("function as value", function()
      assert_generate_cpp_and_run([[
        local sum = function(a, b)
          return a+b
        end
        print(sum(1,2))
      ]], "3")
    end)

    it("return multiple values", function()
      assert_generate_cpp_and_run([[
        function f(i)
          return i+1, i+2
        end
        local a, b = f(0)
        print(a,b)
      ]], "1\t2")
    end)

    it("example1", function()
      assert_generate_cpp_and_run([[
        for i=1,10 do
          if i % 3 == 0 then
            print(3)
          elseif i % 2 == 0 then
            print(2)
          else
            print(1)
          end
        end
      ]], "1\n2\n3\n2\n1\n3\n1\n2\n3\n2")
    end)
  end)
end)
