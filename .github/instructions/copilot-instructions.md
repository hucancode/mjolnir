__This file is used to teach GitHub Copilot or other AI assistants__

# Odin features
variable declaration
```odin
a: int = 42
b: int = 43
c: int = a + b
d := a + b + c // type can be inferred
e := 12 + 13 // type can be inferred
f := [4]f32{ 1.0, 2.0, 3.0, 4.0 } // type can be inferred
```
Array swizzling
```odin
speed: [3]f32
log.info("speed 2d", speed[0:2]) // syntactically correct but not recommended
log.info("speed 2d", speed.xy)
log.info("speed 3d", speed.xyz)
log.info("speed 3d", speed.rgb) // syntactically correct but who would do that?
color: [4]f32
log.info("color rgb", color[0:3]) // syntactically correct but not recommended
log.info("color rgb", color.rgb)
log.info("color rgb", color.rgba)
```
return values propagation
```odin
do_a :: proc() -> vk.Result {
    log.info("do_a")
    return .SUCCESS
}
do_b :: proc() -> bool {
    log.info("do_b")
    return .ERROR_UNKNOWN
}
do_all_verbose :: proc() -> vk.Result {
    result_a := do_a()
    if result_a != .SUCCESS {
        return result_a
    }
    result b := do_b()
    if result_b != .SUCCESS {
        return result_b
    }
    return .SUCCESS
}
// equivalent to the above
do_all :: proc() -> vk.Result {
    do_a() or_return
    do_b() or_return
    return .SUCCESS
}
```
code access
```odin
// my_folder/my_file.odin
my_function :: proc() {
    log.info("my_function")
}
MyStruct :: struct {
    my_field: int,
}
// my_folder/my_other_file.odin
my_other_function :: proc() {
    log.info("my_other_function")
    my_function() // we can access the function in the same folder without doing anything special
    x : MyStruct // we can access the struct in the same folder without doing anything special
    log.info("my_field", x.my_field)
}
```
package declaration must be at the top of the file
the following code will compile
```odin
package my_package
my_function :: proc() {
    log.info("my_function")
}
```
the following code will not compile
```odin
my_function :: proc() {
    log.info("my_function")
}
package my_package
```
slice pointer access
```odin
my_function :: proc(n: int, ptr: ^int) {
    log.info("this function require a size and a pointer to an int")
}
my_slice := [4]int{ 1, 2, 3, 4 }
my_function(len(my_slice), raw_data(my_slice)) // use raw_data to get a pointer to the slice data
```
procedure parameters are passed by immutable reference by default
```odin
MyStruct :: struct {
    a: i32,
    b: i32,
    c: f32,
    d: f32,
}
my_function :: proc(my_data: MyStruct) {
    log.info("my_function", my_data.a, my_data.b, my_data.c, my_data.d)
    // my_data.a = 42 // this will not compile, my_data is immutable
    my_mutable_data := my_data // this will compile, my_mutable_data is a mutable copy of my_data
    my_mutable_data.a = 42 // this will compile, but we are modifying a copy, not the original data
}
my_function2 :: proc(my_data: ^MyStruct) {
    log.info("my_function", my_data.a, my_data.b, my_data.c, my_data.d)
    my_data.a = 42 // this will compile and modify the original data
}
```
ranges and loops
```odin
// the following code are equivalent
my_slice := [4]int{ 1, 2, 3, 4 }
for v,i in my_slice {
    log.infof("my_slice[%d] = %d", i, v)
}
// use exclusive range
for i in 0..<len(my_slice) {
    log.info("my_slice[%d] = %d", i, my_slice[i])
}
// use inclusive range
for i in 0..=len(my_slice)-1 {
    log.info("my_slice[%d] = %d", i, my_slice[i])
}
// use a for loop with full control
for i := 0; i < len(my_slice); i += 1 {
    log.info("my_slice[%d] = %d", i, my_slice[i])
}
// if you care only about the value, you can use the following syntax
for v in my_slice {
    log.infof("v = %d", v)
}
// you can use `do` keyword for single statement
for v in my_slice do log.infof("v = %d", v)
```
short hand do keyword
```odin
// the following code are equivalent
if a > b do log.info("a is greater than b")
if a > b {
    log.info("a is greater than b")
}
// the following code are equivalent
for i in 0..<10 do log.infof("i = %d", i)
for i in 0..<10 {
    log.infof("i = %d", i)
}
```
slice and dynamic slice
```odin
// dynamic slice can be append after creation, this is not recommended for performance critical code
my_slice := make([dynamic]f32, 0)
defer delete(my_slice)
append(&my_slice, 10.0)
log.infof("%v", my_slice)
// fixed slice can not be append after creation, but we can create with a good size at creation time, this is not recommended for performance critical code but it is better than dynamic slice
my_slice_fixed := make([]f32, 1)
defer delete(my_slice_fixed)
my_slice_fixed[0] = 10.0
log.infof("%v", my_slice_fixed)
// static array must be specify with size at compile time, this is the fastest
my_array := [1]f32
my_array[0] = 10.0
log.infof("%v", my_array)
```
