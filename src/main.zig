///! Simple JSON parsing library with a focus on a simple, usable API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const BufferErrors = @import("buffer.zig").BufferErrors;
const bufferFromText = @import("buffer.zig").bufferFromText;
const bufferFromStreamSource = @import("buffer.zig").bufferFromStreamSource;

/// Enable to get debug logging during parsing
/// TODO: Probably...consider std.log?
const DEBUG = false;

/// RFC8259 - quotation mark
const TOKEN_DOUBLE_QUOTE = '"';
/// JSON5.5 - single tick
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

/// RFC8259.2 - Horizonal tab
const TOKEN_HORIZONTAL_TAB = '\u{09}';
/// RFC8259.2 - New line / line feed
const TOKEN_NEW_LINE = '\u{0A}';
/// JSON5.8 - Vertical tab
const TOKEN_VERTICAL_TAB = '\u{0B}';
/// JSON5.8 - Form feed
const TOKEN_FORM_FEED = '\u{0C}';
/// RFC8259.2 - Carriage return
const TOKEN_CARRIAGE_RETURN = '\u{0D}';
/// RFC8259.2 - Space
const TOKEN_SPACE = '\u{20}';
/// JSON5.8 - Non-breaking space
const TOKEN_NON_BREAKING_SPACE = '\u{A0}';
/// JSON5.8 - Line separator
const TOKEN_LINE_SEPARATOR = '\u{2028}';
/// JSON5.8 - Paragraph separator
const TOKEN_PARAGRAPH_SEPARATOR = '\u{2029}';
/// JSON5.8 - Byte order mark
const TOKEN_BOM = '\u{FEFF}';

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
const TOKEN_REVERSE_SOLIDUS = '\\';

/// RFC8259.3 - true value
const TOKEN_TRUE = "true";
/// RFC8259.3 - false value
const TOKEN_FALSE = "false";
/// RFC8259.3 - null value
const TOKEN_NULL = "null";
/// JSON5.6 - infinity
const TOKEN_INFINITY = "Infinity";
/// JSON5.6 - not-a-number
const TOKEN_NAN = "NaN";

/// JSON5.9.1 / ECMA Script 5.1-7.6 - Identifier Starting Character
const TOKEN_DOLLAR_SIGN = '$';
/// JSON5.9.1 / ECMA Script 5.1-7.6 - Identifier Starting Character
const TOKEN_UNDERSCORE = '_';
/// JSON5.7 - Solidus
const TOKEN_SOLIDUS = '/';
/// JSON5.7 - Asterisk
const TOKEN_ASTERISK = '*';
/// JSON5.9.1 / ECMA Script 5.1-7.6 - Identifier Part
const TOKEN_ZERO_WIDTH_NON_JOINER = 0x200C;
/// JSON5.9.1 / ECMA Script 5.1-7.6 - Identifier Part
const TOKEN_ZERO_WIDTH_JOINER = 0x200D;

/// Parser specific errors
pub const ParseError = error{
    /// Returned when failing to determine the type of value to parse
    ParseValueError,
    /// Returned when failing to parse an object
    ParseObjectError,
    /// Returned when failing to parse a number
    ParseNumberError,
    /// Returned when failing to parse a string
    ParseStringError,
    // Returned when an unexpected token is found (generally when we're expecting something else)
    UnexpectedTokenError,
    // std.unicode
    CodepointTooLarge,
    Utf8CannotEncodeSurrogateHalf,
};

/// All parser errors including allocation, and int/float parsing errors.
pub const ParseErrors = ParseError || Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || BufferErrors;

/// Allows callers to configure which parser style to use.
pub const ParserConfig = struct { parserType: ParserType = ParserType.rfc8259 };

/// Enumerator for the JSON parser type.
pub const ParserType = enum { rfc8259, json5 };

/// The possible types of JSON values
pub const JsonType = enum { object, array, string, integer, float, boolean, nil };

/// The type of encoding used for a JSON number
const NumberEncoding = enum { integer, float, exponent, hex };

/// Abstraction for JSON objects
pub const JsonObject = struct {
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
            }
        }

        // Clean the map
        self.map.clearAndFree();
        self.map.deinit();

        allocator.destroy(self);
    }

    /// Returns the number of members in the object
    pub fn len(self: *JsonObject) usize {
        return self.map.count();
    }

    /// Whether the map contains the key or not
    pub fn contains(self: *JsonObject, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Whether the object is equivalent to another object
    pub fn eql(self: *JsonObject, other: *JsonObject) bool {
        // Handle the easy case first
        if (self.len() != other.len()) {
            return false;
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (!other.contains(entry.key_ptr.*) or !entry.value_ptr.*.eql(other.get(entry.key_ptr.*))) {
                return false;
            }
        }
        return true;
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

    /// Return the JSON object's members
    pub fn keys(self: *JsonObject) [][]const u8 {
        return self.map.keys();
    }

    /// Print out the JSON object
    /// TODO: Need to handle proper character escaping
    pub fn print(self: *JsonObject, indent: ?usize) void {
        std.debug.print("{{\n", .{});
        var iv = if (indent) |v| v + 2 else 2;
        for (self.map.keys(), 0..) |key, index| {
            var i: usize = 0;
            while (i < iv) : (i += 1) {
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
        while (i < iv) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("}}\n", .{});
    }
};

/// Abstraction for JSON arrays
pub const JsonArray = struct {
    /// The underlying list of *JsonValue's
    array: std.ArrayList(*JsonValue),

    /// Destructor
    pub fn deinit(self: *JsonArray, allocator: Allocator) void {
        // Iterate through each element and destroy it
        while (self.array.popOrNull()) |item| {
            // Elements are *JsonValues so they need to be deinit'd and destroyed
            if (!item.indestructible) {
                item.deinit(allocator);
            }
        }
        self.array.clearAndFree();
        self.array.deinit();

        allocator.destroy(self);
    }

    /// The length of the array
    pub fn len(self: *JsonArray) usize {
        return self.array.items.len;
    }

    /// Return the items array directly ¯\_(ツ)_/¯
    pub fn items(self: *JsonArray) []*JsonValue {
        return self.array.items;
    }

    /// Whether the object is equivalent to another object
    pub fn eql(self: *JsonArray, other: *JsonArray) bool {
        const length: usize = self.len();
        // Handle the easy case first
        if (length != other.len()) {
            return false;
        }

        var i: usize = 0;

        while (i < length) : (i += 1) {
            if (!self.array.items[i].eql(other.array.items[i])) {
                return false;
            }
        }

        return true;
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
        for (self.array.items, 0..) |item, index| {
            var i: usize = 0;
            while (i < iv) : (i += 1) {
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
        while (i < iv) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("]\n", .{});
    }
};

const JsonValueTypeUnion = union { integer: i64, float: f64, array: *JsonArray, string: []const u8, object: *JsonObject, boolean: bool };

/// Abstraction for all JSON values
pub const JsonValue = struct {
    /// The JSON value type
    type: JsonType,

    /// The JSON value
    value: ?JsonValueTypeUnion,

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
            }
            if (self.type == JsonType.array) {
                value.array.deinit(allocator);
            }
            if (self.type == JsonType.string) {
                if (self.stringPtr) |stringPtr|
                    allocator.free(stringPtr);
            }
        }

        allocator.destroy(self);
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
            else => @panic("JsonType doesn't support get()"),
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
            else => @panic("JsonType doesn't support len()"),
        };
    }

    /// Return true if the two items are deeply equal
    pub fn eql(self: *JsonValue, other: *JsonValue) bool {
        // Avoid crashes due to nulls
        if ((self.value == null and other.value != null) or
            (self.value != null and other.value == null))
        {
            return false;
        }

        if (self.type != other.type) {
            return false;
        }

        return switch (self.type) {
            JsonType.object => self.object().eql(other.object()),
            JsonType.array => self.array().eql(other.array()),
            JsonType.string => std.mem.eql(u8, self.string(), other.string()),
            // TODO: somehow generate these cases at comptime?
            JsonType.integer => self.integer() == other.integer(),
            JsonType.float => self.float() == other.float(),
            JsonType.boolean => self.boolean() == other.boolean(),
            JsonType.nil => true,
        };
    }

    /// Returns the string value or panics
    pub fn string(self: *JsonValue) []const u8 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.string) self.value.?.string else @panic("Not a string");
    }

    /// Returns the object value or panics
    pub fn object(self: *JsonValue) *JsonObject {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.object) self.value.?.object else @panic("Not an object");
    }

    /// Returns the integer value or panics
    pub fn integer(self: *JsonValue) i64 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.integer) self.value.?.integer else @panic("Not an number");
    }

    /// Returns the float value or panics
    pub fn float(self: *JsonValue) f64 {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.float) self.value.?.float else @panic("Not an float");
    }

    /// Returns the array value or panics
    pub fn array(self: *JsonValue) *JsonArray {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.array) self.value.?.array else @panic("Not an array");
    }

    /// Returns the array value or panics
    pub fn boolean(self: *JsonValue) bool {
        if (self.value == null) @panic("Value is null");
        return if (self.type == JsonType.boolean) self.value.?.boolean else @panic("Not a boolean");
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

pub const CONFIG_RFC8259 = ParserConfig{ .parserType = ParserType.rfc8259 };
pub const CONFIG_JSON5 = ParserConfig{ .parserType = ParserType.json5 };

/// "Constant" for JSON true value
var JSON_TRUE = JsonValue{ .type = JsonType.boolean, .value = .{ .boolean = true }, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON false value
var JSON_FALSE = JsonValue{ .type = JsonType.boolean, .value = .{ .boolean = false }, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON null value
var JSON_NULL = JsonValue{ .type = JsonType.nil, .value = null, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON positive infinity
var JSON_POSITIVE_INFINITY = JsonValue{ .type = JsonType.float, .value = .{ .float = std.math.inf(f64) }, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON negative infinity
var JSON_NEGATIVE_INFINITY = JsonValue{ .type = JsonType.float, .value = .{ .float = -std.math.inf(f64) }, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON positive NaN
var JSON_POSITIVE_NAN = JsonValue{ .type = JsonType.float, .value = .{ .float = std.math.nan(f64) }, .indestructible = true, .stringPtr = null };

/// "Constant" for JSON negative NaN
var JSON_NEGATIVE_NAN = JsonValue{ .type = JsonType.float, .value = .{ .float = -std.math.nan(f64) }, .indestructible = true, .stringPtr = null };

/// Parse a JSON5 string using the provided allocator
pub fn parse(jsonString: []const u8, allocator: Allocator) !*JsonValue {
    var buffer = bufferFromText(jsonString);
    return parseValue(&buffer, CONFIG_RFC8259, allocator);
}

fn parseBuffer(buffer: *Buffer, allocator: Allocator) !*JsonValue {
    return parseValue(buffer, CONFIG_RFC8259, allocator);
}

pub fn parseFile(file: std.fs.File, allocator: Allocator) !*JsonValue {
    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);
    return parseValue(&buffer, CONFIG_RFC8259, allocator);
}

/// Parse a JSON5 string using the provided allocator
pub fn parseJson5(jsonString: []const u8, allocator: Allocator) !*JsonValue {
    const buffer = bufferFromText(jsonString);
    return parseValue(buffer, CONFIG_JSON5, allocator);
}

fn parseJson5Buffer(buffer: *Buffer, allocator: Allocator) !*JsonValue {
    return parseValue(buffer, CONFIG_JSON5, allocator);
}

/// Parse a JSON5 file using the provided allocator
pub fn parseJson5File(file: std.fs.File, allocator: Allocator) !*JsonValue {
    var streamSource = std.io.StreamSource{ .file = file };
    const buffer = bufferFromStreamSource(&streamSource);
    return parseValue(buffer, CONFIG_JSON5, allocator);
}

fn internalParse(buffer: *Buffer, config: ParserConfig, allocator: Allocator) !*JsonValue {
    // Walk through each token
    return parseValue(buffer, config, allocator);
}

/// Parse a JSON value from the provided slice
/// Returns the index of the next character to read
fn parseValue(buffer: *Buffer, config: ParserConfig, allocator: Allocator) ParseErrors!*JsonValue {
    try skipWhiteSpaces(buffer, config);
    const char = try buffer.peek();
    const result = result: {
        // { indicates an object
        if (char == TOKEN_CURLY_BRACKET_OPEN) {
            var result = try parseObject(buffer, config, allocator);
            errdefer result.deinit(allocator);
            break :result result;
        }

        // [ indicates an array
        if (char == TOKEN_BRACKET_OPEN) {
            var result = try parseArray(buffer, config, allocator);
            errdefer result.deinit(allocator);
            break :result result;
        }

        // " indicates a string
        if (char == TOKEN_DOUBLE_QUOTE) {
            var result = try parseStringWithTerminal(buffer, config, allocator, TOKEN_DOUBLE_QUOTE);
            errdefer result.deinit(allocator);
            break :result result;
        }

        // ' indicates a string (json5)
        if (config.parserType == ParserType.json5 and char == TOKEN_SINGLE_QUOTE) {
            var result = try parseStringWithTerminal(buffer, config, allocator, TOKEN_SINGLE_QUOTE);
            errdefer result.deinit(allocator);
            break :result result;
        }

        // 0-9|- indicates a number
        if (try isReservedInfinity(buffer) or try isReservedNan(buffer) or isNumberOrPlusOrMinus(char)) {
            var result = try parseNumber(buffer, config, allocator);
            errdefer result.deinit(allocator);
            break :result result;
        }

        if (try isReservedTrue(buffer)) {
            try expectWord(buffer, TOKEN_TRUE);
            break :result &JSON_TRUE;
        }

        if (try isReservedFalse(buffer)) {
            try expectWord(buffer, TOKEN_FALSE);
            break :result &JSON_FALSE;
        }

        if (try isReservedNull(buffer)) {
            try expectWord(buffer, TOKEN_NULL);
            break :result &JSON_NULL;
        }

        var leftOverBuffer: [16]u8 = undefined;
        _ = try buffer.read(&leftOverBuffer);
        debug("Unable to parse value from \"{s}...\"", .{leftOverBuffer});

        return error.ParseValueError;
    };

    errdefer result.deinit(allocator);
    return result;
}

/// Parse a JSON object from the provided slice
/// Returns the index of the next character to read
/// Note: parseObject _assumes_ the leading { has been stripped and jsonString
///  starts after that point.
fn parseObject(buffer: *Buffer, config: ParserConfig, allocator: Allocator) ParseErrors!*JsonValue {
    const jsonObject = try allocator.create(JsonObject);
    errdefer jsonObject.deinit(allocator);

    jsonObject.map = std.StringArrayHashMap(*JsonValue).init(allocator);

    var wasLastComma = false;
    try expect(buffer, config, TOKEN_CURLY_BRACKET_OPEN);
    while (try buffer.getPos() < try buffer.getEndPos() and try buffer.peek() != TOKEN_CURLY_BRACKET_CLOSE) {
        const char = try buffer.peek();
        // Skip comments
        if (try isComment(buffer)) {
            try skipComment(buffer);
            continue;
        }
        if (char == TOKEN_COMMA or isInsignificantWhitespace(char, config)) {
            wasLastComma = char == TOKEN_COMMA or wasLastComma;
            try buffer.skipBytes(1);
            continue;
        }

        if (jsonObject.map.count() > 0 and !wasLastComma) {
            debug("Unexpected token; expected ',' but found a '{?}' instead", .{buffer.lastByte()});
            return error.UnexpectedTokenError;
        }
        wasLastComma = false;

        const key = key: {
            if (char == TOKEN_DOUBLE_QUOTE) {
                var result = try parseStringWithTerminal(buffer, config, allocator, TOKEN_DOUBLE_QUOTE);
                errdefer result.deinit(allocator);
                break :key result;
            }
            if (config.parserType == ParserType.json5 and char == TOKEN_SINGLE_QUOTE) {
                var result = try parseStringWithTerminal(buffer, config, allocator, TOKEN_SINGLE_QUOTE);
                errdefer result.deinit(allocator);
                break :key result;
            }
            if (config.parserType == ParserType.json5 and try isStartOfEcmaScript51Identifier(buffer)) {
                var result = try parseEcmaScript51Identifier(buffer, allocator);
                errdefer result.deinit(allocator);
                break :key result;
            }
            return error.ParseObjectError;
        };
        errdefer key.deinit(allocator);

        try expect(buffer, config, TOKEN_COLON);
        const value = try parseValue(buffer, config, allocator);
        errdefer value.deinit(allocator);

        const keyString = try allocator.alloc(u8, key.string().len);
        errdefer allocator.free(keyString);

        std.mem.copyForwards(u8, keyString, key.string());
        key.deinit(allocator);

        try jsonObject.map.put(keyString, value);
    }

    // Account for the terminal character
    try buffer.skipBytes(1);

    const jsonValue = try allocator.create(JsonValue);
    errdefer jsonValue.deinit(allocator);

    jsonValue.type = JsonType.object;
    jsonValue.value = .{ .object = jsonObject };

    return jsonValue;
}

/// Parse a JSON array from the provided slice
/// Returns the index of the next character to read
/// Note: parseArray _assumes_ the leading [ has been stripped and jsonString
///  starts after that point.
fn parseArray(buffer: *Buffer, config: ParserConfig, allocator: Allocator) ParseErrors!*JsonValue {
    const jsonArray = try allocator.create(JsonArray);
    errdefer jsonArray.deinit(allocator);

    jsonArray.array = std.ArrayList(*JsonValue).init(allocator);

    // Flag to indicate if we've already seen a comma
    var wasLastComma = false;
    try expect(buffer, config, TOKEN_BRACKET_OPEN);
    while (try buffer.getPos() < try buffer.getEndPos() and try buffer.peek() != TOKEN_BRACKET_CLOSE) {
        // Skip comments
        if (try isComment(buffer)) {
            try skipComment(buffer);
            continue;
        }
        // Skip commas and insignificant whitespaces
        if (try buffer.peek() == TOKEN_COMMA or isInsignificantWhitespace(try buffer.peek(), config)) {
            wasLastComma = try buffer.readByte() == TOKEN_COMMA or wasLastComma;
            continue;
        }
        wasLastComma = false;
        const jsonValue = try parseValue(buffer, config, allocator);
        errdefer jsonValue.deinit(allocator);
        try jsonArray.array.append(jsonValue);
    }

    if (wasLastComma and config.parserType != ParserType.json5) {
        return error.UnexpectedTokenError;
    }

    // Account for the terminal character
    try buffer.skipBytes(1);

    const jsonValue = try allocator.create(JsonValue);
    errdefer jsonValue.deinit(allocator);

    jsonValue.type = JsonType.array;
    jsonValue.value = .{ .array = jsonArray };

    return jsonValue;
}

/// Parse a string from the provided slice
/// Returns the index of the next character to read
fn parseStringWithTerminal(buffer: *Buffer, config: ParserConfig, allocator: Allocator, terminal: u8) ParseErrors!*JsonValue {
    try expectUpTo(buffer, config, terminal);
    var slashCount: usize = 0;
    var characters = std.ArrayList(u8).init(allocator);
    while (try buffer.getPos() < try buffer.getEndPos() and (try buffer.peek() != terminal or slashCount % 2 == 1)) : (try buffer.skipBytes(1)) {
        // Track escaping
        if (try buffer.peek() == TOKEN_REVERSE_SOLIDUS) {
            slashCount += 1;

            if (slashCount % 2 == 0) {
                try characters.append(try buffer.peek());
            }
        } else {
            slashCount = 0;
            try characters.append(try buffer.peek());
        }
    }

    if (try buffer.getPos() >= try buffer.getEndPos()) return error.ParseStringError;

    const jsonValue = try allocator.create(JsonValue);
    errdefer jsonValue.deinit(allocator);

    const copy = try allocator.alloc(u8, characters.items.len);
    errdefer allocator.free(copy);

    for (characters.items, 0..) |char, index| {
        copy[index] = char;
    }
    characters.deinit();

    jsonValue.type = JsonType.string;
    jsonValue.value = .{ .string = copy };
    jsonValue.stringPtr = copy;

    try buffer.skipBytes(1);
    return jsonValue;
}

/// Parse a number from the provided slice
/// Returns the index of the next character to read
fn parseNumber(buffer: *Buffer, config: ParserConfig, allocator: Allocator) ParseErrors!*JsonValue {
    var encodingType = NumberEncoding.integer;
    try skipWhiteSpaces(buffer, config);
    var startingDigitAt: usize = 0;
    var polarity: isize = 1;
    var numberList = std.ArrayList(u8).init(allocator);
    defer numberList.deinit();

    if (try buffer.getPos() >= try buffer.getEndPos()) {
        debug("Number cannot be zero length", .{});
        return error.ParseNumberError;
    }

    // First character can be a minus or number
    if (config.parserType == ParserType.json5 and isPlusOrMinus(try buffer.peek()) or config.parserType == ParserType.rfc8259 and try buffer.peek() == TOKEN_MINUS) {
        polarity = if (try buffer.readByte() == TOKEN_MINUS) -1 else 1;
        try numberList.append(buffer.lastByte().?);
        startingDigitAt += 1;
    }

    if (try buffer.getPos() >= try buffer.getEndPos()) {
        debug("Invalid number; cannot be just + or -", .{});
        return error.ParseNumberError;
    }

    if (config.parserType == ParserType.json5 and try isReservedInfinity(buffer)) {
        try expectWord(buffer, TOKEN_INFINITY);
        return if (polarity > 0) &JSON_POSITIVE_INFINITY else &JSON_NEGATIVE_INFINITY;
    }

    if (config.parserType == ParserType.json5 and try isReservedNan(buffer)) {
        try expectWord(buffer, TOKEN_NAN);
        return if (polarity > 0) &JSON_POSITIVE_NAN else &JSON_NEGATIVE_NAN;
    }

    // Next character either is a digit or a .
    if (try buffer.peek() == '0') {
        try numberList.append(try buffer.readByte());
        if (try buffer.getPos() < try buffer.getEndPos()) {
            if (try buffer.peek() == TOKEN_ZERO) {
                debug("Invalid number; number cannot start with multiple zeroes", .{});
                return error.ParseNumberError;
            }
            if (try buffer.peek() == 'x') {
                encodingType = NumberEncoding.hex;
                try numberList.append(try buffer.readByte());
            }
        }
    } else if (isNumber(try buffer.peek())) {
        try numberList.append(try buffer.readByte());
    } else if (try buffer.peek() == TOKEN_PERIOD) {
        if (config.parserType == ParserType.rfc8259) {
            debug("Invalid number; RFS8259 doesn't support floating point numbers starting with a decimal point", .{});
            return error.ParseNumberError;
        }

        encodingType = NumberEncoding.float;
        try numberList.append(try buffer.readByte());
        if (try buffer.getPos() >= try buffer.getEndPos()) {
            debug("Invalid number; decimal value must follow decimal point", .{});
            return error.ParseNumberError;
        }
    } else {
        debug("Invalid number; invalid starting character, '{?}'", .{buffer.lastByte()});
        return error.ParseNumberError;
    }

    // Walk through each character
    while (try buffer.getPos() < try buffer.getEndPos() and ((encodingType != NumberEncoding.hex and isNumber(try buffer.peek())) or (encodingType == NumberEncoding.hex and isHexDigit(try buffer.peek())))) : (try numberList.append(try buffer.readByte())) {}

    // Handle decimal numbers
    if (try buffer.getPos() < try buffer.getEndPos() and encodingType != NumberEncoding.hex and try buffer.peek() == TOKEN_PERIOD) {
        encodingType = NumberEncoding.float;
        try numberList.append(try buffer.readByte());
        while (try buffer.getPos() < try buffer.getEndPos() and isNumber(try buffer.peek())) : (try numberList.append(try buffer.readByte())) {}
    }

    // Handle exponent
    if (try buffer.getPos() < try buffer.getEndPos() and encodingType != NumberEncoding.hex and (try buffer.peek() == TOKEN_EXPONENT_LOWER or try buffer.peek() == TOKEN_EXPONENT_UPPER)) {
        encodingType = NumberEncoding.float;
        try numberList.append(try buffer.readByte());
        if (!isNumberOrPlusOrMinus(try buffer.peek())) {
            return error.ParseNumberError;
        }
        // Handle preceeding +/-
        try numberList.append(try buffer.readByte());
        // Handle the exponent value
        while (try buffer.getPos() < try buffer.getEndPos() and isNumber(try buffer.peek())) : (try numberList.append(try buffer.readByte())) {}
    }

    if (try buffer.getPos() > try buffer.getEndPos()) @panic("Fail");
    const jsonValue = try allocator.create(JsonValue);
    errdefer jsonValue.deinit(allocator);

    jsonValue.type = switch (encodingType) {
        NumberEncoding.integer => JsonType.integer,
        NumberEncoding.float => JsonType.float,
        NumberEncoding.hex => JsonType.integer,
        else => return error.ParseNumberError,
    };

    var numberString = try allocator.alloc(u8, numberList.items.len);
    defer allocator.free(numberString);

    for (numberList.items, 0..) |char, index| {
        numberString[index] = char;
    }

    // TODO: Figure out why this block couldn't be in the switch below; kept complaining about not being able to
    //  initialize the union
    var hexBuffer: []const u8 = undefined;
    if (encodingType == NumberEncoding.hex) {
        hexBuffer = numberString[startingDigitAt + 2 .. numberString.len];
    }

    jsonValue.value = switch (encodingType) {
        NumberEncoding.integer => .{ .integer = try std.fmt.parseInt(i64, numberString, 10) },
        NumberEncoding.float => .{ .float = try std.fmt.parseFloat(f64, numberString) },
        // parseInt doesn't support 0x so we have to skip it and manually apply the sign
        NumberEncoding.hex => .{ .integer = polarity * try std.fmt.parseInt(i64, hexBuffer, 16) },
        else => return error.ParseNumberError,
    };

    return jsonValue;
}

// TODO: Drop the JsonValue return
fn parseEcmaScript51Identifier(buffer: *Buffer, allocator: Allocator) ParseErrors!*JsonValue {
    var characters = std.ArrayList(u8).init(allocator);
    while (try buffer.getPos() < try buffer.getEndPos() and try isValidEcmaScript51IdentifierCharacter(buffer)) {
        if (try buffer.peek() == TOKEN_REVERSE_SOLIDUS) {
            // Unicode escaped character
            if (try buffer.getEndPos() - try buffer.getPos() < 6) {
                return error.ParseStringError;
            }

            var buf: [4]u8 = undefined;
            try expectOnly(buffer, TOKEN_REVERSE_SOLIDUS);
            try expectOnly(buffer, 'u');
            _ = try buffer.read(&buf);
            const intValue = try std.fmt.parseInt(u21, &buf, 16);
            buf = undefined;
            const len = try std.unicode.utf8Encode(intValue, &buf);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try characters.append(buf[i]);
            }
        } else {
            try characters.append(try buffer.readByte());
        }
    }

    if (try buffer.getPos() > try buffer.getEndPos()) return error.ParseStringError;

    const jsonValue = try allocator.create(JsonValue);
    errdefer jsonValue.deinit(allocator);

    const copy = try allocator.alloc(u8, characters.items.len);
    errdefer allocator.free(copy);

    for (characters.items, 0..) |char, i| {
        copy[i] = char;
    }
    characters.deinit();

    jsonValue.type = JsonType.string;
    jsonValue.value = .{ .string = copy };
    jsonValue.stringPtr = copy;

    return jsonValue;
}

/// Expects the next significant character be token, skipping over all leading and trailing
/// insignificant whitespace, or returns UnexpectedTokenError.
fn expect(buffer: *Buffer, config: ParserConfig, token: u8) ParseErrors!void {
    try skipWhiteSpaces(buffer, config);
    if (try buffer.peek() != token) {
        debug("Expected {c} found {c}", .{ token, try buffer.peek() });
        return error.UnexpectedTokenError;
    }
    try buffer.skipBytes(1);
    try skipWhiteSpaces(buffer, config);
}

/// Expects the next character be token or returns UnexpectedTokenError.
fn expectOnly(buffer: *Buffer, token: u8) ParseErrors!void {
    if (try buffer.peek() != token) {
        debug("Expected {c} found {c}", .{ token, try buffer.peek() });
        return error.UnexpectedTokenError;
    }
    try buffer.skipBytes(1);
}

/// Expects the next significant character be token, skipping over all leading insignificant
/// whitespace, or returns UnexpectedTokenError.
fn expectUpTo(buffer: *Buffer, config: ParserConfig, token: u8) ParseErrors!void {
    try skipWhiteSpaces(buffer, config);
    if (try buffer.peek() != token) {
        debug("Expected {c} found {c}", .{ token, try buffer.peek() });
        return error.UnexpectedTokenError;
    }
    try buffer.skipBytes(1);
}

/// Returns the index in the string with the next, significant character
/// starting from the beginning.
fn skipWhiteSpaces(buffer: *Buffer, config: ParserConfig) ParseErrors!void {
    while (true) {
        // Skip any whitespace
        while (try buffer.getPos() < try buffer.getEndPos() and isInsignificantWhitespace(try buffer.peek(), config)) : (try buffer.skipBytes(1)) {}

        // Skip any comments
        if (config.parserType == ParserType.json5 and try isComment(buffer)) {
            try skipComment(buffer);

            // If we found comments; we need to ensure we've skipped whitespace again
            continue;
        }

        return;
    }
}

/// Skip over comments
fn skipComment(buffer: *Buffer) ParseErrors!void {
    if (!try isComment(buffer)) return;

    var tokens: [2]u8 = undefined;
    _ = try buffer.read(&tokens);
    if (tokens[1] == TOKEN_SOLIDUS) {
        // Single line comment - expect a newline
        while (try buffer.getPos() < try buffer.getEndPos() and try buffer.peek() != TOKEN_NEW_LINE) : (try buffer.skipBytes(1)) {}
    } else if (tokens[1] == TOKEN_ASTERISK) {
        // Multi-line comment
        while (try buffer.getPos() < try buffer.getEndPos() and (try buffer.peek() != TOKEN_ASTERISK or try buffer.peekNext() != TOKEN_SOLIDUS)) : (try buffer.skipBytes(1)) {}
        // Skip over the comment lead-out
        try buffer.skipBytes(2);
    } else {
        unreachable;
    }
}

/// Returns true if jsonString starts with a comment
fn isComment(buffer: *Buffer) ParseErrors!bool {
    return 1 < try buffer.getEndPos() and try buffer.peek() == TOKEN_SOLIDUS and (try buffer.peekNext() == TOKEN_SOLIDUS or try buffer.peekNext() == TOKEN_ASTERISK);
}

/// Returns true if a character matches the RFC8259 grammar specificiation for
/// insignificant whitespace.
fn isInsignificantWhitespace(char: u8, config: ParserConfig) bool {
    if (config.parserType == ParserType.rfc8259) {
        return char == TOKEN_HORIZONTAL_TAB or char == TOKEN_NEW_LINE or char == TOKEN_CARRIAGE_RETURN or char == TOKEN_SPACE;
    }

    return char == TOKEN_HORIZONTAL_TAB or char == TOKEN_NEW_LINE or char == TOKEN_VERTICAL_TAB or char == TOKEN_FORM_FEED or char == TOKEN_CARRIAGE_RETURN or char == TOKEN_SPACE or char == TOKEN_NON_BREAKING_SPACE or char == TOKEN_LINE_SEPARATOR or char == TOKEN_PARAGRAPH_SEPARATOR or char == TOKEN_BOM;
    // TODO: Space Separator Unicode category
}

/// Returns true if the character is a plus or minus
fn isPlusOrMinus(char: u8) bool {
    return char == TOKEN_PLUS or char == TOKEN_MINUS;
}

/// Returns true if the character is a number, minus, or plus
fn isNumberOrPlusOrMinus(char: u8) bool {
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

fn isReservedFalse(buffer: *Buffer) ParseErrors!bool {
    return try buffer.peek() == TOKEN_FALSE[0];
}

fn isReservedInfinity(buffer: *Buffer) ParseErrors!bool {
    return try buffer.peek() == TOKEN_INFINITY[0];
}

fn isReservedNan(buffer: *Buffer) ParseErrors!bool {
    return try buffer.peek() == TOKEN_NAN[0] and try buffer.peekNext() == TOKEN_NAN[1];
}

fn isReservedNull(buffer: *Buffer) ParseErrors!bool {
    return try buffer.peek() == TOKEN_NULL[0] and try buffer.peekNext() == TOKEN_NULL[1];
}

fn isReservedTrue(buffer: *Buffer) ParseErrors!bool {
    return try buffer.peek() == TOKEN_TRUE[0];
}

fn expectWord(buffer: *Buffer, word: []const u8) ParseErrors!void {
    for (word) |c| {
        try expectOnly(buffer, c);
    }
}

/// Returns true if jsonString starts with an ECMA Script 5.1 identifier
fn isStartOfEcmaScript51Identifier(buffer: *Buffer) ParseErrors!bool {
    const char = try buffer.peek();
    // Allowable Identifier starting characters
    if (char == TOKEN_COLON) return false;
    if (isEcmaScript51IdentifierUnicodeCharacter(char) or char == TOKEN_DOLLAR_SIGN or char == TOKEN_UNDERSCORE) return true;
    if (try buffer.getEndPos() >= 6) {
        return try buffer.peek() == TOKEN_REVERSE_SOLIDUS and try buffer.peekNext() == 'u';
    }

    return false;
}

/// Returns true if the character is an ECMA Script 5.1 identifier unicode character
fn isEcmaScript51IdentifierUnicodeCharacter(char: u8) bool {
    return char >= 0x0041 and char <= 0x1E921;
}

/// Returns true if the character is an ECMA Script 5.1 identifier character
fn isValidEcmaScript51IdentifierCharacter(buffer: *Buffer) ParseErrors!bool {
    const char = try buffer.peek();
    return char != TOKEN_COLON and (try isStartOfEcmaScript51Identifier(buffer)
    // TODO: or isUnicodeCombiningSpaceMark(jsonString[0])
    or isUnicodeDigit(char)
    // TODO: or isUnicodeConnectorPunctuation(jsonString[0])
    or char == TOKEN_ZERO_WIDTH_NON_JOINER or char == TOKEN_ZERO_WIDTH_JOINER);
}

/// Returns true if the character is a unicode digit
fn isUnicodeDigit(char: u8) bool {
    return (char >= 0x0030 and char <= 0x0039)
    // TODO: Finish these...
    or (char >= 0x0660 and char <= 0x0669) or (char >= 0x06F0 and char <= 0x06F9) or (char >= 0x07C0 and char <= 0x07C9) or (char >= 0x0966 and char <= 0x096F) or (char >= 0x09E6 and char <= 0x09EF) or (char >= 0x0A66 and char <= 0x0A6F) or (char >= 0x0AE6 and char <= 0x0AEF) or (char >= 0x0B66 and char <= 0x00BF) or (char >= 0x0BE6 and char <= 0x0BEF) or (char >= 0x0C66 and char <= 0x0C6F) or (char >= 0x0CE6 and char <= 0x0CEF) or (char >= 0x0D66 and char <= 0x0D6F);
}

fn isHexDigit(char: u8) bool {
    return (char >= '0' and char <= '9') or (char >= 'A' and char <= 'F') or (char >= 'a' and char <= 'f');
}

/// Helper for printing messages
fn debug(comptime msg: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print(msg, args);
        std.debug.print("\n", .{});
    }
}

/// Helper for testing parsed numbers - only calls parseNumber
/// number can be an expected number or an expected error
fn expectParseNumberToParseNumber(number: anytype, text: []const u8, config: ParserConfig) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var buffer = bufferFromText(text);

    const value = switch (@typeInfo(@TypeOf(number))) {
        @typeInfo(ParseErrors) => parseNumber(&buffer, config, allocator),
        else => try parseNumber(&buffer, config, allocator),
    };

    switch (@typeInfo(@TypeOf(number))) {
        .Int, @typeInfo(comptime_int) => try std.testing.expectEqual(JsonType.integer, value.type),
        .Float, @typeInfo(comptime_float) => try std.testing.expectEqual(JsonType.float, value.type),
        @typeInfo(ParseErrors) => {},
        else => @compileError("Eek: " ++ @typeName(@TypeOf(number))),
    }

    switch (@typeInfo(@TypeOf(number))) {
        @typeInfo(comptime_int) => try std.testing.expectEqual(@as(i64, number), value.integer()),
        .Int => try std.testing.expectEqual(number, value.integer()),
        @typeInfo(comptime_float) => try std.testing.expectEqual(@as(f64, number), value.float()),
        .Float => try std.testing.expectEqual(number, value.float()),
        @typeInfo(ParseErrors) => try std.testing.expectError(number, value),
        else => @compileError("Eek: " ++ @typeName(@TypeOf(number))),
    }

    switch (@typeInfo(@TypeOf(number))) {
        @typeInfo(ParseErrors) => {},
        else => {
            if (!value.indestructible) {
                value.deinit(allocator);
            }
        },
    }

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

// Unit Tests
test "parse can parse a number" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var bufferOne = bufferFromText("0");
    var value = try parseBuffer(&bufferOne, allocator);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 0);

    value.deinit(allocator);

    var bufferTwo = bufferFromText("0.1");
    value = try parseBuffer(&bufferTwo, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 0.1);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "parse can parse a object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{\"foo\":\"bar\"}");
    const value = try parseBuffer(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.object);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "parse can parse a array" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("[0,\"foo\",1.337]");
    const value = try parseBuffer(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "foo"));
    try std.testing.expectEqual(value.get(2).float(), 1.337);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "parse can parse an object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{\"foo\":\"bar\", \"zig\":\"zabim\"}");
    const value = try parseBuffer(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expect(std.mem.eql(u8, value.get("foo").string(), "bar"));
    const keys = value.object().keys();

    // TODO: Improve these conditions - can't rely on deterministic key ordering
    try std.testing.expectEqual(2, keys.len);
    try std.testing.expectEqualStrings("foo", keys[0]);
    try std.testing.expectEqualStrings("zig", keys[1]);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.3: parseValue can parse true" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("true");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.boolean);
    try std.testing.expectEqual(value.boolean(), true);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.3: parseValue can parse false" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("false");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.boolean);
    try std.testing.expectEqual(value.boolean(), false);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.3: parseValue can parse null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("null");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.nil);
    try std.testing.expect(value.value == null);

    // Note: true, false, and null are constant JsonValues
    // and should not be destroyed

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject can parse an empty object /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{}");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject can parse an empty object /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{ }");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject can parse an empty object /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create an empty object with all insignificant whitespace characters
    var buffer = bufferFromText("\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}");
    const value = try parseValue(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.object);
    try std.testing.expectEqual(value.object().len(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject can parse a simple object /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{\"key1\": \"foo\", \"key2\": \"foo2\", \"key3\": -1, \"key4\": [], \"key5\": { } }");
    var jsonResult = try parseObject(&buffer, CONFIG_RFC8259, allocator);
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

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject can parse a simple object /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Same text body as /1 but every inbetween character is the set of insignificant whitepsace
    // characters
    var buffer = bufferFromText("\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key1\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key2\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo2\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key3\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key4\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"key5\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}");
    var jsonResult = try parseObject(&buffer, CONFIG_RFC8259, allocator);
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

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject returns UnexpectedTokenException on trailing comma" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Same text body as /1 but every inbetween character is the set of insignificant whitepsace
    // characters
    var buffer = bufferFromText("{\"key1\": 1, \"key2\": \"two\", \"key3\": 3.0, \"key4\", {},}");
    const jsonResult = parseObject(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.UnexpectedTokenError, jsonResult);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.4: parseObject returns UnexpectedTokenException on missing comma" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Same text body as /1 but every inbetween character is the set of insignificant whitepsace
    // characters
    var buffer = bufferFromText("{\"key1\": 1, \"key2\": \"two\", \"key3\": 3.0, \"key4\" {}}");
    const jsonResult = parseObject(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.UnexpectedTokenError, jsonResult);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.5: parseArray can parse an empty array /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("[]");
    const value = try parseArray(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.5: parseArray can parse an empty array /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}");
    const value = try parseArray(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.5: parseArray can parse an simple array /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("[-1,-1.2,0,1,1.2,\"\",\"foo\",true,false,null,{},{\"foo\":\"bar\", \"baz\": {}}]");
    const value = try parseArray(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 12);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.5: parseArray can parse an simple array /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}[\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}-1.2\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}0\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}1\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}1.2\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}true\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}false\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}null\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"foo\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"bar\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d},\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"baz\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}:\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}{\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}}\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}]\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}");
    const value = try parseArray(&buffer, CONFIG_RFC8259, allocator);
    errdefer value.deinit(allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.array().len(), 12);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.5: parseArray returns UnexpectedTokenError on trailing comma" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("[1,\"two\",3.0,{},]");
    const value = parseArray(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.UnexpectedTokenError, value);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a integer /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("0");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a integer /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("1");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 1);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a integer /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("1337");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), 1337);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a integer /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-1337");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.integer);
    try std.testing.expectEqual(value.integer(), -1337);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a float /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("1.0");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 1.0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a float /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-1.0");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -1.0);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a float /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("1337.0123456789");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 1337.0123456789);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse a float /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-1337.0123456789");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -1337.0123456789);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("13e37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13e37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("13E37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("13E+37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E+37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("13E-37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E-37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-13e37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13e37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /6" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-13E37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13E37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /7" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("-13E+37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), -13E+37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber can parse an exponent /8" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("13E-37");
    const value = try parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectEqual(value.type, JsonType.float);
    try std.testing.expectEqual(value.float(), 13E-37);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber fails on a repeating 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("00");
    const value = parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.ParseNumberError, value);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber fails on a non-minus and non-digit start /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("a0");
    const value = parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.ParseNumberError, value);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber fails on a non-minus and non-digit start /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("+0");
    const value = parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.ParseNumberError, value);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6: parseNumber fails on number starting with decimal point" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText(".0");
    const value = parseNumber(&buffer, CONFIG_RFC8259, allocator);
    try std.testing.expectError(error.ParseNumberError, value);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.6 parseNumber ignores multi-line comments /1" {
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */0.0/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-0.0/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */+0.0/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */0.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */+.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */+0.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-0.1/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */100.0/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-100.0/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */Infinity/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-Infinity/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */+Infinity/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */NaN/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */-NaN/* comment */", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "/* comment */+NaN/* comment */", CONFIG_RFC8259);
}

test "RFC8259.6 parseNumber fails on single-line comments /1" {
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n0.0\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-0.0\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n+0.0\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n0.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n+.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n+0.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-0.1\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n100.0\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-100.0\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\nInfinity\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-Infinity\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n+Infinity\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\nNaN\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n-NaN\n// comment", CONFIG_RFC8259);
    try expectParseNumberToParseNumber(error.ParseNumberError, "// comment\n+NaN\n// comment", CONFIG_RFC8259);
}

test "JSON5.7 parseArray ignores multi-line comments /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("/* comment */[/* comment */1/* comment */,/* comment */\"two\"/* comment */,/* comment */3.0/* comment */,/* comment */{/* comment */},/* comment */'five'/* comment */,/* comment */{/* comment */six/* comment */:/* comment */0x07/* comment */}/* comment */]/* comment */");
    const value = try parseArray(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 1);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "two"));
    try std.testing.expectEqual(value.get(2).float(), 3.0);
    try std.testing.expectEqual(value.get(3).object().len(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(4).string(), "five"));
    try std.testing.expectEqual(value.get(5).get("six").integer(), 7);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7 parseArray ignores single-line comments /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("// comment \n[// comment \n1// comment \n,// comment \n\"two\"// comment \n,// comment \n3.0// comment \n,// comment \n{// comment \n},// comment \n'five'// comment \n,// comment \n{// comment \nsix// comment \n:// comment \n0x07// comment \n}// comment \n]// comment \n");
    const value = try parseArray(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 1);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "two"));
    try std.testing.expectEqual(value.get(2).float(), 3.0);
    try std.testing.expectEqual(value.get(3).object().len(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(4).string(), "five"));
    try std.testing.expectEqual(value.get(5).get("six").integer(), 7);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7: parseObject ignores multi-line comments /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("/* comment */{/* comment */key1/* comment */:/* comment */\"foo\"/* comment */,/* comment */ȡkey2/* comment */:/* comment */\"foo2\"/* comment */,/* comment */\u{0221}key3/* comment */:/* comment */-1/* comment */,/* comment */'key4'/* comment */:/* comment */[/* comment */]/* comment */,/* comment */\"key5\"/* comment */:/* comment */{/* comment */}/* comment */,/* comment */}/* comment */");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7: parseObject ignores single-line comments /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("// comment \n{// comment \nkey1// comment \n:// comment \n\"foo\"// comment \n,// comment \nȡkey2// comment \n:// comment \n\"foo2\"// comment \n,// comment \n\u{0221}key3// comment \n:// comment \n-1// comment \n,// comment \n'key4'// comment \n:// comment \n[// comment \n]// comment \n,// comment \n\"key5\"// comment \n:// comment \n{// comment \n}// comment \n,// comment \n}// comment \n");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse an empty string /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\"\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), ""));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse an empty string /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}\"\"\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), ""));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\"some string\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some string"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\"some\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}string\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\u{20}\u{09}\u{0A}\u{0a}\u{0D}\u{0d}string"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // some\"string
    var buffer = bufferFromText("\"some\\\"string\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\"string"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // some\\"string
    var buffer = bufferFromText("\"some\\\\\\\"string\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "some\\\"string"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.7: parseStringWithTerminal can parse a simple string /5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // ",\,\u{00-0f}
    var buffer = bufferFromText("\"\\\"\\\\\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{0F}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1A}\u{1B}\u{1C}\u{1D}\u{1E}\u{1F}\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "\"\\\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{0F}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1A}\u{1B}\u{1C}\u{1D}\u{1E}\u{1F}"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "RFC8259.8.3: parseStringWithTerminal parsing results in equivalent strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Test that \\ equals \u{5C}
    var buffer = bufferFromText("\"a\\\\b\"");
    const value = try parseStringWithTerminal(&buffer, CONFIG_RFC8259, allocator, TOKEN_DOUBLE_QUOTE);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "a\u{5C}b"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5; parseEcmaScript51Identifier can parse simple identifier /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("someIdentifier");
    const value = try parseEcmaScript51Identifier(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "someIdentifier"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5; parseEcmaScript51Identifier can parse simple identifier /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("_someIdentifier");
    const value = try parseEcmaScript51Identifier(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "_someIdentifier"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5; parseEcmaScript51Identifier can parse simple identifier /3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("$someIdentifier");
    const value = try parseEcmaScript51Identifier(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "$someIdentifier"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.3; parseEcmaScript51Identifier can parse simple identifier /2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("\\u005FsomeIdentifier");
    const value = try parseEcmaScript51Identifier(&buffer, allocator);
    try std.testing.expectEqual(value.type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, value.string(), "\u{005f}someIdentifier"));

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.3: parseObject can parse a simple object /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{key1: \"foo\", ȡkey2: \"foo2\", \u{0221}key3 : -1, 'key4': [], \"key5\": { } }");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.3: parseObject can parse a simple object with trailing comma" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("{key1: \"foo\", ȡkey2: \"foo2\", \u{0221}key3 : -1, 'key4': [], \"key5\": { }, }");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.4 parseArray can parse a simple array /1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("[1, \"two\", 3.0, {}, 'five', {six: 0x07}]");
    const value = try parseArray(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 1);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "two"));
    try std.testing.expectEqual(value.get(2).float(), 3.0);
    try std.testing.expectEqual(value.get(3).object().len(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(4).string(), "five"));
    try std.testing.expectEqual(value.get(5).get("six").integer(), 7);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.6 parseNumber can parse an integer" {
    try expectParseNumberToParseNumber(0, "0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0, "-0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0, "+0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(100, "100", CONFIG_JSON5);
    try expectParseNumberToParseNumber(100, "+100", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-100, "-100", CONFIG_JSON5);
}

test "JSON5.6 parseNumber can parse a hex number" {
    try expectParseNumberToParseNumber(0x0, "0x0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "0x00", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "0x000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "0x0000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "-0x0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "-0x00", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "-0x000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "-0x0000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "+0x0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "+0x00", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "+0x000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0, "+0x0000", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0123456789ABCDEF, "0x0123456789ABCDEF", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0x0123456789ABCDEF, "-0x0123456789ABCDEF", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0x0123456789ABCDEF, "+0x0123456789ABCDEF", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xA, "0xA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0xA, "-0xA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xA, "+0xA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xAA, "0xAA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0xAA, "-0xAA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xAA, "+0xAA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xAAA, "0xAAA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0xAAA, "-0xAAA", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0xAAA, "+0xAAA", CONFIG_JSON5);
}

test "JSON5.4 parseNumber can parse a float" {
    try expectParseNumberToParseNumber(0.0, "0.0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "-0.0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "+0.0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "0.1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, ".1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "+.1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "-.1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "+0.1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "-0.1", CONFIG_JSON5);
    try expectParseNumberToParseNumber(100.0, "100.0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-100.0, "-100.0", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "Infinity", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-std.math.inf(f64), "-Infinity", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "+Infinity", CONFIG_JSON5);
    // No nan checking here because NaN != NaN
}

test "JSON5.6 parseNumber can parse nan" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer1 = bufferFromText("NaN");
    var value = try parseNumber(&buffer1, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(JsonType.float, value.type);
    try std.testing.expectEqual(value, &JSON_POSITIVE_NAN);
    try std.testing.expect(std.math.isNan(value.float()));

    var buffer2 = bufferFromText("+NaN");
    value = try parseNumber(&buffer2, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(JsonType.float, value.type);
    try std.testing.expectEqual(value, &JSON_POSITIVE_NAN);
    try std.testing.expect(std.math.isNan(value.float()));

    var buffer3 = bufferFromText("-NaN");
    value = try parseNumber(&buffer3, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(JsonType.float, value.type);
    try std.testing.expectEqual(value, &JSON_NEGATIVE_NAN);
    try std.testing.expect(std.math.isNan(value.float()));

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7 parseArray ignores multi-line comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("/* comment */[/* comment */1/* comment */,/* comment */\"two\"/* comment */,/* comment */3.0/* comment */,/* comment */{/* comment */},/* comment */'five'/* comment */,/* comment */{/* comment */six/* comment */:/* comment */0x07/* comment */}/* comment */]/* comment */");
    const value = try parseArray(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 1);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "two"));
    try std.testing.expectEqual(value.get(2).float(), 3.0);
    try std.testing.expectEqual(value.get(3).object().len(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(4).string(), "five"));
    try std.testing.expectEqual(value.get(5).get("six").integer(), 7);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7 parseArray ignores single-line comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("// comment \n[// comment \n1// comment \n,// comment \n\"two\"// comment \n,// comment \n3.0// comment \n,// comment \n{// comment \n},// comment \n'five'// comment \n,// comment \n{// comment \nsix// comment \n:// comment \n0x07// comment \n}// comment \n]// comment \n");
    const value = try parseArray(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(value.type, JsonType.array);
    try std.testing.expectEqual(value.get(0).integer(), 1);
    try std.testing.expect(std.mem.eql(u8, value.get(1).string(), "two"));
    try std.testing.expectEqual(value.get(2).float(), 3.0);
    try std.testing.expectEqual(value.get(3).object().len(), 0);
    try std.testing.expect(std.mem.eql(u8, value.get(4).string(), "five"));
    try std.testing.expectEqual(value.get(5).get("six").integer(), 7);

    value.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7: parseObject ignores multi-line comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("/* comment */{/* comment */key1/* comment */:/* comment */\"foo\"/* comment */,/* comment */ȡkey2/* comment */:/* comment */\"foo2\"/* comment */,/* comment */\u{0221}key3/* comment */:/* comment */-1/* comment */,/* comment */'key4'/* comment */:/* comment */[/* comment */]/* comment */,/* comment */\"key5\"/* comment */:/* comment */{/* comment */}/* comment */,/* comment */}/* comment */");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.7: parseObject ignores single-line comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buffer = bufferFromText("// comment \n{// comment \nkey1// comment \n:// comment \n\"foo\"// comment \n,// comment \nȡkey2// comment \n:// comment \n\"foo2\"// comment \n,// comment \n\u{0221}key3// comment \n:// comment \n-1// comment \n,// comment \n'key4'// comment \n:// comment \n[// comment \n]// comment \n,// comment \n\"key5\"// comment \n:// comment \n{// comment \n}// comment \n,// comment \n}// comment \n");
    var jsonResult = try parseObject(&buffer, CONFIG_JSON5, allocator);
    try std.testing.expectEqual(jsonResult.type, JsonType.object);

    try std.testing.expectEqual(jsonResult.object().contains("key1"), true);
    try std.testing.expectEqual(jsonResult.get("key1").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("key1").string(), "foo"));

    try std.testing.expectEqual(jsonResult.object().contains("\u{0221}key2"), true);
    try std.testing.expectEqual(jsonResult.get("\u{0221}key2").type, JsonType.string);
    try std.testing.expect(std.mem.eql(u8, jsonResult.get("\u{0221}key2").string(), "foo2"));

    try std.testing.expectEqual(jsonResult.object().contains("ȡkey3"), true);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").type, JsonType.integer);
    try std.testing.expectEqual(jsonResult.get("ȡkey3").integer(), -1);

    try std.testing.expectEqual(jsonResult.object().contains("key4"), true);
    try std.testing.expectEqual(jsonResult.get("key4").type, JsonType.array);
    try std.testing.expectEqual(jsonResult.get("key4").len(), 0);

    try std.testing.expectEqual(jsonResult.object().contains("key5"), true);
    try std.testing.expectEqual(jsonResult.get("key5").type, JsonType.object);
    try std.testing.expectEqual(jsonResult.get("key5").len(), 0);

    jsonResult.deinit(allocator);

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "JSON5.4 parseNumber ignores multi-line comments" {
    try expectParseNumberToParseNumber(0.0, "/* comment */0.0/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "/* comment */-0.0/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "/* comment */+0.0/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "/* comment */0.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "/* comment */.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "/* comment */+.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "/* comment */-.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "/* comment */+0.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "/* comment */-0.1/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(100.0, "/* comment */100.0/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-100.0, "/* comment */-100.0/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "/* comment */Infinity/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-std.math.inf(f64), "/* comment */-Infinity/* comment */", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "/* comment */+Infinity/* comment */", CONFIG_JSON5);
}

test "JSON5.4 parseNumber ignores single-line comments" {
    try expectParseNumberToParseNumber(0.0, "// comment\n0.0\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "// comment\n-0.0\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.0, "// comment\n+0.0\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "// comment\n0.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "// comment\n.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "// comment\n+.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "// comment\n-.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(0.1, "// comment\n+0.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-0.1, "// comment\n-0.1\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(100.0, "// comment\n100.0\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-100.0, "// comment\n-100.0\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "// comment\nInfinity\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(-std.math.inf(f64), "// comment\n-Infinity\n// comment", CONFIG_JSON5);
    try expectParseNumberToParseNumber(std.math.inf(f64), "// comment\n+Infinity\n// comment", CONFIG_JSON5);
}

test "README.md simple test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const Check = std.heap.Check;
    defer std.debug.assert(gpa.deinit() == Check.ok);
    const allocator = gpa.allocator();

    var buffer = bufferFromText(
        \\{
        \\  "foo": [
        \\    null,
        \\    true,
        \\    false,
        \\    "bar",
        \\    {
        \\      "baz": -13e+37
        \\    }
        \\  ]
        \\}
    );
    const value = try parseBuffer(&buffer, allocator);
    const bazObj = value.get("foo").get(4);

    bazObj.print(null);
    try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

    defer value.deinit(allocator);
}

test "README.md simple test json5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const Check = std.heap.Check;
    defer std.debug.assert(gpa.deinit() == Check.ok);
    const allocator = gpa.allocator();

    var buffer = bufferFromText(
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
    );
    const value = try parseJson5Buffer(&buffer, allocator);
    const bazObj = value.get("foo").get(4);

    bazObj.print(null);
    try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

    defer value.deinit(allocator);
}

test "README.md simple test with stream source" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == std.heap.Check.ok);
    const allocator = gpa.allocator();

    var source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(
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
    ) };
    var buffer = bufferFromStreamSource(&source);
    const value = try parseJson5Buffer(&buffer, allocator);
    const bazObj = value.get("foo").get(4);

    bazObj.print(null);
    try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);

    defer value.deinit(allocator);
}

test "README.md simple test from file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == std.heap.Check.ok);
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("testFiles/some.json", .{});
    defer file.close();

    const value = try parseFile(file, allocator);
    errdefer value.deinit(allocator);
    defer value.deinit(allocator);

    const bazObj = value.get("foo").get(4);

    bazObj.print(null);
    try std.testing.expectEqual(bazObj.get("baz").float(), -13e+37);
}

fn testEquality(allocator: std.mem.Allocator, string1: []const u8, string2: []const u8) !void {
    const value1 = try parse(string1, allocator);
    const value2 = try parse(string2, allocator);

    try std.testing.expect(value1.eql(value2));
    value1.deinit(allocator);
    value2.deinit(allocator);
}

// Positive equality tests
// Are these base type tests worth checking? I think the compiler optimizes the "different" values away
test "Test integer equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "5";
    try testEquality(allocator, body, "5");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test boolean equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "true";
    try testEquality(allocator, body, "true");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test float equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "84793.0";
    try testEquality(allocator, body, "84793.0");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test string equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body =
        \\"a string to parse"
    ;

    try testEquality(allocator, body, "\"a string to parse\"");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test trivial array equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "[]";
    try testEquality(allocator, body, "[]");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test single type array equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "[5, 3, 8, 9, 53]";
    try testEquality(allocator, body, "[5, 3, 8, 9, 53]");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test trivial object equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "{}";

    try testEquality(allocator, body, "{}");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test basic object equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body =
        \\{"an": "object", "even": true}
    ;
    try testEquality(allocator, body,
        \\{"an": "object", "even": true}
    );
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test deep object equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body =
        \\{"an": "object", "even": {"with": "fields", "and": ["an", "array", "inside", "that", {"object": 3}]}}
    ;

    try testEquality(allocator, body,
        \\{"even": {"and": ["an", "array", "inside", "that", {"object": 3}], "with": "fields"}, "an": "object"}
    );
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test deep array equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body =
        \\[5, 3.0, false, 9, "a big string", {"an": "object", "even": true}, ["a", "b", "c"]]
    ;

    try testEquality(allocator, body,
        \\[5, 3.0, false, 9, "a big string", {"an": "object", "even": true}, ["a", "b", "c"]]
    );
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test null equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "null";

    try testEquality(allocator, body, "null");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}
// Add in a few negative tests for some common gotchas
fn testInequality(allocator: std.mem.Allocator, string1: []const u8, string2: []const u8) !void {
    const value1 = try parse(string1, allocator);
    const value2 = try parse(string2, allocator);

    try std.testing.expect(!value1.eql(value2));
    value1.deinit(allocator);
    value2.deinit(allocator);
}

test "Test integer-float inequality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "6.0";

    try testInequality(allocator, body, "6");
    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test anything-null inequality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const examples = [_][]const u8{ "6.0", "5", "{}", "[]", "\"\"", "true" };
    var i: usize = 0;
    while (i < examples.len) : (i += 1) {
        try testInequality(allocator, examples[i], "null");
    }

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test small float inequality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "6.0";
    try testInequality(allocator, body, "6.0001");

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test empty-filled object inequality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "{}";
    try testInequality(allocator, body,
        \\{"trivial": "key"}
    );

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}

test "Test empty-filled array inequality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const body = "[]";
    try testInequality(allocator, body,
        \\["trivial"]
    );

    const Check = std.heap.Check;
    try std.testing.expect(gpa.deinit() == Check.ok);
}
// Check whether tests are executed.
//test{try std.testing.expect(false);}
