# zig-json

Simple JSON parsing library with a focus on a simple, usable API.

_Note: The simple and usable part is a WIP :)_

# Importing

1. Clone the repo

```bash
mkdir deps
git clone --depth 1 git@github.com:berdon/zig-json.git ./deps/zig-json
```

2. Update build.zig

```zig
exe.addPackagePath("json", "deps/zig-json/src/main.zig");
```


# Usage

```zig
const json = @import("json");

// ...

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(!gpa.deinit());
const allocator = gpa.allocator();

const value = try json.parse("{\"foo\": [null, true, false, \"bar\", {\"baz\": -13e+37}]}", allocator);
const bazObj = value.get("foo").get(4);

bazObj.print(null);
try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

defer {
    value.deinit(allocator);
    allocator.destroy(value);
}
```

```bash
{
  "baz": -130000000000000000000000000000000000000
}%
```