// A small JSON reader: the icon manifest, and nothing that needs to be fast.
// `//` and `/* */` comments are accepted, as settings files carry them.
#pragma once

#include "base.h"

struct JsonValue {
    enum class Kind { Null, Bool, Number, String, Array, Object };
    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<JsonValue> array;
    std::vector<std::pair<std::string, JsonValue>> object;

    bool isObject() const { return kind == Kind::Object; }
    bool isArray() const { return kind == Kind::Array; }
    bool isString() const { return kind == Kind::String; }
    bool isNumber() const { return kind == Kind::Number; }
    bool isBool() const { return kind == Kind::Bool; }
    /// The member called `key`, or nullptr.
    const JsonValue* get(const std::string& key) const;
};

/// Nullopt when the text is not JSON.
std::optional<JsonValue> parseJson(const std::string& text);
