#include "json.h"

const JsonValue* JsonValue::get(const std::string& key) const {
    if (kind != Kind::Object) return nullptr;
    for (auto& [name, value] : object) {
        if (name == key) return &value;
    }
    return nullptr;
}

namespace {

struct Parser {
    const std::string& text;
    size_t pos = 0;
    bool failed = false;

    void skip() {
        while (pos < text.size()) {
            char c = text[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos;
            } else if (c == '/' && pos + 1 < text.size() && text[pos + 1] == '/') {
                while (pos < text.size() && text[pos] != '\n') ++pos;
            } else if (c == '/' && pos + 1 < text.size() && text[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < text.size() && !(text[pos] == '*' && text[pos + 1] == '/')) ++pos;
                pos = std::min(text.size(), pos + 2);
            } else {
                break;
            }
        }
    }

    static void appendUtf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out.push_back((char)cp);
        } else if (cp < 0x800) {
            out.push_back((char)(0xC0 | (cp >> 6)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back((char)(0xE0 | (cp >> 12)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            out.push_back((char)(0xF0 | (cp >> 18)));
            out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }

    std::string parseString() {
        std::string out;
        ++pos;  // opening quote
        while (pos < text.size() && text[pos] != '"') {
            char c = text[pos++];
            if (c != '\\') {
                out.push_back(c);
                continue;
            }
            if (pos >= text.size()) break;
            char e = text[pos++];
            switch (e) {
            case 'n': out.push_back('\n'); break;
            case 't': out.push_back('\t'); break;
            case 'r': out.push_back('\r'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'u': {
                auto hex4 = [&]() -> uint32_t {
                    if (pos + 4 > text.size()) return 0;
                    uint32_t v = (uint32_t)strtoul(text.substr(pos, 4).c_str(), nullptr, 16);
                    pos += 4;
                    return v;
                };
                uint32_t cp = hex4();
                if (cp >= 0xD800 && cp < 0xDC00 && pos + 6 <= text.size() && text[pos] == '\\'
                    && text[pos + 1] == 'u') {
                    pos += 2;
                    uint32_t low = hex4();
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                }
                appendUtf8(out, cp);
                break;
            }
            default: out.push_back(e); break;
            }
        }
        if (pos < text.size()) ++pos;  // closing quote
        else failed = true;
        return out;
    }

    JsonValue parseValue() {
        skip();
        JsonValue value;
        if (pos >= text.size()) {
            failed = true;
            return value;
        }
        char c = text[pos];
        if (c == '{') {
            value.kind = JsonValue::Kind::Object;
            ++pos;
            skip();
            if (pos < text.size() && text[pos] == '}') {
                ++pos;
                return value;
            }
            while (!failed) {
                skip();
                if (pos >= text.size() || text[pos] != '"') {
                    // A trailing comma before the brace is tolerated.
                    if (pos < text.size() && text[pos] == '}') {
                        ++pos;
                        break;
                    }
                    failed = true;
                    break;
                }
                std::string key = parseString();
                skip();
                if (pos >= text.size() || text[pos] != ':') {
                    failed = true;
                    break;
                }
                ++pos;
                JsonValue member = parseValue();
                value.object.emplace_back(std::move(key), std::move(member));
                skip();
                if (pos < text.size() && text[pos] == ',') {
                    ++pos;
                    continue;
                }
                if (pos < text.size() && text[pos] == '}') {
                    ++pos;
                    break;
                }
                failed = true;
            }
        } else if (c == '[') {
            value.kind = JsonValue::Kind::Array;
            ++pos;
            skip();
            if (pos < text.size() && text[pos] == ']') {
                ++pos;
                return value;
            }
            while (!failed) {
                skip();
                if (pos < text.size() && text[pos] == ']') {
                    ++pos;
                    break;
                }
                value.array.push_back(parseValue());
                skip();
                if (pos < text.size() && text[pos] == ',') {
                    ++pos;
                    continue;
                }
                if (pos < text.size() && text[pos] == ']') {
                    ++pos;
                    break;
                }
                failed = true;
            }
        } else if (c == '"') {
            value.kind = JsonValue::Kind::String;
            value.string = parseString();
        } else if (text.compare(pos, 4, "true") == 0) {
            value.kind = JsonValue::Kind::Bool;
            value.boolean = true;
            pos += 4;
        } else if (text.compare(pos, 5, "false") == 0) {
            value.kind = JsonValue::Kind::Bool;
            pos += 5;
        } else if (text.compare(pos, 4, "null") == 0) {
            pos += 4;
        } else {
            char* end = nullptr;
            value.number = strtod(text.c_str() + pos, &end);
            if (end == text.c_str() + pos) {
                failed = true;
            } else {
                value.kind = JsonValue::Kind::Number;
                pos = end - text.c_str();
            }
        }
        return value;
    }
};

}  // namespace

std::optional<JsonValue> parseJson(const std::string& text) {
    Parser parser{text};
    // A UTF-8 byte-order mark is not part of the document.
    if (startsWith(text, "\xEF\xBB\xBF")) parser.pos = 3;
    JsonValue value = parser.parseValue();
    if (parser.failed) return std::nullopt;
    return value;
}
