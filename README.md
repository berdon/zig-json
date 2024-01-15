# zig-json

Simple JSON ([RFC8259 Spec](https://www.rfc-editor.org/rfc/rfc8259)) and JSON5 ([JSON5 Spec](https://spec.json5.org)) parsing library with a focus on a simple, usable API.

_Note: The simple and usable part is a WIP :)_

# Importing

## Lagacy

1. Clone the repo

```bash
mkdir deps
git clone --depth 1 git@github.com:Klebestreifen/zig-json.git ./deps/zig-json
```

2. Update build.zig

```zig
exe.addPackagePath("json", "deps/zig-json/src/main.zig");
```

## Using Zig Packages

1. Add the dependency to your `build.zig.zon`.

```zig
.dependencies = .{
    .zigjson = .{
        .url = "https://codeload.github.com/Klebestreifen/zig-json/tar.gz/{FULL_COMMIT_HASH}",
        .hash = "12##################################################################",
    }
},
```

2. Select a commit you want to use and replace it in the URL
3. Try to build. You should get a `hash mismatch` error.
4. Replace the hash with the correct one shown in the error message.
5. Add the module to your artefact.

```zig
    // build.zig
    //   -> fn build
    //      b: *std.Build

    const zigJsonDep = b.dependency("zigjson", .{}); // "zigjson"-name declared in ".dependencies"
    
    // ...

    exe.addModule("json" /* is renameble; repressentation in code */, zigJsonDep.module(/* must be */ "zig-json"));
    // usage:
    //   const json = @import("json");
```

# Usage

```zig
const json = @import("json");

// ...

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(!gpa.deinit());
const allocator = gpa.allocator();

const value = try json.parse(
    \\{
    \\  "foo": [
    \\    null,
    \\    true,
    \\    false,
    \\    \"bar\",
    \\    {
    \\      "baz": -13e+37
    \\    }
    \\  ]
    \\}
    , allocator);
const bazObj = value.get("foo").get(4);

bazObj.print(null);
try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

defer value.deinit(allocator);
```

```bash
{
  "baz": -130000000000000000000000000000000000000
}%
```

## JSON5

```zig
const json = @import("json");

// ...

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(!gpa.deinit());
const allocator = gpa.allocator();

const value = try parseJson5(
    \\{
    \\  foo: [
    \\    /* Some
    \\     * multi-line comment
    \\     */ null,
    \\    true,
    \\    false,
    \\    "bar",
    \\    // Single line comment
    \\    {
    \\      baz: -13e+37,
    \\      'nan': NaN,
    \\      inf: +Infinity,
    \\    },
    \\  ],
    \\}
    , allocator);
const bazObj = value.get("foo").get(4);

bazObj.print(null);
try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

defer value.deinit(allocator);
```

```bash
{
  "baz": -130000000000000000000000000000000000000
}%
```

## Ownership

The parser returns a `*JsonValue` that you own and are expected to `deinit()` and `destroy()` when done. `deinit()` handles destroying all children.

# API

`json.parse([]const u8, std.mem.Allocator)` returns a `*JsonValue` struct.

## JsonValue

```zig
struct {
    /// The JSON value type
    type: JsonType,

    /// Destructor
    pub fn deinit(self: *JsonValue, allocator: Allocator) void { }

    /// Handy pass-thru to typed get(...) calls
    pub fn get(self: *JsonValue, index: anytype) *JsonValue { }

    /// Handy pass-thru to typed len(...) calls
    pub fn len(self: *JsonValue) usize { }

    /// Returns the string value or panics
    pub fn string(self: *JsonValue) []const u8 { }

    /// Returns the object value or panics
    pub fn object(self: *JsonValue) *JsonObject { }

    /// Returns the integer value or panics
    pub fn integer(self: *JsonValue) i64 { }

    /// Returns the float value or panics
    pub fn float(self: *JsonValue) f64 { }

    /// Returns the array value or panics
    pub fn array(self: *JsonValue) *JsonArray { }

    /// Returns the array value or panics
    pub fn boolean(self: *JsonValue) bool { }

    /// Returns the string value or null
    pub fn stringOrNull(self: *JsonValue) ?[]const u8 { }

    /// Returns the object value or null
    pub fn objectOrNull(self: *JsonValue) ?*JsonObject { }

    /// Returns the integer value or null
    pub fn integerOrNull(self: *JsonValue) ?i64 { }

    /// Returns the float value or null
    pub fn floatOrNull(self: *JsonValue) ?f64 { }

    /// Returns the array value or null
    pub fn arrayOrNull(self: *JsonValue) ?*JsonArray { }

    /// Returns the boolean value or null
    pub fn booleanOrNull(self: *JsonValue) ?bool { }

    /// Print the JSON value
    pub fn print(self: *JsonValue, indent: ?usize) void { }
};
```

If the JSON schema is known ahead of time, you can chain calls to `get(...)` to access the nested field you want (through `JsonObject` and `JsonArray`). To access the actual value you would call the typed accessors (e.g. `integer()`, `string()`, etc).

`object()` and `array()` return `*JsonObject` and `*JsonArray`s respectively.

## JsonType

```zig
enum {
    object,
    array,
    string,
    integer,
    float,
    boolean,
    nil
};
```

## JsonObject

```zig
struct {
    /// Destructor
    pub fn deinit(self: *JsonObject, allocator: Allocator) void { }

    /// Returns the number of members in the object
    pub fn len(self: *JsonObject) usize { }
    
    /// Whether the map contains the key or not
    pub fn contains(self: *JsonObject, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Return the value for key or panic
    pub fn get(self: *JsonObject, key: []const u8) *JsonValue { }

    /// Return the value for key or null
    pub fn getOrNull(self: *JsonObject, key: []const u8) ?*JsonValue { }

    /// Print out the JSON object
    /// TODO: Need to handle proper character escaping
    pub fn print(self: *JsonObject, indent: ?usize) void { }
};
```

## JsonArray

```zig
struct {
    /// Destructor
    pub fn deinit(self: *JsonArray, allocator: Allocator) void { }

    /// The length of the array
    pub fn len(self: *JsonArray) usize { }

    /// Return the items array directly ¯\_(ツ)_/¯
    pub fn items(self: *JsonArray) []*JsonValue { }

    /// Return the item at the index or panic if exceeding normal bounds
    pub fn get(self: *JsonArray, index: usize) *JsonValue { }

    /// Return the item at the index or null
    pub fn getOrNull(self: *JsonArray, index: usize) ?*JsonValue { }

    /// Return the first item or panic if none
    pub fn first(self: *JsonArray) *JsonValue { }

    /// Return the first item or null
    pub fn firstOrNull(self: *JsonArray) ?*JsonValue { }

    /// Print the JSON array
    pub fn print(self: *JsonArray, indent: ?usize) void { }
};
```