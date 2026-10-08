#include "epub.h"

#include "imaging.h"
#include "prefs.h"
#include "services.h"
#include "theme.h"

#include <shellapi.h>

// ── DEFLATE ────────────────────────────────────────────────────────────────
//
// A compact decoder after Mark Adler's puff.c: stored, fixed and dynamic
// Huffman blocks, into a buffer the ZIP directory already sized.

namespace {

struct InflateState {
    const uint8_t* in;
    size_t inLength;
    size_t inCount = 0;
    uint32_t bitBuffer = 0;
    int bitCount = 0;
    uint8_t* out;
    size_t outLength;
    size_t outCount = 0;
    bool failed = false;
};

struct Huffman {
    short count[16];
    short symbol[288];
};

int bits(InflateState& s, int need) {
    uint32_t value = s.bitBuffer;
    while (s.bitCount < need) {
        if (s.inCount >= s.inLength) {
            s.failed = true;
            return 0;
        }
        value |= (uint32_t)s.in[s.inCount++] << s.bitCount;
        s.bitCount += 8;
    }
    s.bitBuffer = value >> need;
    s.bitCount -= need;
    return (int)(value & ((1u << need) - 1));
}

bool stored(InflateState& s) {
    s.bitBuffer = 0;
    s.bitCount = 0;
    if (s.inCount + 4 > s.inLength) return false;
    unsigned length = s.in[s.inCount] | (s.in[s.inCount + 1] << 8);
    unsigned check = s.in[s.inCount + 2] | (s.in[s.inCount + 3] << 8);
    s.inCount += 4;
    if (length != (~check & 0xffff)) return false;
    if (s.inCount + length > s.inLength || s.outCount + length > s.outLength) return false;
    memcpy(s.out + s.outCount, s.in + s.inCount, length);
    s.inCount += length;
    s.outCount += length;
    return true;
}

int decode(InflateState& s, const Huffman& h) {
    int code = 0, first = 0, index = 0;
    for (int length = 1; length <= 15; ++length) {
        code |= bits(s, 1);
        if (s.failed) return -1;
        int count = h.count[length];
        if (code - count < first) return h.symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -1;
}

int construct(Huffman& h, const short* length, int n) {
    for (int len = 0; len <= 15; ++len) h.count[len] = 0;
    for (int symbol = 0; symbol < n; ++symbol) h.count[length[symbol]]++;
    if (h.count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= 15; ++len) {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) return left;
    }
    short offsets[16];
    offsets[1] = 0;
    for (int len = 1; len < 15; ++len) offsets[len + 1] = offsets[len] + h.count[len];
    for (int symbol = 0; symbol < n; ++symbol) {
        if (length[symbol] != 0) h.symbol[offsets[length[symbol]]++] = (short)symbol;
    }
    return left;
}

bool codes(InflateState& s, const Huffman& lengths, const Huffman& distances) {
    static const short lengthBase[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                                         31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
    static const short lengthExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                                          2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
    static const short distanceBase[30] = {1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
                                           193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
    static const short distanceExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
                                            6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
    while (true) {
        int symbol = decode(s, lengths);
        if (symbol < 0 || s.failed) return false;
        if (symbol < 256) {
            if (s.outCount >= s.outLength) return false;
            s.out[s.outCount++] = (uint8_t)symbol;
        } else if (symbol == 256) {
            return true;
        } else {
            symbol -= 257;
            if (symbol >= 29) return false;
            int length = lengthBase[symbol] + bits(s, lengthExtra[symbol]);
            int dsymbol = decode(s, distances);
            if (dsymbol < 0 || dsymbol >= 30 || s.failed) return false;
            size_t distance = distanceBase[dsymbol] + bits(s, distanceExtra[dsymbol]);
            if (s.failed || distance > s.outCount || s.outCount + length > s.outLength) return false;
            for (int i = 0; i < length; ++i, ++s.outCount) s.out[s.outCount] = s.out[s.outCount - distance];
        }
    }
}

bool fixedBlock(InflateState& s) {
    static Huffman lengths, distances;
    static bool built = false;
    if (!built) {
        short length[288];
        int symbol = 0;
        for (; symbol < 144; ++symbol) length[symbol] = 8;
        for (; symbol < 256; ++symbol) length[symbol] = 9;
        for (; symbol < 280; ++symbol) length[symbol] = 7;
        for (; symbol < 288; ++symbol) length[symbol] = 8;
        construct(lengths, length, 288);
        for (symbol = 0; symbol < 30; ++symbol) length[symbol] = 5;
        construct(distances, length, 30);
        built = true;
    }
    return codes(s, lengths, distances);
}

bool dynamicBlock(InflateState& s) {
    static const short order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    short length[320];
    int nlen = bits(s, 5) + 257, ndist = bits(s, 5) + 1, ncode = bits(s, 4) + 4;
    if (s.failed || nlen > 286 || ndist > 30) return false;
    int index = 0;
    for (; index < ncode; ++index) length[order[index]] = (short)bits(s, 3);
    for (; index < 19; ++index) length[order[index]] = 0;
    if (s.failed) return false;
    Huffman lencode, distcode;
    if (construct(lencode, length, 19) != 0) return false;
    index = 0;
    while (index < nlen + ndist) {
        int symbol = decode(s, lencode);
        if (symbol < 0 || s.failed) return false;
        if (symbol < 16) {
            length[index++] = (short)symbol;
        } else {
            short value = 0;
            int repeat;
            if (symbol == 16) {
                if (index == 0) return false;
                value = length[index - 1];
                repeat = 3 + bits(s, 2);
            } else if (symbol == 17) {
                repeat = 3 + bits(s, 3);
            } else {
                repeat = 11 + bits(s, 7);
            }
            if (s.failed || index + repeat > nlen + ndist) return false;
            while (repeat--) length[index++] = value;
        }
    }
    if (length[256] == 0) return false;
    int err = construct(lencode, length, nlen);
    if (err < 0 || (err > 0 && nlen - lencode.count[0] != 1)) return false;
    err = construct(distcode, length + nlen, ndist);
    if (err < 0 || (err > 0 && ndist - distcode.count[0] != 1)) return false;
    return codes(s, lencode, distcode);
}

}  // namespace

std::optional<std::string> inflateRaw(const uint8_t* data, size_t size, size_t expected) {
    std::string out(expected, '\0');
    if (expected == 0) return out;
    InflateState s{data, size};
    s.out = reinterpret_cast<uint8_t*>(out.data());
    s.outLength = expected;
    int last;
    do {
        last = bits(s, 1);
        int type = bits(s, 2);
        if (s.failed) return std::nullopt;
        bool ok = type == 0 ? stored(s) : type == 1 ? fixedBlock(s) : type == 2 ? dynamicBlock(s) : false;
        if (!ok) return std::nullopt;
    } while (!last);
    // A short stream is a truncated one.
    if (s.outCount != expected) return std::nullopt;
    return out;
}

// ── ZipArchive ─────────────────────────────────────────────────────────────

namespace {
uint16_t u16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t u32(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
}  // namespace

std::unique_ptr<ZipArchive> ZipArchive::open(const std::wstring& path) {
    std::unique_ptr<ZipArchive> zip(new ZipArchive());
    zip->file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (zip->file_ == INVALID_HANDLE_VALUE) return nullptr;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(zip->file_, &size) || size.QuadPart < 22) return nullptr;
    zip->size_ = (size_t)size.QuadPart;
    zip->mapping_ = CreateFileMappingW(zip->file_, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!zip->mapping_) return nullptr;
    zip->bytes_ = static_cast<const uint8_t*>(MapViewOfFile(zip->mapping_, FILE_MAP_READ, 0, 0, 0));
    if (!zip->bytes_) return nullptr;
    const uint8_t* d = zip->bytes_;
    size_t n = zip->size_;
    // The end-of-central-directory record, after a comment of up to 64 KB.
    size_t floor = n > 0xFFFF + 22 ? n - 0xFFFF - 22 : 0;
    long long eocd = -1;
    for (long long c = (long long)n - 22; c >= (long long)floor; --c) {
        if (u32(d + c) == 0x06054b50) {
            eocd = c;
            break;
        }
    }
    if (eocd < 0) return nullptr;
    size_t count = u16(d + eocd + 10);
    size_t dirSize = u32(d + eocd + 12), dirOffset = u32(d + eocd + 16);
    if (dirOffset + dirSize > n) return nullptr;
    size_t cursor = dirOffset, end = dirOffset + dirSize;
    for (size_t i = 0; i < count; ++i) {
        if (cursor + 46 > end || u32(d + cursor) != 0x02014b50) break;
        Entry entry;
        entry.method = u16(d + cursor + 10);
        entry.compressed = u32(d + cursor + 20);
        entry.uncompressed = u32(d + cursor + 24);
        size_t nameLength = u16(d + cursor + 28), extra = u16(d + cursor + 30), comment = u16(d + cursor + 32);
        entry.localHeader = u32(d + cursor + 42);
        size_t nameStart = cursor + 46;
        if (nameStart + nameLength > end) break;
        std::string name(reinterpret_cast<const char*>(d + nameStart), nameLength);
        if (!name.empty() && name.back() != '/' && isValidUTF8(name)) {
            if (zip->entries_.emplace(name, entry).second) zip->order_.push_back(name);
        }
        cursor = nameStart + nameLength + extra + comment;
    }
    if (zip->entries_.empty()) return nullptr;
    return zip;
}

ZipArchive::~ZipArchive() {
    if (bytes_) UnmapViewOfFile(bytes_);
    if (mapping_) CloseHandle(mapping_);
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
}

std::optional<std::string> ZipArchive::data(const std::string& path) const {
    auto hit = entries_.find(path);
    if (hit == entries_.end()) return std::nullopt;
    const Entry& e = hit->second;
    if (e.uncompressed > maxEntryBytes || e.compressed > maxEntryBytes) return std::nullopt;
    if (e.localHeader + 30 > size_ || u32(bytes_ + e.localHeader) != 0x04034b50) return std::nullopt;
    size_t start = e.localHeader + 30 + u16(bytes_ + e.localHeader + 26) + u16(bytes_ + e.localHeader + 28);
    if (start + e.compressed > size_) return std::nullopt;
    if (e.method == 0) {
        if (e.compressed != e.uncompressed) return std::nullopt;
        return std::string(reinterpret_cast<const char*>(bytes_ + start), e.compressed);
    }
    if (e.method == 8) return inflateRaw(bytes_ + start, e.compressed, e.uncompressed);
    return std::nullopt;
}

// ── XML ────────────────────────────────────────────────────────────────────

std::optional<std::string> XmlNode::attribute(const std::string& key) const {
    for (auto& [k, v] : attributes) {
        if (k == key) return v;
    }
    return std::nullopt;
}

std::string XmlNode::localName() const {
    size_t colon = name.find(':');
    return colon == std::string::npos ? name : name.substr(colon + 1);
}

std::string XmlNode::textContent() const {
    if (isText()) return text;
    std::string out;
    for (auto& child : children) out += child.textContent();
    return out;
}

void XmlNode::findAll(const std::string& local, std::vector<const XmlNode*>& out) const {
    for (auto& child : children) {
        if (!child.isText() && child.localName() == local) out.push_back(&child);
        child.findAll(local, out);
    }
}

const XmlNode* XmlNode::find(const std::string& local) const {
    std::vector<const XmlNode*> found;
    findAll(local, found);
    return found.empty() ? nullptr : found.front();
}

XmlNode parseXml(std::string_view s) {
    XmlNode root;
    root.name = "#document";
    std::vector<XmlNode*> stack{&root};
    size_t i = 0;
    auto appendText = [&](std::string_view text) {
        if (text.empty()) return;
        XmlNode* parent = stack.back();
        if (!parent->children.empty() && parent->children.back().isText()) {
            parent->children.back().text.append(text);
        } else {
            XmlNode node;
            node.text = std::string(text);
            parent->children.push_back(std::move(node));
        }
    };
    while (i < s.size() && stack.size() < 400) {
        size_t lt = s.find('<', i);
        if (lt == std::string_view::npos) {
            appendText(s.substr(i));
            break;
        }
        appendText(s.substr(i, lt - i));
        if (s.compare(lt, 4, "<!--") == 0) {
            size_t close = s.find("-->", lt + 4);
            i = close == std::string_view::npos ? s.size() : close + 3;
            continue;
        }
        if (s.compare(lt, 9, "<![CDATA[") == 0) {
            size_t close = s.find("]]>", lt + 9);
            size_t stop = close == std::string_view::npos ? s.size() : close;
            appendText(s.substr(lt + 9, stop - lt - 9));
            i = close == std::string_view::npos ? s.size() : close + 3;
            continue;
        }
        if (lt + 1 < s.size() && (s[lt + 1] == '?' || s[lt + 1] == '!')) {
            size_t close = s.find('>', lt);
            i = close == std::string_view::npos ? s.size() : close + 1;
            continue;
        }
        if (lt + 1 < s.size() && s[lt + 1] == '/') {
            size_t close = s.find('>', lt);
            std::string name = lowercased(trim(std::string(s.substr(lt + 2, (close == std::string_view::npos ? s.size() : close) - lt - 2))));
            // Pop to the matching element; an unmatched end tag is ignored.
            for (size_t k = stack.size(); k-- > 1;) {
                if (stack[k]->name == name) {
                    stack.resize(k);
                    break;
                }
            }
            i = close == std::string_view::npos ? s.size() : close + 1;
            continue;
        }
        // A start tag.
        size_t j = lt + 1;
        size_t nameStart = j;
        while (j < s.size() && !isspace((unsigned char)s[j]) && s[j] != '>' && s[j] != '/') ++j;
        if (j == nameStart) {
            appendText("<");
            i = lt + 1;
            continue;
        }
        XmlNode node;
        node.name = lowercased(std::string(s.substr(nameStart, j - nameStart)));
        bool selfClosing = false;
        while (j < s.size()) {
            while (j < s.size() && isspace((unsigned char)s[j])) ++j;
            if (j >= s.size()) break;
            if (s[j] == '>') {
                ++j;
                break;
            }
            if (s[j] == '/') {
                selfClosing = true;
                ++j;
                continue;
            }
            size_t keyStart = j;
            while (j < s.size() && !isspace((unsigned char)s[j]) && s[j] != '=' && s[j] != '>' && s[j] != '/') ++j;
            std::string key = lowercased(std::string(s.substr(keyStart, j - keyStart)));
            while (j < s.size() && isspace((unsigned char)s[j])) ++j;
            std::string value;
            if (j < s.size() && s[j] == '=') {
                ++j;
                while (j < s.size() && isspace((unsigned char)s[j])) ++j;
                if (j < s.size() && (s[j] == '"' || s[j] == '\'')) {
                    char quote = s[j++];
                    size_t close = s.find(quote, j);
                    if (close == std::string_view::npos) close = s.size();
                    value = std::string(s.substr(j, close - j));
                    j = close + 1;
                } else {
                    size_t valueStart = j;
                    while (j < s.size() && !isspace((unsigned char)s[j]) && s[j] != '>') ++j;
                    value = std::string(s.substr(valueStart, j - valueStart));
                }
            }
            if (!key.empty()) node.attributes.emplace_back(key, EPUBRenderer::decodeEntities(value));
        }
        i = j;
        static const std::set<std::string> voids = {"br", "img", "hr", "meta", "link", "input", "image", "col", "source"};
        bool isVoid = selfClosing || voids.count(node.localName());
        std::string name = node.name;
        stack.back()->children.push_back(std::move(node));
        XmlNode* added = &stack.back()->children.back();
        if (isVoid) continue;
        if (name == "script" || name == "style") {
            // Raw text up to the closing tag.
            std::string closing = "</" + name;
            size_t close = i;
            while (true) {
                close = s.find('<', close);
                if (close == std::string_view::npos || lowercased(std::string(s.substr(close, closing.size()))) == closing) break;
                ++close;
            }
            size_t stop = close == std::string_view::npos ? s.size() : close;
            size_t gt = close == std::string_view::npos ? s.size() : s.find('>', close);
            i = gt == std::string_view::npos ? s.size() : gt + 1;
            (void)stop;
            continue;
        }
        stack.push_back(added);
    }
    return root;
}

// ── EPUBBook ───────────────────────────────────────────────────────────────

namespace {
const char kUntitled[] = "\x01chapter ";

std::string percentDecode(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size() && isxdigit((unsigned char)s[i + 1]) && isxdigit((unsigned char)s[i + 2])) {
            out.push_back((char)std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else {
            out.push_back(s[i]);
        }
    }
    return out;
}
}  // namespace

std::string EPUBBook::directory(const std::string& path) {
    size_t slash = path.rfind('/');
    return slash == std::string::npos ? "" : path.substr(0, slash);
}

std::string EPUBBook::stripFragment(const std::string& href) {
    size_t hash = href.find('#');
    return hash == std::string::npos ? href : href.substr(0, hash);
}

std::string EPUBBook::resolve(const std::string& href, const std::string& dir) {
    std::string decoded = percentDecode(href);
    if (startsWith(decoded, "/")) return decoded.substr(1);
    std::vector<std::string> components = dir.empty() ? std::vector<std::string>{} : split(dir, '/');
    for (auto& part : split(decoded, '/', true)) {
        if (part.empty() || part == ".") continue;
        if (part == "..") {
            if (!components.empty()) components.pop_back();
        } else {
            components.push_back(part);
        }
    }
    return join(components, "/");
}

std::string EPUBBook::displayTitle(const std::string& title) {
    if (!startsWith(title, kUntitled)) return title;
    return "Chapter " + title.substr(strlen(kUntitled));
}

std::unique_ptr<EPUBBook> EPUBBook::open(const std::wstring& path) {
    auto archive = ZipArchive::open(path);
    if (!archive) return nullptr;
    auto containerData = archive->data("META-INF/container.xml");
    if (!containerData) return nullptr;
    XmlNode container = parseXml(*containerData);
    const XmlNode* rootfile = container.find("rootfile");
    auto opfPath = rootfile ? rootfile->attribute("full-path") : std::nullopt;
    if (!opfPath || opfPath->empty()) return nullptr;
    auto opfData = archive->data(*opfPath);
    if (!opfData) return nullptr;
    XmlNode package = parseXml(*opfData);

    auto book = std::unique_ptr<EPUBBook>(new EPUBBook());
    book->packageDirectory = directory(*opfPath);
    const std::string& base = book->packageDirectory;
    const XmlNode* titleNode = package.find("title");
    book->title = titleNode ? trim(titleNode->textContent()) : "";
    if (book->title.empty()) book->title = lastPathComponent(*opfPath);
    if (const XmlNode* creator = package.find("creator")) {
        std::string author = trim(creator->textContent());
        if (!author.empty()) book->author = author;
    }

    std::map<std::string, std::string> hrefByID;
    std::optional<std::string> navigationID;
    std::vector<const XmlNode*> items;
    package.findAll("item", items);
    for (auto* item : items) {
        auto id = item->attribute("id");
        auto href = item->attribute("href");
        if (!id || !href) continue;
        hrefByID[*id] = resolve(*href, base);
        if (auto properties = item->attribute("properties")) {
            for (auto& p : split(*properties, ' ')) {
                if (p == "nav") navigationID = *id;
            }
        }
    }
    std::optional<std::string> tocID;
    if (const XmlNode* spine = package.find("spine")) tocID = spine->attribute("toc");
    std::map<std::string, int> spineIndexByPath;
    std::vector<const XmlNode*> itemrefs;
    package.findAll("itemref", itemrefs);
    for (auto* itemref : itemrefs) {
        auto idref = itemref->attribute("idref");
        if (!idref) continue;
        auto hit = hrefByID.find(*idref);
        if (hit == hrefByID.end() || !archive->contains(hit->second)) continue;
        spineIndexByPath[hit->second] = (int)book->chapters.size();
        book->chapters.push_back({*idref, hit->second, std::string(kUntitled) + std::to_string(book->chapters.size() + 1)});
    }
    if (book->chapters.empty()) return nullptr;

    std::vector<TOCEntry> entries;
    // EPUB 3's navigation document first.
    if (navigationID && hrefByID.count(*navigationID)) {
        std::string navPath = hrefByID[*navigationID];
        if (auto navData = archive->data(navPath)) {
            XmlNode nav = parseXml(*navData);
            std::vector<const XmlNode*> navs;
            nav.findAll("nav", navs);
            const XmlNode* toc = nullptr;
            for (auto* n : navs) {
                auto type = n->attribute("epub:type");
                if (!type) type = n->attribute("type");
                if (type && type->find("toc") != std::string::npos) {
                    toc = n;
                    break;
                }
            }
            if (!toc && !navs.empty()) toc = navs.front();
            std::string navBase = directory(navPath);
            std::function<void(const XmlNode&, int)> walk = [&](const XmlNode& list, int level) {
                for (auto& item : list.children) {
                    if (item.localName() != "li") continue;
                    for (auto& child : item.children) {
                        if (child.localName() != "a") continue;
                        auto href = child.attribute("href");
                        if (!href) continue;
                        auto index = spineIndexByPath.find(resolve(stripFragment(*href), navBase));
                        std::string label = trim(child.textContent());
                        if (index != spineIndexByPath.end() && !label.empty()) {
                            entries.push_back({label, level, index->second});
                        }
                        break;
                    }
                    for (auto& nested : item.children) {
                        if (nested.localName() == "ol" || nested.localName() == "ul") walk(nested, level + 1);
                    }
                }
            };
            if (toc) {
                for (auto& list : toc->children) {
                    if (list.localName() == "ol" || list.localName() == "ul") walk(list, 0);
                }
            }
        }
    }
    // Then EPUB 2's NCX.
    if (entries.empty() && tocID && hrefByID.count(*tocID)) {
        std::string ncxPath = hrefByID[*tocID];
        if (auto ncxData = archive->data(ncxPath)) {
            XmlNode ncx = parseXml(*ncxData);
            std::string ncxBase = directory(ncxPath);
            std::function<void(const XmlNode&, int)> walk = [&](const XmlNode& parent, int level) {
                for (auto& point : parent.children) {
                    if (!endsWith(point.localName(), "navpoint")) continue;
                    std::string label;
                    std::optional<std::string> src;
                    for (auto& child : point.children) {
                        if (child.localName() == "navlabel") {
                            if (const XmlNode* t = child.find("text")) label = trim(t->textContent());
                        } else if (child.localName() == "content") {
                            src = child.attribute("src");
                        }
                    }
                    if (!label.empty() && src) {
                        auto index = spineIndexByPath.find(resolve(stripFragment(*src), ncxBase));
                        if (index != spineIndexByPath.end()) entries.push_back({label, level, index->second});
                    }
                    walk(point, level + 1);
                }
            };
            if (const XmlNode* map = ncx.find("navmap")) walk(*map, 0);
        }
    }
    // Spine entries are named after the contents where the two line up.
    for (auto& entry : entries) {
        if (entry.chapterIndex < 0 || entry.chapterIndex >= (int)book->chapters.size()) continue;
        auto& chapter = book->chapters[entry.chapterIndex];
        if (startsWith(chapter.title, kUntitled)) chapter.title = entry.title;
    }
    if (entries.empty()) {
        for (size_t i = 0; i < book->chapters.size(); ++i) entries.push_back({book->chapters[i].title, 0, (int)i});
    }
    book->contents = entries;
    book->archive_ = std::move(archive);
    return book;
}

// ── EPUBRenderer ───────────────────────────────────────────────────────────

namespace EPUBRenderer {

float bodySize() { return Theme::uiFont(13).size(); }
float readingWidth() { return bodySize() * 34; }

std::string decodeEntities(const std::string& text) {
    if (text.find('&') == std::string::npos) return text;
    static const std::map<std::string, std::string> named = {
        {"amp", "&"}, {"lt", "<"}, {"gt", ">"}, {"quot", "\""}, {"apos", "'"}, {"nbsp", " "},
        {"mdash", "—"}, {"ndash", "–"}, {"hellip", "…"}, {"lsquo", "‘"}, {"rsquo", "’"},
        {"ldquo", "“"}, {"rdquo", "”"}, {"bull", "•"}, {"middot", "·"}, {"times", "×"},
        {"copy", "©"}, {"reg", "®"}, {"trade", "™"}, {"deg", "°"}, {"shy", "­"}, {"laquo", "«"},
        {"raquo", "»"}, {"eacute", "é"}, {"egrave", "è"}, {"agrave", "à"}, {"ccedil", "ç"}, {"uuml", "ü"},
        {"ouml", "ö"}, {"auml", "ä"}, {"szlig", "ß"}, {"ntilde", "ñ"}, {"frac12", "½"}, {"frac14", "¼"},
        {"pound", "£"}, {"euro", "€"}, {"ensp", " "}, {"emsp", " "}, {"thinsp", " "},
        {"sbquo", "‚"}, {"bdquo", "„"}, {"dagger", "†"}, {"Dagger", "‡"}, {"permil", "‰"}, {"lsaquo", "‹"},
        {"rsaquo", "›"}, {"prime", "′"}, {"Prime", "″"}, {"oline", "‾"}, {"frasl", "⁄"}, {"minus", "−"},
        {"divide", "÷"}, {"plusmn", "±"}, {"sup2", "²"}, {"sup3", "³"}, {"sup1", "¹"}, {"frac34", "¾"},
        {"micro", "µ"}, {"para", "¶"}, {"sect", "§"}, {"cent", "¢"}, {"yen", "¥"}, {"curren", "¤"},
        {"brvbar", "¦"}, {"uml", "¨"}, {"ordf", "ª"}, {"not", "¬"}, {"macr", "¯"}, {"acute", "´"},
        {"cedil", "¸"}, {"ordm", "º"}, {"iquest", "¿"}, {"iexcl", "¡"}, {"hearts", "♥"}, {"larr", "←"},
        {"uarr", "↑"}, {"rarr", "→"}, {"darr", "↓"}, {"harr", "↔"}, {"Agrave", "À"}, {"Aacute", "Á"},
        {"Acirc", "Â"}, {"Atilde", "Ã"}, {"Auml", "Ä"}, {"Aring", "Å"}, {"AElig", "Æ"}, {"Ccedil", "Ç"},
        {"Egrave", "È"}, {"Eacute", "É"}, {"Ecirc", "Ê"}, {"Euml", "Ë"}, {"Igrave", "Ì"}, {"Iacute", "Í"},
        {"Icirc", "Î"}, {"Iuml", "Ï"}, {"ETH", "Ð"}, {"Ntilde", "Ñ"}, {"Ograve", "Ò"}, {"Oacute", "Ó"},
        {"Ocirc", "Ô"}, {"Otilde", "Õ"}, {"Ouml", "Ö"}, {"Oslash", "Ø"}, {"Ugrave", "Ù"}, {"Uacute", "Ú"},
        {"Ucirc", "Û"}, {"Uuml", "Ü"}, {"Yacute", "Ý"}, {"THORN", "Þ"}, {"aacute", "á"}, {"acirc", "â"},
        {"atilde", "ã"}, {"aring", "å"}, {"aelig", "æ"}, {"ecirc", "ê"}, {"euml", "ë"}, {"igrave", "ì"},
        {"iacute", "í"}, {"icirc", "î"}, {"iuml", "ï"}, {"eth", "ð"}, {"ograve", "ò"}, {"oacute", "ó"},
        {"ocirc", "ô"}, {"otilde", "õ"}, {"oslash", "ø"}, {"ugrave", "ù"}, {"uacute", "ú"}, {"ucirc", "û"},
        {"yacute", "ý"}, {"thorn", "þ"}, {"yuml", "ÿ"},
    };
    std::string out;
    size_t i = 0;
    while (i < text.size()) {
        size_t amp = text.find('&', i);
        if (amp == std::string::npos) {
            out.append(text, i, std::string::npos);
            break;
        }
        out.append(text, i, amp - i);
        size_t semi = text.find(';', amp + 1);
        if (semi == std::string::npos || semi - amp - 1 > 10) {
            out.push_back('&');
            i = amp + 1;
            continue;
        }
        std::string name = text.substr(amp + 1, semi - amp - 1);
        auto hit = named.find(name);
        if (hit != named.end()) {
            out += hit->second;
            i = semi + 1;
            continue;
        }
        if (startsWith(name, "#")) {
            try {
                unsigned long value = (name.size() > 1 && (name[1] == 'x' || name[1] == 'X'))
                    ? std::stoul(name.substr(2), nullptr, 16) : std::stoul(name.substr(1));
                if (value > 0 && value <= 0x10FFFF && !(value >= 0xD800 && value <= 0xDFFF)) {
                    std::wstring wide;
                    if (value >= 0x10000) {
                        value -= 0x10000;
                        wide.push_back((wchar_t)(0xD800 + (value >> 10)));
                        wide.push_back((wchar_t)(0xDC00 + (value & 0x3FF)));
                    } else {
                        wide.push_back((wchar_t)value);
                    }
                    out += U(wide);
                    i = semi + 1;
                    continue;
                }
            } catch (...) {
            }
        }
        out.push_back('&');
        i = amp + 1;
    }
    return out;
}

namespace {

struct Inline {
    bool bold = false, italic = false, monospace = false, preformatted = false;
    Color color = Theme::foreground;
    std::string link;
    float sizeScale = 1;
};

struct ListState {
    bool ordered;
    int depth;
    int index;
};

bool isSpaceUTF8(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }

class Builder {
public:
    Builder(const std::string& dir, const EPUBBook& book) : directory_(dir), book_(book) {}
    EPUBChapter out;

    void walk(const std::vector<XmlNode>& nodes, const Inline& inl, std::optional<ListState>& list) {
        for (auto& node : nodes) {
            if (node.isText()) {
                std::string decoded = decodeEntities(node.text);
                append(inl.preformatted ? decoded : collapse(decoded), inl);
            } else {
                element(node, inl, list);
            }
        }
    }

    void finish() { closeBlock(); }

private:
    EPUBBlock defaultBlock() const {
        EPUBBlock b;
        b.fontSize = bodySize();
        b.spacing = bodySize() * 0.75f;
        return b;
    }

    std::string collapse(const std::string& text) {
        std::string output;
        bool inWhitespace = endsWithWhitespace_;
        for (unsigned char c : text) {
            if (isSpaceUTF8(c)) {
                if (!inWhitespace) output.push_back(' ');
                inWhitespace = true;
            } else {
                output.push_back((char)c);
                inWhitespace = false;
            }
        }
        return output;
    }

    void openBlock(EPUBBlock block) {
        block.indent += inheritedIndent_;
        closeBlock();
        current_ = block;
        endsWithWhitespace_ = true;
    }

    void closeBlock() {
        if (!current_) return;
        bool hasContent = current_->kind == EPUBBlock::Kind::Image;
        for (auto& run : current_->runs) hasContent = hasContent || !run.text.empty();
        if (hasContent) {
            // A trailing space at the end of a paragraph is not drawn.
            if (!current_->runs.empty()) {
                auto& last = current_->runs.back().text;
                while (!last.empty() && last.back() == L' ') last.pop_back();
            }
            out.blocks.push_back(*current_);
        }
        current_.reset();
    }

    void append(const std::string& string, const Inline& inl) {
        if (string.empty()) return;
        if (!current_) openBlock(defaultBlock());
        EPUBRun run;
        run.text = W(string);
        run.bold = inl.bold;
        run.italic = inl.italic;
        run.monospace = inl.monospace;
        run.sizeScale = inl.sizeScale;
        run.color = inl.link.empty() ? inl.color : Theme::blue;
        run.link = inl.link;
        current_->runs.push_back(std::move(run));
        endsWithWhitespace_ = isSpaceUTF8((unsigned char)string.back());
    }

    void element(const XmlNode& node, const Inline& inl, std::optional<ListState>& list) {
        std::string tag = node.localName();
        if (auto id = node.attribute("id")) {
            if (!out.anchors.count(*id)) out.anchors[*id] = out.blocks.size();
        } else if (auto name = node.attribute("name")) {
            if (!out.anchors.count(*name)) out.anchors[*name] = out.blocks.size();
        }
        if (tag == "script" || tag == "style" || tag == "head" || tag == "title" || tag == "meta" || tag == "link"
            || tag == "svg") {
            return;
        }
        float body = bodySize();
        if (tag.size() == 2 && tag[0] == 'h' && tag[1] >= '1' && tag[1] <= '6') {
            int level = tag[1] - '0';
            static const float scales[] = {1.0f, 1.6f, 1.42f, 1.28f, 1.16f, 1.08f, 1.0f};
            EPUBBlock block;
            block.fontSize = body * scales[level];
            block.spacing = body * (level <= 2 ? 1.8f : 1.3f);
            block.heading = true;
            openBlock(block);
            Inline inner = inl;
            inner.bold = true;
            std::optional<ListState> none;
            walk(node.children, inner, none);
            closeBlock();
        } else if (tag == "p" || tag == "div" || tag == "section" || tag == "article" || tag == "header"
                   || tag == "footer" || tag == "main" || tag == "figcaption" || tag == "dd" || tag == "dt") {
            openBlock(defaultBlock());
            walk(node.children, inl, list);
            closeBlock();
        } else if (tag == "blockquote") {
            float outer = inheritedIndent_;
            inheritedIndent_ += body * 1.6f;
            openBlock(defaultBlock());
            Inline inner = inl;
            inner.italic = true;
            inner.color = Theme::dimText;
            walk(node.children, inner, list);
            closeBlock();
            inheritedIndent_ = outer;
        } else if (tag == "pre") {
            EPUBBlock block = defaultBlock();
            block.indent = body;
            openBlock(block);
            Inline inner = inl;
            inner.preformatted = true;
            inner.monospace = true;
            walk(node.children, inner, list);
            closeBlock();
        } else if (tag == "ul" || tag == "ol") {
            std::optional<ListState> nested = ListState{tag == "ol", (list ? list->depth : -1) + 1, 1};
            walk(node.children, inl, nested);
        } else if (tag == "li") {
            EPUBBlock block = defaultBlock();
            float step = body * 1.4f;
            block.indent = step * ((list ? list->depth : 0) + 1);
            block.spacing = body * 0.35f;
            openBlock(block);
            Inline marker = inl;
            marker.color = Theme::dimText;
            append(list && list->ordered ? std::to_string(list->index) + ". " : "• ", marker);
            float outer = inheritedIndent_;
            inheritedIndent_ = block.indent;
            walk(node.children, inl, list);
            closeBlock();
            inheritedIndent_ = outer;
            if (list) list->index += 1;
        } else if (tag == "br") {
            append("\n", inl);
            endsWithWhitespace_ = true;
        } else if (tag == "hr") {
            EPUBBlock block = defaultBlock();
            block.centered = true;
            openBlock(block);
            Inline rule = inl;
            rule.color = Theme::dimText;
            append("* * *", rule);
            closeBlock();
        } else if (tag == "img" || tag == "image") {
            auto src = node.attribute("src");
            if (!src) src = node.attribute("xlink:href");
            if (!src) src = node.attribute("href");
            image(src, node.attribute("alt"), inl);
        } else if (tag == "tr") {
            openBlock(defaultBlock());
            walk(node.children, inl, list);
            closeBlock();
        } else if (tag == "td" || tag == "th") {
            Inline inner = inl;
            inner.bold = inl.bold || tag == "th";
            walk(node.children, inner, list);
            append("  ", inl);
        } else if (tag == "a") {
            Inline inner = inl;
            if (auto href = node.attribute("href")) inner.link = linkFor(*href);
            walk(node.children, inner, list);
        } else if (tag == "em" || tag == "i" || tag == "cite" || tag == "var" || tag == "dfn") {
            Inline inner = inl;
            inner.italic = true;
            walk(node.children, inner, list);
        } else if (tag == "strong" || tag == "b") {
            Inline inner = inl;
            inner.bold = true;
            walk(node.children, inner, list);
        } else if (tag == "code" || tag == "kbd" || tag == "samp" || tag == "tt") {
            Inline inner = inl;
            inner.monospace = true;
            walk(node.children, inner, list);
        } else if (tag == "small" || tag == "sup" || tag == "sub") {
            Inline inner = inl;
            inner.sizeScale = 0.8f;
            walk(node.children, inner, list);
        } else {
            walk(node.children, inl, list);
        }
    }

    void image(const std::optional<std::string>& href, const std::optional<std::string>& alt, const Inline& inl) {
        if (!href || href->empty()) return;
        std::string path = EPUBBook::resolve(EPUBBook::stripFragment(*href), directory_);
        if (!book_.data(path)) {
            if (alt && !alt->empty()) {
                Inline caption = inl;
                caption.color = Theme::dimText;
                caption.italic = true;
                openBlock(defaultBlock());
                append(*alt, caption);
                closeBlock();
            }
            return;
        }
        EPUBBlock block = defaultBlock();
        block.kind = EPUBBlock::Kind::Image;
        block.centered = true;
        block.imagePath = path;
        openBlock(block);
        closeBlock();
    }

    std::string linkFor(const std::string& href) {
        if (startsWith(href, "#")) return href;
        size_t colon = href.find(':');
        if (colon != std::string::npos && colon > 1 && href.find('/') > colon && !startsWith(lowercased(href), "file:")) {
            return href;  // absolute: the browser's business
        }
        std::string path = EPUBBook::resolve(EPUBBook::stripFragment(href), directory_);
        if (path.empty()) return "";
        size_t hash = href.find('#');
        return "epub:" + path + (hash == std::string::npos ? "" : href.substr(hash));
    }

    std::string directory_;
    const EPUBBook& book_;
    std::optional<EPUBBlock> current_;
    bool endsWithWhitespace_ = true;
    float inheritedIndent_ = 0;
};

}  // namespace

EPUBChapter render(const std::string& xhtml, const std::string& chapterPath, const EPUBBook& book) {
    std::string source = isValidUTF8(xhtml) ? xhtml : latin1ToUTF8(xhtml);
    XmlNode root = parseXml(source);
    Builder builder(EPUBBook::directory(chapterPath), book);
    // The body, when there is one; otherwise everything.
    const XmlNode* body = root.find("body");
    std::optional<ListState> none;
    builder.walk(body ? body->children : root.children, Inline(), none);
    builder.finish();
    return builder.out;
}

}  // namespace EPUBRenderer

// ── The reader ─────────────────────────────────────────────────────────────

namespace {
constexpr float kReaderHeader = 30;
constexpr float kContentsWidth = 240;
constexpr wchar_t kPositionKey[] = L"PuzzleEPUBPositions";

struct StoredPosition {
    int chapter = 0;
    double scroll = 0;
};

std::optional<StoredPosition> storedPosition(const std::wstring& path) {
    for (auto& entry : Prefs::stringList(kPositionKey)) {
        // "chapter|scroll|path"
        size_t a = entry.find(L'|');
        size_t b = a == std::wstring::npos ? std::wstring::npos : entry.find(L'|', a + 1);
        if (b == std::wstring::npos) continue;
        if (!samePath(entry.substr(b + 1), path)) continue;
        return StoredPosition{_wtoi(entry.substr(0, a).c_str()), _wtof(entry.substr(a + 1, b - a - 1).c_str())};
    }
    return std::nullopt;
}
}  // namespace

class EPUBReaderView::Page : public ScrollArea {
public:
    struct Laid {
        Rect frame;
        Com<IDWriteTextLayout> layout;
        std::vector<std::pair<DWRITE_TEXT_RANGE, size_t>> runRanges;  // range → run index
        Com<IWICBitmapSource> image;
        Com<ID2D1Bitmap> bitmap;
        Size imageSize;
    };
    EPUBChapter chapter;
    const EPUBBook* book = nullptr;
    std::vector<Laid> laid;
    float laidWidth = -1;
    std::function<void(const std::string&)> onLink;

    Page() { backgroundColor = Theme::editorBackground; }

    float measure() const { return std::min(EPUBRenderer::readingWidth(), std::max(1.0f, bounds().w - 56)); }
    float inset() const { return std::max(28.0f, (bounds().w - measure()) / 2); }

    void setChapter(EPUBChapter c, const EPUBBook* b) {
        chapter = std::move(c);
        book = b;
        laid.clear();
        laidWidth = -1;
        relayout();
    }

    void relayout() {
        float width = measure();
        if (std::fabs(width - laidWidth) < 0.5f && laid.size() == chapter.blocks.size()) return;
        laidWidth = width;
        std::vector<Laid> previous = std::move(laid);
        laid.clear();
        float x0 = inset();
        float y = 28;
        for (size_t i = 0; i < chapter.blocks.size(); ++i) {
            const EPUBBlock& block = chapter.blocks[i];
            Laid item;
            if (i > 0) y += block.spacing;
            float available = std::max(1.0f, width - block.indent);
            if (block.kind == EPUBBlock::Kind::Image) {
                if (i < previous.size() && previous[i].image) {
                    item.image = previous[i].image;
                    item.imageSize = previous[i].imageSize;
                } else if (book) {
                    if (auto data = book->data(block.imagePath)) {
                        if (auto info = Imaging::probe(*data)) {
                            item.image = Imaging::decode(*data, 1600);
                            item.imageSize = Size(info->width, info->height);
                        }
                    }
                }
                float w = std::min(item.imageSize.w, width), h = item.imageSize.w > 0 ? w * item.imageSize.h / item.imageSize.w : 0;
                item.frame = Rect(x0 + (width - w) / 2, y, w, h);
                y += h;
            } else {
                std::wstring text;
                for (size_t r = 0; r < block.runs.size(); ++r) {
                    DWRITE_TEXT_RANGE range{(UINT32)text.size(), (UINT32)block.runs[r].text.size()};
                    item.runRanges.push_back({range, r});
                    text += block.runs[r].text;
                }
                Com<IDWriteTextFormat> format;
                Render::dwrite()->CreateTextFormat(Theme::uiFamily().c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                                   DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, block.fontSize, L"",
                                                   format.put());
                if (format) {
                    format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
                    if (block.centered) format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
                    Render::dwrite()->CreateTextLayout(text.c_str(), (UINT32)text.size(), format.get(), available, 100000,
                                                       item.layout.put());
                }
                if (item.layout) {
                    std::wstring mono = Theme::editorFamily();
                    for (auto& [range, r] : item.runRanges) {
                        const EPUBRun& run = block.runs[r];
                        if (run.bold) item.layout->SetFontWeight(DWRITE_FONT_WEIGHT_BOLD, range);
                        if (run.italic) item.layout->SetFontStyle(DWRITE_FONT_STYLE_ITALIC, range);
                        if (run.monospace) item.layout->SetFontFamilyName(mono.c_str(), range);
                        if (run.sizeScale != 1) item.layout->SetFontSize(block.fontSize * run.sizeScale, range);
                        if (!run.link.empty()) item.layout->SetUnderline(TRUE, range);
                    }
                    // Lines 1.45 times their natural height.
                    float natural = block.fontSize * 1.2f;
                    item.layout->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, natural * 1.45f,
                                                natural * 1.45f * 0.8f);
                    DWRITE_TEXT_METRICS metrics{};
                    item.layout->GetMetrics(&metrics);
                    item.frame = Rect(x0 + block.indent, y, available, metrics.height);
                    y += metrics.height;
                }
            }
            laid.push_back(std::move(item));
        }
        setContentSize(Size(bounds().w, y + 28));
        setNeedsDisplay();
    }

    void layout() override {
        laidWidth = -1;
        relayout();
        ScrollArea::layout();
    }

    float offsetOfBlock(size_t index) const {
        if (index >= laid.size()) return 0;
        return std::max(0.0f, laid[index].frame.y - 28);
    }

    void drawContent(Graphics& g, const Rect& visible) override {
        std::map<uint32_t, Com<ID2D1SolidColorBrush>> brushes;
        auto brushFor = [&](const Color& c) {
            uint32_t key = c.colorref();
            auto hit = brushes.find(key);
            if (hit != brushes.end()) return hit->second.get();
            Com<ID2D1SolidColorBrush> brush;
            g.context()->CreateSolidColorBrush(D2D1::ColorF(c.r, c.g, c.b, c.a), brush.put());
            auto* raw = brush.get();
            brushes[key] = brush;
            return raw;
        };
        for (size_t i = 0; i < laid.size(); ++i) {
            Laid& item = laid[i];
            if (!item.frame.intersects(visible)) continue;
            if (item.image) {
                if (!item.bitmap) item.bitmap = Imaging::bitmap(g.context(), item.image.get());
                if (item.bitmap) g.drawBitmap(item.bitmap.get(), item.frame);
                continue;
            }
            if (!item.layout) continue;
            const EPUBBlock& block = chapter.blocks[i];
            for (auto& [range, r] : item.runRanges) item.layout->SetDrawingEffect(brushFor(block.runs[r].color), range);
            Point o = g.offset();
            (void)o;
            g.context()->DrawTextLayout(D2D1::Point2F(item.frame.x, item.frame.y), item.layout.get(),
                                        brushFor(Theme::foreground), D2D1_DRAW_TEXT_OPTIONS_NONE);
        }
    }

    std::optional<std::string> linkAt(Point p) const {
        for (size_t i = 0; i < laid.size(); ++i) {
            const Laid& item = laid[i];
            if (!item.layout || !item.frame.contains(p)) continue;
            BOOL trailing = FALSE, inside = FALSE;
            DWRITE_HIT_TEST_METRICS metrics{};
            item.layout->HitTestPoint(p.x - item.frame.x, p.y - item.frame.y, &trailing, &inside, &metrics);
            if (!inside) return std::nullopt;
            for (auto& [range, r] : item.runRanges) {
                if (metrics.textPosition >= range.startPosition && metrics.textPosition < range.startPosition + range.length) {
                    const std::string& link = chapter.blocks[i].runs[r].link;
                    if (!link.empty()) return link;
                }
            }
        }
        return std::nullopt;
    }

    bool contentMouseDown(const MouseEvent&, Point p) override {
        if (auto link = linkAt(p)) {
            if (onLink) onLink(*link);
            return true;
        }
        return false;
    }

    Cursor cursorAt(Point p) override { return linkAt(toContent(p)) ? Cursor::Hand : Cursor::Arrow; }
};

EPUBReaderView::EPUBReaderView() : page_(std::make_unique<Page>()) {
    backgroundColor = Theme::editorBackground;
    auto configure = [this](SymbolButton& b, Symbol symbol, const wchar_t* tip, std::function<void()> action) {
        b.symbol = symbol;
        b.symbolSize = 11;
        b.weight = 1.1f;
        b.tint = Theme::dimText;
        b.hoverBackground = true;
        b.tooltip = tip;
        b.onClick = std::move(action);
        addSubview(&b);
    };
    configure(contentsButton_, Symbol::MenuLines, L"Contents", [this] { setContentsVisible(!showsContents_); });
    configure(previousButton_, Symbol::ChevronLeft, L"Previous chapter", [this] {
        if (chapterIndex_ > 0) load(chapterIndex_ - 1);
    });
    configure(nextButton_, Symbol::ChevronRight, L"Next chapter", [this] {
        if (book_ && chapterIndex_ + 1 < (int)book_->chapters.size()) load(chapterIndex_ + 1);
    });
    contents_.backgroundColor = Theme::panelBackground;
    contents_.rowHeight = std::max(24.0f, Theme::treeRowHeight());
    contents_.numberOfRows = [this] { return book_ ? (int)book_->contents.size() : 0; };
    contents_.rowBackground = [this](int row) {
        return row == contents_.selectedRow() ? Theme::selectedControl : Theme::panelBackground;
    };
    contents_.drawRow = [this](Graphics& g, int row, const Rect& rect) {
        if (!book_ || row >= (int)book_->contents.size()) return;
        const auto& entry = book_->contents[row];
        float x = rect.x + 10 + entry.level * 14;
        bool top = entry.level == 0;
        g.text(W(EPUBBook::displayTitle(entry.title)), Theme::uiFont(top ? 11.5f : 11),
               top ? Theme::foreground : Theme::dimText, Rect(x, rect.y, std::max(0.0f, rect.maxX() - 8 - x), rect.h));
    };
    contents_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (!book_ || row >= (int)book_->contents.size()) return L"";
        return W(EPUBBook::displayTitle(book_->contents[row].title));
    };
    contents_.onClick = [this](int row) {
        if (book_ && row >= 0 && row < (int)book_->contents.size()) load(book_->contents[row].chapterIndex);
    };
    addSubview(&contents_);
    page_->onLink = [this](const std::string& link) { openLink(link); };
    page_->onScroll = [this] {};
    addSubview(page_.get());
}

EPUBReaderView::~EPUBReaderView() { clear(); }

void EPUBReaderView::layout() {
    Rect b = bounds();
    float y = std::floor((kReaderHeader - 22) / 2);
    contentsButton_.setFrame(Rect(6, y, 28, 22));
    nextButton_.setFrame(Rect(b.w - 28 - 6, y, 28, 22));
    previousButton_.setFrame(Rect(nextButton_.frame().x - 28, y, 28, 22));
    float left = showsContents_ ? kContentsWidth : 0;
    contents_.setHidden(!showsContents_);
    contents_.setFrame(Rect(0, kReaderHeader, kContentsWidth, std::max(0.0f, b.h - kReaderHeader)));
    page_->setFrame(Rect(left, kReaderHeader, std::max(0.0f, b.w - left), std::max(0.0f, b.h - kReaderHeader)));
}

void EPUBReaderView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(Rect(0, 0, b.w, kReaderHeader), Theme::barBackground);
    g.fillRect(Rect(0, kReaderHeader - 1, b.w, 1), Theme::border);
    float left = contentsButton_.frame().maxX() + 8;
    float right = previousButton_.frame().x - 8;
    float positionWidth = 78;
    g.text(title_, Theme::uiFont(11.5f), Theme::foreground,
           Rect(left, 0, std::max(0.0f, right - left - positionWidth - 8), kReaderHeader));
    g.text(position_, Theme::uiFont(10.5f), Theme::dimText,
           Rect(std::max(left, right - positionWidth), 0, positionWidth, kReaderHeader), LineBreak::Clipping, Align::Right);
}

bool EPUBReaderView::show(const std::wstring& path) {
    if (samePath(path_, path) && book_) return true;
    auto book = EPUBBook::open(path);
    if (!book) return false;
    clear();
    book_ = std::move(book);
    path_ = path;
    title_ = W(book_->title);
    if (book_->author) title_ += L"  ·  " + W(*book_->author);
    tooltip = title_;
    contents_.reloadData();
    int chapter = 0;
    if (auto stored = storedPosition(path)) chapter = stored->chapter;
    load(std::clamp(chapter, 0, (int)book_->chapters.size() - 1), true);
    return true;
}

void EPUBReaderView::clear() {
    rememberPosition();
    page_->setChapter(EPUBChapter(), nullptr);
    book_.reset();
    path_.clear();
    title_.clear();
    position_.clear();
    chapterIndex_ = 0;
    contents_.reloadData();
    setNeedsDisplay();
}

void EPUBReaderView::refreshFonts() {
    contents_.rowHeight = std::max(24.0f, Theme::treeRowHeight());
    contents_.reloadData();
    // Fonts are baked into the laid-out chapter: build it again.
    if (book_) load(chapterIndex_, true);
    setNeedsDisplay();
}

void EPUBReaderView::setContentsVisible(bool visible) {
    showsContents_ = visible;
    setNeedsLayout();
}

void EPUBReaderView::load(int index, bool restoringScroll, const std::string& anchor) {
    if (!book_ || index < 0 || index >= (int)book_->chapters.size()) return;
    chapterIndex_ = index;
    const auto& chapter = book_->chapters[index];
    EPUBChapter rendered;
    if (auto data = book_->data(chapter.path)) {
        rendered = EPUBRenderer::render(*data, chapter.path, *book_);
    } else {
        EPUBBlock block;
        block.fontSize = EPUBRenderer::bodySize();
        EPUBRun run;
        run.text = L"This chapter could not be read from the book.";
        run.color = Theme::dimText;
        block.runs.push_back(run);
        rendered.blocks.push_back(block);
    }
    auto anchors = rendered.anchors;
    page_->setChapter(std::move(rendered), book_.get());
    page_->layoutSubtreeIfNeeded();
    page_->relayout();
    position_ = std::to_wstring(index + 1) + L" / " + std::to_wstring(book_->chapters.size());
    previousButton_.setEnabled(index > 0);
    nextButton_.setEnabled(index + 1 < (int)book_->chapters.size());
    int row = -1;
    for (int i = 0; i < (int)book_->contents.size(); ++i) {
        if (book_->contents[i].chapterIndex == index) row = i;
    }
    contents_.setSelectedRow(row, row >= 0);
    auto hit = anchor.empty() ? anchors.end() : anchors.find(anchor);
    if (hit != anchors.end()) {
        page_->setContentOffset(Point(0, page_->offsetOfBlock(hit->second)));
    } else if (restoringScroll) {
        auto stored = storedPosition(path_);
        Point limit = page_->maximumOffset();
        page_->setContentOffset(Point(0, stored ? (float)(limit.y * stored->scroll) : 0));
    } else {
        page_->setContentOffset(Point(0, 0));
    }
    rememberPosition();
    setNeedsDisplay();
}

void EPUBReaderView::rememberPosition() {
    if (!book_ || path_.empty()) return;
    Point limit = page_->maximumOffset();
    double fraction = limit.y > 0 ? std::clamp(page_->contentOffset().y / limit.y, 0.0f, 1.0f) : 0;
    std::vector<std::wstring> kept;
    for (auto& entry : Prefs::stringList(kPositionKey)) {
        size_t a = entry.find(L'|');
        size_t b = a == std::wstring::npos ? std::wstring::npos : entry.find(L'|', a + 1);
        if (b != std::wstring::npos && samePath(entry.substr(b + 1), path_)) continue;
        kept.push_back(entry);
    }
    wchar_t scroll[32];
    swprintf(scroll, 32, L"%.4f", fraction);
    kept.push_back(std::to_wstring(chapterIndex_) + L"|" + scroll + L"|" + path_);
    while (kept.size() > 200) kept.erase(kept.begin());
    Prefs::setStringList(kPositionKey, kept);
}

void EPUBReaderView::openLink(const std::string& link) {
    if (startsWith(link, "#")) {
        auto& anchors = page_->chapter.anchors;
        auto hit = anchors.find(link.substr(1));
        if (hit != anchors.end()) page_->setContentOffset(Point(0, page_->offsetOfBlock(hit->second)), true);
        return;
    }
    if (startsWith(link, "epub:")) {
        std::string rest = link.substr(5);
        size_t hash = rest.find('#');
        std::string path = hash == std::string::npos ? rest : rest.substr(0, hash);
        std::string fragment = hash == std::string::npos ? "" : rest.substr(hash + 1);
        if (!book_) return;
        for (size_t i = 0; i < book_->chapters.size(); ++i) {
            if (book_->chapters[i].path == path) {
                load((int)i, false, fragment);
                return;
            }
        }
        return;
    }
    // An outward link is the browser's business.
    ShellExecuteW(nullptr, L"open", W(link).c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}
