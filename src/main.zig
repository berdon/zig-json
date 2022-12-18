///! Simple JSON parsing library with a focus on a simple, usable API.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// RFC8259 - quotation mark
const TOKEN_DOUBLE_QUOTE = '"';
/// TODO: Probably remove support ¯\_(ツ)_/¯
const TOKEN_SINGLE_QUOTE = '\'';

/// RFC8259.2 - begin-object
const TOKEN_CURLY_BRACKET_OPEN = '{';
/// RFC8259.2 - end-object
const TOKEN_CURLY_BRACKET_CLOSE = '}';
/// RFC8259.2 - name-separator
const TOKEN_COLON = ':';

/// RFC8259.2 - begin-array
const TOKEN_BRACKET_OPEN = '[';
/// RFC8259.2 - end-array
const TOKEN_BRACKET_CLOSE = ']';
/// RFC8259.2 - value-separator
const TOKEN_COMMA = ',';

/// RFC8259.2 - Insignificant white space
const TOKEN_SPACE = '\u{20}';
/// RFC8259.2 - Horizonal feed / tab
const TOKEN_TAB = '\u{09}';
/// RFC8259.2 - New line / line feed
const TOKEN_NEW_LINE = '\u{0A}';
/// RFC8259.2 - Carriage return
const TOKEN_CARRIAGE_RETURN = '\u{0D}';

/// RFC8259.6 - Zero
const TOKEN_ZERO = '0';
/// RFC8259.6 - Minus
const TOKEN_MINUS = '-';
/// RFC8259.6 - Plus
const TOKEN_PLUS = '+';
/// RFC8259.6 - Decimal-point
const TOKEN_PERIOD = '.';
/// RFC8259.6 - Exp e
const TOKEN_EXPONENT_LOWER = 'e';
/// RFC8259.6 - Exp E
const TOKEN_EXPONENT_UPPER = 'E';

/// RFC8259.7 - Reverse solidus
const TOKEN_BACKSLASH = '\\';

/// RFC8259.3 true value
const TOKEN_TRUE = "true";
/// RFC8259.3 false value
const TOKEN_FALSE = "false";
/// RFC8259.3 null value
const TOKEN_NULL = "null";

/// Parser specific errors
pub const ParseError = error {
    /// Returned when failing to determine the type of value to parse
    ParseValueError,
    /// Returned when failing to parse an object
    ParseObjectError,
    /// Returned when failing to parse a number
    ParseNumberError,
    /// Returned when failing to parse a string
    ParseStringError,
    UnexpectedTokenError
};

/// All parser errors including allocation, and int/float parsing errors.
pub const ParseErrors = ParseError || Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

/// The possible types of JSON values
pub const JsonType = enum {
    object,
    array,
    string,
    integer,
    float,
    boolean,
    nil
};

/// Abstraction for JSON objects
const JsonObject = struct {
    /// Underlying key/pair mapping
    map: std.StringArrayHashMap(*JsonValue),

    /// Destructor
    pub fn deinit(self: *JsonObject, allocator: Allocator) void {
        // Iterate through each entry and handle key/value cleanup
        while (self.map.popOrNull()) |entry| {
            // Keys are []u8 and must be free'd
            allocator.free(entry.key);

            // Values are *JsonValues and must be deinit'd and destroyed
            if (!entry.value.indestructible) {
                entry.value.deinit(allocator);
                allocator.destroy(entry.value);
            }
        }

        // Clean the map
        self.map.clearAndFree();
        self.map.deinit();
    }

    pub fn len(self: *JsonObject) usize {
        return self.map.count();
    }
    
    /// Whether the map contains the key or not
    pub fn contains(self: *JsonObject, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Return the value for key or panic
    pub fn get(self: *JsonObject, key: []const u8) *JsonValue {
        if (self.map.get(key)) |value| {
            return value;
        }
        @panic("Map doesn't contain key");
    }

    /// Return the value for key or null
    pub fn getOrNull(self: *JsonObject, key: []const u8) ?*JsonValue {
        if (self.map.get(key)) |value| {
            return value;
        }
        return null;
    }

    /// Print out the JSON object
    /// TODO: Need to handle proper character escaping
    pub fn print(self: *JsonObject, indent: ?usize) void {
        std.debug.print("{{\n", .{});
        var iv = if (indent) |v| v + 2 else 2;
        for (self.map.keys()) |key, index| {
            var i: usize = 0;
            while (i < iv): (i += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("\"{s}\": ", .{key});
            const value = self.map.get(key);
            if (value) |v| {
                v.print(iv);
            }
            if (index < self.map.count() - 1) {
                std.debug.print(",\n", .{});
            }
        }
        iv -= 2;
        std.debug.print("\n", .{});
        var i: usize = 0;
        while (i < iv): (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("}}", .{});
    }
};

/// Abstraction for JSON arrays
const JsonArray = struct {
    /// The underlying list of *JsonValue's
    array: std.ArrayList(*JsonValue),

    /// Destructor
    pub fn deinit(self: *JsonArray, allocator: Allocator) void {
        // Iterate through each element and destroy it
        while (self.array.popOrNull()) |item| {
            // Elements are *JsonValues so they need to be deinit'd and destroyed
            if (!item.indestructible) {
                item.deinit(allocator);
                allocator.destroy(item);
            }
        }
        self.array.clearAndFree();
        self.array.deinit();
    }

    /// The length of the array
    pub fn len(self: *JsonArray) usize {
        return self.array.items.len;
    }

    /// Return the items array directly ¯\_(ツ)_/¯
    pub fn items(self: *JsonArray) []*JsonValue {
        return self.array.items;
    }

    /// Return the item at the index or panic if exceeding normal bounds
    pub fn get(self: *JsonArray, index: usize) *JsonValue {
        return self.array.items[index];
    }

    /// Return the item at the index or null
    pub fn getOrNull(self: *JsonArray, index: usize) ?*JsonValue {
        if (index < 0 or index >= self.len()) {
            return null;
        }
        return self.array.items[index];
    }

    /// Return the first item or panic if none
    pub fn first(self: *JsonArray) *JsonValue {
        return self.get(0);
    }

    /// Return the first item or null
    pub fn firstOrNull(self: *JsonArray) ?*JsonValue {
        return self.getOrNull(0);
    }

    /// Print the JSON array
    pub fn print(self: *JsonArray, indent: ?usize) void {
        std.debug.print("[\n", .{});
        var iv = if (indent) |v| v + 2 else 2;
        for (self.array.items) |item, index| {
            var i: usize = 0;
            while (i < iv): (i += 1) {
                std.debug.print(" ", .{});
            }
            item.print(iv);
            if (index < self.len() - 1) {
                std.debug.print(",\n", .{});
            }
        }
        std.debug.print("\n", .{});
        iv -= 2;
        var i: usize = 0;
        while (i < iv): (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("]", .{});
    }
};

/// Abstraction for all JSON values
const JsonValue = struct {
    /// The JSON value type
    type: JsonType,

    /// The JSON value
    value: ?union {
        integer: i64,
        float: f64,
        array: *JsonArray,
        string: []const u8,
        object: *JsonObject,
        boolean: bool
    },

    /// A pointer for the string value if we don't use a slice from the parsed
    /// string. Presently we're always using this but we can step back for non
    /// escaped strings that don't need to be transformed.
    stringPtr: ?[]u8,

    /// True if the instance of this JsonValue shouldn't be destroyed
    indestructible: bool = false,

    /// Destructor
    pub fn deinit(self: *JsonValue, allocator: Allocator) void {
        if (self.indestructible) {
            return;
        }

        if (self.value) |value| {
            if (self.type == JsonType.object) {
                value.object.deinit(allocator);
                allocator.destroy(value.object);
            }
            if (self.type == JsonType.array) {
                value.array.deinit(allocator);
                allocator.destroy(value.array);
            }
            if (self.type == JsonType.string) {
                if (self.stringPtr) |stringPtr|
                allocator.free(stringPtr);
            }
        }
    }

    /// Handy pass-thru to typed get(...) calls
    pub fn get(self: *JsonValue, index: anytype) *JsonValue {
        if (self.value == null) {
            @panic("Value is null");
        }

        return switch (self.type) {
            // Figure out a better way to do this
            JsonType.object => if (@TypeOf(index) != usize and @TypeOf(index) != comptime_int) self.value.?.object.get(index) else @panic("Invalid key type"),
            JsonType.array => if (@TypeOf(index) == usize or @TypeOf(index) == comptime_int) self.value.?.array.get(index) else @panic("Invalid key type"),
            else => @panic("JsonType doesn't support get()")
        };
    }

    /// Handy pass-thru to typed len(...) calls
    pub fn len(self: *JsonValue) usize {
        if (self.value == null) {
            @panic("Value is null");
        }

        return switch (self.type) {
            // Figure out a better way to do this
            JsonType.object => self.value.?.object.len(),
            JsonType.array => self.value.?.array.len(),
            JsonType.string => self.value.?.string.len,
            else => @panic("JsonType doesn't support len()")
        };
    }

    /// Returns the string value or panics
    pub fn string(self: *JsonValue) []const u8 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.string ) self.value.?.string else @panic("Not a string");
    }

    /// Returns the object value or panics
    pub fn object(self: *JsonValue) *JsonObject {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.object ) self.value.?.object else @panic("Not an object");
    }

    /// Returns the integer value or panics
    pub fn integer(self: *JsonValue) i64 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.integer ) self.value.?.integer else @panic("Not an number");
    }

    /// Returns the float value or panics
    pub fn float(self: *JsonValue) f64 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.float ) self.value.?.float else @panic("Not an float");
    }

    /// Returns the array value or panics
    pub fn array(self: *JsonValue) *JsonArray {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.array ) self.value.?.array else @panic("Not an array");
    }

    /// Returns the array value or panics
    pub fn boolean(self: *JsonValue) bool {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.boolean ) self.value.?.boolean else @panic("Not a boolean");
    }

    /// Returns the string value or null
    pub fn stringOrNull(self: *JsonValue) ?[]const u8 {
        return if (self.value == null or self.type == JsonType.string) self.value.string else null;
    }

    /// Returns the object value or null
    pub fn objectOrNull(self: *JsonValue) ?*JsonObject {
        return if (self.value == null or self.type == JsonType.object) self.value.object else null;
    }

    /// Returns the integer value or null
    pub fn integerOrNull(self: *JsonValue) ?i64 {
        return if (self.value == null or self.type == JsonType.integer) self.value.integer else null;
    }

    /// Returns the float value or null
    pub fn floatOrNull(self: *JsonValue) ?f64 {
        return if (self.value == null or self.type == JsonType.float) self.value.float else null;
    }

    /// Returns the array value or null
    pub fn arrayOrNull(self: *JsonValue) ?*JsonArray {
        return if (self.value == null or self.type == JsonType.array) self.value.array else null;
    }

    /// Returns the boolean value or null
    pub fn booleanOrNull(self: *JsonValue) ?bool {
        return if (self.value == null or self.type == JsonType.boolean) self.value.boolean else null;
    }

    /// Print the JSON value
    pub fn print(self: *JsonValue, indent: ?usize) void {
        switch (self.type) {
            JsonType.integer => std.debug.print("{d}", .{self.integer()}),
            JsonType.float => std.debug.print("{d}", .{self.float()}),
            JsonType.string => std.debug.print("\"{s}\"", .{self.string()}),
            JsonType.boolean => std.debug.print("\"{any}\"", .{self.boolean()}),
            JsonType.nil => std.debug.print("null", .{}),
            JsonType.object => self.value.?.object.print(indent),
            JsonType.array => self.value.?.array.print(indent),
        }
    }
};

/// "Constant" for JSON true value
var JSON_TRUE = JsonValue {
    .type = JsonType.boolean,
    .value = .{ .boolean = true },
    .indestructible = true,
    .stringPtr = null
};

/// "Constant" for JSON false value
var JSON_FALSE = JsonValue {
    .type = JsonType.boolean,
    .value = .{ .boolean = false },
    .indestructible = true,
    .stringPtr = null
};

/// "Constant" for JSON null value
var JSON_NULL = JsonValue {
    .type = JsonType.nil,
    .value = null,
    .indestructible = true,
    .stringPtr = null
};

/// Parse a JSON string using the proved allocator
pub fn parse(jsonString: []const u8, allocator: Allocator) !*JsonValue {
    // Walk through each token
    var index: usize = 0;
    return parseValue(jsonString, allocator, &index);
}

/// Parse a JSON value from the provided slice
/// Returns the index of the next character to read
fn parseValue(jsonString: []const u8, allocator: Allocator, outIndex: *usize) ParseErrors!*JsonValue {
    var index = skipWhiteSpaces(jsonString);
    const char = jsonString[index];
    const result = result: {
        // { indicates an object
        if (char == TOKEN_CURLY_BRACKET_OPEN) {
            var result = try parseObject(jsonString[index..jsonString.len], allocator, &index);
            errdefer {
                result.deinit(allocator);
                allocator.destroy(result);
            }
            break :result result;
        }

        // [ indicates an array
        if (char == TOKEN_BRACKET_OPEN) {
            var result = try parseArray(jsonString[index..jsonString.len], allocator, &index);
            errdefer {
                result.deinit(allocator);
                allocator.destroy(result);
            }
            break :result result;
        }

        // " indicates a string
        if (char == TOKEN_DOUBLE_QUOTE) {
            var result = try parseStringWithTerminal(jsonString[index..jsonString.len], allocator, TOKEN_DOUBLE_QUOTE, &index);
            errdefer {
                result.deinit(allocator);
                allocator.destroy(result);
            }
            break :result result;
        }

        // ' indicates a string (probably remove?)
        if (char == TOKEN_SINGLE_QUOTE) {
            index += 1;
            var result = try parseStringWithTerminal(jsonString[index..jsonString.len], allocator, TOKEN_SINGLE_QUOTE, &index);
            errdefer {
                result.deinit(allocator);
                allocator.destroy(result);
            }
            break :result result;
        }

        // 0-9|- indicates a number
        if (isNumberOrMinus(char)) {
            var result = try parseNumber(jsonString[index..jsonString.len], allocator, &index);
            errdefer {
                result.deinit(allocator);
                allocator.destroy(result);
            }
            break :result result;
        }

        if (isTrueValue(jsonString[index..jsonString.len])) {
            index += TOKEN_TRUE.len;
            break :result &JSON_TRUE;
        }

        if (isFalseValue(jsonString[index..jsonString.len])) {
            index += TOKEN_FALSE.len;
            break :result &JSON_FALSE;
        }

        if (isNullValue(jsonString[index..jsonString.len])) {
            index += TOKEN_NULL.len;
            break :result &JSON_NULL;
        }

        return error.ParseValueError;
    };

    errdefer {
        result.deinit(allocator);
        allocator.destroy(result);
    }

    outIndex.* += index;
    return result;
}

/// Parse a JSON object from the provided slice
/// Returns the index of the next character to read
/// Note: parseObject _assumes_ the leading { has been stripped and jsonString
///  starts after that point.
fn parseObject(jsonString: []const u8, allocator: Allocator, outIndex: *usize) ParseErrors!*JsonValue {
    const jsonObject = try allocator.create(JsonObject); 
    errdefer allocator.destroy(jsonObject);

    jsonObject.map = std.StringArrayHashMap(*JsonValue).init(allocator);

    var index = try expect(jsonString, TOKEN_CURLY_BRACKET_OPEN);
    while (index < jsonString.len and jsonString[index] != TOKEN_CURLY_BRACKET_CLOSE) {
        const char = jsonString[index];
        if (char == TOKEN_COMMA or isInsignificantWhitespace(char)) {
            index += 1;
            continue;
        }
        const key = key: {
            if (char == TOKEN_DOUBLE_QUOTE) {
                var result = try parseStringWithTerminal(jsonString[index..jsonString.len], allocator, TOKEN_DOUBLE_QUOTE, &index);
                errdefer allocator.destroy(result);
                break :key result;
            }
            if (char == TOKEN_SINGLE_QUOTE) {
                var result = try parseStringWithTerminal(jsonString[index..jsonString.len], allocator, TOKEN_SINGLE_QUOTE, &index);
                errdefer allocator.destroy(result);
                break :key result;
            }
            return error.ParseObjectError;
        };
        errdefer {
            key.deinit(allocator);
            allocator.destroy(key);
        }

        index += try expect(jsonString[index..jsonString.len], TOKEN_COLON);
        const value = try parseValue(jsonString[index..jsonString.len], allocator, &index);
        errdefer {
            value.deinit(allocator);
            allocator.destroy(value);
        }

        const keyString = try allocator.alloc(u8, key.string().len);
        errdefer allocator.free(keyString);
        std.mem.copy(u8, keyString, key.string());
        key.deinit(allocator);
        allocator.destroy(key);

        try jsonObject.map.put(keyString, value);
    }

    // Account for the terminal character
    outIndex.* += index + 1;

    const jsonValue = try allocator.create(JsonValue);
    errdefer allocator.destroy(jsonValue);

    jsonValue.type = JsonType.object;
    jsonValue.value = .{ .object = jsonObject };

    return jsonValue;
}

/// Parse a JSON array from the provided slice
/// Returns the index of the next character to read
/// Note: parseArray _assumes_ the leading [ has been stripped and jsonString
///  starts after that point.
fn parseArray(jsonString: []const u8, allocator: Allocator, outIndex: *usize) ParseErrors!*JsonValue {
    const jsonArray = try allocator.create(JsonArray); 
    errdefer allocator.destroy(jsonArray);

    jsonArray.array = std.ArrayList(*JsonValue).init(allocator);

    var index = try expect(jsonString, TOKEN_BRACKET_OPEN);
    while (index < jsonString.len and jsonString[index] != TOKEN_BRACKET_CLOSE) {
        // Skip commas and insignificant whitespaces
        if (jsonString[index] == TOKEN_COMMA or isInsignificantWhitespace(jsonString[index])) {
            index += 1;
            continue;
        }
        const jsonValue = try parseValue(jsonString[index..jsonString.len], allocator, &index);
        errdefer {
            jsonValue.deinit(allocator);
            allocator.destroy(jsonValue);
        }
        try jsonArray.array.append(jsonValue);
    }

    // Account for the terminal character
    outIndex.* += index + 1;

    const jsonValue = try allocator.create(JsonValue);
    errdefer allocator.destroy(jsonValue);

    jsonValue.type = JsonType.array;
    jsonValue.value = .{ .array = jsonArray };

    return jsonValue;
}

/// Parse a string from the provided slice
/// Returns the index of the next character to read
fn parseStringWithTerminal(jsonString: []const u8, allocator: Allocator, terminal: u8, outIndex: *usize) ParseErrors!*JsonValue {
    var i = try expectUpTo(jsonString, terminal);
    var slashCount: usize = 0;
    var characters = std.ArrayList(u8).init(allocator);
    while (i < jsonString.len and (jsonString[i] != terminal or slashCount % 2 == 1)): (i += 1) {
        // Track escaping
        if (jsonString[i] == TOKEN_BACKSLASH) {
            slashCount += 1;

            if (slashCount % 2 == 0) {
                try characters.append(jsonString[i]);
            }
        }
        else {
            slashCount = 0;
            try characters.append(jsonString[i]);
        }
    }

    if (i >= jsonString.len) return error.ParseStringError;

    const jsonValue = try allocator.create(JsonValue);
    errdefer allocator.destroy(jsonValue);

    const copy = try allocator.alloc(u8, characters.items.len);
    errdefer allocator.free(copy);

    for (characters.items) |char, index| {
        copy[index] = char;
    }
    characters.deinit();

    jsonValue.type = JsonType.string;
    jsonValue.value = .{ .string = copy };
    jsonValue.stringPtr = copy;

    outIndex.* += i + 1;
    return jsonValue;
}

/// Parse a number from the provided slice
/// Returns the index of the next character to read
fn parseNumber(jsonString: []const u8, allocator: Allocator, outIndex: *usize) ParseErrors!*JsonValue {
    var numberType = JsonType.integer;
    var i: usize = 0;
    
    // First character can be a minus or number
    if (!isNumberOrMinus(jsonString[i])) {
        return error.ParseNumberError;
    }
    // Increment past the first character
    i += 1;

    // Walk through each character
    while (i < jsonString.len and isNumber(jsonString[i])): (i += 1) {
        if (i > 0 and jsonString[i - 1] == TOKEN_ZERO and jsonString[i] == TOKEN_ZERO) {
            return error.ParseNumberError;
        }
    }

    // Handle decimal numbers
    if (i < jsonString.len and jsonString[i] == TOKEN_PERIOD) {
        numberType = JsonType.float;
        i += 1;
        while (i < jsonString.len and isNumber(jsonString[i])): (i += 1) { }
    }

    // Handle exponent
    if (i < jsonString.len and (jsonString[i] == TOKEN_EXPONENT_LOWER or jsonString[i] == TOKEN_EXPONENT_UPPER)) {
        numberType = JsonType.float;
        i += 1;
        if (!isNumberOrMinusOrPlus(jsonString[i])) {
            return error.ParseNumberError;
        }
        // Handle preceeding +/-
        i += 1;
        // Handle the exponent value
        while (i < jsonString.len and isNumber(jsonString[i])): (i += 1) { }
    }

    if (i > jsonString.len) @panic("Fail");
    const jsonValue = try allocator.create(JsonValue);
    errdefer allocator.destroy(jsonValue);
    jsonValue.type = numberType;
    jsonValue.value = switch (numberType) {
        JsonType.integer => .{ .integer = try std.fmt.parseInt(i64, jsonString[0..i], 10) },
        JsonType.float => .{ .float = try std.fmt.parseFloat(f64, jsonString[0..i]) },
        else => return error.ParseNumberError
    };
    outIndex.* += i;
    return jsonValue;
}

/// Expects the next significant character be token, skipping over all leading and trailing
/// insignificant whitespace, or returns UnexpectedTokenError.
fn expect(jsonString: []const u8, token: u8) ParseErrors!usize {
    var index = skipWhiteSpaces(jsonString);
    if (jsonString[index] != token) return error.UnexpectedTokenError;
    return skipWhiteSpacesAfter(jsonString, index + 1);
}

/// Expects the next character be token or returns UnexpectedTokenError.
fn expectOnly(jsonString: []const u8, token: u8) ParseErrors!usize {
    if (jsonString[0] != token) return error.UnexpectedTokenError;
    return 1;
}

/// Expects the next significant character be token, skipping over all leading insignificant
/// whitespace, or returns UnexpectedTokenError.
fn expectUpTo(jsonString: []const u8, token: u8) ParseErrors!usize {
    var index = skipWhiteSpaces(jsonString);
    if (jsonString[index] != token) return error.UnexpectedTokenError;
    return index + 1;
}

/// Returns the index in the string with the next, significant character
/// starting from the beginning.
fn skipWhiteSpaces(jsonString: []const u8) usize {
    return skipWhiteSpacesAfter(jsonString, 0);
}

/// Returns the index in the string with the next, significant character
/// starting after start.
fn skipWhiteSpacesAfter(jsonString: []const u8, start: usize) usize {
    var i: usize = start;
    while (i <= jsonString.len and isInsignificantWhitespace(jsonString[i])): (i += 1) { }
    return i;
}

/// Returns true if a character matches the RFC8259 grammar specificiation for
/// insignificant whitespace.
fn isInsignificantWhitespace(char: u8) bool {
    return char == TOKEN_SPACE
        or char == TOKEN_TAB
        or char == TOKEN_NEW_LINE
        or char == TOKEN_CARRIAGE_RETURN;
}

/// Returns true if the character is a number, minus, or plus
fn isNumberOrMinusOrPlus(char: u8) bool {
    return char == TOKEN_MINUS or char == TOKEN_PLUS or isNumber(char);
}

/// Returns true if the character is a number or minus
fn isNumberOrMinus(char: u8) bool {
    return char == TOKEN_MINUS or isNumber(char);
}

/// Returns true if the character is a number
fn isNumber(char: u8) bool {
    return (char >= 48 and char <= 57);
}

/// Returns true if the next token in the string is TOKEN_TRUE
fn isTrueValue(jsonString: []const u8) bool {
    return TOKEN_TRUE.len <= jsonString.len
        and std.mem.eql(u8, jsonString[0..TOKEN_TRUE.len], TOKEN_TRUE);
}

/// Returns true if the next token in the string is TOKEN_FALSE
fn isFalseValue(jsonString: []const u8) bool {
    return TOKEN_FALSE.len <= jsonString.len
        and std.mem.eql(u8, jsonString[0..TOKEN_FALSE.len], TOKEN_FALSE);
}

/// Returns true if the next token in the string is TOKEN_NULL
fn isNullValue(jsonString: []const u8) bool {
    return TOKEN_NULL.len <= jsonString.len
        and std.mem.eql(u8, jsonString[0..TOKEN_NULL.len], TOKEN_NULL);
}

/// Helper for printing messages
fn debug(comptime msg: []const u8, args: anytype) void {
    std.debug.print(msg, args);
}

// Unit Tests
test "RFC8259.3: parseValue can parse true" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "true";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.boolean);
    try std.testing.expectEqual(value.boolean(), true);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.3: parseValue can parse false" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "false";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.boolean);
    try std.testing.expectEqual(value.boolean(), false);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.3: parseValue can parse null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "null";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.nil);
    try std.testing.expect(value.value == null);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.4: parseObject can parse an empty object /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "{}";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.4: parseObject can parse an empty object /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "{ }";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.4: parseObject can parse an empty object /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create an empty object with all insignificant whitespace characters
    const text = "\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}";
    var index: usize = 0;
    const value = try parseValue(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.4: parseObject can parse a simple object /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var jsonResult = try parse("{\"key1\": \"foo\", \"key2\": \"foo2\", \"key3\": -1, \"key4\": [], \"key5\": { } }", allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("key2"), true);
    try std.testing.expectEqual(jsonResult.get("key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("key3"), true);
    try std.testing.expectEqual(jsonResult.get("key3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("key3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);
    allocator.destroy(jsonResult);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.4: parseObject can parse a simple object /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Same text body as /1 but every inbetween character is the set of insignificant whitepsace
    // characters
    var jsonResult = try parse(
        "\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key1\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key2\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo2\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key3\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key4\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key5\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}",
        allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("key2"), true);
    try std.testing.expectEqual(jsonResult.get("key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("key3"), true);
    try std.testing.expectEqual(jsonResult.get("key3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("key3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);
    allocator.destroy(jsonResult);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.5: parseArray can parse an empty array /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "[]";
    var index: usize = 0;
    const value = try parseArray(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.5: parseArray can parse an empty array /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}";
    var index: usize = 0;
    const value = try parseArray(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.5: parseArray can parse an simple array /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 
    const text = "[-1,-1.2,0,1,1.2,\"\",\"foo\",true,false,null,{},{\"foo\":\"bar\", \"baz\": {}}]";
    var index: usize = 0;
    const value = try parseArray(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 12);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.5: parseArray can parse an simple array /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 
    const text = "\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1.2\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}0\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}1.2\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}true\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}false\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}null\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"bar\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"baz\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}";
    var index: usize = 0;
    const value = try parseArray(text, allocator, &index);
    errdefer {
        value.deinit(allocator);
        allocator.destroy(value);
    }
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 12);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a integer /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "0";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a integer /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "1";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 1);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a integer /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "1337";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 1337);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a integer /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-1337";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), -1337);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a float /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "1.0";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 1.0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a float /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-1.0";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -1.0);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a float /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "1337.0123456789";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 1337.0123456789);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse a float /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-1337.0123456789";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -1337.0123456789);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "13e37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13e37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "13E37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "13E+37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E+37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "13E-37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E-37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-13e37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13e37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /6" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-13E37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13E37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /7" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "-13E+37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13E+37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber can parse an exponent /8" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "13E-37";
    var index: usize = 0;
    const value = try parseNumber(text, allocator, &index);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E-37);

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber fails on a repeating 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "00";
    var index: usize = 0;
    const value = parseNumber(text, allocator, &index);
    try std.testing.expectError(error.ParseNumberError, value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber fails on a non-minus and non-digit start /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "a0";
    var index: usize = 0;
    const value = parseNumber(text, allocator, &index);
    try std.testing.expectError(error.ParseNumberError, value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.6: parseNumber fails on a non-minus and non-digit start /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "+0";
    var index: usize = 0;
    const value = parseNumber(text, allocator, &index);
    try std.testing.expectError(error.ParseNumberError, value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse an empty string /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "\"\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), ""));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse an empty string /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), ""));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "\"some string\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some string"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const text = "\"some\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}string\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}string"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // some\"string
    const text = "\"some\\\"string\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\"string"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // some\\"string
    const text = "\"some\\\\\\\"string\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\\\"string"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // ",\,\u{00-0f}
    const text = "\"\\\"\\\\\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{0F}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1A}\u{1B}\u{1C}\u{1D}\u{1E}\u{1F}\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "\"\\\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{0F}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1A}\u{1B}\u{1C}\u{1D}\u{1E}\u{1F}"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}

test "RFC8259.8.3: parseStringWithTerminal parsing results in equivalent strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Test that \\ equals \u{5C}
    const text = "\"a\\\\b\"";
    var index: usize = 0;
    const value = try parseStringWithTerminal(text, allocator, TOKEN_DOUBLE_QUOTE, &index);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "a\u{5C}b"));

    value.deinit(allocator);
    allocator.destroy(value);

    try std.testing.expect(!gpa.deinit());
}